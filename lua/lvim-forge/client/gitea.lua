-- lvim-forge.client.gitea: the Gitea / Forgejo / Codeberg backend — the same function surface as
-- `client/github` and `client/gitlab` (the read set the sync engine drives + the write set the action
-- layer composes), implemented against the Gitea/Forgejo `/api/v1` REST API. It is reached ONLY through
-- the `client.backend(forge)` dispatch seam; the sync engine, the action layer and the UI never name it
-- directly, so Gitea slots in beside GitHub/GitLab with no change to any of them. **Codeberg** is hosted
-- Forgejo — `client/codeberg.lua` is a one-line re-export of THIS module, so a `codeberg.org` (or a
-- self-hosted Forgejo/Gitea) repo runs the exact same code, only the base URL (`https://<host>/api/v1`)
-- differing, resolved host-driven from `config.hosts` / `detect.api_base`.
--
-- Transport: REST via the SAME `client.request(spec, cb)` seam — Gitea/Forgejo have no raw-API-passthrough
-- CLI (the `tea` CLI is a porcelain, not an `api` passthrough like gh/glab), so the transport is ALWAYS
-- curl+PAT to `https://<host>/api/v1` (`client.resolve_transport` forces "rest" for gitea/codeberg). The
-- seam's pagination/rate-limit loop is REST/Link-shaped and Gitea pages via `Link: rel="next"` too.
--
-- The Gitea shape the mappings hinge on (see `model.gitea.*` for the row normalization) — GitHub-FLAVORED
-- but its OWN endpoints/fields, mapped EXPLICITLY (never assumed github-identical):
--   * A PULL REQUEST is the PR flavour; a PR IS an issue (they share the `number` / `index`, and the
--     issue endpoint carries a `pull_request` marker), so comments live under `issues/{index}`.
--   * The user-facing number is the per-repo `number` (the schema's topic key, like GitHub); Gitea's
--     global `id` is the `forge_id`. A user handle is `login` (github-shaped).
--   * DRAFT is a `WIP:` title prefix (Gitea's draft convention) — toggling it is a TITLE edit, not a
--     dedicated endpoint (mirrors GitLab's `Draft:`).
--   * REVIEWS (`/pulls/{i}/reviews`, states APPROVED/REQUEST_CHANGES/COMMENT/PENDING) carry line comments
--     under `/reviews/{id}/comments`; there is NO flat `/pulls/{i}/comments` (unlike GitHub) — each
--     review's comments are fetched and GROUPED into threads by (path,line). Conversation-resolve has no
--     stable REST endpoint → `caps.thread_resolve = false` (the resolved state is read-only, from the
--     comment's `resolver`).
--   * LABELS are a DEDICATED endpoint (`PUT issues/{i}/labels`), NOT a field on the issue PATCH (Gitea's
--     EditIssueOption has no labels) → `plan_labels` (the seam's capability the action layer prefers).
--   * MERGE is `POST /pulls/{i}/merge { Do: merge|rebase|squash|rebase-merge|fast-forward-only }` (more
--     methods than GitHub); the branch is removed via `delete_branch_after_merge` (so a separate head-ref
--     delete is `unsupported`, like GitLab). NOTIFICATIONS are the GitHub-shaped `/notifications` inbox.
--
-- Every callback is `cb(data, err)` with the Phase-1 clean `{ kind, message, … }` error shape; a spec
-- builder returns a routed `client.request` spec (or a `{ kind = "unsupported" }` sentinel where Gitea has
-- no equivalent, which the caps gate + the action layer anticipate).
--
---@module "lvim-forge.client.gitea"

local client = require("lvim-forge.client")

local M = {}

--- The capability row (preferred by `client.caps("gitea")` / `client.caps("codeberg")` over the central
--- matrix). Gitea supports the widest merge-method set (merge/rebase/squash/rebase-merge/fast-forward),
--- draft via a title prefix, the GitHub-shaped notifications inbox, and a NATIVE batch review submit (the
--- Phase-10 DB-pending model maps to ONE `POST /pulls/{i}/reviews` with comments + a verdict). Conversation
--- RESOLVE has no stable REST endpoint across versions, so `thread_resolve` is gated OFF (read-only
--- resolved state); GraphQL is not offered.
---@type table<string, boolean>
M.caps = {
    issues = true,
    pullreqs = true,
    reviews = true,
    review_threads = true, -- read: line comments grouped into conversations
    thread_resolve = false, -- no stable REST resolve endpoint → gated off (resolved state is read-only)
    pending_review = true, -- accumulated locally (DB), submitted as ONE native Gitea review
    draft = true, -- via the WIP: title prefix (a title edit, not a dedicated API)
    notifications = true, -- the /notifications inbox (GitHub-shaped)
    graphql = false, -- Gitea has no GraphQL
    merge = true,
    rebase = true,
    squash = true,
    rebase_merge = true, -- Gitea's Do: "rebase-merge"
    fast_forward = true, -- Gitea's Do: "fast-forward-only"
    lock = true, -- PUT/DELETE /issues/{index}/lock
}

-- ── ctx + routing ──────────────────────────────────────────────────────────────
-- Gitea reuses the GitHub ctx shape (`owner`/`name`/`forge`/`host`/`base`/`transport`); paths address the
-- repo by raw `owner/name` (like GitHub, not GitLab's URL-encoded project id). `ctx.forge` is "gitea" OR
-- "codeberg" (the same impl serves both) and is stamped onto every spec so the seam resolves the base URL
-- + token for the right host.

--- Stamp the routing fields from `ctx` onto a request spec (forge/host/base + an injected test transport).
---@param ctx LvimForgeGithubCtx
---@param spec table
---@return table
local function routed(ctx, spec)
    spec.forge = ctx.forge
    spec.host = ctx.host
    spec.base = ctx.base
    if ctx.transport ~= nil then
        spec.transport = ctx.transport
    end
    return spec
end

--- The `/repos/{owner}/{name}` path prefix for `ctx`.
---@param ctx LvimForgeGithubCtx
---@return string
local function repo_path(ctx)
    return ("/repos/%s/%s"):format(ctx.owner, ctx.name)
end

--- Issue a single (or paginated) GET and hand back the decoded body. `cb(body, err, res)`.
---@param ctx LvimForgeGithubCtx
---@param path string
---@param query? table
---@param paginate boolean
---@param cb fun(body: any, err: table?, res: table?)
local function get(ctx, path, query, paginate, cb)
    client.request(routed(ctx, { path = path, query = query, paginate = paginate }), function(res, err)
        if err then
            cb(nil, err, nil)
            return
        end
        cb(res and res.body, nil, res)
    end)
end

--- The max `updated_at` across a list, or `fallback` when empty (the incremental watermark; ISO-8601
--- strings compare lexicographically).
---@param items table[]
---@param fallback? string
---@return string?
local function max_updated(items, fallback)
    local watermark = fallback
    for _, it in ipairs(items or {}) do
        local u = it.updated_at
        if type(u) == "string" and (not watermark or u > watermark) then
            watermark = u
        end
    end
    return watermark
end

-- ── repo metadata + the offline pickers' data ──────────────────────────────────

--- Repository metadata (`default_branch`, `private`, …). `cb(repo_object, err)`.
---@param ctx LvimForgeGithubCtx
---@param cb fun(repo: table?, err: table?)
function M.repo(ctx, cb)
    get(ctx, repo_path(ctx), nil, false, function(body, err)
        cb(body, err)
    end)
end

--- All repository labels (paginated). Feeds the offline label picker + the chip colors. `cb(list, err)`.
---@param ctx LvimForgeGithubCtx
---@param cb fun(labels: table[]?, err: table?)
function M.labels(ctx, cb)
    get(ctx, repo_path(ctx) .. "/labels", { limit = 50 }, true, function(body, err)
        cb(err and nil or (type(body) == "table" and body or {}), err)
    end)
end

--- All repository milestones (open + closed; paginated). `cb(list, err)`.
---@param ctx LvimForgeGithubCtx
---@param cb fun(milestones: table[]?, err: table?)
function M.milestones(ctx, cb)
    get(ctx, repo_path(ctx) .. "/milestones", { state = "all", limit = 50 }, true, function(body, err)
        cb(err and nil or (type(body) == "table" and body or {}), err)
    end)
end

--- The assignable users (paginated) — the offline assignee / @-mention picker data. `cb(list, err)`.
---@param ctx LvimForgeGithubCtx
---@param cb fun(users: table[]?, err: table?)
function M.assignable_users(ctx, cb)
    get(ctx, repo_path(ctx) .. "/assignees", { limit = 50 }, true, function(body, err)
        cb(err and nil or (type(body) == "table" and body or {}), err)
    end)
end

--- The authenticated user's login (for a selective involves-me pull / the draft author label).
--- `cb(login, err)`.
---@param ctx LvimForgeGithubCtx
---@param cb fun(login: string?, err: table?)
function M.viewer(ctx, cb)
    get(ctx, "/user", nil, false, function(body, err)
        cb(err and nil or (type(body) == "table" and body.login or nil), err)
    end)
end

-- ── incremental topic list ─────────────────────────────────────────────────────

--- Topics (issues + PRs) updated since a watermark. Gitea's `issues` endpoint returns BOTH issues and
--- pulls (each PR carries a `pull_request` marker, like GitHub), so one paged request covers both kinds;
--- `since` filters to items updated after the watermark (the max `updated_at` is carried forward). Gitea
--- has no combined `involves` scope, so the `selective` mode falls back to the full list (documented,
--- like GitLab). `cb({ topics, watermark, truncated }, err)`.
---@param ctx LvimForgeGithubCtx
---@param since? string  the ISO-8601 watermark
---@param opts? { selective?: boolean, viewer?: string }
---@param cb fun(result: { topics: table[], watermark: string?, truncated: boolean }?, err: table?)
function M.topics_since(ctx, since, opts, cb)
    -- `type` is omitted deliberately: Gitea returns issues AND pulls when it is not set.
    local query = { state = "all", limit = 50 }
    if since then
        query.since = since
    end
    client.request(
        routed(ctx, { path = repo_path(ctx) .. "/issues", query = query, paginate = true }),
        function(res, err)
            if err then
                cb(nil, err)
                return
            end
            local items = type(res.body) == "table" and res.body or {}
            cb({ topics = items, watermark = max_updated(items, since), truncated = res.truncated or false }, nil)
        end
    )
end

-- ── one topic's full detail ─────────────────────────────────────────────────────

--- The anchor line of a Gitea review comment (`line_num` is the primary field; `position` / the original
--- variants are fallbacks across versions).
---@param rc table
---@return integer?
local function comment_line(rc)
    return rc.line_num or rc.position or rc.original_line or rc.original_position or rc.line
end

--- Group the flat set of a PR's review comments (accumulated across its reviews) into review-comment posts
--- (each stamped with a `thread_id`, and a `reply_to` when it is not the group's first comment) and the
--- thread rows. Gitea has no explicit reply/thread id on a review comment, so a CONVERSATION is the set of
--- comments sharing a (path,line) — the group's first comment is the thread root; a thread is `resolved`
--- when its root carries a `resolver` (the read-only resolved state Gitea exposes). `system` notes skip.
---@param comments table[]
---@return table[] review_comments, table[] threads
local function group_review_comments(comments)
    local root_by_key = {}
    local threads = {}
    local out = {}
    for _, rc in ipairs(comments or {}) do
        if not rc.system then
            local line = comment_line(rc)
            local key = (rc.path or "") .. ":" .. tostring(line)
            local root = root_by_key[key]
            if not root then
                root = rc
                root_by_key[key] = rc
                local resolver = rc.resolver
                threads[#threads + 1] = {
                    id = rc.id,
                    path = rc.path,
                    line = line,
                    side = "RIGHT",
                    resolved = resolver ~= nil and resolver ~= vim.NIL,
                }
            end
            rc.thread_id = root.id
            if rc.id ~= root.id then
                rc.reply_to = root.id
            end
            out[#out + 1] = rc
        end
    end
    return out, threads
end

--- One topic's FULL detail as a single object shaped for `model.normalize` (the SAME `detail` contract the
--- GitHub / GitLab backends produce: `{ issue, pull?, comments, reviews?, review_comments?, threads?,
--- files? }`, so `sync.upsert_detail` is forge-blind). A PR is detected by the issue's `pull_request`
--- marker; for a PR it additionally fetches the pull object, its reviews, EACH review's line comments
--- (grouped into threads), and the changed-file set. Any sub-request error aborts (never a partial detail).
--- `cb(detail, err)`.
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param cb fun(detail: table?, err: table?)
function M.topic_detail(ctx, number, cb)
    local rp = repo_path(ctx)

    get(ctx, ("%s/issues/%d"):format(rp, number), nil, false, function(issue, e1)
        if e1 then
            cb(nil, e1)
            return
        end
        local is_pr = type(issue) == "table" and issue.pull_request ~= nil
        get(ctx, ("%s/issues/%d/comments"):format(rp, number), { limit = 50 }, true, function(comments, e2)
            if e2 then
                cb(nil, e2)
                return
            end
            local detail = { issue = issue, comments = type(comments) == "table" and comments or {} }
            if not is_pr then
                cb(detail, nil)
                return
            end

            get(ctx, ("%s/pulls/%d"):format(rp, number), nil, false, function(pull, e3)
                if e3 then
                    cb(nil, e3)
                    return
                end
                detail.pull = pull

                get(ctx, ("%s/pulls/%d/reviews"):format(rp, number), { limit = 50 }, true, function(reviews, e4)
                    if e4 then
                        cb(nil, e4)
                        return
                    end
                    detail.reviews = type(reviews) == "table" and reviews or {}

                    -- Gitea has no flat PR-comments endpoint — collect each review's comments (skip a
                    -- review that reports zero) sequentially, then group them into threads.
                    local with_comments = {}
                    for _, rv in ipairs(detail.reviews) do
                        if
                            type(rv) == "table"
                            and rv.id ~= nil
                            and (rv.comments_count == nil or (tonumber(rv.comments_count) or 0) > 0)
                        then
                            with_comments[#with_comments + 1] = rv
                        end
                    end

                    local all_rc = {}
                    local i = 0
                    local function next_review()
                        i = i + 1
                        if i > #with_comments then
                            detail.review_comments, detail.threads = group_review_comments(all_rc)
                            get(ctx, ("%s/pulls/%d/files"):format(rp, number), { limit = 50 }, true, function(files, e6)
                                if e6 then
                                    cb(nil, e6)
                                    return
                                end
                                detail.files = type(files) == "table" and files or {}
                                cb(detail, nil)
                            end)
                            return
                        end
                        local rv = with_comments[i]
                        get(
                            ctx,
                            ("%s/pulls/%d/reviews/%s/comments"):format(rp, number, tostring(rv.id)),
                            nil,
                            false,
                            function(rcs, e5)
                                if e5 then
                                    cb(nil, e5)
                                    return
                                end
                                for _, rc in ipairs(type(rcs) == "table" and rcs or {}) do
                                    rc.review_id = rv.id
                                    rc.pull_request_review_id = rv.id
                                    all_rc[#all_rc + 1] = rc
                                end
                                next_review()
                            end
                        )
                    end
                    next_review()
                end)
            end)
        end)
    end)
end

-- ── notifications ───────────────────────────────────────────────────────────────

--- The repo-scoped notifications (paginated), including already-read ones (`all=true`) so a read-state
--- change is reflected. `since` filters to threads updated after the watermark. `cb({ notifications,
--- watermark }, err)`.
---@param ctx LvimForgeGithubCtx
---@param since? string  the ISO-8601 notifications watermark
---@param cb fun(result: { notifications: table[], watermark: string? }?, err: table?)
function M.notifications(ctx, since, cb)
    local query = { all = "true", limit = 50 }
    if since then
        query.since = since
    end
    get(ctx, repo_path(ctx) .. "/notifications", query, true, function(body, err)
        if err then
            cb(nil, err)
            return
        end
        local items = type(body) == "table" and body or {}
        cb({ notifications = items, watermark = max_updated(items, since) }, nil)
    end)
end

-- ── WRITE endpoints (mutations) ─────────────────────────────────────────────────
-- Each returns a routed `client.request` SPEC (or drives requests + calls back, for the ops Gitea cannot
-- express in one request); it does NOT issue the request itself. The mutation path is `sync.mutate` (no
-- optimistic write). `{ kind = "unsupported" }` sentinels are surfaced cleanly by the action layer.

--- Post a new comment on a topic (a PR is an issue in Gitea → the issues comments endpoint serves both).
--- `POST /repos/{o}/{r}/issues/{number}/comments`.
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param body string
---@return table spec
function M.create_issue_comment(ctx, number, body)
    return routed(ctx, {
        method = "POST",
        path = ("%s/issues/%d/comments"):format(repo_path(ctx), number),
        body = { body = body },
    })
end

--- Edit an existing issue comment. `PATCH /repos/{o}/{r}/issues/comments/{comment_id}`.
---@param ctx LvimForgeGithubCtx
---@param comment_id integer|string
---@param body string
---@return table spec
function M.update_comment(ctx, comment_id, body)
    return routed(ctx, {
        method = "PATCH",
        path = ("%s/issues/comments/%s"):format(repo_path(ctx), tostring(comment_id)),
        body = { body = body },
    })
end

--- Editing a review (line) comment has no clean Gitea endpoint — a clean `unsupported` the action layer
--- surfaces (mirrors GitLab).
---@param _ctx LvimForgeGithubCtx
---@param _comment_id integer|string
---@param _body string
---@return table spec
function M.update_review_comment(_ctx, _comment_id, _body)
    return { kind = "unsupported", message = "editing a review comment is not supported on Gitea yet" }
end

--- Update an issue OR pull request. Gitea's `EditIssueOption` carries `title` / `body` / `state`
--- ("open"/"closed") / `assignees` (login array) / `milestone` (the milestone ID, 0 to clear) — but NO
--- labels (those are the dedicated `plan_labels` endpoint). `PATCH /repos/{o}/{r}/issues/{number}`.
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param fields table  a subset of { title, body, state, assignees, milestone }
---@return table spec
function M.update_issue(ctx, number, fields)
    fields = fields or {}
    local b = {}
    if fields.title ~= nil then
        b.title = fields.title
    end
    if fields.body ~= nil then
        b.body = fields.body
    end
    if fields.state ~= nil then
        b.state = fields.state -- "open" | "closed"
    end
    if fields.assignees ~= nil then
        b.assignees = fields.assignees
    end
    if fields.milestone ~= nil then
        b.milestone = (fields.milestone == vim.NIL) and 0 or fields.milestone
    end
    return routed(ctx, {
        method = "PATCH",
        path = ("%s/issues/%d"):format(repo_path(ctx), number),
        body = b,
    })
end

--- Lock (or unlock) an issue's conversation. Response: 204 No Content (the caller reconciles the cached
--- `locked` flag directly). `PUT /repos/{o}/{n}/issues/{index}/lock` (a `lock_reason` body) / `DELETE …/lock`.
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param lock boolean
---@return table spec
function M.lock_issue(ctx, number, lock)
    return routed(ctx, {
        method = lock and "PUT" or "DELETE",
        path = ("%s/issues/%d/lock"):format(repo_path(ctx), number),
        body = lock and { lock_reason = "resolved" } or nil,
    })
end

--- Prepare a set-assignees spec: Gitea takes an `assignees` login array on the issue PATCH (no id
--- resolution) → `cb(spec)`. `kind` is accepted for signature symmetry and ignored (a PR is an issue).
---@param ctx LvimForgeGithubCtx
---@param _kind string
---@param number integer
---@param logins string[]
---@param cb fun(spec: table?, err: table?)
function M.prepare_assignees(ctx, _kind, number, logins, cb)
    cb(M.update_issue(ctx, number, { assignees = logins or {} }))
end

--- A set-milestone spec: Gitea addresses a milestone by its global ID (= the cached row's `forge_id`), set
--- on the issue PATCH; 0 clears. `milestone_row` is the cached milestones row; `kind` is ignored.
---@param ctx LvimForgeGithubCtx
---@param _kind string
---@param number integer
---@param milestone_row? table
---@return table spec
function M.set_milestone_spec(ctx, _kind, number, milestone_row)
    local id = (milestone_row and tonumber(milestone_row.forge_id)) or 0
    return M.update_issue(ctx, number, { milestone = id })
end

--- Plan a label change. Gitea's `EditIssueOption` has NO labels field — labels are a DEDICATED endpoint
--- (`PUT /repos/{o}/{r}/issues/{number}/labels`, which REPLACES the set), and its response is the new
--- LABEL ARRAY (not the issue), so a single-PATCH + `apply_issue_sets` cannot express it. Instead this
--- planner (the `plan_reviewers` shape) returns `{ specs, apply }` and OWNS its reconcile: the PUT sends
--- the label NAMES (Gitea ≥ 1.19 / Forgejo / Codeberg accept names in `IssueLabelsOption`), and `apply`
--- upserts the returned labels + sets them on the topic. `cb(plan, err)`.
---@param ctx LvimForgeGithubCtx
---@param _kind string
---@param number integer
---@param names string[]
---@param cb fun(plan: { specs: table[], apply: fun(repo_row: table, body: table) }?, err: table?)
function M.plan_labels(ctx, _kind, number, names, cb)
    local db = require("lvim-forge.db")
    local model = require("lvim-forge.model")
    local spec = routed(ctx, {
        method = "PUT",
        path = ("%s/issues/%d/labels"):format(repo_path(ctx), number),
        body = { labels = names or {} },
    })
    cb({
        specs = { spec },
        apply = function(repo_row, body)
            local topic = db.get_topic(repo_row.id, number)
            if not topic then
                return
            end
            local ids = {}
            for _, l in ipairs(type(body) == "table" and body or {}) do
                local lid = db.upsert_label(model.normalize(repo_row.forge, "label", l, { repo_id = repo_row.id }))
                if lid then
                    ids[#ids + 1] = lid
                end
            end
            db.set_labels(topic.id, ids)
        end,
    })
end

--- Create an issue. `POST /repos/{o}/{r}/issues`.
---@param ctx LvimForgeGithubCtx
---@param title string
---@param body? string
---@return table spec
function M.create_issue(ctx, title, body)
    local b = { title = title }
    if body ~= nil and body ~= "" then
        b.body = body
    end
    return routed(ctx, { method = "POST", path = repo_path(ctx) .. "/issues", body = b })
end

--- Create a pull request. `head` = the source branch (a bare branch same-repo, `owner:branch` cross-fork),
--- `base` = the target branch. Draft is a `WIP:` title prefix (Gitea has no draft flag on create).
--- `POST /repos/{o}/{r}/pulls`.
---@param ctx LvimForgeGithubCtx
---@param fields { title: string, head: string, base: string, body?: string, draft?: boolean }
---@return table spec
function M.create_pull(ctx, fields)
    local title = fields.title
    if fields.draft and not (type(title) == "string" and title:lower():match("^%s*wip:")) then
        title = "WIP: " .. title
    end
    local b = { head = fields.head, base = fields.base, title = title }
    if type(fields.body) == "string" and fields.body ~= "" then
        b.body = fields.body
    end
    return routed(ctx, { method = "POST", path = repo_path(ctx) .. "/pulls", body = b })
end

--- Gitea's Do-value for a merge method (Gitea offers more than GitHub/GitLab).
---@type table<string, string>
local DO_MAP = {
    merge = "merge",
    squash = "squash",
    rebase = "rebase",
    ["rebase-merge"] = "rebase-merge",
    ["fast-forward"] = "fast-forward-only",
}

--- Merge a pull request. `POST /repos/{o}/{r}/pulls/{number}/merge` with `Do` (merge/rebase/squash/
--- rebase-merge/fast-forward-only), `delete_branch_after_merge` (Gitea removes the source branch as part
--- of the merge → the separate `delete_ref` is unsupported), `head_commit_id` (the sha guard) and the
--- capitalized `MergeTitleField` / `MergeMessageField`.
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param opts { method?: string, sha?: string, commit_title?: string, commit_message?: string, delete_branch?: boolean }
---@return table spec
function M.merge_pull(ctx, number, opts)
    opts = opts or {}
    local b = { Do = DO_MAP[opts.method or "merge"] or "merge" }
    if opts.delete_branch then
        b.delete_branch_after_merge = true
    end
    if type(opts.sha) == "string" and opts.sha ~= "" then
        b.head_commit_id = opts.sha
    end
    if type(opts.commit_title) == "string" and opts.commit_title ~= "" then
        b.MergeTitleField = opts.commit_title
    end
    if type(opts.commit_message) == "string" and opts.commit_message ~= "" then
        b.MergeMessageField = opts.commit_message
    end
    return routed(ctx, {
        method = "POST",
        path = ("%s/pulls/%d/merge"):format(repo_path(ctx), number),
        body = b,
    })
end

--- Gitea removes the merged source branch via the merge (`delete_branch_after_merge`), so there is no
--- separate head-ref delete — a clean `unsupported` the merge verb skips (mirrors GitLab).
---@param _ctx LvimForgeGithubCtx
---@param _branch string
---@return table spec
function M.delete_ref(_ctx, _branch)
    return { kind = "unsupported", message = "Gitea removes the source branch as part of the merge" }
end

--- Toggle a pull request's DRAFT state via a TITLE edit (Gitea's draft is the `WIP:` title prefix — no
--- dedicated endpoint, mirroring GitLab's `Draft:`). Yields a title-edit PATCH spec through `cb(spec, err)`
--- (async-shaped to match GitHub's node-id fetch, so the action layer is forge-blind). `topic.title`
--- supplies the current title; any existing `WIP:` / `Draft:` prefix is stripped, then re-added when
--- wanting a draft.
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param topic table  the cached topic row (carries `title`)
---@param want_draft boolean
---@param cb fun(spec: table?, err: table?)
function M.draft_op(ctx, number, topic, want_draft, cb)
    local title = (type(topic) == "table" and type(topic.title) == "string") and topic.title or ""
    local stripped = title:gsub("^%s*[Ww][Ii][Pp]:%s*", ""):gsub("^%s*[Dd][Rr][Aa][Ff][Tt]:%s*", "")
    local new_title = want_draft and ("WIP: " .. stripped) or stripped
    cb(routed(ctx, {
        method = "PATCH",
        path = ("%s/issues/%d"):format(repo_path(ctx), number),
        body = { title = new_title },
    }))
end

-- ── reviewers (PR — Gitea, like GitHub, has no replace: POST additions / DELETE removals) ─────────────

--- Request reviewers on a PR (adds them). `POST /repos/{o}/{r}/pulls/{number}/requested_reviewers`.
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param logins string[]
---@return table spec
function M.add_reviewers(ctx, number, logins)
    return routed(ctx, {
        method = "POST",
        path = ("%s/pulls/%d/requested_reviewers"):format(repo_path(ctx), number),
        body = { reviewers = logins },
    })
end

--- Remove requested reviewers from a PR. `DELETE /repos/{o}/{r}/pulls/{number}/requested_reviewers`.
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param logins string[]
---@return table spec
function M.remove_reviewers(ctx, number, logins)
    return routed(ctx, {
        method = "DELETE",
        path = ("%s/pulls/%d/requested_reviewers"):format(repo_path(ctx), number),
        body = { reviewers = logins },
    })
end

--- Plan the reviewer change. Gitea has no replace (like GitHub): the desired set is diffed against the
--- current, a DELETE (removals) + a POST (additions) are the specs to run. Gitea's requested-reviewer
--- endpoints return the created review-request objects (NOT the pull), so `apply` reconciles from the
--- KNOWN desired set (idempotent) rather than the response body. `cb(plan, err)`.
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param desired string[]
---@param current string[]
---@param cb fun(plan: { specs: table[], apply: fun(repo_row: table, body: table) }?, err: table?)
function M.plan_reviewers(ctx, number, desired, current, cb)
    local cur_set, des_set = {}, {}
    for _, l in ipairs(current or {}) do
        cur_set[l] = true
    end
    for _, l in ipairs(desired or {}) do
        des_set[l] = true
    end
    local added, removed = {}, {}
    for l in pairs(des_set) do
        if not cur_set[l] then
            added[#added + 1] = l
        end
    end
    for l in pairs(cur_set) do
        if not des_set[l] then
            removed[#removed + 1] = l
        end
    end
    local specs = {}
    if #removed > 0 then
        specs[#specs + 1] = M.remove_reviewers(ctx, number, removed)
    end
    if #added > 0 then
        specs[#specs + 1] = M.add_reviewers(ctx, number, added)
    end
    local db = require("lvim-forge.db")
    cb({
        specs = specs,
        apply = function(repo_row, _body)
            local topic = db.get_topic(repo_row.id, number, "pullreq")
            if topic then
                db.set_review_requests(topic.id, desired or {})
            end
        end,
    })
end

-- ── the branch's PR + the batch review submit ─────────────────────────────────────

--- The pull requests whose SOURCE branch is `head` — the `pr_for_branch` API fallback. Gitea's pulls list
--- has no head-branch filter, so the open+closed list is fetched and filtered client-side by `head.ref`
--- (an `owner:branch` head is reduced to the bare branch). `GET /repos/{o}/{r}/pulls?state=all`.
---@param ctx LvimForgeGithubCtx
---@param head string  `owner:branch` or a bare branch
---@param cb fun(pulls: table[]?, err: table?)
function M.pulls_for_head(ctx, head, cb)
    local branch = tostring(head):gsub("^[^:]+:", "")
    get(ctx, repo_path(ctx) .. "/pulls", { state = "all", limit = 50 }, true, function(body, err)
        if err then
            cb(nil, err)
            return
        end
        local out = {}
        for _, pr in ipairs(type(body) == "table" and body or {}) do
            if type(pr.head) == "table" and pr.head.ref == branch then
                out[#out + 1] = pr
            end
        end
        cb(out, nil)
    end)
end

--- The remote-side refspec segment for a PR head — Gitea (like GitHub) exposes `pull/<n>/head`.
---@param number integer
---@return string
function M.pull_head_refspec(number)
    return ("pull/%d/head"):format(number)
end

--- Resolving a review conversation has no stable Gitea REST endpoint — a clean `unsupported` (also gated
--- off by `caps.thread_resolve = false`, so the UI never offers it).
---@param _ctx LvimForgeGithubCtx
---@param _node_id string
---@param _resolve boolean
---@return table spec
function M.resolve_thread(_ctx, _node_id, _resolve)
    return { kind = "unsupported", message = "resolving review conversations is not supported on Gitea yet" }
end

--- Build the batch-review submit spec. Gitea has a NATIVE batch review endpoint (like GitHub):
--- `POST /repos/{o}/{r}/pulls/{number}/reviews` with `{ event, body, comments }`. `event` is APPROVE |
--- REQUEST_CHANGES | COMMENT. Each drafted NEW line comment maps to `{ path, body, new_position }` (RIGHT)
--- or `{ path, body, old_position }` (LEFT). Gitea's review API has NO reply-in-thread field, so a drafted
--- REPLY (which the action layer shapes as `{ in_reply_to, body }`, without an anchor) is omitted from the
--- batch (a documented v1 gap — new comments submit fully).
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param opts { event: string, body?: string, comments?: table[] }
---@return table spec
function M.submit_review(ctx, number, opts)
    opts = opts or {}
    local b = { event = opts.event }
    if type(opts.body) == "string" and opts.body ~= "" then
        b.body = opts.body
    end
    local comments = {}
    for _, c in ipairs(opts.comments or {}) do
        if c.path and c.line then
            local gc = { path = c.path, body = c.body }
            if (c.side or "RIGHT") == "LEFT" then
                gc.old_position = math.floor(c.line)
            else
                gc.new_position = math.floor(c.line)
            end
            comments[#comments + 1] = gc
        end
    end
    if #comments > 0 then
        b.comments = comments
    end
    return routed(ctx, {
        method = "POST",
        path = ("%s/pulls/%d/reviews"):format(repo_path(ctx), number),
        body = b,
    })
end

--- Run the batch review submit (Gitea's native single POST). Issues the spec and calls back with the
--- returned review object (the action layer reconciles it, like GitHub). `opts.viewer` is accepted for
--- signature symmetry with GitLab (which synthesizes the author) and unused here.
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param opts { event: string, body?: string, comments?: table[], viewer?: string }
---@param cb fun(review: table?, err: table?)
function M.run_submit(ctx, number, opts, cb)
    client.request(M.submit_review(ctx, number, opts), function(res, err)
        if err then
            cb(nil, err)
            return
        end
        cb(res and res.body, nil)
    end)
end

return M
