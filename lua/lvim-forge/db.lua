-- lvim-forge.db: the local SQLite cache — Forge's defining feature. Every tracked repository's
-- topics (issues + pull requests), posts, reviews, threads, labels, milestones, participants and
-- notifications live here, so the UI renders INSTANTLY and works OFFLINE; an explicit `pull`
-- (the sync engine, a later phase) reconciles this cache with the forge API, and mutations upsert
-- their API response back into it. This module owns the db HANDLE, the schema (v1 below), the
-- versioned migrations, every upsert the sync layer writes, and every query the UI reads.
--
-- Persistence goes through the set's canon — `lvim-utils.store`, backend "sqlite" (the
-- lvim-vault / lvim-control-center precedent): OWN db file under stdpath("data")/lvim-forge, OWN
-- schema, OWN `PRAGMA user_version` migrations. sqlite.lua is MANDATORY (the DB *is* the plugin);
-- health reports it via `store.health(h, true)` and setup degrades cleanly when it is absent.
--
-- Two invariants the whole layer is built around:
--   • LOCAL-preserve — a remote upsert of a topic NEVER clobbers the user's LOCAL columns
--     (`unread`, `saved_note`) or their LOCAL marks (`topic_marks`). Re-pulling the same topic from
--     a fresh API object leaves a private note + marks + read-state intact. Enforced by
--     `LOCAL_TOPIC_COLS` being stripped from every topic UPDATE, and by the remote join-set
--     replacers (`set_labels`/`set_assignees`/`set_review_requests`) touching ONLY their own remote
--     join tables, never `topic_marks`.
--   • Tokens are NEVER stored — no column and no insert path touches an auth token; auth is resolved
--     live per request (see `client/auth`).
--
-- Natural keys (the upsert dedup keys) are enforced by UNIQUE INDEXes created on open, and the
-- upsert helpers find-by-natural-key then update-or-insert (so an existing row's id is stable and
-- its local columns survive). Parent→child FKs are `on delete cascade`, so removing a repository
-- row drops all of its topics/posts/reviews/… in one delete.
--
---@module "lvim-forge.db"

local config = require("lvim-forge.config")

local M = {}

-- Bump TOGETHER with a matching `MIGRATIONS[<new version>]` step whenever the schema changes: a
-- fresh db is created at this version and stamped directly (no steps run); an older db runs
-- MIGRATIONS[old+1 .. SCHEMA_VERSION] in order (append-only from v1 — never a drop-and-recreate).
---@type integer
local SCHEMA_VERSION = 3

