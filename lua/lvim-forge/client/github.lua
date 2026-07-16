-- lvim-forge.client.github: the GitHub-specific READ layer. Every function here composes ONE OR MORE
-- `client.request(spec, cb)` calls (the Phase-1 seam) and hands back the RAW GitHub API objects — the
-- normalization into db rows is `model.lua`'s job (never duplicated here). The sync engine drives these
-- reads, feeds the results through `model.normalize`, and writes them with `db.upsert_*`.
--
-- Transport choice (the plan allows GraphQL OR REST — we pick REST):
--   * REST is the SAME shape under both transports — `gh api <path>` passes a REST path straight
--     through, and `curl` hits the same endpoint — so the CLI-first transport and the curl fallback are
--     interchangeable with zero query rewriting.
--   * The Phase-1 pagination + rate-limit loop in `client/init` is REST-shaped (it follows the
--     `Link: rel="next"` header). GraphQL would need a second, cursor-based pagination path in the seam.
--   * The only place REST is thinner than GraphQL is review-thread RESOLVE state (GraphQL-only) — a
--     WRITE concern that lands in the review phases; for the read pass we SYNTHESIZE the thread set from
--     the REST review comments (grouping replies under their root comment), with `resolved` left unset
--     (the GraphQL `reviewThreads` upgrade fills it in the review phase).
--
-- Every function's callback is `cb(data, err)` — `data` is the raw object/array (nil on error), `err` is
-- the clean `{ kind, message, … }` the Phase-1 seam returns (rate_limit / http / transport / detect). A
-- caller NEVER sees a curl string or a page cursor, and an error is surfaced, never thrown.
--
-- `ctx` carries the resolved repo the sync engine built from the tracked `repositories` row:
-- `{ owner, name, forge, host, base, root?, transport? }`. The routing fields (forge/host/base — and the
-- INJECTED `transport` fake in tests) are stamped onto every spec so `client.request` skips its own
-- detect and, in tests, bypasses the network entirely.
--
---@module "lvim-forge.client.github"

local client = require("lvim-forge.client")

local M = {}

--- The forge-repository context the sync engine passes to every read.
---@class LvimForgeGithubCtx
---@field owner      string
---@field name       string
---@field forge      string
---@field host       string
---@field base       string
---@field root?      string|integer  a repo root/buffer (unused when forge/base are explicit — kept for symmetry)
---@field transport? table           an INJECTED transport (test fake); bypasses transport resolution + auth
---@field kind?      string          the topic kind (issue|pullreq) a kind-specific backend endpoint needs (GitLab); GitHub ignores it
---@field number?    integer         the topic iid a kind-specific backend endpoint needs (GitLab); GitHub ignores it

--- Stamp the routing fields from `ctx` onto a request spec so `client.request` resolves this repo (and,
--- under a test, uses the injected transport). Returns the same spec table.
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

--- Issue a single (or paginated) GET and hand back the decoded body. `cb(body, err, res)` — `res` is the
--- full seam response (for `truncated`); `body` is nil on error.
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

--- The `/repos/{owner}/{name}` path prefix for `ctx`.
---@param ctx LvimForgeGithubCtx
---@return string
local function repo_path(ctx)
    return ("/repos/%s/%s"):format(ctx.owner, ctx.name)
end

--- The max `updated_at` across a list of API objects, or `fallback` when the list is empty. Used to
--- carry the incremental watermark forward (ISO-8601 strings compare lexicographically).
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
    get(ctx, repo_path(ctx) .. "/labels", { per_page = 100 }, true, function(body, err)
        cb(err and nil or (type(body) == "table" and body or {}), err)
    end)
end

--- All repository milestones (open + closed; paginated). `cb(list, err)`.
---@param ctx LvimForgeGithubCtx
---@param cb fun(milestones: table[]?, err: table?)
function M.milestones(ctx, cb)
    get(ctx, repo_path(ctx) .. "/milestones", { state = "all", per_page = 100 }, true, function(body, err)
        cb(err and nil or (type(body) == "table" and body or {}), err)
    end)
