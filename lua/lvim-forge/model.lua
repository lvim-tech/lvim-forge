-- lvim-forge.model: the NORMALIZATION layer between a forge's API JSON and the `db.lua` row shape.
-- The sync engine (a later phase) calls `model.<forge>.<entity>(api_obj, ctx)` to turn a raw API
-- object into the exact column→value row `db.upsert_<entity>` writes: API field names are mapped to
-- schema columns, timestamps coerced to ISO-8601 strings, booleans to 0/1, and compound responses
-- split (a PR → a topic row + a pullreq extras row + pr_files rows; a review → a review row + a
-- review-body post; a review comment → a post row). Keeping this seam forge-agnostic
-- (`normalize(forge, entity, …)` dispatches to a per-forge table) is what lets the GitLab / Gitea
-- normalizers slot in later phases WITHOUT the sync engine or db changing — it always calls
-- `model.normalize_* → db.upsert_*`.
--
-- v1 ships the GitHub normalizers (the plan is GitHub-first). GitHub REST is the source shape:
-- issues + PRs come from the same issue-ish object (a PR additionally carries `pull_request` on the
-- issue endpoint and the base/head/draft/… fields on the pulls endpoint); comments, reviews, review
-- comments, labels, milestones, users, notifications and PR files are their own endpoints.
--
-- Tokens NEVER appear here — this layer only ever touches public content fields.
--
---@module "lvim-forge.model"

local M = {}

-- ── shared coercions ──────────────────────────────────────────────────────────

--- Coerce an API timestamp to an ISO-8601 string. GitHub already gives ISO-8601 (`2024-…Z`), so a
--- string passes through; an epoch NUMBER is rendered as UTC ISO-8601; nil stays nil.
---@param v any
---@return string?
local function to_iso(v)
    if type(v) == "string" then
        return v ~= "" and v or nil
    elseif type(v) == "number" then
        return os.date("!%Y-%m-%dT%H:%M:%SZ", v) --[[@as string]]
    end
    return nil
end

--- A JSON value that is actually PRESENT, else nil. `vim.json.decode` turns a JSON `null` into `vim.NIL`
--- (a truthy userdata sentinel — NOT `nil`), so a bare `obj and obj.field` guard passes on a null object and
--- then indexes `vim.NIL` → a hard error. `present(obj) and obj.field` is the safe form: both `nil` and a
--- decoded `null` collapse to nil. Use it before indexing any NULLABLE nested API object (a deleted PR head
--- repo, an unset milestone, …).
---@param v any
---@return any
local function present(v)
    if v == nil or v == vim.NIL then
        return nil
    end
    return v
end

--- A truthy API value → 1, a falsy one → 0, nil / JSON-null → nil (leave the column unset).
---@param v any
---@return integer?
local function bool(v)
    if v == nil or v == vim.NIL then
        return nil
    end
    return v and 1 or 0
end

--- The `login` of a GitHub user sub-object (`{ login = … }`), or nil.
---@param u any
---@return string?
local function login_of(u)
    return type(u) == "table" and u.login or nil
end

--- Encode a value as a json string for a text column (used for `reactions`); nil stays nil.
---@param v any
---@return string?
local function json_of(v)
    if v == nil then
        return nil
    end
    local ok, s = pcall(vim.json.encode, v)
    return ok and s or nil
end

-- ── GitHub normalizers ─────────────────────────────────────────────────────────

---@class LvimForgeModelGithub
local github = {}

--- A GitHub repository object → a `repositories` row. `ctx` carries the classification the DB needs
--- (`forge`, `host`, and the `tracked` mode); the API supplies default_branch / privacy / remote.
---@param api table  a GitHub repo object (`{ owner={login}, name, private, default_branch, clone_url|html_url }`)
---@param ctx { forge: string, host: string, owner?: string, name?: string, tracked?: "full"|"selective" }
---@return table row
function github.repository(api, ctx)
    return {
        forge = ctx.forge,
        host = ctx.host,
        owner = login_of(api.owner) or ctx.owner,
        name = api.name or ctx.name,
        remote_url = api.clone_url or api.html_url,
        default_branch = api.default_branch,
        is_private = bool(api.private),
        tracked = ctx.tracked, -- nil leaves an existing row's tracked untouched (see db.upsert_repository)
    }
end