-- ── Schema v1 ────────────────────────────────────────────────────────────────
-- sqlite.tbl column defs: `{ "<type>", primary=, autoincrement=, required=, unique=, reference=,
-- on_delete= }`. `reference = "parent.col"` + `on_delete = "cascade"` compiles to a real FK with
-- ON DELETE CASCADE. Timestamps are ISO-8601 TEXT (as the APIs give them); booleans are 0/1
-- INTEGERs; `forge_id` is the API's global id (kept as TEXT — GitHub node ids are strings, REST
-- ids are numbers, both round-trip losslessly as text).
---@type table<string, table>
local TABLES = {
    -- A tracked repository. `tracked` = "full" | "selective" (demand-based, huge repos). The two
    -- cursors are the incremental-pull watermarks the sync engine advances.
    repositories = {
        id = { "integer", primary = true, autoincrement = true },
        forge = { "text", required = true }, -- github | gitlab | gitea | codeberg
        host = { "text", required = true },
        owner = { "text", required = true },
        name = { "text", required = true },
        remote_url = { "text" },
        default_branch = { "text" },
        is_private = { "integer" }, -- 0/1
        tracked = { "text", required = true }, -- full | selective
        topics_cursor = { "text" }, -- ISO-8601 updatedAt watermark for the topics pull
        notifications_cursor = { "text" },
        pulled_at = { "text" }, -- ISO-8601 of the last successful pull
    },
    -- Issues + pull requests share this table (kind discriminates). `unread` + `saved_note` are
    -- LOCAL-only (never sent to the API, preserved across re-pull).
    topics = {
        id = { "integer", primary = true, autoincrement = true },
        repo_id = { "integer", required = true, reference = "repositories.id", on_delete = "cascade" },
        kind = { "text", required = true }, -- issue | pullreq
        number = { "integer", required = true },
        state = { "text" }, -- open | closed | merged
        title = { "text" },
        body = { "text" },
        author = { "text" },
        created = { "text" },
        updated = { "text" },
        closed_at = { "text" },
        locked = { "integer" }, -- 0/1
        milestone_id = { "integer" }, -- → milestones.id (soft ref; not FK — a topic may outlive a milestone row)
        unread = { "integer" }, -- LOCAL: 1 when changed since last read
        saved_note = { "text" }, -- LOCAL: a private per-topic note (forge.el feature)
        html_url = { "text" },
    },
    -- PR-only extras, 1:1 with a topic of kind = pullreq.
    pullreqs = {
        id = { "integer", primary = true, autoincrement = true },
        topic_id = { "integer", required = true, reference = "topics.id", on_delete = "cascade" },
        base_ref = { "text" },
        head_ref = { "text" },
        head_repo = { "text" }, -- owner/name of the head repo (a fork when != base)
        head_sha = { "text" },
        draft = { "integer" }, -- 0/1
        mergeable = { "integer" }, -- 0/1 (nil when the forge has not computed it)
        merged_by = { "text" },
        additions = { "integer" },
        deletions = { "integer" },
        changed_files = { "integer" },
        commits = { "integer" },
        review_decision = { "text" }, -- approved | changes_requested | review_required | nil
    },
    -- Timeline posts: issue comments, review bodies, and review (line) comments.
    posts = {
        id = { "integer", primary = true, autoincrement = true },
        topic_id = { "integer", required = true, reference = "topics.id", on_delete = "cascade" },
        forge_id = { "text" }, -- the API's comment/review-comment id
        kind = { "text" }, -- comment | review-comment | review-body
        author = { "text" },
        created = { "text" },
        updated = { "text" },
        body = { "text" },
        reply_to = { "text" }, -- the forge_id of the post this replies to
        review_id = { "text" }, -- the review this comment belongs to (review-comment/review-body); for a
        -- LOCAL pending draft it holds the pending review's local db id (as text) — see the pending model
        thread_id = { "text" }, -- the review thread this line-comment anchors to
        path = { "text" }, -- review-comment: the file
        line = { "integer" }, -- review-comment: the line (end line of a multi-line comment)
        start_line = { "integer" }, -- review-comment: the START line of a multi-line (range) comment (v3)
        side = { "text" }, -- LEFT | RIGHT
        original_line = { "integer" },
        outdated = { "integer" }, -- 0/1
        reactions = { "text" }, -- json blob (stored now, UI is a v2 idea)
    },
    -- A submitted (or pending) review header.
    reviews = {
        id = { "integer", primary = true, autoincrement = true },
        topic_id = { "integer", required = true, reference = "topics.id", on_delete = "cascade" },
        forge_id = { "text" }, -- the API review id (nil while pending/local)
        author = { "text" },
        state = { "text" }, -- approved | changes | commented | pending
        body = { "text" },
        submitted_at = { "text" },
    },
    -- A review thread (a resolvable conversation anchored to a file/line).
    threads = {
        id = { "integer", primary = true, autoincrement = true },
        topic_id = { "integer", required = true, reference = "topics.id", on_delete = "cascade" },
        forge_id = { "text" }, -- the REST root-comment id the thread is synthesized from (read phase)
        node_id = { "text" }, -- the GraphQL thread node id — the ONLY key that can resolve/unresolve (v3)
        path = { "text" },
        line = { "integer" },
        side = { "text" },
        resolved = { "integer" }, -- 0/1
        outdated = { "integer" }, -- 0/1
    },
    -- Repo labels (data-driven chip colors) + the topic⇄label join.
    labels = {
        id = { "integer", primary = true, autoincrement = true },
        repo_id = { "integer", required = true, reference = "repositories.id", on_delete = "cascade" },
        forge_id = { "text" },
        name = { "text", required = true },
        color = { "text" }, -- hex, no leading '#'
        description = { "text" },
    },
    topic_labels = {
        id = { "integer", primary = true, autoincrement = true },
        topic_id = { "integer", required = true, reference = "topics.id", on_delete = "cascade" },
        label_id = { "integer", required = true, reference = "labels.id", on_delete = "cascade" },
    },
    -- Repo milestones (feed the milestone picker offline).
    milestones = {
        id = { "integer", primary = true, autoincrement = true },
        repo_id = { "integer", required = true, reference = "repositories.id", on_delete = "cascade" },
        forge_id = { "text" },
        number = { "integer" }, -- the per-repo milestone NUMBER the "set milestone" mutation PATCHes with (v2)
        title = { "text", required = true },
        state = { "text" }, -- open | closed
        due = { "text" }, -- ISO-8601
    },
    -- Repo-scoped participants / assignable users (feed the @-mention + assignee pickers offline).
    users = {
        id = { "integer", primary = true, autoincrement = true },
        repo_id = { "integer", required = true, reference = "repositories.id", on_delete = "cascade" },
        login = { "text", required = true },
        name = { "text" },
    },
    -- Remote join tables (a remote upsert REPLACES the whole set per topic).
    topic_assignees = {
        id = { "integer", primary = true, autoincrement = true },
        topic_id = { "integer", required = true, reference = "topics.id", on_delete = "cascade" },
        user_login = { "text", required = true },
    },
    topic_review_requests = {
        id = { "integer", primary = true, autoincrement = true },
        topic_id = { "integer", required = true, reference = "topics.id", on_delete = "cascade" },
        reviewer = { "text", required = true },
    },
    -- LOCAL user-defined topic tags (forge.el marks) + the topic⇄mark join. NEVER sent to the API,
    -- NEVER cleared by a remote pull — a filter dimension the user owns.
    marks = {
        id = { "integer", primary = true, autoincrement = true },
        name = { "text", required = true, unique = true },
        color = { "text" },
    },
    topic_marks = {
        id = { "integer", primary = true, autoincrement = true },
        topic_id = { "integer", required = true, reference = "topics.id", on_delete = "cascade" },
        mark_id = { "integer", required = true, reference = "marks.id", on_delete = "cascade" },
    },
    -- The notifications inbox.
    notifications = {
        id = { "integer", primary = true, autoincrement = true },
        repo_id = { "integer", reference = "repositories.id", on_delete = "cascade" },
        topic_id = { "integer" }, -- soft ref (a notification may name a topic not yet cached)
        forge_id = { "text" }, -- the API notification (thread) id — globally unique
        reason = { "text" }, -- review_requested | mention | assign | …
        unread = { "integer" }, -- 0/1
        updated = { "text" },
        title = { "text" },
        url = { "text" },
    },
    -- The PR file set (the files section + the no-lvim-git file-list fallback).
    pr_files = {
        id = { "integer", primary = true, autoincrement = true },
        topic_id = { "integer", required = true, reference = "topics.id", on_delete = "cascade" },
        path = { "text", required = true },
        status = { "text" }, -- added | modified | removed | renamed
        additions = { "integer" },
        deletions = { "integer" },
    },
}