end

--- The assignable users (paginated) — the offline assignee / @-mention picker data. `cb(list, err)`.
---@param ctx LvimForgeGithubCtx
---@param cb fun(users: table[]?, err: table?)
function M.assignable_users(ctx, cb)
    get(ctx, repo_path(ctx) .. "/assignees", { per_page = 100 }, true, function(body, err)
        cb(err and nil or (type(body) == "table" and body or {}), err)
    end)
end

--- The authenticated user's login (needed by a `selective` involves-me pull). `cb(login, err)`.
---@param ctx LvimForgeGithubCtx
---@param cb fun(login: string?, err: table?)
function M.viewer(ctx, cb)
    get(ctx, "/user", nil, false, function(body, err)
        cb(err and nil or (type(body) == "table" and body.login or nil), err)
    end)
end

-- ── incremental topic list ─────────────────────────────────────────────────────

--- Topics (issues + PRs) updated since a watermark. The REST `issues` endpoint RETURNS PRS TOO (each PR
--- carries a `pull_request` marker), so one paged request covers both kinds — `sort=updated&direction=asc`
--- so the last item seen is the newest and its `updated_at` is the new watermark. `opts.selective` (with
--- `opts.viewer`) routes to the search endpoint (`repo:o/n involves:<viewer>`), forge.el's demand-based
--- mode for huge repos. `cb({ topics, watermark, truncated }, err)`.
---@param ctx LvimForgeGithubCtx
---@param since? string  the ISO-8601 watermark (nil = the initial-pull window is applied by the caller)
---@param opts? { selective?: boolean, viewer?: string }
---@param cb fun(result: { topics: table[], watermark: string?, truncated: boolean }?, err: table?)
function M.topics_since(ctx, since, opts, cb)
    opts = opts or {}
    local spec
    if opts.selective and opts.viewer then
        local q = ("repo:%s/%s involves:%s"):format(ctx.owner, ctx.name, opts.viewer)
        if since then
            q = q .. " updated:>=" .. since
        end
        spec = { path = "/search/issues", query = { q = q, sort = "updated", order = "asc", per_page = 100 } }
    else
        local query = { state = "all", sort = "updated", direction = "asc", per_page = 100 }
        if since then
            query.since = since
        end
        spec = { path = repo_path(ctx) .. "/issues", query = query }
    end
    spec.paginate = true
    client.request(routed(ctx, spec), function(res, err)
        if err then
            cb(nil, err)
            return
        end
        local items = res and res.body
        -- The search endpoint wraps its hits in `{ items = [...] }`; the issues endpoint is a bare array.
        if type(items) == "table" and items.items ~= nil then
            items = items.items
        end
        items = type(items) == "table" and items or {}
        cb({ topics = items, watermark = max_updated(items, since), truncated = res and res.truncated or false }, nil)
    end)
end

-- ── one topic's full detail ─────────────────────────────────────────────────────

--- Walk a review comment's reply chain up to its ROOT comment id (GitHub `in_reply_to_id`), so every
--- comment in a thread is grouped under one stable thread id. Guards against a cycle.
---@param c table
---@param by_id table<integer, table>
---@return integer
local function root_comment_id(c, by_id)
    local seen = {}
    while c.in_reply_to_id and by_id[c.in_reply_to_id] and not seen[c.id] do
        seen[c.id] = true
        c = by_id[c.in_reply_to_id]
    end
    return c.id
end

--- Synthesize the review-thread set from the REST review comments (REST has no thread endpoint). A
--- thread = a root comment (no `in_reply_to_id`) and every reply under it; each comment is stamped with
--- its `thread_id` so `model.github.post` links it. `resolved` is left unset — REST cannot report it
--- (the GraphQL `reviewThreads` upgrade in the review phase fills it); `outdated` is inferred from a
--- JSON-null `position` (the anchored line has since moved).
---@param comments table[]
---@return table[] threads  each `{ id, path, line, side, outdated }` (model.github.thread shape)
local function synthesize_threads(comments)
    local by_id = {}
    for _, c in ipairs(comments or {}) do
        by_id[c.id] = c
    end
    local threads = {}
    for _, c in ipairs(comments or {}) do
        c.thread_id = root_comment_id(c, by_id)
        if not c.in_reply_to_id then
            threads[#threads + 1] = {
                id = c.id,
                path = c.path,
                line = c.line or c.original_line,
                side = c.side,
                outdated = (c.position == vim.NIL) and true or false,
            }
        end
    end
    return threads