--- A GitHub issue OR pull object → a `topics` row. Distinguishes kind by the `pull_request` marker
--- (issue endpoint) or the presence of PR-only fields (`head`). Maps GitHub's merged/closed/open to
--- the schema's state; `unread`/`saved_note` are LOCAL and deliberately NOT set here.
---@param api table  a GitHub issue/pull object
---@param ctx { repo_id: integer }
---@return table row
function github.topic(api, ctx)
    local is_pr = api.pull_request ~= nil or api.head ~= nil or api.base ~= nil
    local state
    if api.merged or api.merged_at then
        state = "merged"
    else
        state = api.state -- "open" | "closed"
    end
    return {
        repo_id = ctx.repo_id,
        kind = is_pr and "pullreq" or "issue",
        number = api.number,
        state = state,
        title = api.title,
        body = api.body,
        author = login_of(api.user),
        created = to_iso(api.created_at),
        updated = to_iso(api.updated_at),
        closed_at = to_iso(api.closed_at),
        locked = bool(api.locked),
        milestone_id = nil, -- resolved to a local milestones.id by the sync layer after milestones upsert
        html_url = api.html_url,
    }
end

--- A GitHub pull object → a `pullreqs` extras row (PR-only fields).
---@param api table  a GitHub pull object
---@param ctx { topic_id: integer }
---@return table row
function github.pullreq(api, ctx)
    -- `head`/`base` (and `head.repo`) can be a decoded JSON `null` (`vim.NIL`) — a cross-repo PR whose head
    -- fork was deleted, an in-flight object. `present()` collapses null → nil so the indexing is safe.
    local head = present(api.head) or {}
    local base = present(api.base) or {}
    return {
        topic_id = ctx.topic_id,
        base_ref = base.ref,
        head_ref = head.ref,
        head_repo = present(head.repo) and head.repo.full_name or nil,
        head_sha = head.sha,
        draft = bool(api.draft),
        mergeable = bool(api.mergeable),
        merged_by = login_of(api.merged_by),
        additions = api.additions,
        deletions = api.deletions,
        changed_files = api.changed_files,
        commits = api.commits,
        review_decision = api.review_decision, -- present on the GraphQL path; nil on plain REST
    }
end