-- The natural-key UNIQUE INDEXes (integrity behind the find-then-upsert helpers). Created IF NOT
-- EXISTS on open — idempotent, and cheap. sqlite.tbl only supports single-column `unique`, so the
-- COMPOSITE keys (the real dedup keys) live here as indexes; this is the proper SQL mechanism, not a
-- workaround.
---@type string[]
local INDEXES = {
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_repositories ON repositories(host, owner, name)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_topics ON topics(repo_id, kind, number)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_pullreqs ON pullreqs(topic_id)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_posts ON posts(topic_id, forge_id)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_reviews ON reviews(topic_id, forge_id)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_threads ON threads(topic_id, forge_id)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_labels ON labels(repo_id, name)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_topic_labels ON topic_labels(topic_id, label_id)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_milestones ON milestones(repo_id, forge_id)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_users ON users(repo_id, login)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_topic_assignees ON topic_assignees(topic_id, user_login)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_topic_review_requests ON topic_review_requests(topic_id, reviewer)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_topic_marks ON topic_marks(topic_id, mark_id)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_notifications ON notifications(forge_id)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_pr_files ON pr_files(topic_id, path)",
}

-- PRAGMA user_version steps. Append-only from v1; each `function(db) db:exec("ALTER TABLE …") end`.
-- A fresh db is created directly at SCHEMA_VERSION (all columns present, no step); an EXISTING lower
-- db runs MIGRATIONS[old+1 .. SCHEMA_VERSION] in order (never a drop-and-recreate).
--   v2 — the "set milestone" mutation PATCHes an issue with the milestone's per-repo NUMBER, so the
--        milestones cache must carry it (v1 stored only the global forge_id + title).
--   v3 — the review WRITE layer: `threads.node_id` (the GraphQL thread node id — resolve/unresolve is
--        GraphQL-only, keyed by this id, which the REST read pass could not know) + `posts.start_line`
--        (a multi-line/range review comment's start line, needed to submit a pending draft comment).
---@type table<integer, fun(db: table)>
local MIGRATIONS = {
    [2] = function(db)
        db:exec("ALTER TABLE milestones ADD COLUMN number integer")
    end,
    [3] = function(db)
        db:exec("ALTER TABLE threads ADD COLUMN node_id text")
        db:exec("ALTER TABLE posts ADD COLUMN start_line integer")
    end,
}

-- The LOCAL topic columns a remote upsert must NEVER overwrite (the local-preserve invariant).
---@type string[]
local LOCAL_TOPIC_COLS = { "unread", "saved_note" }

---@type table?  the live store handle (lazy singleton)
local handle
---@type boolean  whether the natural-key indexes have been ensured on the current handle
local indexed = false

-- ── lifecycle ────────────────────────────────────────────────────────────────

--- Whether the sqlite backend is available (sqlite.lua installed). The DB IS the plugin — sqlite is
--- MANDATORY; there is no JSON fallback.
---@return boolean
function M.available()
    return require("lvim-utils.store").available()
end

--- The db file path: `config.database.path` when set (the test/relocate override), else
--- stdpath("data")/lvim-forge/lvim-forge.db. Normalised with vim.fs.normalize (never vim.fn.expand).
---@return string
local function db_path()
    if config.database and config.database.path and config.database.path ~= "" then
        return vim.fs.normalize(config.database.path)
    end
    return vim.fs.normalize(vim.fn.stdpath("data") .. "/lvim-forge/lvim-forge.db")
end

--- The (lazily opened) live store handle. Opens the OWN db file, stamps/migrates the schema to
--- SCHEMA_VERSION, and ensures the natural-key indexes once.
---@return table  the lvim-utils.store handle
function M.get()
    if handle then
        return handle
    end
    handle = require("lvim-utils.store").new({
        backend = "sqlite",
        name = "lvim-forge",
        path = db_path(),
        version = SCHEMA_VERSION,
        tables = TABLES,
        migrations = MIGRATIONS,
    })
    if not indexed and handle:is_open() then
        for _, sql in ipairs(INDEXES) do
            handle:exec(sql)
        end
        indexed = true
    end
    return handle
end

--- Whether the db actually opened (sqlite.lua present AND the file is writable).
---@return boolean
function M.is_open()
    return M.get():is_open()
end

--- The db file path (for :checkhealth).
---@return string?
function M.path()
    return M.get():path()
end

--- The on-disk schema version (PRAGMA user_version; for :checkhealth).
---@return integer
function M.schema_version()
    local rows = M.get():exec("PRAGMA user_version")
    if type(rows) == "table" and rows[1] and rows[1].user_version ~= nil then
        return tonumber(rows[1].user_version) or 0
    end
    return 0
end

--- Close the handle (tests / teardown). Resets the index guard so a reopen re-ensures them.
function M.close()
    if handle then
        handle:close()
        handle = nil
        indexed = false
    end
end

-- ── generic upsert (find-by-natural-key → update-or-insert) ───────────────────

--- Insert-or-update `row` into `name`, deduped on `where` (the natural key). On an existing row the
--- update set is `row` minus `preserve` (the LOCAL columns that must survive a re-pull) and the
--- stable row id is returned; a new row is inserted and its id returned.
---@param name string
---@param where table  the natural-key WHERE (equality)
---@param row table    the full column→value row
---@param preserve? string[]  columns stripped from the UPDATE set (kept from the existing row)
---@return integer? id  the row id (nil on a failed insert)
local function upsert(name, where, row, preserve)
    local s = M.get()
    local existing = s:find(name, where)
    if type(existing) == "table" and existing[1] then
        local id = existing[1].id
        local set = vim.deepcopy(row)
        if preserve then
            for _, col in ipairs(preserve) do
                set[col] = nil
            end
        end
        s:update(name, { id = id }, set)
        return id
    end
    local id = s:insert(name, row)
    return (id ~= false) and id or nil
end

-- ── repositories ──────────────────────────────────────────────────────────────

--- Upsert a repository row (natural key host/owner/name). `tracked` and the cursors are preserved
--- across a metadata re-pull only when the incoming row omits them (a metadata sync passes the
--- forge fields; tracking + cursors are set by their own writers).
---@param row table  a normalized repositories row (must carry forge/host/owner/name/tracked)
---@return integer? repo_id
function M.upsert_repository(row)
    -- Never let a metadata re-pull downgrade `tracked` or wipe a cursor it did not compute: strip
    -- nil-valued control columns so the UPDATE leaves the existing values in place.
    local preserve = {}
    for _, col in ipairs({ "tracked", "topics_cursor", "notifications_cursor", "pulled_at" }) do
        if row[col] == nil then
            preserve[#preserve + 1] = col
        end
    end
    return upsert("repositories", { host = row.host, owner = row.owner, name = row.name }, row, preserve)
end

--- All tracked repositories.
---@return table[]
function M.repositories()
    return M.get():find("repositories") or {}
end

--- One repository by id.
---@param repo_id integer
---@return table?
function M.repository(repo_id)
    local rows = M.get():find("repositories", { id = repo_id })
    return type(rows) == "table" and rows[1] or nil
end

--- One repository by its remote coordinates (host/owner/name) — the detect→row lookup.
---@param host string
---@param owner string
---@param name string
---@return table?
function M.repo_by_remote(host, owner, name)
    local rows = M.get():find("repositories", { host = host, owner = owner, name = name })
    return type(rows) == "table" and rows[1] or nil
end

--- The repository row matching a detect result, or nil when it is not tracked.
---@param detect table  a `LvimForgeRepo` (host/owner/name)
---@return table?
function M.repo_for_detect(detect)
    if not detect then
        return nil
    end
    return M.repo_by_remote(detect.host, detect.owner, detect.name)
end

--- Remove a repository and everything under it (FK ON DELETE CASCADE drops its topics/posts/reviews/
--- threads/labels/milestones/users/joins/pr_files/notifications). Returns whether a row was removed.
---@param repo_id integer
---@return boolean
function M.remove_repository(repo_id)
    if not M.repository(repo_id) then
        return false
    end
    return M.get():remove("repositories", { id = repo_id })
end

--- Set the tracked mode of a repository ("full" | "selective").
---@param repo_id integer
---@param tracked "full"|"selective"
---@return boolean
function M.set_tracked(repo_id, tracked)
    return M.get():update("repositories", { id = repo_id }, { tracked = tracked })
end

--- Advance the pull cursors / pulled_at watermark on a repository (the sync engine's writer).
---@param repo_id integer
---@param set { topics_cursor?: string, notifications_cursor?: string, pulled_at?: string }
---@return boolean
function M.set_cursors(repo_id, set)
    return M.get():update("repositories", { id = repo_id }, set)
end

--- Count of tracked repositories (for :checkhealth).
---@return integer
function M.repo_count()
    return M.get():count("repositories")
end

-- ── topics (+ pullreq extras) ──────────────────────────────────────────────────

--- Upsert a topic (natural key repo_id/kind/number). The LOCAL columns (`unread`, `saved_note`) are
--- PRESERVED on an existing row — a remote re-pull never clobbers a user's read-state or note. A
--- fresh topic defaults to `unread = 1` (freshly pulled = unread) unless the row says otherwise.
---@param row table  a normalized topics row (repo_id/kind/number required)
---@return integer? topic_id
function M.upsert_topic(row)
    local s = M.get()
    local existing = s:find("topics", { repo_id = row.repo_id, kind = row.kind, number = row.number })
    if type(existing) == "table" and existing[1] then
        local id = existing[1].id
        local set = vim.deepcopy(row)
        for _, col in ipairs(LOCAL_TOPIC_COLS) do
            set[col] = nil -- keep the user's local columns
        end
        s:update("topics", { id = id }, set)
        return id
    end
    if row.unread == nil then
        row.unread = 1
    end
    local id = s:insert("topics", row)
    return (id ~= false) and id or nil
end

--- Upsert a PR's extras row (1:1 with a pullreq topic; natural key topic_id).
---@param row table  a normalized pullreqs row (topic_id required)
---@return integer? id
function M.upsert_pullreq(row)
    return upsert("pullreqs", { topic_id = row.topic_id }, row)
end

--- List topics for a repository, filtered. Every filter dimension is optional; a nil or "all" value
--- imposes no constraint. `label`/`assignee`/`reviewer`/`mark` filter through the join tables; `search`
--- is a case-insensitive LIKE over title+body. Each row carries `draft` (the PR's draft flag via the 1:1
--- `pullreqs` LEFT JOIN; nil for issues) so the list can pick a draft state icon without an N+1 fetch.
--- Newest-updated first.
---@param repo_id integer
---@param filter? { state?: string, kind?: string, label?: string, assignee?: string, reviewer?: string, author?: string, milestone_id?: integer, mark?: string, search?: string }
---@return table[]
function M.topics(repo_id, filter)
    filter = filter or {}
    local sql = {
        "SELECT t.*, p.draft AS draft FROM topics t"
            .. " LEFT JOIN pullreqs p ON p.topic_id = t.id"
            .. " WHERE t.repo_id = :repo_id",
    }
    local params = { repo_id = repo_id }
    local function has(v)
        return v ~= nil and v ~= "" and v ~= "all"
    end
    if has(filter.kind) then
        sql[#sql + 1] = "AND t.kind = :kind"
        params.kind = filter.kind
    end
    if has(filter.state) then
        sql[#sql + 1] = "AND t.state = :state"
        params.state = filter.state
    end
    if has(filter.author) then
        sql[#sql + 1] = "AND t.author = :author"
        params.author = filter.author
    end
    if filter.milestone_id ~= nil then
        sql[#sql + 1] = "AND t.milestone_id = :milestone_id"
        params.milestone_id = filter.milestone_id
    end
    if has(filter.search) then
        sql[#sql + 1] = "AND (t.title LIKE :search OR t.body LIKE :search)"
        params.search = "%" .. filter.search .. "%"
    end
    if has(filter.label) then
        sql[#sql + 1] = "AND EXISTS (SELECT 1 FROM topic_labels tl JOIN labels l ON l.id = tl.label_id"
            .. " WHERE tl.topic_id = t.id AND l.name = :label)"
        params.label = filter.label
    end
    if has(filter.assignee) then
        sql[#sql + 1] = "AND EXISTS (SELECT 1 FROM topic_assignees ta"
            .. " WHERE ta.topic_id = t.id AND ta.user_login = :assignee)"
        params.assignee = filter.assignee
    end
    if has(filter.reviewer) then
        sql[#sql + 1] = "AND EXISTS (SELECT 1 FROM topic_review_requests tr"
            .. " WHERE tr.topic_id = t.id AND tr.reviewer = :reviewer)"
        params.reviewer = filter.reviewer
    end
    if has(filter.mark) then
        sql[#sql + 1] = "AND EXISTS (SELECT 1 FROM topic_marks tm JOIN marks m ON m.id = tm.mark_id"
            .. " WHERE tm.topic_id = t.id AND m.name = :mark)"
        params.mark = filter.mark
    end
    sql[#sql + 1] = "ORDER BY t.updated DESC"
    local rows = M.get():exec(table.concat(sql, " "), params)
    return type(rows) == "table" and rows or {}
end

--- One topic by number (optionally narrowed by kind), with its `pullreq` extras attached when it is
--- a PR. Returns nil when absent.
---@param repo_id integer
---@param number integer
---@param kind? "issue"|"pullreq"
---@return table?
function M.get_topic(repo_id, number, kind)
    local where = { repo_id = repo_id, number = number }
    if kind then
        where.kind = kind
    end
    local rows = M.get():find("topics", where)
    local topic = type(rows) == "table" and rows[1] or nil
    if not topic then
        return nil
    end
    if topic.kind == "pullreq" then
        local pr = M.get():find("pullreqs", { topic_id = topic.id })
        topic.pullreq = type(pr) == "table" and pr[1] or nil
    end
    return topic
end

--- One topic row by its db id.
---@param topic_id integer
---@return table?
function M.topic(topic_id)
    local rows = M.get():find("topics", { id = topic_id })
    return type(rows) == "table" and rows[1] or nil
end

--- The PR topic whose head branch is `head_ref` in `repo_id` — the local half of `pr_for_branch`. Scans
--- the `pullreqs` rows with this head ref and returns the first whose topic belongs to this repo (with its
--- `pullreq` extras attached, like `get_topic`). Prefers an OPEN PR when several branches reuse a name.
---@param repo_id integer
---@param head_ref string
---@return table?
function M.topic_by_head_ref(repo_id, head_ref)
    local prs = M.get():find("pullreqs", { head_ref = head_ref })
    if type(prs) ~= "table" then
        return nil
    end
    local fallback
    for _, pr in ipairs(prs) do
        local t = M.topic(pr.topic_id)
        if t and t.repo_id == repo_id then
            t.pullreq = pr
            if t.state == "open" then
                return t
            end
            fallback = fallback or t
        end
    end
    return fallback
end

-- ── LOCAL topic mutations (never sent to the API) ──────────────────────────────

--- Set / clear a topic's LOCAL private note (empty text clears it).
---@param topic_id integer
---@param text? string
---@return boolean
function M.set_note(topic_id, text)
    local value = (text and vim.trim(text) ~= "") and text or nil
    return M.get():update("topics", { id = topic_id }, { saved_note = value })
end

--- Set a topic's LOCAL unread flag.
---@param topic_id integer
---@param unread boolean
---@return boolean
function M.set_unread(topic_id, unread)
    return M.get():update("topics", { id = topic_id }, { unread = unread and 1 or 0 })
end

-- ── merge / draft reconcile (a merge response is `{ sha, merged }`, a draft toggle a GraphQL ack — neither
--    carries a full topic object, so the state change is written explicitly against the cached row) ──

--- Set a topic's `state` ("open"|"closed"|"merged"). The merge mutation's response is only `{ sha, merged }`
--- (no full topic), so the merged state is reconciled against the cached row directly.
---@param topic_id integer
---@param new_state "open"|"closed"|"merged"
---@return boolean
function M.set_topic_state(topic_id, new_state)
    return M.get():update("topics", { id = topic_id }, { state = new_state })
end

--- Set a pull request's `draft` flag (0/1) on its `pullreqs` extras row. The GitHub GraphQL draft toggle
--- acks with the node only, so the flag is written against the cached PR directly.
---@param topic_id integer  the pullreq topic's id (the `pullreqs.topic_id` natural key)
---@param draft boolean
---@return boolean
function M.set_pr_draft(topic_id, draft)
    return M.get():update("pullreqs", { topic_id = topic_id }, { draft = draft and 1 or 0 })
end

--- Set a topic's `locked` flag (0/1). The lock/unlock endpoints return 204 No Content (no topic body), so
--- the flag is reconciled against the cached row directly — like the merge-state / draft reconcilers above.
---@param topic_id integer
---@param locked boolean
---@return boolean
function M.set_locked(topic_id, locked)
    return M.get():update("topics", { id = topic_id }, { locked = locked and 1 or 0 })
end

-- ── remote soft-ref setters (a mutation response can CLEAR a column, which the table :update API
--    cannot express — an absent key leaves the old value — so these use an explicit SQL statement) ──

--- Set (or clear) a topic's `milestone_id` (a soft ref into `milestones.id`). nil sets SQL NULL — the
--- "set milestone" mutation clears the milestone by choosing "None". The `:update` set-table API can't
--- null a column (an absent key is a no-op), so this writes the statement directly.
---@param topic_id integer
---@param milestone_id? integer
---@return boolean
function M.set_milestone(topic_id, milestone_id)
    if milestone_id == nil then
        return M.get():exec("UPDATE topics SET milestone_id = NULL WHERE id = :id", { id = topic_id }) ~= false
    end
    return M.get():exec("UPDATE topics SET milestone_id = :mid WHERE id = :id", { mid = milestone_id, id = topic_id })
        ~= false
end

-- ── posts / reviews / threads / pr_files ───────────────────────────────────────

--- Upsert a timeline post (natural key topic_id/forge_id).
---@param row table
---@return integer? id
function M.upsert_post(row)
    return upsert("posts", { topic_id = row.topic_id, forge_id = row.forge_id }, row)
end

--- Upsert a review header (natural key topic_id/forge_id).
---@param row table
---@return integer? id
function M.upsert_review(row)
    return upsert("reviews", { topic_id = row.topic_id, forge_id = row.forge_id }, row)
end

--- Upsert a review thread (natural key topic_id/forge_id).
---@param row table
---@return integer? id
function M.upsert_thread(row)
    return upsert("threads", { topic_id = row.topic_id, forge_id = row.forge_id }, row)
end

--- Upsert a PR file (natural key topic_id/path).
---@param row table
---@return integer? id
function M.upsert_pr_file(row)
    return upsert("pr_files", { topic_id = row.topic_id, path = row.path }, row)
end

--- The timeline posts of a topic, oldest first.
---@param topic_id integer
---@return table[]
function M.posts(topic_id)
    local rows = M.get():find("posts", { topic_id = topic_id }, { order_by = { asc = "created" } })
    return type(rows) == "table" and rows or {}
end

--- The reviews of a topic.
---@param topic_id integer
---@return table[]
function M.reviews(topic_id)
    return M.get():find("reviews", { topic_id = topic_id }) or {}
end

--- The review threads of a topic (unresolved first).
---@param topic_id integer
---@return table[]
function M.threads(topic_id)
    local rows = M.get():find("threads", { topic_id = topic_id })
    rows = type(rows) == "table" and rows or {}
    table.sort(rows, function(a, b)
        return (a.resolved or 0) < (b.resolved or 0)
    end)
    return rows
end

--- The PR file set of a topic.
---@param topic_id integer
---@return table[]
function M.pr_files(topic_id)
    return M.get():find("pr_files", { topic_id = topic_id }) or {}
end

-- ── the DB-backed PENDING REVIEW model (LOCAL draft state — restart-safe, remote-preserved) ─────────
-- A single in-progress review per (PR, viewer) lives as a `reviews` row with state = "pending" and
-- forge_id UNSET (nil); its draft line/range comments live as `posts` rows with forge_id UNSET, bound to
-- it by `review_id = <the pending review's local db id, as text>`. `cc`/`cr` APPEND to it locally (instant,
-- offline-capable); `cs` SUBMITS the whole batch. Because a remote pull's `upsert_review`/`upsert_post`
-- dedup on the natural key (topic_id, forge_id) with REAL forge ids — and no pull path DELETES a review or
-- post — the forge_id-NULL pending rows are NEVER touched by a remote pull: the local-preserve invariant
-- extends to pending rows by construction, so an interrupted review survives a restart. On GitHub the batch
-- maps to ONE `POST /pulls/{n}/reviews`; GitLab/Gitea batch client-side — same UX, caps decide the wire.

--- The LOCAL pending review row for a PR topic (forge_id UNSET), or nil. A REMOTE native pending review
--- (forge_id set) is deliberately NOT matched here — this is the user's local draft.
---@param topic_id integer
---@return table?
local function find_pending(topic_id)
    local rows = M.get():exec(
        "SELECT * FROM reviews WHERE topic_id = :tid AND state = 'pending' AND forge_id IS NULL LIMIT 1",
        { tid = topic_id }
    )
    return type(rows) == "table" and rows[1] or nil
end

--- The LOCAL pending review for a PR (find-or-create). `viewer` sets the draft author on create (a
--- cosmetic label — the API assigns the real author at submit). Returns the review row (nil = no such PR).
---@param repo_id integer
---@param number integer
---@param viewer? string
---@return table?
function M.pending_review(repo_id, number, viewer)
    local topic = M.get_topic(repo_id, number, "pullreq")
    if not topic then
        return nil
    end
    local existing = find_pending(topic.id)
    if existing then
        return existing
    end
    local id = M.get():insert("reviews", { topic_id = topic.id, author = viewer, state = "pending" })
    if not id or id == false then
        return nil
    end
    local rows = M.get():find("reviews", { id = id })
    return type(rows) == "table" and rows[1] or nil
end

--- Append a draft comment to a PR's LOCAL pending review (creating the pending review if needed). A NEW
--- line/range comment carries path/line(+start_line)/side; a REPLY carries `reply_to` (the root comment's
--- forge id) and inherits the thread's path/line/side. `forge_id` stays UNSET (no API id until submit).
--- Returns the new post id (nil when the PR is not cached).
---@param o { repo_id: integer, number: integer, viewer?: string, path?: string, line?: integer, start_line?: integer, side?: string, body: string, reply_to?: integer|string, thread_id?: integer|string }
---@return integer? post_id
function M.add_pending_comment(o)
    local review = M.pending_review(o.repo_id, o.number, o.viewer)
    if not review then
        return nil
    end
    local id = M.get():insert("posts", {
        topic_id = review.topic_id,
        forge_id = nil, -- local draft — no API id yet
        kind = "review-comment",
        author = o.viewer,
        created = os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]],
        body = o.body,
        path = o.path,
        line = o.line,
        start_line = o.start_line,
        side = o.side,
        review_id = tostring(review.id), -- binds the draft to the LOCAL pending review
        reply_to = o.reply_to and tostring(o.reply_to) or nil,
        thread_id = o.thread_id and tostring(o.thread_id) or nil,
    })
    return (id ~= false) and id or nil
end

--- The draft comments bound to a LOCAL pending review, oldest first. `review_id` may be the review row or
--- its id.
---@param review integer|table  the pending review's id (or the row)
---@return table[]
function M.pending_comments(review)
    local rid = type(review) == "table" and review.id or review
    local rows = M.get():exec(
        "SELECT * FROM posts WHERE review_id = :rid AND forge_id IS NULL ORDER BY created ASC, id ASC",
        { rid = tostring(rid) }
    )
    return type(rows) == "table" and rows or {}
end

--- The number of draft comments in a PR's LOCAL pending review — WITHOUT creating one (the standalone
--- submit command reads this to show the count).
---@param repo_id integer
---@param number integer
---@return integer
function M.pending_review_count(repo_id, number)
    local topic = M.get_topic(repo_id, number, "pullreq")
    if not topic then
        return 0
    end
    local review = find_pending(topic.id)
    if not review then
        return 0
    end
    return #M.pending_comments(review)
end

--- Discard a PR's LOCAL pending review + all its draft comments (the `cx`/cancel-review path). Returns
--- whether a pending review existed.
---@param repo_id integer
---@param number integer
---@return boolean
function M.discard_pending(repo_id, number)
    local topic = M.get_topic(repo_id, number, "pullreq")
    if not topic then
        return false
    end
    local review = find_pending(topic.id)
    if not review then
        return false
    end
    M.get():exec("DELETE FROM posts WHERE review_id = :rid AND forge_id IS NULL", { rid = tostring(review.id) })
    M.get():remove("reviews", { id = review.id })
    return true
end

-- ── thread resolution (GraphQL) — node id + resolved state the REST read pass could not know ─────────

--- Set a thread's `resolved` flag (0/1) directly (the resolve/unresolve GraphQL ack carries no thread row).
---@param thread_id integer
---@param resolved boolean
---@return boolean
function M.set_thread_resolved(thread_id, resolved)
    return M.get():update("threads", { id = thread_id }, { resolved = resolved and 1 or 0 })
end

--- Store the GraphQL node id + resolved/outdated state onto a synthesized thread, matched by its REST root
--- comment id (`forge_id`). Populates the fields the GraphQL `reviewThreads` fetch supplies but REST cannot.
---@param topic_id integer
---@param root_comment_id integer|string  the thread's root REST comment id (== the synthesized `forge_id`)
---@param node_id string
---@param resolved boolean
---@param outdated? boolean
---@return boolean
function M.set_thread_graphql(topic_id, root_comment_id, node_id, resolved, outdated)
    local set = { node_id = node_id, resolved = resolved and 1 or 0 }
    if outdated ~= nil then
        set.outdated = outdated and 1 or 0
    end
    return M.get():update("threads", { topic_id = topic_id, forge_id = tostring(root_comment_id) }, set)
end

-- ── labels / milestones / users (+ their joins) ────────────────────────────────

--- Upsert a repo label (natural key repo_id/name).
---@param row table
---@return integer? id
function M.upsert_label(row)
    return upsert("labels", { repo_id = row.repo_id, name = row.name }, row)
end

--- Upsert a repo milestone (natural key repo_id/forge_id).
---@param row table
---@return integer? id
function M.upsert_milestone(row)
    return upsert("milestones", { repo_id = row.repo_id, forge_id = row.forge_id }, row)
end

--- Upsert a repo-scoped user (natural key repo_id/login).
---@param row table
---@return integer? id
function M.upsert_user(row)
    return upsert("users", { repo_id = row.repo_id, login = row.login }, row)
end

--- The labels of a repository.
---@param repo_id integer
---@return table[]
function M.labels(repo_id)
    return M.get():find("labels", { repo_id = repo_id }) or {}
end

--- The milestones of a repository.
---@param repo_id integer
---@return table[]
function M.milestones(repo_id)
    return M.get():find("milestones", { repo_id = repo_id }) or {}
end

--- The repo-scoped users (assignable / participants).
---@param repo_id integer
---@return table[]
function M.users(repo_id)
    return M.get():find("users", { repo_id = repo_id }) or {}
end

--- Replace a topic's REMOTE label set with `label_ids` (the label db ids). Clears the old join rows
--- and inserts the new — a remote pull owns this set entirely. Never touches `topic_marks`.
---@param topic_id integer
---@param label_ids integer[]
function M.set_labels(topic_id, label_ids)
    local s = M.get()
    s:remove("topic_labels", { topic_id = topic_id })
    for _, lid in ipairs(label_ids or {}) do
        s:insert("topic_labels", { topic_id = topic_id, label_id = lid })
    end
end

--- Replace a topic's assignee set (logins).
---@param topic_id integer
---@param logins string[]
function M.set_assignees(topic_id, logins)
    local s = M.get()
    s:remove("topic_assignees", { topic_id = topic_id })
    for _, login in ipairs(logins or {}) do
        s:insert("topic_assignees", { topic_id = topic_id, user_login = login })
    end
end

--- Replace a topic's requested-reviewer set (logins).
---@param topic_id integer
---@param reviewers string[]
function M.set_review_requests(topic_id, reviewers)
    local s = M.get()
    s:remove("topic_review_requests", { topic_id = topic_id })
    for _, r in ipairs(reviewers or {}) do
        s:insert("topic_review_requests", { topic_id = topic_id, reviewer = r })
    end
end

--- The label rows attached to a topic (joined through topic_labels).
---@param topic_id integer
---@return table[]
function M.topic_labels(topic_id)
    local rows = M.get():exec(
        "SELECT l.* FROM labels l JOIN topic_labels tl ON tl.label_id = l.id WHERE tl.topic_id = :tid",
        { tid = topic_id }
    )
    return type(rows) == "table" and rows or {}
end

--- Every topic's label set for a whole repository, in ONE query (topic_id → label rows). The topic-list
--- panel renders label CHIPS for hundreds of rows; a per-row `topic_labels` fetch would be N+1, so the
--- list reads this once per render. Each label row carries `name` + `color` (the data-driven chip hex).
---@param repo_id integer
---@return table<integer, table[]>  topic_id → its label rows
function M.topic_labels_by_repo(repo_id)
    local rows = M.get():exec(
        "SELECT tl.topic_id AS topic_id, l.name AS name, l.color AS color, l.description AS description"
            .. " FROM topic_labels tl"
            .. " JOIN labels l ON l.id = tl.label_id"
            .. " JOIN topics t ON t.id = tl.topic_id"
            .. " WHERE t.repo_id = :rid",
        { rid = repo_id }
    )
    local out = {}
    if type(rows) == "table" then
        for _, r in ipairs(rows) do
            local list = out[r.topic_id]
            if not list then
                list = {}
                out[r.topic_id] = list
            end
            list[#list + 1] = { name = r.name, color = r.color, description = r.description }
        end
    end
    return out
end

--- The assignee logins of a topic.
---@param topic_id integer
---@return string[]
function M.topic_assignees(topic_id)
    local rows = M.get():find("topic_assignees", { topic_id = topic_id }) or {}
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = r.user_login
    end
    return out
end

--- The requested-reviewer logins of a topic.
---@param topic_id integer
---@return string[]
function M.topic_review_requests(topic_id)
    local rows = M.get():find("topic_review_requests", { topic_id = topic_id }) or {}
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = r.reviewer
    end
    return out
end

-- ── marks (LOCAL, user-defined) + topic_marks ─────────────────────────────────

--- Create (or fetch) a local mark by name; returns its id.
---@param name string
---@param color? string
---@return integer? id
function M.upsert_mark(name, color)
    local s = M.get()
    local existing = s:find("marks", { name = name })
    if type(existing) == "table" and existing[1] then
        if color ~= nil then
            s:update("marks", { id = existing[1].id }, { color = color })
        end
        return existing[1].id
    end
    local id = s:insert("marks", { name = name, color = color })
    return (id ~= false) and id or nil
end

--- All local marks.
---@return table[]
function M.marks()
    return M.get():find("marks") or {}
end

--- Attach a local mark to a topic (idempotent on the topic_id/mark_id pair).
---@param topic_id integer
---@param mark_id integer
---@return boolean
function M.add_topic_mark(topic_id, mark_id)
    local s = M.get()
    local existing = s:find("topic_marks", { topic_id = topic_id, mark_id = mark_id })
    if type(existing) == "table" and existing[1] then
        return true
    end
    return s:insert("topic_marks", { topic_id = topic_id, mark_id = mark_id }) ~= false
end

--- Detach a local mark from a topic.
---@param topic_id integer
---@param mark_id integer
---@return boolean
function M.remove_topic_mark(topic_id, mark_id)
    return M.get():remove("topic_marks", { topic_id = topic_id, mark_id = mark_id })
end

--- The local mark rows attached to a topic (joined through topic_marks).
---@param topic_id integer
---@return table[]
function M.topic_marks(topic_id)
    local rows = M.get():exec(
        "SELECT m.* FROM marks m JOIN topic_marks tm ON tm.mark_id = m.id WHERE tm.topic_id = :tid",
        { tid = topic_id }
    )
    return type(rows) == "table" and rows or {}
end

-- ── notifications ─────────────────────────────────────────────────────────────

--- Upsert a notification (natural key forge_id).
---@param row table
---@return integer? id
function M.upsert_notification(row)
    return upsert("notifications", { forge_id = row.forge_id }, row)
end

--- List notifications, filtered by unread. Newest-updated first.
---@param filter? { unread?: boolean, repo_id?: integer }
---@return table[]
function M.notifications(filter)
    filter = filter or {}
    local where = {}
    if filter.repo_id ~= nil then
        where.repo_id = filter.repo_id
    end
    if filter.unread == true then
        where.unread = 1
    end
    local rows = M.get():find("notifications", next(where) and where or nil, { order_by = { desc = "updated" } })
    return type(rows) == "table" and rows or {}
end

--- The unread-notification count (the statusline / dispatch-title badge source). All tracked repos, or
--- one repo when `repo_id` is given.
---@param repo_id? integer  scope the count to a single repo (nil = across every tracked repo)
---@return integer
function M.notifications_unread(repo_id)
    local where = { unread = 1 }
    if repo_id ~= nil then
        where.repo_id = repo_id
    end
    return M.get():count("notifications", where)
end

--- Mark one notification read/unread by id.
---@param id integer
---@param unread boolean
---@return boolean
function M.set_notification_unread(id, unread)
    return M.get():update("notifications", { id = id }, { unread = unread and 1 or 0 })
end

--- Mark ALL notifications read (optionally only a repo's).
---@param repo_id? integer
---@return boolean
function M.mark_all_notifications_read(repo_id)
    local s = M.get()
    if repo_id ~= nil then
        return s:update("notifications", { repo_id = repo_id }, { unread = 0 })
    end
    -- No repo scope: an empty-where table `:update` is a no-op in the store, so clear EVERY row via a
    -- statement (the same raw-SQL seam `set_milestone` uses for what the table `:update` API can't express).
    s:exec("UPDATE notifications SET unread = 0")
    return true
end

return M