end

--- One topic's FULL detail as a single object shaped for `model.normalize`. Composes the sub-requests:
--- the issue object (body/state/labels/assignees/milestone), its comments, and — when it is a PR — the
--- pull object (base/head/sha/mergeable/additions/…), reviews, review (line) comments, and the changed-
--- file set; the review threads are synthesized from the review comments. Any sub-request error aborts
--- and is surfaced (never a partial detail). `cb(detail, err)` where `detail = { issue, pull?, comments,
--- reviews?, review_comments?, threads?, files? }`.
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param cb fun(detail: table?, err: table?)
function M.topic_detail(ctx, number, cb)
    local rp = repo_path(ctx)
    local detail = {}

    get(ctx, ("%s/issues/%d"):format(rp, number), nil, false, function(issue, e1)
        if e1 then
            cb(nil, e1)
            return
        end
        detail.issue = issue
        local is_pr = type(issue) == "table" and issue.pull_request ~= nil

        get(ctx, ("%s/issues/%d/comments"):format(rp, number), { per_page = 100 }, true, function(comments, e2)
            if e2 then
                cb(nil, e2)
                return
            end
            detail.comments = type(comments) == "table" and comments or {}
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

                get(ctx, ("%s/pulls/%d/reviews"):format(rp, number), { per_page = 100 }, true, function(reviews, e4)
                    if e4 then
                        cb(nil, e4)
                        return
                    end
                    detail.reviews = type(reviews) == "table" and reviews or {}

                    get(
                        ctx,
                        ("%s/pulls/%d/comments"):format(rp, number),
                        { per_page = 100 },
                        true,
                        function(rcomments, e5)
                            if e5 then
                                cb(nil, e5)
                                return
                            end
                            detail.review_comments = type(rcomments) == "table" and rcomments or {}
                            detail.threads = synthesize_threads(detail.review_comments)

                            get(
                                ctx,
                                ("%s/pulls/%d/files"):format(rp, number),
                                { per_page = 100 },
                                true,
                                function(files, e6)
                                    if e6 then
                                        cb(nil, e6)
                                        return
                                    end
                                    detail.files = type(files) == "table" and files or {}
                                    cb(detail, nil)
                                end
                            )
                        end
                    )
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
    local query = { all = "true", per_page = 100 }
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
-- Each returns a `client.request` SPEC (method/path/body) stamped with the routing fields via `routed`
-- — it does NOT issue the request. The mutation path is `sync.mutate(root, spec, cb)`: it runs the spec
-- through the client seam and, ONLY on the API response (no optimistic write), normalizes + upserts it
-- and fires `LvimForgeTopicChanged`. `actions.lua` composes these specs, attaches the upsert meta
-- (`entity`/`upsert_ctx`/`emit`/`apply`), and drives them through `sync.mutate`. The `{kind}` error
-- shapes (http / rate_limit / …) are the Phase-1 seam's; a caller never sees a raw failure.

--- Create an issue comment. Response: the new comment object (a `posts` "comment"). `POST
--- /repos/{o}/{n}/issues/{number}/comments`.
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

--- Edit (update) an existing issue comment. Response: the updated comment object. `PATCH
--- /repos/{o}/{n}/issues/comments/{comment_id}`.
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

--- Edit (update) an existing PR review (line) comment. Response: the updated review-comment object.
--- `PATCH /repos/{o}/{n}/pulls/comments/{comment_id}`.
---@param ctx LvimForgeGithubCtx
---@param comment_id integer|string
---@param body string
---@return table spec
function M.update_review_comment(ctx, comment_id, body)
    return routed(ctx, {
        method = "PATCH",
        path = ("%s/pulls/comments/%s"):format(repo_path(ctx), tostring(comment_id)),
        body = { body = body },
    })
end

--- Update an issue OR pull request via the shared issue endpoint. `fields` may carry any of `title`,
--- `body`, `state` ("open"|"closed"), `labels` (name array — REPLACES the set), `assignees` (login
--- array — REPLACES the set), `milestone` (the milestone NUMBER, or `vim.NIL` to clear). Response: the
--- full issue object. `PATCH /repos/{o}/{n}/issues/{number}`.
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param fields table  a subset of { title, body, state, labels, assignees, milestone }
---@return table spec
function M.update_issue(ctx, number, fields)
    return routed(ctx, {
        method = "PATCH",
        path = ("%s/issues/%d"):format(repo_path(ctx), number),
        body = fields,
    })
end

--- Lock (or unlock) a topic's conversation. Response: 204 No Content (no body — the caller reconciles the
--- cached `locked` flag directly). `PUT /repos/{o}/{n}/issues/{number}/lock` / `DELETE …/lock`.
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param lock boolean  true = lock, false = unlock
---@return table spec
function M.lock_issue(ctx, number, lock)
    return routed(ctx, {
        method = lock and "PUT" or "DELETE",
        path = ("%s/issues/%d/lock"):format(repo_path(ctx), number),
    })
end

--- Request reviewers on a PR (adds them). Response: the pull object (with `requested_reviewers`).
--- `POST /repos/{o}/{n}/pulls/{number}/requested_reviewers`.
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

--- Remove requested reviewers from a PR. Response: the pull object. `DELETE
--- /repos/{o}/{n}/pulls/{number}/requested_reviewers`.
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

--- Create an issue. Response: the new issue object (a `topics` "issue"). `POST
--- /repos/{o}/{n}/issues`.
---@param ctx LvimForgeGithubCtx
---@param title string
---@param body? string
---@return table spec
function M.create_issue(ctx, title, body)
    local fields = { title = title }
    if body ~= nil and body ~= "" then
        fields.body = body
    end
    return routed(ctx, { method = "POST", path = repo_path(ctx) .. "/issues", body = fields })
end

--- Create a pull request. Response: the new pull object (a `topics` "pullreq" + `pullreqs` extras).
--- `POST /repos/{o}/{n}/pulls` with `{ title, head, base, body?, draft? }` — `head` = the source branch
--- (`owner:branch` for a cross-fork PR, a bare `branch` for same-repo), `base` = the target branch.
---@param ctx LvimForgeGithubCtx
---@param fields { title: string, head: string, base: string, body?: string, draft?: boolean }
---@return table spec
function M.create_pull(ctx, fields)
    local b = { title = fields.title, head = fields.head, base = fields.base }
    if type(fields.body) == "string" and fields.body ~= "" then
        b.body = fields.body
    end
    if fields.draft then
        b.draft = true
    end
    return routed(ctx, { method = "POST", path = repo_path(ctx) .. "/pulls", body = b })
end

--- Merge a pull request. Response: `{ sha, merged, message }` (NOT a full pull object — the topic's merged
--- state is reconciled by the caller). `PUT /repos/{o}/{n}/pulls/{number}/merge` with `merge_method` =
--- `merge` | `squash` | `rebase`. `opts.sha` guards against merging a head that moved; `commit_title` /
--- `commit_message` override the merge/squash commit message. A merge conflict / a disabled method surfaces
--- as the Phase-1 clean `{kind}` http error (405/409), never a throw.
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param opts { method?: "merge"|"squash"|"rebase", sha?: string, commit_title?: string, commit_message?: string }
---@return table spec
function M.merge_pull(ctx, number, opts)
    opts = opts or {}
    local body = {}
    if opts.method and opts.method ~= "" then
        body.merge_method = opts.method
    end
    if type(opts.sha) == "string" and opts.sha ~= "" then
        body.sha = opts.sha
    end
    if type(opts.commit_title) == "string" and opts.commit_title ~= "" then
        body.commit_title = opts.commit_title
    end
    if type(opts.commit_message) == "string" and opts.commit_message ~= "" then
        body.commit_message = opts.commit_message
    end
    return routed(ctx, {
        method = "PUT",
        path = ("%s/pulls/%d/merge"):format(repo_path(ctx), number),
        body = body,
    })
end

--- Delete a branch ref (the merged PR head). Response: 204 No Content. `DELETE
--- /repos/{o}/{n}/git/refs/heads/{branch}`. A missing ref surfaces as a clean http 422, never a throw.
---@param ctx LvimForgeGithubCtx
---@param branch string  the SHORT branch name (no `refs/heads/` prefix)
---@return table spec
function M.delete_ref(ctx, branch)
    return routed(ctx, {
        method = "DELETE",
        path = ("%s/git/refs/heads/%s"):format(repo_path(ctx), branch),
    })
end

--- Toggle a pull request's DRAFT state via the GraphQL API — GitHub's REST API cannot flip draft, only the
--- `convertPullRequestToDraft` / `markPullRequestReadyForReview` GraphQL mutations can (both keyed by the
--- PR's `node_id`). Composed as a `POST /graphql` spec the Phase-1 transport carries (curl POSTs the query
--- body; `gh api /graphql` does the same authenticated POST). The response is `{ data | errors }` — a
--- GraphQL-level error arrives with HTTP 200, so the caller inspects `body.errors`. `node_id` must be the
--- PR's global node id (fetch it via `pull_node_id` when it is not cached).
---@param ctx LvimForgeGithubCtx
---@param node_id string  the PR's GraphQL node id
---@param draft boolean   true = convert to draft; false = mark ready for review
---@return table spec
function M.set_draft(ctx, node_id, draft)
    local mutation = draft
            and "mutation($id:ID!){convertPullRequestToDraft(input:{pullRequestId:$id}){pullRequest{id isDraft}}}"
        or "mutation($id:ID!){markPullRequestReadyForReview(input:{pullRequestId:$id}){pullRequest{id isDraft}}}"
    return routed(ctx, {
        method = "POST",
        path = "/graphql",
        body = { query = mutation, variables = { id = node_id } },
    })
end

--- The PR's GraphQL `node_id` (a base64 global id) — needed by the draft GraphQL mutation, which is not
--- stored in the schema (an OPEN follow-up: a `node_id` column). Fetched via the pull object. `cb(node_id,
--- err)`. `GET /repos/{o}/{n}/pulls/{number}`.
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param cb fun(node_id: string?, err: table?)
function M.pull_node_id(ctx, number, cb)
    get(ctx, ("%s/pulls/%d"):format(repo_path(ctx), number), nil, false, function(body, err)
        cb(err and nil or (type(body) == "table" and body.node_id or nil), err)
    end)
end

--- The PRs whose HEAD is `head` (`owner:branch`) — the `pr_for_branch` API fallback when the DB has no
--- cached PR for a branch. `state=all` so a merged/closed PR is found too (paginated). `cb(list, err)`.
--- `GET /repos/{o}/{n}/pulls?head=<owner:branch>&state=all`.
---@param ctx LvimForgeGithubCtx
---@param head string  `owner:branch`
---@param cb fun(pulls: table[]?, err: table?)
function M.pulls_for_head(ctx, head, cb)
    get(ctx, repo_path(ctx) .. "/pulls", { head = head, state = "all", per_page = 100 }, true, function(body, err)
        cb(err and nil or (type(body) == "table" and body or {}), err)
    end)
end

-- ── review WRITE endpoints (the batch pending-review model + thread resolve) ─────────────────────────
-- The pending review is accumulated LOCALLY (in the DB, restart-safe) and submitted in ONE
-- `POST /pulls/{n}/reviews { event, body, comments:[…] }` — GitHub's native batch review. This is the
-- chosen model (over "create a pending review, then add comments one by one") because it maps the local
-- batch cleanly to a single wire call: every drafted line/range comment rides in the `comments` array
-- (`{ path, line, side, start_line? }`), and a drafted REPLY rides as `{ in_reply_to, body }` — GitHub's
-- reviews endpoint accepts `in_reply_to` in the comments array, so a whole review (fresh comments AND
-- replies to existing threads) submits in ONE request. Thread RESOLVE is GraphQL-only (below).

--- Submit a review (the batch). `event` = "APPROVE" | "REQUEST_CHANGES" | "COMMENT". `opts.body` is the
--- summary; `opts.comments` is the accumulated draft-comment array, each either a NEW line/range comment
--- `{ path, line, side?, start_line?, start_side? }` or a REPLY `{ in_reply_to, body }`. Response: the new
--- review object (its individual comments are re-pulled by the caller). `POST /pulls/{n}/reviews`.
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param opts { event: string, body?: string, comments?: table[] }
---@return table spec
function M.submit_review(ctx, number, opts)
    opts = opts or {}
    local body = { event = opts.event }
    if type(opts.body) == "string" and opts.body ~= "" then
        body.body = opts.body
    end
    if type(opts.comments) == "table" and #opts.comments > 0 then
        body.comments = opts.comments
    end
    return routed(ctx, {
        method = "POST",
        path = ("%s/pulls/%d/reviews"):format(repo_path(ctx), number),
        body = body,
    })
end

--- Resolve OR unresolve a review thread via the GraphQL API — GitHub has NO REST endpoint for this, only
--- the `resolveReviewThread` / `unresolveReviewThread` mutations (both keyed by the thread's GraphQL
--- `node_id`). Composed as a `POST /graphql` spec; the response is `{ data | errors }` (a GraphQL-level
--- error arrives with HTTP 200, so the caller inspects `body.errors`).
---@param ctx LvimForgeGithubCtx
---@param node_id string  the review thread's GraphQL node id
---@param resolve boolean  true = resolve; false = unresolve
---@return table spec
function M.resolve_thread(ctx, node_id, resolve)
    local mutation = resolve and "mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id isResolved}}}"
        or "mutation($id:ID!){unresolveReviewThread(input:{threadId:$id}){thread{id isResolved}}}"
    return routed(ctx, {
        method = "POST",
        path = "/graphql",
        body = { query = mutation, variables = { id = node_id } },
    })
end

--- Fetch a PR's review threads via GraphQL — the ONLY source of the real thread `node_id` (needed to
--- resolve) and the authoritative `isResolved` flag (the REST read pass leaves `resolved` unset). Each
--- returned thread carries its node id, resolved/outdated state, path/line, and its ROOT comment's REST
--- `databaseId` (== the synthesized REST thread's `forge_id`) so the caller can match it onto the cached
--- thread rows. `cb(threads, err)` where each = `{ node_id, resolved, outdated, path, line, root_comment_id? }`.
--- `POST /graphql`.
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param cb fun(threads: table[]?, err: table?)
function M.review_threads(ctx, number, cb)
    local query = table.concat({
        "query($owner:String!,$name:String!,$number:Int!){",
        "repository(owner:$owner,name:$name){",
        "pullRequest(number:$number){",
        "reviewThreads(first:100){nodes{",
        "id isResolved isOutdated path line",
        "comments(first:1){nodes{databaseId}}",
        "}}}}}",
    }, "")
    local spec = routed(ctx, {
        method = "POST",
        path = "/graphql",
        body = { query = query, variables = { owner = ctx.owner, name = ctx.name, number = number } },
    })
    client.request(spec, function(res, err)
        if err then
            cb(nil, err)
            return
        end
        local b = res and res.body
        if type(b) == "table" and b.errors ~= nil then
            local msg = (type(b.errors) == "table" and b.errors[1] and b.errors[1].message) or "GraphQL error"
            cb(nil, { kind = "graphql", message = msg })
            return
        end
        local nodes = vim.tbl_get(b or {}, "data", "repository", "pullRequest", "reviewThreads", "nodes")
        local out = {}
        for _, t in ipairs(type(nodes) == "table" and nodes or {}) do
            local first = vim.tbl_get(t, "comments", "nodes", 1, "databaseId")
            out[#out + 1] = {
                node_id = t.id,
                resolved = t.isResolved == true,
                outdated = t.isOutdated == true,
                path = t.path,
                line = t.line,
                root_comment_id = first,
            }
        end
        cb(out, nil)
    end)
end

-- ── uniform write adapters (the forge-blind action-layer contract; GitHub's wire behaviour is unchanged) ─
-- These wrap the endpoints above in the SAME shape the GitLab backend exposes, so `actions.lua` drives
-- every forge identically (`backend.prepare_assignees` / `set_milestone_spec` / `plan_reviewers` /
-- `draft_op` / `run_submit`) without a `forge ==` branch. Each is a thin adapter — it composes existing
-- specs, adding no new request behaviour.

--- Prepare a set-assignees spec (GitHub takes a login array directly on the issue PATCH — no id
--- resolution). `cb(spec, err)`; the `kind` is accepted for signature symmetry with GitLab and ignored.
---@param ctx LvimForgeGithubCtx
---@param _kind string
---@param number integer
---@param logins string[]
---@param cb fun(spec: table?, err: table?)
function M.prepare_assignees(ctx, _kind, number, logins, cb)
    cb(M.update_issue(ctx, number, { assignees = logins or {} }))
end

--- A set-milestone spec: GitHub PATCHes the issue with the milestone NUMBER (or `vim.NIL` to clear).
--- `milestone_row` is the cached milestones row; `kind` is accepted for symmetry and ignored.
---@param ctx LvimForgeGithubCtx
---@param _kind string
---@param number integer
---@param milestone_row? table
---@return table spec
function M.set_milestone_spec(ctx, _kind, number, milestone_row)
    return M.update_issue(ctx, number, { milestone = milestone_row and milestone_row.number or vim.NIL })
end

--- Plan the reviewer change. GitHub has no replace — the desired set is diffed against the current, and a
--- DELETE (removals) + a POST (additions) are the specs to run. `cb(plan, err)` where `plan = { specs,
--- apply }` (`apply` reconciles the requested-reviewer set from the pull response).
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
    local sync = require("lvim-forge.sync")
    cb({
        specs = specs,
        apply = function(repo_row, body)
            sync.apply_pr_reviewers(repo_row.id, number, body)
        end,
    })
end

--- Prepare the draft-toggle spec. GitHub's draft is GraphQL-only (keyed by the PR node id, which is not
--- cached) → the node id is fetched first, then `cb(set_draft spec, err)`. `topic` is accepted for
--- signature symmetry with GitLab (whose draft toggle is a title edit) and unused here.
---@param ctx LvimForgeGithubCtx
---@param number integer
---@param _topic table
---@param want_draft boolean
---@param cb fun(spec: table?, err: table?)
function M.draft_op(ctx, number, _topic, want_draft, cb)
    M.pull_node_id(ctx, number, function(node_id, err)
        if err then
            cb(nil, err)
            return
        end
        if type(node_id) ~= "string" or node_id == "" then
            cb(nil, { kind = "no_node", message = "could not resolve the pull request node id" })
            return
        end
        cb(M.set_draft(ctx, node_id, want_draft))
    end)
end

--- The remote-side refspec segment for a PR head — GitHub (and Gitea) expose `pull/<n>/head`, the ref a
--- checkout fetches the PR head from. (A git-remote convention, not an API call — the checkout flow reads
--- it via the backend so the pattern stays with the forge.)
---@param number integer
---@return string
function M.pull_head_refspec(number)
    return ("pull/%d/head"):format(number)
end

--- Run the batch review submit (GitHub's native single `POST /pulls/{n}/reviews`). Issues the spec and
--- calls back with the returned review object (the action layer reconciles it). `opts.viewer` is accepted
--- for symmetry with GitLab (which synthesizes the review author) and unused here.
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