--- A GitHub comment / review comment → a `posts` row. `ctx.kind` selects the flavour
--- ("comment" for an issue comment, "review-comment" for a PR line comment, "review-body" for a
--- review's summary body). Line-comment anchors (path/line/side) are set when present.
---@param api table  a GitHub comment / review-comment object
---@param ctx { topic_id: integer, kind: "comment"|"review-comment"|"review-body" }
---@return table row
function github.post(api, ctx)
    -- Outdated: an explicit `outdated` bool wins; otherwise a GitHub REST review-comment with a
    -- JSON-null `position` (decoded to vim.NIL) is one whose anchored line has since moved.
    local outdated
    if api.outdated ~= nil then
        outdated = bool(api.outdated)
    elseif api.position == vim.NIL then
        outdated = 1
    end
    return {
        topic_id = ctx.topic_id,
        forge_id = api.id and tostring(api.id) or nil,
        kind = ctx.kind,
        author = login_of(api.user),
        created = to_iso(api.created_at),
        updated = to_iso(api.updated_at),
        body = api.body,
        reply_to = api.in_reply_to_id and tostring(api.in_reply_to_id) or nil,
        review_id = api.pull_request_review_id and tostring(api.pull_request_review_id) or nil,
        thread_id = api.thread_id and tostring(api.thread_id) or nil,
        path = api.path,
        line = api.line,
        side = api.side,
        original_line = api.original_line,
        outdated = outdated,
        reactions = json_of(api.reactions),
    }
end

--- A GitHub review → a `reviews` row. GitHub review states map: APPROVED→approved,
--- CHANGES_REQUESTED→changes, COMMENTED→commented, PENDING→pending.
---@param api table  a GitHub review object
---@param ctx { topic_id: integer }
---@return table row
function github.review(api, ctx)
    local map = {
        APPROVED = "approved",
        CHANGES_REQUESTED = "changes",
        COMMENTED = "commented",
        PENDING = "pending",
        DISMISSED = "commented",
    }
    return {
        topic_id = ctx.topic_id,
        forge_id = api.id and tostring(api.id) or nil,
        author = login_of(api.user),
        state = map[api.state] or (present(api.state) and api.state:lower()) or nil,
        body = api.body,
        submitted_at = to_iso(api.submitted_at),
    }
end

--- A GitHub review thread (GraphQL `reviewThreads` node) → a `threads` row.
---@param api table  `{ id, path, line, diffSide|side, isResolved|resolved, isOutdated|outdated }`
---@param ctx { topic_id: integer }
---@return table row
function github.thread(api, ctx)
    return {
        topic_id = ctx.topic_id,
        forge_id = api.id and tostring(api.id) or nil,
        path = api.path,
        line = api.line,
        side = api.diffSide or api.side,
        resolved = bool(api.isResolved ~= nil and api.isResolved or api.resolved),
        outdated = bool(api.isOutdated ~= nil and api.isOutdated or api.outdated),
    }
end

--- A GitHub label → a `labels` row (color kept as the raw hex the API gives, no leading '#').
---@param api table  `{ id, name, color, description }`
---@param ctx { repo_id: integer }
---@return table row
function github.label(api, ctx)
    return {
        repo_id = ctx.repo_id,
        forge_id = api.id and tostring(api.id) or nil,
        name = api.name,
        color = api.color,
        description = api.description,
    }
end

--- A GitHub milestone → a `milestones` row. `number` (the per-repo milestone number) is what the "set
--- milestone" mutation PATCHes an issue with, so it is cached alongside the global `forge_id`.
---@param api table  `{ id, number, title, state, due_on }`
---@param ctx { repo_id: integer }
---@return table row
function github.milestone(api, ctx)
    return {
        repo_id = ctx.repo_id,
        forge_id = api.id and tostring(api.id) or nil,
        number = api.number,
        title = api.title,
        state = api.state,
        due = to_iso(api.due_on),
    }
end

--- A GitHub user → a repo-scoped `users` row.
---@param api table  `{ login, name }`
---@param ctx { repo_id: integer }
---@return table row
function github.user(api, ctx)
    return {
        repo_id = ctx.repo_id,
        login = api.login,
        name = api.name,
    }
end

--- A GitHub notification → a `notifications` row. `topic_id` resolution (subject → a cached topic)
--- is the sync layer's job; here `ctx.topic_id`/`ctx.repo_id` are passed through when known.
---@param api table  a GitHub notification thread object
---@param ctx { repo_id?: integer, topic_id?: integer }
---@return table row
function github.notification(api, ctx)
    local subject = api.subject or {}
    return {
        repo_id = ctx.repo_id,
        topic_id = ctx.topic_id,
        forge_id = api.id and tostring(api.id) or nil,
        reason = api.reason,
        unread = bool(api.unread),
        updated = to_iso(api.updated_at),
        title = subject.title,
        url = subject.url,
    }
end

--- A GitHub PR file → a `pr_files` row.
---@param api table  `{ filename, status, additions, deletions }`
---@param ctx { topic_id: integer }
---@return table row
function github.pr_file(api, ctx)
    return {
        topic_id = ctx.topic_id,
        path = api.filename,
        status = api.status,
        additions = api.additions,
        deletions = api.deletions,
    }
end

M.github = github

-- ── GitLab normalizers ──────────────────────────────────────────────────────────
-- GitLab v4 REST is the source shape. A merge request is the PR flavour (`source_branch`/`target_branch`
-- distinguish it from an issue); the user-facing number is the per-project `iid` (the schema's topic key),
-- while GitLab's global `id` is the entity `forge_id`. Notes are comments; a resolvable discussion is a
-- review thread. A user's handle is `username` (GitHub's `login`). Draft is encoded in the title (a
-- `Draft:`/`WIP:` prefix) as well as the `draft`/`work_in_progress` flags. Timestamps are already ISO-8601.

---@class LvimForgeModelGitlab
local gitlab = {}

--- The `username` of a GitLab user sub-object (`{ username = … }`), or nil (GitLab's equivalent of
--- GitHub's `login`).
---@param u any
---@return string?
local function username_of(u)
    return type(u) == "table" and u.username or nil
end

--- Whether a GitLab title marks a draft (`Draft:` or the legacy `WIP:` prefix, case-insensitive).
---@param title any
---@return boolean
local function title_is_draft(title)
    if type(title) ~= "string" then
        return false
    end
    local t = title:gsub("^%s+", "")
    return t:lower():match("^draft:") ~= nil or t:lower():match("^wip:") ~= nil
end

--- A GitLab project object → a `repositories` row. `ctx` supplies the classification (forge/host/tracked);
--- the API supplies default_branch / visibility / clone url.
---@param api table  a GitLab project object
---@param ctx { forge: string, host: string, owner?: string, name?: string, tracked?: "full"|"selective" }
---@return table row
function gitlab.repository(api, ctx)
    local ns = type(api.namespace) == "table" and api.namespace.full_path or nil
    return {
        forge = ctx.forge,
        host = ctx.host,
        owner = ns or ctx.owner,
        name = api.path or ctx.name,
        remote_url = api.http_url_to_repo or api.web_url,
        default_branch = api.default_branch,
        is_private = api.visibility ~= nil and bool(api.visibility ~= "public") or nil,
        tracked = ctx.tracked,
    }
end

--- A GitLab merge request OR issue object → a `topics` row. An MR is distinguished by `source_branch`.
--- GitLab states (`opened`/`closed`/`merged`/`locked`) map to the schema's open/closed/merged. The
--- user-facing number is `iid`. `unread`/`saved_note` are LOCAL and deliberately NOT set here.
---@param api table  a GitLab MR/issue object
---@param ctx { repo_id: integer }
---@return table row
function gitlab.topic(api, ctx)
    local is_pr = api.source_branch ~= nil or api.target_branch ~= nil
    local state = api.state
    if state == "opened" then
        state = "open"
    elseif state == "locked" then
        state = "open"
    end -- "closed" / "merged" pass through
    return {
        repo_id = ctx.repo_id,
        kind = is_pr and "pullreq" or "issue",
        number = api.iid,
        state = state,
        title = api.title,
        body = api.description,
        author = username_of(api.author),
        created = to_iso(api.created_at),
        updated = to_iso(api.updated_at),
        closed_at = to_iso(api.closed_at),
        locked = bool(api.discussion_locked),
        milestone_id = nil, -- resolved by the sync layer after the milestones upsert
        html_url = api.web_url,
    }
end

--- A GitLab merge request → a `pullreqs` extras row. Draft is the `draft`/`work_in_progress` flag OR the
--- title prefix; mergeability comes from `merge_status`; the head sha from `sha`/`diff_refs.head_sha`.
---@param api table  a GitLab MR object
---@param ctx { topic_id: integer }
---@return table row
function gitlab.pullreq(api, ctx)
    local diff_refs = type(api.diff_refs) == "table" and api.diff_refs or {}
    local is_draft = api.draft == true or api.work_in_progress == true or title_is_draft(api.title)
    local head_repo
    if api.source_project_id ~= nil and api.source_project_id ~= api.target_project_id then
        head_repo = tostring(api.source_project_id)
    end
    return {
        topic_id = ctx.topic_id,
        base_ref = api.target_branch,
        head_ref = api.source_branch,
        head_repo = head_repo,
        head_sha = api.sha or diff_refs.head_sha,
        draft = bool(is_draft),
        mergeable = api.merge_status ~= nil and bool(api.merge_status == "can_be_merged") or nil,
        merged_by = username_of(api.merged_by),
        additions = nil, -- GitLab does not return per-MR line totals on the MR object
        deletions = nil,
        changed_files = tonumber(api.changes_count), -- a string like "3" when present
        commits = nil,
        review_decision = nil,
    }
end

--- A GitLab note → a `posts` row. `ctx.kind` selects the flavour ("comment"|"review-comment"|
--- "review-body"). A diff note carries a `position` (new/old path + line) anchoring it; `thread_id` (the
--- owning discussion id) is stamped by the sync layer before normalizing so replies group.
---@param api table  a GitLab note object
---@param ctx { topic_id: integer, kind: string }
---@return table row
function gitlab.post(api, ctx)
    local pos = type(api.position) == "table" and api.position or nil
    local path, line, side
    if pos then
        path = pos.new_path or pos.old_path
        if pos.new_line ~= nil then
            line, side = pos.new_line, "RIGHT"
        elseif pos.old_line ~= nil then
            line, side = pos.old_line, "LEFT"
        end
    end
    return {
        topic_id = ctx.topic_id,
        forge_id = api.id and tostring(api.id) or nil,
        kind = ctx.kind,
        author = username_of(api.author),
        created = to_iso(api.created_at),
        updated = to_iso(api.updated_at),
        body = api.body,
        reply_to = api.reply_to and tostring(api.reply_to) or nil,
        review_id = nil,
        thread_id = api.thread_id and tostring(api.thread_id) or nil,
        path = path,
        line = line,
        side = side,
        original_line = nil,
        outdated = nil,
        reactions = nil,
    }
end

--- A GitLab approval (one entry of the approvals object's `approved_by`, reshaped by the sync layer to
--- `{ id, user, submitted_at? }`) → a `reviews` row (state "approved").
---@param api table  a GitLab approval-derived review object
---@param ctx { topic_id: integer }
---@return table row
function gitlab.review(api, ctx)
    return {
        topic_id = ctx.topic_id,
        forge_id = api.id and tostring(api.id) or nil,
        author = username_of(api.user),
        state = api.state or "approved",
        body = api.body,
        submitted_at = to_iso(api.submitted_at),
    }
end

--- A GitLab discussion (reshaped by the sync layer to carry `{ id, position?, resolved }`) → a `threads`
--- row. The discussion id is BOTH `forge_id` and `node_id` (GitLab resolves a thread by its discussion id
--- over REST — no separate GraphQL node id).
---@param api table  a GitLab discussion-derived thread object
---@param ctx { topic_id: integer }
---@return table row
function gitlab.thread(api, ctx)
    local pos = type(api.position) == "table" and api.position or {}
    local line, side
    if pos.new_line ~= nil then
        line, side = pos.new_line, "RIGHT"
    elseif pos.old_line ~= nil then
        line, side = pos.old_line, "LEFT"
    end
    return {
        topic_id = ctx.topic_id,
        forge_id = api.id and tostring(api.id) or nil,
        node_id = api.id and tostring(api.id) or nil,
        path = pos.new_path or pos.old_path,
        line = line,
        side = side,
        resolved = bool(api.resolved),
        outdated = nil,
    }
end

--- A GitLab label (a `with_labels_details` object) → a `labels` row. GitLab colours are `#rrggbb` — the
--- leading `#` is stripped to match GitHub's bare hex.
---@param api table  `{ id, name, color, description }`
---@param ctx { repo_id: integer }
---@return table row
function gitlab.label(api, ctx)
    local color = api.color
    if type(color) == "string" then
        color = color:gsub("^#", "")
    end
    return {
        repo_id = ctx.repo_id,
        forge_id = api.id and tostring(api.id) or nil,
        name = api.name,
        color = color,
        description = api.description,
    }
end

--- A GitLab milestone → a `milestones` row. `number` = the per-project `iid` (the user-facing milestone
--- number); the global `id` is `forge_id` (the value the "set milestone" write PUTs as `milestone_id`).
---@param api table  `{ id, iid, title, state, due_date }`
---@param ctx { repo_id: integer }
---@return table row
function gitlab.milestone(api, ctx)
    local state = api.state == "active" and "open" or api.state
    return {
        repo_id = ctx.repo_id,
        forge_id = api.id and tostring(api.id) or nil,
        number = api.iid,
        title = api.title,
        state = state,
        due = to_iso(api.due_date),
    }
end

--- A GitLab member/user → a repo-scoped `users` row.
---@param api table  `{ username, name }`
---@param ctx { repo_id: integer }
---@return table row
function gitlab.user(api, ctx)
    return {
        repo_id = ctx.repo_id,
        login = api.username,
        name = api.name,
    }
end

--- A GitLab todo → a `notifications` row. GitLab's action_name is mapped to the closest config reason key
--- so the inbox badge resolves; a pending todo is unread.
---@param api table  a GitLab todo object
---@param ctx { repo_id?: integer, topic_id?: integer }
---@return table row
function gitlab.notification(api, ctx)
    local reason_map = {
        assigned = "assign",
        mentioned = "mention",
        directly_addressed = "mention",
        review_requested = "review_requested",
        approval_required = "review_requested",
        build_failed = "ci_activity",
        marked = "state_change",
        unmergeable = "state_change",
        merge_train_removed = "state_change",
    }
    local target = type(api.target) == "table" and api.target or {}
    return {
        repo_id = ctx.repo_id,
        topic_id = ctx.topic_id,
        forge_id = api.id and tostring(api.id) or nil,
        reason = reason_map[api.action_name] or api.action_name,
        unread = bool(api.state == "pending"),
        updated = to_iso(api.updated_at),
        title = target.title or api.body,
        url = api.target_url,
    }
end

--- A GitLab MR change (one entry of `/changes`) → a `pr_files` row. GitLab's status is derived from the
--- new_file/deleted_file/renamed_file flags; per-file line totals are not on the change object.
---@param api table  `{ old_path, new_path, new_file, deleted_file, renamed_file }`
---@param ctx { topic_id: integer }
---@return table row
function gitlab.pr_file(api, ctx)
    local status = "modified"
    if api.new_file then
        status = "added"
    elseif api.deleted_file then
        status = "removed"
    elseif api.renamed_file then
        status = "renamed"
    end
    return {
        topic_id = ctx.topic_id,
        path = api.new_path or api.old_path,
        status = status,
        additions = nil,
        deletions = nil,
    }
end

M.gitlab = gitlab

-- ── Gitea / Forgejo / Codeberg normalizers ────────────────────────────────────────
-- Gitea/Forgejo `/api/v1` is GitHub-FLAVORED but its OWN shape, mapped EXPLICITLY (never assumed
-- github-identical). Shared with GitHub: a user handle is `login`; a PR IS an issue (they share the
-- per-repo `number`, and the issue carries a `pull_request` marker); notifications are a `subject.url`
-- thread. Its OWN: `is_locked` (not `locked`); DRAFT is the `WIP:` title prefix (or a `draft` flag); a
-- milestone is addressed by its global `id` (no per-repo number); a user's display name is `full_name`;
-- a changed-file status uses `deleted`/`copied`/`changed` (normalized to the github vocabulary); a
-- notification carries no GitHub `reason`. Codeberg reuses this table (`M.forges.codeberg = gitea`).

---@class LvimForgeModelGitea
local gitea = {}

--- Whether a Gitea title marks a draft (the `WIP:` convention, or the `Draft:` prefix; case-insensitive).
---@param title any
---@return boolean
local function gitea_title_is_draft(title)
    if type(title) ~= "string" then
        return false
    end
    local t = title:gsub("^%s+", ""):lower()
    return t:match("^wip:") ~= nil or t:match("^draft:") ~= nil
end

--- A Gitea repository object → a `repositories` row.
---@param api table  a Gitea repo object (`{ owner={login}, name, private, default_branch, clone_url|html_url }`)
---@param ctx { forge: string, host: string, owner?: string, name?: string, tracked?: "full"|"selective" }
---@return table row
function gitea.repository(api, ctx)
    return {
        forge = ctx.forge,
        host = ctx.host,
        owner = login_of(api.owner) or ctx.owner,
        name = api.name or ctx.name,
        remote_url = api.clone_url or api.html_url,
        default_branch = api.default_branch,
        is_private = bool(api.private),
        tracked = ctx.tracked,
    }
end

--- A Gitea issue OR pull object → a `topics` row. A PR is marked by `pull_request` (issue endpoint) or the
--- presence of `head`/`base` (pull endpoint); merged state comes from `merged`/`merged_at` or the issue's
--- `pull_request.merged`. Gitea uses `is_locked`. `unread`/`saved_note` are LOCAL and NOT set here.
---@param api table  a Gitea issue/pull object
---@param ctx { repo_id: integer }
---@return table row
function gitea.topic(api, ctx)
    local pr_meta = type(api.pull_request) == "table" and api.pull_request or nil
    local is_pr = pr_meta ~= nil or api.head ~= nil or api.base ~= nil
    local state
    if api.merged or api.merged_at or (pr_meta and pr_meta.merged) then
        state = "merged"
    else
        state = api.state -- "open" | "closed"
    end
    return {
        repo_id = ctx.repo_id,
        kind = is_pr and "pullreq" or "issue",
        number = api.number,
        state = state,
        title = api.title,
        body = api.body,
        author = login_of(api.user),
        created = to_iso(api.created_at),
        updated = to_iso(api.updated_at),
        closed_at = to_iso(api.closed_at),
        locked = bool(api.is_locked),
        milestone_id = nil, -- resolved by the sync layer after the milestones upsert
        html_url = api.html_url,
    }
end

--- A Gitea pull object → a `pullreqs` extras row. Draft is the `draft` flag OR the `WIP:` title prefix;
--- head/base come off the `head`/`base` sub-objects (`ref`/`sha`/`repo.full_name`).
---@param api table  a Gitea pull object
---@param ctx { topic_id: integer }
---@return table row
function gitea.pullreq(api, ctx)
    local head = type(api.head) == "table" and api.head or {}
    local base = type(api.base) == "table" and api.base or {}
    local is_draft = api.draft == true or gitea_title_is_draft(api.title)
    return {
        topic_id = ctx.topic_id,
        base_ref = base.ref,
        head_ref = head.ref,
        head_repo = type(head.repo) == "table" and head.repo.full_name or nil,
        head_sha = head.sha,
        draft = bool(is_draft),
        mergeable = bool(api.mergeable),
        merged_by = login_of(api.merged_by),
        additions = api.additions,
        deletions = api.deletions,
        changed_files = api.changed_files,
        commits = api.commits,
        review_decision = nil,
    }
end

--- A Gitea comment / review comment → a `posts` row. `ctx.kind` selects the flavour ("comment" |
--- "review-comment" | "review-body"). `thread_id` / `reply_to` / `review_id` are stamped by the backend's
--- detail assembly (Gitea has no reply/thread id on a comment). The line comes off `line_num` (fallbacks
--- across versions); the side defaults to the new (RIGHT) side.
---@param api table  a Gitea comment / review-comment object
---@param ctx { topic_id: integer, kind: string }
---@return table row
function gitea.post(api, ctx)
    local line = api.line_num or api.position or api.original_line or api.original_position or api.line
    return {
        topic_id = ctx.topic_id,
        forge_id = api.id and tostring(api.id) or nil,
        kind = ctx.kind,
        author = login_of(api.user),
        created = to_iso(api.created_at),
        updated = to_iso(api.updated_at),
        body = api.body,
        reply_to = api.reply_to and tostring(api.reply_to) or nil,
        review_id = (api.pull_request_review_id and tostring(api.pull_request_review_id))
            or (api.review_id and tostring(api.review_id))
            or nil,
        thread_id = api.thread_id and tostring(api.thread_id) or nil,
        path = api.path,
        line = line,
        side = api.side or (ctx.kind == "review-comment" and "RIGHT" or nil),
        original_line = api.original_line,
        outdated = nil,
        reactions = nil,
    }
end

--- A Gitea PullReview → a `reviews` row. States map: APPROVED→approved, REQUEST_CHANGES→changes,
--- COMMENT→commented, PENDING/REQUEST_REVIEW→pending.
---@param api table  a Gitea review object
---@param ctx { topic_id: integer }
---@return table row
function gitea.review(api, ctx)
    local map = {
        APPROVED = "approved",
        REQUEST_CHANGES = "changes",
        COMMENT = "commented",
        PENDING = "pending",
        REQUEST_REVIEW = "pending",
    }
    return {
        topic_id = ctx.topic_id,
        forge_id = api.id and tostring(api.id) or nil,
        author = login_of(api.user),
        state = map[api.state] or (type(api.state) == "string" and api.state:lower()) or nil,
        body = api.body,
        submitted_at = to_iso(api.submitted_at),
    }
end

--- A Gitea review thread (reshaped by the backend to `{ id, path, line, side, resolved }`, grouped by
--- (path,line) from the review comments) → a `threads` row. `node_id` is left nil: Gitea has no resolve
--- API keyed by a node id (`caps.thread_resolve = false`; the resolved state is read-only).
---@param api table  a Gitea-derived thread object
---@param ctx { topic_id: integer }
---@return table row
function gitea.thread(api, ctx)
    return {
        topic_id = ctx.topic_id,
        forge_id = api.id and tostring(api.id) or nil,
        node_id = nil,
        path = api.path,
        line = api.line,
        side = api.side,
        resolved = bool(api.resolved),
        outdated = bool(api.outdated),
    }
end

--- A Gitea label → a `labels` row. Gitea colours may or may not carry a leading `#` across versions — the
--- `#` is stripped to match GitHub's bare hex.
---@param api table  `{ id, name, color, description }`
---@param ctx { repo_id: integer }
---@return table row
function gitea.label(api, ctx)
    local color = api.color
    if type(color) == "string" then
        color = color:gsub("^#", "")
    end
    return {
        repo_id = ctx.repo_id,
        forge_id = api.id and tostring(api.id) or nil,
        name = api.name,
        color = color,
        description = api.description,
    }
end

--- A Gitea milestone → a `milestones` row. Gitea addresses a milestone by its global `id` (there is no
--- per-repo milestone number), so `number` MIRRORS the id — the value the "set milestone" write PUTs.
---@param api table  `{ id, title, state, due_on }`
---@param ctx { repo_id: integer }
---@return table row
function gitea.milestone(api, ctx)
    return {
        repo_id = ctx.repo_id,
        forge_id = api.id and tostring(api.id) or nil,
        number = api.id,
        title = api.title,
        state = api.state, -- "open" | "closed"
        due = to_iso(api.due_on),
    }
end

--- A Gitea user → a repo-scoped `users` row (the display name is `full_name`).
---@param api table  `{ login, full_name }`
---@param ctx { repo_id: integer }
---@return table row
function gitea.user(api, ctx)
    return {
        repo_id = ctx.repo_id,
        login = api.login,
        name = api.full_name or api.name,
    }
end

--- A Gitea notification thread → a `notifications` row. Gitea carries NO GitHub-style `reason` (the inbox
--- falls back to a bell for a nil reason); the topic number is parsed from `subject.url` by the sync layer.
---@param api table  a Gitea notification thread object
---@param ctx { repo_id?: integer, topic_id?: integer }
---@return table row
function gitea.notification(api, ctx)
    local subject = type(api.subject) == "table" and api.subject or {}
    return {
        repo_id = ctx.repo_id,
        topic_id = ctx.topic_id,
        forge_id = api.id and tostring(api.id) or nil,
        reason = nil, -- Gitea has no reason field → the inbox badge uses its bell fallback
        unread = bool(api.unread),
        updated = to_iso(api.updated_at),
        title = subject.title,
        url = subject.url,
    }
end

--- A Gitea changed file → a `pr_files` row. Gitea's status vocabulary is normalized to the github one the
--- UI renders (added / modified / removed / renamed).
---@param api table  `{ filename, status, additions, deletions }`
---@param ctx { topic_id: integer }
---@return table row
function gitea.pr_file(api, ctx)
    local status_map = { deleted = "removed", copied = "modified", changed = "modified" }
    return {
        topic_id = ctx.topic_id,
        path = api.filename,
        status = status_map[api.status] or api.status,
        additions = api.additions,
        deletions = api.deletions,
    }
end

M.gitea = gitea

-- ── the forge-agnostic dispatch seam ───────────────────────────────────────────

--- Per-forge normalizer tables. Every forge exposes the SAME entity keys, so the sync engine only ever
--- calls `model.normalize(forge, entity, api, ctx)`. Codeberg IS hosted Forgejo → it reuses the gitea
--- normalizers (one table, a first-class named forge).
---@type table<string, table<string, fun(api: table, ctx: table): table>>
M.forges = { github = github, gitlab = gitlab, gitea = gitea, codeberg = gitea }

-- ── per-forge field accessors (the forge-varying reads the sync engine needs off a raw topic object) ──
-- These live beside the normalizers (the one place forge shape is known) so the sync engine never
-- reaches into a forge-specific field directly. GitHub uses `login` / `requested_reviewers` /
-- `subject.url` / `number`; GitLab uses `username` / `reviewers` / `target_url` / `iid`. Gitea / Codeberg
-- are GitHub-shaped for ALL of these (login / requested_reviewers / subject.url / number + head/base), so
-- they take the same (non-gitlab) branch — no gitea-specific accessor is needed.

--- The assignee handles of a raw topic (issue/MR) object.
---@param forge string
---@param api table
---@return string[]
function M.assignee_logins(forge, api)
    local out = {}
    local key = forge == "gitlab" and "username" or "login"
    for _, a in ipairs((type(api) == "table" and api.assignees) or {}) do
        if a[key] then
            out[#out + 1] = a[key]
        end
    end
    return out
end

--- The requested-reviewer handles of a raw pull/MR object.
---@param forge string
---@param api table
---@return string[]
function M.reviewer_logins(forge, api)
    local out = {}
    local list = forge == "gitlab" and (type(api) == "table" and api.reviewers)
        or (type(api) == "table" and api.requested_reviewers)
    local key = forge == "gitlab" and "username" or "login"
    for _, r in ipairs(list or {}) do
        if r[key] then
            out[#out + 1] = r[key]
        end
    end
    return out
end

--- The subject URL of a raw notification (GitHub notification thread / GitLab todo) — the sync layer
--- parses the trailing topic number off it.
---@param forge string
---@param n table
---@return string?
function M.notification_url(forge, n)
    if type(n) ~= "table" then
        return nil
    end
    if forge == "gitlab" then
        return n.target_url
    end
    return type(n.subject) == "table" and n.subject.url or nil
end

--- The `{ kind, number }` a mutation RESPONSE announces (the fallback when a verb did not pass an explicit
--- `emit`). GitHub: a PR carries `pull_request`/`head`/`base`, the number is `number`. GitLab: an MR
--- carries `source_branch`, the number is `iid`.
---@param forge string
---@param body table
---@return { kind: string?, number: integer? }
function M.response_ref(forge, body)
    if type(body) ~= "table" then
        return {}
    end
    if forge == "gitlab" then
        local kind = (body.source_branch ~= nil or body.target_branch ~= nil) and "pullreq"
            or (body.iid ~= nil and "issue")
            or nil
        return { kind = kind, number = body.iid }
    end
    local kind = (body.pull_request ~= nil and "pullreq")
        or ((body.head ~= nil or body.base ~= nil) and "pullreq")
        or (body.number ~= nil and "issue")
        or nil
    return { kind = kind, number = body.number }
end

--- Normalize an API object for `forge`/`entity` into a db row. Errors if the forge/entity has no
--- normalizer yet (a build-time contract check, never a silent nil row).
---@param forge string
---@param entity string  repository|topic|pullreq|post|review|thread|label|milestone|user|notification|pr_file
---@param api table
---@param ctx table
---@return table row
function M.normalize(forge, entity, api, ctx)
    local fns = M.forges[forge]
    if not fns or type(fns[entity]) ~= "function" then
        error(("lvim-forge.model: no %s normalizer for forge '%s'"):format(entity, tostring(forge)))
    end
    return fns[entity](api, ctx)
end

return M
