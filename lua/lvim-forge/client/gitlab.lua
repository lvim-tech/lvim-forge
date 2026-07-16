-- lvim-forge.client.gitlab: the GitLab-specific backend — the same function surface as `client/github`
-- (the read set the sync engine drives + the write set the action layer composes), implemented against
-- the GitLab v4 REST API. It is reached ONLY through the `client.backend(forge)` dispatch seam; the sync
-- engine, the action layer and the UI never name it directly, so GitLab slots in beside GitHub with no
-- change to any of them.
--
-- Transport: REST via the SAME `client.request(spec, cb)` seam GitHub uses — `spec.transport = "auto"`
-- resolves to `glab api` when installed+authed, else curl+PAT against `https://<host>/api/v4` (self-managed
-- hosts included, via `config.hosts` + `detect.api_base`). REST is preferred over GitLab's GraphQL: it is
-- the same shape under both transports and the seam's pagination/rate-limit loop is REST/Link-shaped
-- (GitLab pages via `Link: rel="next"` too). GraphQL is avoided entirely for v1 — every op below has a
-- clean REST endpoint.
--
-- The GitLab shape the mappings hinge on (see `model.gitlab.*` for the row normalization):
--   * A MERGE REQUEST is the PR flavour; the project id in a path is the URL-encoded `owner/name`; the
--     user-facing number is the per-project `iid` (the schema's topic key), GitLab's global `id` is the
--     `forge_id`.
--   * NOTES are comments (`/notes`); DISCUSSIONS are threads (`/discussions`, `resolvable`/`resolved`); a
--     diff discussion's notes are review (line) comments.
--   * DRAFT is a `Draft:` title prefix — toggling it is a TITLE edit (a PUT), NOT a dedicated endpoint.
--   * MERGE is `PUT /merge_requests/{iid}/merge` (+ `squash`, `should_remove_source_branch`); APPROVALS
--     are the review signal (`/approve` · `/unapprove`); TODOS are the notifications inbox (`/todos`).
--
-- Every callback is `cb(data, err)` with the Phase-1 clean `{ kind, message, … }` error shape; a spec
-- builder returns a routed `client.request` spec (or a `{ kind = "unsupported" }` sentinel when GitLab has
-- no equivalent, which the caps gate + the action layer anticipate). Some ops that GitLab cannot express
-- as a single request (id-resolving a reviewer set, the batch review submit) are async and drive
-- `client.request` themselves, calling back with the final object the action layer reconciles.
--
---@module "lvim-forge.client.gitlab"

local client = require("lvim-forge.client")

local M = {}

--- The capability row (preferred by `client.caps("gitlab")` over the central matrix). GitLab supports
--- merge/squash + branch removal on merge, draft via a title prefix, thread resolve over REST
--- (discussions), and the todos notifications inbox; the pending review is BATCHED client-side (Phase 10's
--- DB-pending model) then submitted as discussions + an approval.
---@type table<string, boolean>
M.caps = {
    issues = true,
    pullreqs = true,
    reviews = true,
    review_threads = true,
    thread_resolve = true,
    pending_review = true, -- accumulated locally (DB), submitted as discussions + approval
    draft = true, -- via the Draft: title prefix (a title edit, not a dedicated API)
    notifications = true, -- the todos API
    graphql = false, -- v1 uses REST exclusively
    merge = true,
    rebase = true,
    squash = true,
}

-- ── ctx + routing ──────────────────────────────────────────────────────────────

--- The forge-repository context (mirrors the GitHub ctx). The write layer additionally stamps `kind`
--- (issue|pullreq) and `number` (the iid) on it for the ops whose GitLab endpoint depends on them
--- (a note lives under `merge_requests/{iid}` OR `issues/{iid}`); GitHub ignores those fields.
---@class LvimForgeGitlabCtx : LvimForgeGithubCtx
---@field kind?   string
---@field number? integer

--- URL-encode a path SEGMENT (RFC 3986 unreserved kept; `/` encoded — a subgroup path `a/b/name` becomes
--- one project id `a%2Fb%2Fname`).
---@param s string
---@return string
local function enc(s)
    return (
        tostring(s):gsub("[^%w%-_%.~]", function(ch)
            return string.format("%%%02X", string.byte(ch))
        end)
    )
end

--- The URL-encoded project id (`owner%2Fname`) for `ctx`.
---@param ctx LvimForgeGitlabCtx
---@return string
local function project(ctx)
    return enc(ctx.owner .. "/" .. ctx.name)
end

--- The `/projects/{id}` path prefix for `ctx`.
---@param ctx LvimForgeGitlabCtx
---@return string
local function proj_path(ctx)
    return "/projects/" .. project(ctx)
end

--- The topic endpoint segment for a kind ("merge_requests" | "issues").
---@param kind? string
---@return string
local function kind_seg(kind)
    return kind == "pullreq" and "merge_requests" or "issues"
end

--- Stamp the routing fields from `ctx` onto a request spec (forge/host/base + an injected test transport).
---@param ctx LvimForgeGitlabCtx
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

--- Issue a single (or paginated) GET and hand back the decoded body. `cb(body, err, res)`.
---@param ctx LvimForgeGitlabCtx
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

--- The max `updated_at` across a list, or `fallback` when empty (the incremental watermark).
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

--- Project metadata (`default_branch`, `visibility`, …). `cb(project_object, err)`.
---@param ctx LvimForgeGitlabCtx
---@param cb fun(repo: table?, err: table?)
function M.repo(ctx, cb)
    get(ctx, proj_path(ctx), nil, false, function(body, err)
        cb(body, err)
    end)
end

--- All project labels (paginated, with colour/description details). `cb(list, err)`.
---@param ctx LvimForgeGitlabCtx
---@param cb fun(labels: table[]?, err: table?)
function M.labels(ctx, cb)
    get(ctx, proj_path(ctx) .. "/labels", { per_page = 100, with_counts = "false" }, true, function(body, err)
        cb(err and nil or (type(body) == "table" and body or {}), err)
    end)
end

--- All project milestones (open + closed; paginated). `cb(list, err)`.
---@param ctx LvimForgeGitlabCtx
---@param cb fun(milestones: table[]?, err: table?)
function M.milestones(ctx, cb)
    get(ctx, proj_path(ctx) .. "/milestones", { per_page = 100 }, true, function(body, err)
        cb(err and nil or (type(body) == "table" and body or {}), err)
    end)
end

---@type table<string, table<string, integer>>  project id → { username → numeric user id } (write-path cache)
local member_ids = {}

--- The project members (paginated) — the offline assignee / @-mention picker data. Also warms the
--- username→id cache the write path (assignees / reviewers) resolves against. `cb(list, err)`.
---@param ctx LvimForgeGitlabCtx
---@param cb fun(users: table[]?, err: table?)
function M.assignable_users(ctx, cb)
    get(ctx, proj_path(ctx) .. "/members/all", { per_page = 100 }, true, function(body, err)
        local list = err and nil or (type(body) == "table" and body or {})
        if list then
            local map = member_ids[project(ctx)] or {}
            for _, u in ipairs(list) do
                if u.username and u.id then
                    map[u.username] = u.id
                end
            end
            member_ids[project(ctx)] = map
        end
        cb(list, err)
    end)
end

--- The authenticated user's `username` (for a selective involves-me pull / the draft author label).
--- `cb(username, err)`.
---@param ctx LvimForgeGitlabCtx
---@param cb fun(login: string?, err: table?)
function M.viewer(ctx, cb)
    get(ctx, "/user", nil, false, function(body, err)
        cb(err and nil or (type(body) == "table" and body.username or nil), err)
    end)
end

-- ── incremental topic list ─────────────────────────────────────────────────────

--- Topics (merge requests + issues) updated since a watermark. GitLab has SEPARATE MR and issue
--- endpoints (unlike GitHub's combined issues feed), so both are fetched and merged; `order_by=updated_at
--- &sort=asc` matches the incremental model. The `selective` involves-me mode is not distinguished for
--- GitLab v1 (the whole project is fetched; documented). `cb({ topics, watermark, truncated }, err)`.
---@param ctx LvimForgeGitlabCtx
---@param since? string  the ISO-8601 watermark
---@param opts? { selective?: boolean, viewer?: string }
---@param cb fun(result: { topics: table[], watermark: string?, truncated: boolean }?, err: table?)
function M.topics_since(ctx, since, opts, cb)
    local base_query = { order_by = "updated_at", sort = "asc", per_page = 100, scope = "all" }
    if since then
        base_query.updated_after = since
    end

    local function fetch(kind_path, extra, done)
        local q = vim.tbl_extend("force", {}, base_query, extra or {})
        client.request(
            routed(ctx, { path = proj_path(ctx) .. kind_path, query = q, paginate = true }),
            function(res, err)
                if err then
                    done(nil, false, err)
                    return
                end
                done(type(res.body) == "table" and res.body or {}, res.truncated or false, nil)
            end
        )
    end

    fetch("/merge_requests", { with_labels_details = "true" }, function(mrs, mr_trunc, e1)
        if e1 then
            cb(nil, e1)
            return
        end
        fetch("/issues", { with_labels_details = "true" }, function(issues, iss_trunc, e2)
            if e2 then
                cb(nil, e2)
                return
            end
            local topics = {}
            vim.list_extend(topics, mrs)
            vim.list_extend(topics, issues)
            cb({ topics = topics, watermark = max_updated(topics, since), truncated = mr_trunc or iss_trunc }, nil)
        end)
    end)
end

-- ── one topic's full detail ─────────────────────────────────────────────────────

--- Split a discussions list into the timeline `comments`, the diff `review_comments` (thread_id stamped),
--- and the review `threads`. System notes (label/assign/state events) are skipped. An `individual_note`
--- discussion is a single plain comment; a diff discussion (its first note carries a `position`) becomes a
--- thread + review-comment notes; a non-diff discussion thread is treated as plain comments.
---@param discussions table[]
---@return table comments, table review_comments, table threads
local function split_discussions(discussions)
    local comments, review_comments, threads = {}, {}, {}
    for _, d in ipairs(discussions or {}) do
        local notes = type(d.notes) == "table" and d.notes or {}
        local first = notes[1]
        local is_diff = first ~= nil and (first.type == "DiffNote" or type(first.position) == "table")
        if is_diff then
            threads[#threads + 1] = { id = d.id, position = first.position, resolved = first.resolved == true }
            for i, n in ipairs(notes) do
                if not n.system then
                    n.thread_id = d.id
                    if i > 1 then
                        n.reply_to = first.id
                    end
                    review_comments[#review_comments + 1] = n
                end
            end
        else
            for _, n in ipairs(notes) do
                if not n.system then
                    comments[#comments + 1] = n
                end
            end
        end
    end
    return comments, review_comments, threads
end

--- The approvals object's `approved_by` → review-shaped objects (`{ id, user, state = "approved" }`), one
--- per approver (a synthetic `forge_id` keys the review row's natural key).
---@param approvals table?
---@return table[]
local function approvals_to_reviews(approvals)
    local out = {}
    for _, a in ipairs((type(approvals) == "table" and approvals.approved_by) or {}) do
        local user = a.user or a
        if type(user) == "table" and user.username then
            out[#out + 1] = { id = "approval:" .. user.username, user = user, state = "approved" }
        end
    end
    return out
end

--- One topic's FULL detail as a single object shaped for `model.normalize` (the SAME `detail` contract the
--- GitHub backend produces: `{ issue, pull?, comments, reviews?, review_comments?, threads?, files? }`, so
--- `sync.upsert_detail` is forge-blind). Resolves the kind from `ctx.kind` when the sync engine stamped it,
--- else probes the merge_request endpoint and falls back to the issue endpoint on a 404. For an MR it also
--- fetches discussions (→ comments/review-comments/threads), approvals (→ reviews) and the change set
--- (→ files). `cb(detail, err)`.
---@param ctx LvimForgeGitlabCtx
---@param number integer
---@param cb fun(detail: table?, err: table?)
function M.topic_detail(ctx, number, cb)
    local pp = proj_path(ctx)

    --- Assemble the MR detail (discussions + approvals + changes).
    ---@param mr table
    local function mr_detail(mr)
        local detail = { issue = mr, pull = mr }
        get(ctx, ("%s/merge_requests/%d/discussions"):format(pp, number), { per_page = 100 }, true, function(disc, e2)
            if e2 then
                cb(nil, e2)
                return
            end
            detail.comments, detail.review_comments, detail.threads =
                split_discussions(type(disc) == "table" and disc or {})
            get(ctx, ("%s/merge_requests/%d/approvals"):format(pp, number), nil, false, function(appr)
                detail.reviews = approvals_to_reviews(appr)
                get(ctx, ("%s/merge_requests/%d/changes"):format(pp, number), nil, false, function(chg)
                    detail.files = (type(chg) == "table" and type(chg.changes) == "table") and chg.changes or {}
                    cb(detail, nil)
                end)
            end)
        end)
    end

    --- Assemble the issue detail (discussions → comments only).
    ---@param issue table
    local function issue_detail(issue)
        local detail = { issue = issue }
        get(ctx, ("%s/issues/%d/discussions"):format(pp, number), { per_page = 100 }, true, function(disc, e2)
            if e2 then
                cb(nil, e2)
                return
            end
            detail.comments = (split_discussions(type(disc) == "table" and disc or {}))
            cb(detail, nil)
        end)
    end

    if ctx.kind == "issue" then
        get(ctx, ("%s/issues/%d"):format(pp, number), { with_labels_details = "true" }, false, function(issue, e1)
            if e1 then
                cb(nil, e1)
                return
            end
            issue_detail(issue)
        end)
        return
    end

    -- kind == "pullreq" OR unknown: try the merge request, fall back to the issue on a 404.
    get(ctx, ("%s/merge_requests/%d"):format(pp, number), { with_labels_details = "true" }, false, function(mr, e1)
        if e1 then
            if ctx.kind == nil and e1.status == 404 then
                get(
                    ctx,
                    ("%s/issues/%d"):format(pp, number),
                    { with_labels_details = "true" },
                    false,
                    function(issue, e2)
                        if e2 then
                            cb(nil, e2)
                            return
                        end
                        issue_detail(issue)
                    end
                )
                return
            end
            cb(nil, e1)
            return
        end
        mr_detail(mr)
    end)
end

-- ── notifications (the todos inbox) ──────────────────────────────────────────────

--- The GitLab todos, scoped to THIS project (a todo carries its `project.path_with_namespace`). GitLab's
--- todos endpoint returns pending todos (the actionable inbox = unread notifications); marking one done
--- removes it (`POST /todos/{id}/mark_as_done`). `cb({ notifications, watermark }, err)`.
---@param ctx LvimForgeGitlabCtx
---@param since? string  the ISO-8601 notifications watermark
---@param cb fun(result: { notifications: table[], watermark: string? }?, err: table?)
function M.notifications(ctx, since, cb)
    get(ctx, "/todos", { per_page = 100 }, true, function(body, err)
        if err then
            cb(nil, err)
            return
        end
        local want = ctx.owner .. "/" .. ctx.name
        local items = {}
        for _, t in ipairs(type(body) == "table" and body or {}) do
            local p = type(t.project) == "table" and t.project or {}
            if
                p.path_with_namespace == want
                and (not since or (type(t.updated_at) == "string" and t.updated_at >= since))
            then
                items[#items + 1] = t
            end
        end
        cb({ notifications = items, watermark = max_updated(items, since) }, nil)
    end)
end

-- ── WRITE endpoints (mutations) ─────────────────────────────────────────────────

--- Post a new comment (note) on a topic. `POST /projects/{id}/{merge_requests|issues}/{iid}/notes`.
---@param ctx LvimForgeGitlabCtx
---@param number integer
---@param body string
---@return table spec
function M.create_issue_comment(ctx, number, body)
    return routed(ctx, {
        method = "POST",
        path = ("%s/%s/%d/notes"):format(proj_path(ctx), kind_seg(ctx.kind), number),
        body = { body = body },
    })
end

--- Edit an existing comment (note). Needs the OWNING topic iid (`ctx.number`) + its kind (`ctx.kind`).
--- `PUT /projects/{id}/{merge_requests|issues}/{iid}/notes/{note_id}`.
---@param ctx LvimForgeGitlabCtx
---@param comment_id integer|string
---@param body string
---@return table spec
function M.update_comment(ctx, comment_id, body)
    return routed(ctx, {
        method = "PUT",
        path = ("%s/%s/%d/notes/%s"):format(proj_path(ctx), kind_seg(ctx.kind), ctx.number or 0, tostring(comment_id)),
        body = { body = body },
    })
end

--- Editing a diff (review) comment requires its owning discussion id, which the edit verb does not carry —
--- deferred for GitLab v1 (a clean `unsupported` the action layer surfaces).
---@param _ctx LvimForgeGitlabCtx
---@param _comment_id integer|string
---@param _body string
---@return table spec
function M.update_review_comment(_ctx, _comment_id, _body)
    return { kind = "unsupported", message = "editing a review comment is not supported on GitLab yet" }
end

--- Update an issue OR merge request. Translates the shared GitHub-shaped `fields` to GitLab: `state`
--- ("open"/"closed") → `state_event` (reopen/close), `labels` (name array) → a comma list. Title / body
--- pass through (`body` → `description`). `PUT /projects/{id}/{merge_requests|issues}/{iid}`.
---@param ctx LvimForgeGitlabCtx
---@param number integer
---@param fields table  a subset of { title, body, state, labels }
---@return table spec
function M.update_issue(ctx, number, fields)
    fields = fields or {}
    local b = {}
    if fields.title ~= nil then
        b.title = fields.title
    end
    if fields.body ~= nil then
        b.description = fields.body
    end
    if fields.state ~= nil then
        b.state_event = (fields.state == "closed") and "close" or "reopen"
    end
    if fields.labels ~= nil then
        b.labels = table.concat(fields.labels, ",")
    end
    return routed(ctx, {
        method = "PUT",
        path = ("%s/%s/%d"):format(proj_path(ctx), kind_seg(ctx.kind), number),
        body = b,
    })
end

--- Set (or clear) a topic's milestone. `milestone_row` is the cached `milestones` row (its `forge_id` =
--- GitLab's global milestone id, the value the write PUTs as `milestone_id`); nil clears (id 0).
---@param ctx LvimForgeGitlabCtx
---@param kind string
---@param number integer
---@param milestone_row? table
---@return table spec
function M.set_milestone_spec(ctx, kind, number, milestone_row)
    local id = (milestone_row and tonumber(milestone_row.forge_id)) or 0
    return routed(ctx, {
        method = "PUT",
        path = ("%s/%s/%d"):format(proj_path(ctx), kind_seg(kind), number),
        body = { milestone_id = id },
    })
end

--- Create an issue. `POST /projects/{id}/issues`.
---@param ctx LvimForgeGitlabCtx
---@param title string
---@param body? string
---@return table spec
function M.create_issue(ctx, title, body)
    local b = { title = title }
    if body ~= nil and body ~= "" then
        b.description = body
    end
    return routed(ctx, { method = "POST", path = proj_path(ctx) .. "/issues", body = b })
end

--- Create a merge request. `head` = the source branch, `base` = the target branch. Draft is encoded as a
--- `Draft:` title prefix (GitLab has no draft flag on create). `POST /projects/{id}/merge_requests`.
---@param ctx LvimForgeGitlabCtx
---@param fields { title: string, head: string, base: string, body?: string, draft?: boolean }
---@return table spec
function M.create_pull(ctx, fields)
    local title = fields.title
    if fields.draft and not (type(title) == "string" and title:lower():match("^%s*draft:")) then
        title = "Draft: " .. title
    end
    local b = { source_branch = fields.head, target_branch = fields.base, title = title }
    if type(fields.body) == "string" and fields.body ~= "" then
        b.description = fields.body
    end
    return routed(ctx, { method = "POST", path = proj_path(ctx) .. "/merge_requests", body = b })
end

--- Merge a merge request. `PUT /projects/{id}/merge_requests/{iid}/merge` with `squash` (method "squash")
--- and `should_remove_source_branch` (`opts.delete_branch`) — GitLab removes the branch as part of the
--- merge (so the separate `delete_ref` is unsupported). `opts.sha` guards a moved head.
---@param ctx LvimForgeGitlabCtx
---@param number integer
---@param opts { method?: "merge"|"squash"|"rebase", sha?: string, commit_title?: string, commit_message?: string, delete_branch?: boolean }
---@return table spec
function M.merge_pull(ctx, number, opts)
    opts = opts or {}
    local b = {}
    if opts.method == "squash" then
        b.squash = true
    end
    if opts.delete_branch then
        b.should_remove_source_branch = true
    end
    if type(opts.sha) == "string" and opts.sha ~= "" then
        b.sha = opts.sha
    end
    if type(opts.commit_message) == "string" and opts.commit_message ~= "" then
        b.merge_commit_message = opts.commit_message
        b.squash_commit_message = opts.commit_message
    end
    return routed(ctx, {
        method = "PUT",
        path = ("%s/merge_requests/%d/merge"):format(proj_path(ctx), number),
        body = b,
    })
end

--- GitLab removes the merged source branch via the merge request merge (`should_remove_source_branch`), so
--- there is no separate head-ref delete — a clean `unsupported` the merge verb skips.
---@param _ctx LvimForgeGitlabCtx
---@param _branch string
---@return table spec
function M.delete_ref(_ctx, _branch)
    return { kind = "unsupported", message = "GitLab removes the source branch as part of the merge" }
end

--- Resolve OR unresolve a discussion (review thread) over REST — `PUT /projects/{id}/merge_requests/{iid}/
--- discussions/{discussion_id}` with `resolved`. `discussion_id` is the thread's stored node_id (= its
--- discussion id); the MR iid is `ctx.number`. No GraphQL (unlike GitHub).
---@param ctx LvimForgeGitlabCtx
---@param discussion_id string
---@param resolve boolean
---@return table spec
function M.resolve_thread(ctx, discussion_id, resolve)
    return routed(ctx, {
        method = "PUT",
        path = ("%s/merge_requests/%d/discussions/%s"):format(proj_path(ctx), ctx.number or 0, tostring(discussion_id)),
        body = { resolved = resolve and true or false },
    })
end

--- Toggle a merge request's DRAFT state via a TITLE edit (GitLab's draft is the `Draft:` title prefix —
--- there is NO dedicated endpoint, unlike GitHub's GraphQL). Yields a `PUT …/merge_requests/{iid}` title
--- spec through `cb(spec, err)` (async-shaped to match the GitHub node-id fetch, so the action layer is
--- forge-blind). `topic.title` supplies the current title.
---@param ctx LvimForgeGitlabCtx
---@param number integer
---@param topic table  the cached topic row (carries `title`)
---@param want_draft boolean
---@param cb fun(spec: table?, err: table?)
function M.draft_op(ctx, number, topic, want_draft, cb)
    local title = (type(topic) == "table" and type(topic.title) == "string") and topic.title or ""
    -- Strip any existing Draft:/WIP: prefix, then re-add when we want a draft.
    local stripped = title:gsub("^%s*[Dd][Rr][Aa][Ff][Tt]:%s*", ""):gsub("^%s*[Ww][Ii][Pp]:%s*", "")
    local new_title = want_draft and ("Draft: " .. stripped) or stripped
    cb(routed(ctx, {
        method = "PUT",
        path = ("%s/merge_requests/%d"):format(proj_path(ctx), number),
        body = { title = new_title },
    }))
end

-- ── writes needing a username→id resolution (GitLab assignees / reviewers take numeric ids) ────────────

--- Resolve a list of usernames to numeric user ids, using the members cache (warmed by `assignable_users`)
--- and fetching the member list on a miss. `cb(ids, err)`.
---@param ctx LvimForgeGitlabCtx
---@param logins string[]
---@param cb fun(ids: integer[]?, err: table?)
local function resolve_ids(ctx, logins, cb)
    logins = logins or {}
    local key = project(ctx)
    local function collect()
        local map = member_ids[key] or {}
        local ids = {}
        for _, l in ipairs(logins) do
            if map[l] then
                ids[#ids + 1] = map[l]
            end
        end
        return ids
    end
    local map = member_ids[key] or {}
    local all_known = true
    for _, l in ipairs(logins) do
        if not map[l] then
            all_known = false
            break
        end
    end
    if all_known then
        cb(collect(), nil)
        return
    end
    M.assignable_users(ctx, function(_, err)
        if err then
            cb(nil, err)
            return
        end
        cb(collect(), nil)
    end)
end

--- Prepare a set-assignees spec. GitLab takes `assignee_ids` (numeric) — the usernames are resolved to ids
--- first (async), then `cb(spec, err)` with a `PUT …/{merge_requests|issues}/{iid}` spec (an empty set
--- clears). Matches the GitHub `prepare_assignees` shape so the action layer is forge-blind.
---@param ctx LvimForgeGitlabCtx
---@param kind string
---@param number integer
---@param logins string[]
---@param cb fun(spec: table?, err: table?)
function M.prepare_assignees(ctx, kind, number, logins, cb)
    resolve_ids(ctx, logins, function(ids, err)
        if err then
            cb(nil, err)
            return
        end
        cb(routed(ctx, {
            method = "PUT",
            path = ("%s/%s/%d"):format(proj_path(ctx), kind_seg(kind), number),
            body = { assignee_ids = ids },
        }))
    end)
end

--- Plan the reviewer change. GitLab REPLACES the reviewer set in ONE `PUT …/merge_requests/{iid}` with
--- `reviewer_ids` (numeric — resolved from `desired` first). `cb(plan, err)` where `plan = { specs, apply }`
--- (`specs` = the sequence to run; `apply` reconciles the requested-reviewer set from the MR response).
---@param ctx LvimForgeGitlabCtx
---@param number integer
---@param desired string[]
---@param _current string[]
---@param cb fun(plan: { specs: table[], apply: fun(repo_row: table, body: table) }?, err: table?)
function M.plan_reviewers(ctx, number, desired, _current, cb)
    resolve_ids(ctx, desired, function(ids, err)
        if err then
            cb(nil, err)
            return
        end
        local sync = require("lvim-forge.sync")
        local spec = routed(ctx, {
            method = "PUT",
            path = ("%s/merge_requests/%d"):format(proj_path(ctx), number),
            body = { reviewer_ids = ids },
        })
        cb({
            specs = { spec },
            apply = function(repo_row, body)
                sync.apply_pr_reviewers(repo_row.id, number, body)
            end,
        })
    end)
end

-- ── the branch's MR + the batch review submit ────────────────────────────────────

--- The merge requests whose SOURCE branch is `head` — the `pr_for_branch` API fallback. `head` may be a
--- bare branch (GitLab has no `owner:branch` head syntax); `state=all` so a merged/closed MR is found too.
--- `GET /projects/{id}/merge_requests?source_branch=<branch>&state=all`.
---@param ctx LvimForgeGitlabCtx
---@param head string  a branch name (an `owner:branch` is reduced to `branch`)
---@param cb fun(pulls: table[]?, err: table?)
function M.pulls_for_head(ctx, head, cb)
    local branch = tostring(head):gsub("^[^:]+:", "")
    get(
        ctx,
        proj_path(ctx) .. "/merge_requests",
        { source_branch = branch, scope = "all", per_page = 100 },
        true,
        function(body, err)
            cb(err and nil or (type(body) == "table" and body or {}), err)
        end
    )
end

--- The remote-side refspec segment for an MR head — GitLab exposes `merge-requests/<iid>/head`, the ref a
--- checkout fetches the MR head from.
---@param number integer
---@return string
function M.pull_head_refspec(number)
    return ("merge-requests/%d/head"):format(number)
end

--- Submit the pending review as a batch (GitLab has no single review endpoint — the local batch is posted
--- as discussions + a summary note + the verdict). Fetches the MR once for its `diff_refs` (the position a
--- new diff comment needs), posts each drafted comment (a NEW diff comment → a discussion with a position;
--- a REPLY → a note under its discussion), posts the summary body as a note, then applies the verdict
--- (APPROVE → `/approve`, REQUEST_CHANGES → `/unapprove`, COMMENT → none). Calls back with a synthesized
--- review object (`{ id, user, state, body, submitted_at }`) the action layer reconciles like GitHub's
--- review response. `opts = { event, body?, comments?, viewer? }`.
---@param ctx LvimForgeGitlabCtx
---@param number integer
---@param opts { event: string, body?: string, comments?: table[], viewer?: string }
---@param cb fun(review: table?, err: table?)
function M.run_submit(ctx, number, opts, cb)
    opts = opts or {}
    local pp = proj_path(ctx)
    local mrp = ("%s/merge_requests/%d"):format(pp, number)

    --- Post one drafted comment. A reply targets its discussion (`in_reply_to` = the discussion id); a new
    --- diff comment opens a discussion with a `position` built from the MR `diff_refs`.
    ---@param c table
    ---@param diff_refs table
    ---@param done fun(err: table?)
    local function post_comment(c, diff_refs, done)
        local spec
        if c.in_reply_to ~= nil and c.in_reply_to ~= "" then
            spec = routed(ctx, {
                method = "POST",
                path = ("%s/discussions/%s/notes"):format(mrp, tostring(c.in_reply_to)),
                body = { body = c.body },
            })
        elseif c.path and c.line then
            local position = {
                position_type = "text",
                base_sha = diff_refs.base_sha,
                start_sha = diff_refs.start_sha,
                head_sha = diff_refs.head_sha,
                new_path = c.path,
                old_path = c.path,
            }
            if (c.side or "RIGHT") == "LEFT" then
                position.old_line = c.line
            else
                position.new_line = c.line
            end
            spec = routed(ctx, {
                method = "POST",
                path = mrp .. "/discussions",
                body = { body = c.body, position = position },
            })
        else
            spec = routed(ctx, { method = "POST", path = mrp .. "/notes", body = { body = c.body } })
        end
        client.request(spec, function(_, err)
            done(err)
        end)
    end

    --- Post the summary note, then apply the verdict, then synthesize the review object.
    local function finish()
        local function verdict()
            if opts.event == "APPROVE" then
                client.request(routed(ctx, { method = "POST", path = mrp .. "/approve" }), function(_, err)
                    if err then
                        cb(nil, err)
                        return
                    end
                    cb(M._synth_review(opts, "approved"), nil)
                end)
            elseif opts.event == "REQUEST_CHANGES" then
                client.request(routed(ctx, { method = "POST", path = mrp .. "/unapprove" }), function(_, err)
                    if err then
                        cb(nil, err)
                        return
                    end
                    cb(M._synth_review(opts, "changes"), nil)
                end)
            else
                cb(M._synth_review(opts, "commented"), nil)
            end
        end
        if type(opts.body) == "string" and opts.body ~= "" then
            client.request(
                routed(ctx, { method = "POST", path = mrp .. "/notes", body = { body = opts.body } }),
                function(_, err)
                    if err then
                        cb(nil, err)
                        return
                    end
                    verdict()
                end
            )
        else
            verdict()
        end
    end

    --- Fetch the MR (for diff_refs), then post the drafted comments sequentially, then finish.
    get(ctx, mrp, nil, false, function(mr, err)
        if err then
            cb(nil, err)
            return
        end
        local diff_refs = (type(mr) == "table" and type(mr.diff_refs) == "table") and mr.diff_refs or {}
        local comments = opts.comments or {}
        local i = 0
        local function step()
            i = i + 1
            if i > #comments then
                finish()
                return
            end
            post_comment(comments[i], diff_refs, function(perr)
                if perr then
                    cb(nil, perr)
                    return
                end
                step()
            end)
        end
        step()
    end)
end

--- A synthesized review object for the submit response (GitLab returns no review object — the verdict is
--- an approval + notes). `state` is the schema verdict; `viewer` (when known) is the author.
---@param opts { body?: string, viewer?: string }
---@param state string
---@return table
function M._synth_review(opts, state)
    return {
        id = ("gitlab-review:%s:%d"):format(opts.viewer or "you", os.time()),
        user = { username = opts.viewer or "you" },
        state = state,
        body = opts.body,
        submitted_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
end

return M
