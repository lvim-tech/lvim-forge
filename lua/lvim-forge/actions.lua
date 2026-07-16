-- lvim-forge.actions: the VERB LAYER — the thin seam between the topic UI (ui/topic.lua keymaps,
-- ui/topics.lua create, ui/composer.lua submit) and the mutation engine (sync.mutate). Each verb
-- RESOLVES the tracked repo, obtains the FORGE BACKEND via `client.backend(forge)` (never a named forge
-- module), composes a WRITE spec (method/path/body) through it, attaches the upsert meta the mutation
-- engine needs (`entity` / `upsert_ctx` / `emit` / `apply`), and drives it through `sync.mutate` — which
-- issues the request and, ONLY on the API response (no optimistic write), upserts it into the cache and
-- fires `LvimForgeTopicChanged` so every open panel refreshes from the DB. Because every forge call goes
-- through the backend + `model` normalizers, the SAME verbs work on GitHub, GitLab and future forges with
-- no `forge ==` branch here — the forge divergence lives in the backend modules + the normalizers.
--
-- The UI stays thin: it collects intent (a body, a chosen label set, a title) via canonical lvim-ui
-- pickers and calls one function here. Nothing here opens a window; nothing in the UI builds a request.
--
-- Testability: every verb accepts a trailing `opts` that may carry `repo_row` / `repo_id` (target a repo
-- without a filesystem detect) and `transport` (an INJECTED fake) — so the whole verb→mutate→db→event
-- round-trip runs headless against canned responses, exactly like the sync engine's tests.
--
-- Phase 6 is the TOPIC write layer: comment / edit post / edit title / body / close-reopen / labels /
-- assignees / milestone / reviewers / create-issue. PR create + checkout + merge + review are their own
-- later phases behind the same `sync.mutate` seam.
--
---@module "lvim-forge.actions"

local db = require("lvim-forge.db")
local sync = require("lvim-forge.sync")
local git = require("lvim-forge.git")
local config = require("lvim-forge.config")
local state = require("lvim-forge.state")
local client = require("lvim-forge.client")
local detect = require("lvim-forge.client.detect")

local M = {}

--- A human/event-facing root label for a target (the real root path else `owner/name`) — matches the
--- payload shape open panels filter on (a review workspace binds both the git root AND `owner/name`).
---@param root? string|integer
---@param repo_row table
---@return string
local function event_root(root, repo_row)
    if type(root) == "string" and root ~= "" then
        return root
    end
    return ("%s/%s"):format(repo_row.owner, repo_row.name)
end

--- Fire `LvimForgeTopicChanged` so open panels (the review overlay, the topic buffer) re-render from the
--- cache — used by the LOCAL pending-review verbs, which never hit the network (so `sync.mutate` — which
--- would fire it — is not in play).
---@param root? string|integer
---@param repo_row table
---@param number integer
local function fire_topic_changed(root, repo_row, number)
    vim.api.nvim_exec_autocmds("User", {
        pattern = "LvimForgeTopicChanged",
        data = { root = event_root(root, repo_row), kind = "pullreq", number = number },
    })
end

--- The viewer's login for a repo host (the cosmetic draft-comment author label; a local draft carries no
--- real author until submit, when the API assigns it). Falls back to "you" when the viewer is not cached.
---@param repo_row table
---@return string
local function viewer_login(repo_row)
    return state.viewer[repo_row.host] or "you"
end

--- Fire a callback with a clean failure (never throws). No-op when `cb` is nil.
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param kind string
---@param message string
local function fail(cb, kind, message)
    if cb then
        cb(false, { kind = kind, message = message })
    end
end

--- Resolve the tracked `repositories` row + a github ctx for a verb. Targets by `opts.repo_row` /
--- `opts.repo_id` (the test path — no filesystem) else the current buffer's detected repo; `opts.transport`
--- threads an injected test fake through onto every built spec. Returns `repo_row, ctx` or `nil`.
---@param root? string|integer
---@param opts? { repo_row?: table, repo_id?: integer, transport?: table }
---@return table? repo_row, table? ctx
local function resolve(root, opts)
    opts = opts or {}
    local repo_row
    if opts.repo_row then
        repo_row = opts.repo_row
    elseif opts.repo_id then
        repo_row = db.repository(opts.repo_id)
    else
        local d = client.detect(root)
        repo_row = d and db.repo_for_detect(d)
    end
    if not repo_row then
        return nil
    end
    ---@type LvimForgeGithubCtx
    local ctx = {
        owner = repo_row.owner,
        name = repo_row.name,
        forge = repo_row.forge,
        host = repo_row.host,
        base = detect.api_base(repo_row.forge, repo_row.host),
        root = root,
        transport = opts.transport,
    }
    return repo_row, ctx
end

--- The FORGE BACKEND for a resolved repo (the dispatch seam). Fails cleanly (via `cb`) for a forge with no
--- backend yet (e.g. gitea until Phase 14). Returns nil in that case so the verb early-returns.
---@param repo_row table
---@param cb? fun(ok: boolean, res_or_err: table?)
---@return table?
local function backend_for(repo_row, cb)
    local b = client.backend(repo_row.forge)
    if not b then
        fail(cb, "unsupported", repo_row.forge .. " mutations are not built yet")
        return nil
    end
    return b
end

-- ── comment / edit ────────────────────────────────────────────────────────────

--- Post a new comment on a topic. Response: the new comment → a `posts` "comment" row.
---@param root? string|integer
---@param number integer
---@param body string
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? table
function M.comment(root, number, body, cb, opts)
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    local backend = backend_for(repo_row, cb)
    if not backend then
        return
    end
    if type(body) ~= "string" or vim.trim(body) == "" then
        return fail(cb, "empty", "an empty comment was not sent")
    end
    local topic = db.get_topic(repo_row.id, number)
    if not topic then
        return fail(cb, "no_topic", "topic #" .. tostring(number) .. " is not cached")
    end
    ctx.kind, ctx.number = topic.kind, number
    local spec = backend.create_issue_comment(ctx, number, body)
    spec.entity = "post"
    spec.upsert_ctx = { topic_id = topic.id, kind = "comment" }
    spec.emit = { kind = topic.kind, number = number }
    spec.repo_row = repo_row
    sync.mutate(root, spec, cb)
end

--- Edit an existing post (or the topic description) under the cursor. `target` selects what:
---   `{ kind = "description" }`             — the topic body (PATCH the issue).
---   `{ kind = "comment", forge_id }`       — an issue comment.
---   `{ kind = "review-comment", forge_id }`— a PR review (line) comment.
--- Author-gating is the UI's job (it knows the viewer + the post author); this only issues the edit.
---@param root? string|integer
---@param number integer
---@param target { kind: string, forge_id?: integer|string }
---@param body string
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? table
function M.edit_post(root, number, target, body, cb, opts)
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    local backend = backend_for(repo_row, cb)
    if not backend then
        return
    end
    local topic = db.get_topic(repo_row.id, number)
    if not topic then
        return fail(cb, "no_topic", "topic #" .. tostring(number) .. " is not cached")
    end
    ctx.kind, ctx.number = topic.kind, number
    target = target or {}
    local spec
    if target.kind == "description" then
        spec = backend.update_issue(ctx, number, { body = body })
        spec.entity = "topic"
        spec.upsert_ctx = { repo_id = repo_row.id }
    elseif target.kind == "comment" then
        spec = backend.update_comment(ctx, target.forge_id, body)
        spec.entity = "post"
        spec.upsert_ctx = { topic_id = topic.id, kind = "comment" }
    elseif target.kind == "review-comment" then
        spec = backend.update_review_comment(ctx, target.forge_id, body)
        spec.entity = "post"
        spec.upsert_ctx = { topic_id = topic.id, kind = "review-comment" }
    else
        return fail(cb, "unsupported", "this post kind cannot be edited here")
    end
    if type(spec) == "table" and spec.kind == "unsupported" then
        return fail(cb, "unsupported", spec.message or ("this edit is not supported on " .. repo_row.forge))
    end
    spec.emit = { kind = topic.kind, number = number }
    spec.repo_row = repo_row
    sync.mutate(root, spec, cb)
end

--- Edit a topic's title. Response: the issue → a `topics` row.
---@param root? string|integer
---@param number integer
---@param title string
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? table
function M.set_title(root, number, title, cb, opts)
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    local backend = backend_for(repo_row, cb)
    if not backend then
        return
    end
    if type(title) ~= "string" or vim.trim(title) == "" then
        return fail(cb, "empty", "an empty title was not sent")
    end
    local topic = db.get_topic(repo_row.id, number)
    ctx.kind, ctx.number = topic and topic.kind, number
    local spec = backend.update_issue(ctx, number, { title = title })
    spec.entity = "topic"
    spec.upsert_ctx = { repo_id = repo_row.id }
    spec.emit = { kind = topic and topic.kind, number = number }
    spec.repo_row = repo_row
    sync.mutate(root, spec, cb)
end

-- ── close / reopen ──────────────────────────────────────────────────────────────

--- Set a topic's state ("closed" | "open"). Response: the issue → a `topics` row (its `state` reconciles).
---@param root? string|integer
---@param number integer
---@param new_state "closed"|"open"
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? table
function M.set_state(root, number, new_state, cb, opts)
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    local backend = backend_for(repo_row, cb)
    if not backend then
        return
    end
    local topic = db.get_topic(repo_row.id, number)
    ctx.kind, ctx.number = topic and topic.kind, number
    local spec = backend.update_issue(ctx, number, { state = new_state })
    spec.entity = "topic"
    spec.upsert_ctx = { repo_id = repo_row.id }
    spec.emit = { kind = topic and topic.kind, number = number }
    spec.repo_row = repo_row
    sync.mutate(root, spec, cb)
end

-- ── lock / unlock ─────────────────────────────────────────────────────────────

--- Lock (or unlock) a topic's conversation. The lock/unlock endpoint responds 204 No Content (no topic
--- body), so this does NOT go through `sync.mutate` (whose normalize→upsert path needs a body) — it issues
--- the request directly, reconciles the cached `locked` flag on success, and fires `LvimForgeTopicChanged`
--- so open panels re-render. Caps-gated at the UI (`client.caps(forge).lock`); a backend without a
--- `lock_issue` builder (e.g. GitLab in v1) fails cleanly here as a backstop.
---@param root? string|integer
---@param number integer
---@param lock boolean  true = lock, false = unlock
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? table
function M.set_lock(root, number, lock, cb, opts)
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    local backend = backend_for(repo_row, cb)
    if not backend then
        return
    end
    if type(backend.lock_issue) ~= "function" then
        return fail(cb, "unsupported", repo_row.forge .. " does not support locking a conversation")
    end
    local topic = db.get_topic(repo_row.id, number)
    ctx.kind, ctx.number = topic and topic.kind, number
    local spec = backend.lock_issue(ctx, number, lock)
    -- Route the spec to this repo's forge/host/base (+ the injected test transport) — the same stamping
    -- `sync.mutate` does, done here because this verb bypasses mutate (204 = no body to upsert).
    spec.forge, spec.host, spec.base = ctx.forge, ctx.host, ctx.base
    if ctx.transport ~= nil then
        spec.transport = ctx.transport
    end
    client.request(spec, function(_, err)
        if err then
            return fail(cb, err.kind or "http", err.message or "lock request failed")
        end
        if topic then
            db.set_locked(topic.id, lock)
        end
        vim.api.nvim_exec_autocmds("User", {
            pattern = "LvimForgeTopicChanged",
            data = { root = event_root(root, repo_row), kind = topic and topic.kind, number = number },
        })
        if cb then
            cb(true, { locked = lock })
        end
    end)
end

-- ── labels / assignees / milestone (PATCH the issue; apply the full sets from the response) ──────────

--- Replace a topic's label set (`names` = label names). Response: the issue → the topic + label/assignee
--- sets re-derived (via `sync.apply_issue_sets`).
---@param root? string|integer
---@param number integer
---@param names string[]
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? table
function M.set_labels(root, number, names, cb, opts)
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    local backend = backend_for(repo_row, cb)
    if not backend then
        return
    end
    local topic = db.get_topic(repo_row.id, number)
    ctx.kind, ctx.number = topic and topic.kind, number

    -- A backend whose label set is a DEDICATED endpoint (Gitea: no labels field on the issue PATCH, and
    -- the labels endpoint responds with a label array, not the issue) advertises `plan_labels` — it PLANS
    -- the change as `{ specs, apply }` and OWNS its reconcile (the `plan_reviewers` shape). GitHub / GitLab
    -- set labels in the single issue PATCH, whose response is the issue → the `apply_issue_sets` path below
    -- (their behaviour is unchanged — they expose no `plan_labels`).
    if type(backend.plan_labels) == "function" then
        backend.plan_labels(ctx, topic and topic.kind or "issue", number, names or {}, function(plan, perr)
            if perr or not plan then
                return fail(cb, perr and perr.kind or "prepare", perr and perr.message or "could not plan labels")
            end
            local specs = plan.specs or {}
            if #specs == 0 then
                if cb then
                    cb(true, nil)
                end
                return
            end
            local i = 0
            local function step()
                i = i + 1
                if i > #specs then
                    if cb then
                        cb(true, nil)
                    end
                    return
                end
                local s = specs[i]
                s.apply = plan.apply
                s.emit = { kind = topic and topic.kind, number = number }
                s.repo_row = repo_row
                sync.mutate(root, s, function(okm, res)
                    if not okm then
                        if cb then
                            cb(okm, res)
                        end
                        return
                    end
                    step()
                end)
            end
            step()
        end)
        return
    end

    local spec = backend.update_issue(ctx, number, { labels = names or {} })
    spec.apply = function(rr, body)
        sync.apply_issue_sets(rr.id, body)
    end
    spec.emit = { kind = topic and topic.kind, number = number }
    spec.repo_row = repo_row
    sync.mutate(root, spec, cb)
end

--- Replace a topic's assignee set (`logins`). Response applied like `set_labels`.
---@param root? string|integer
---@param number integer
---@param logins string[]
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? table
function M.set_assignees(root, number, logins, cb, opts)
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    local backend = backend_for(repo_row, cb)
    if not backend then
        return
    end
    local topic = db.get_topic(repo_row.id, number)
    local kind = topic and topic.kind or "issue"
    ctx.kind, ctx.number = kind, number
    -- The assignee write may need a username→id resolution (GitLab) → the backend PREPARES the spec
    -- (async) and we drive it through `sync.mutate` like any other; GitHub prepares synchronously.
    backend.prepare_assignees(ctx, kind, number, logins or {}, function(spec, perr)
        if perr or not spec then
            return fail(cb, perr and perr.kind or "prepare", perr and perr.message or "could not resolve assignees")
        end
        spec.apply = function(rr, body)
            sync.apply_issue_sets(rr.id, body)
        end
        spec.emit = { kind = topic and topic.kind, number = number }
        spec.repo_row = repo_row
        sync.mutate(root, spec, cb)
    end)
end

--- Set (or clear) a topic's milestone. `milestone_number` is the milestone's per-repo NUMBER, or nil to
--- clear (choosing "None"). Response applied like `set_labels`.
---@param root? string|integer
---@param number integer
---@param milestone_number? integer
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? table
function M.set_milestone(root, number, milestone_number, cb, opts)
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    local backend = backend_for(repo_row, cb)
    if not backend then
        return
    end
    local topic = db.get_topic(repo_row.id, number)
    local kind = topic and topic.kind or "issue"
    ctx.kind, ctx.number = kind, number
    -- Resolve the cached milestones row by its per-repo number so the backend can pick the right wire id
    -- (GitHub PATCHes the milestone NUMBER; GitLab PUTs the global milestone id — both live on the row).
    local ms_row
    if milestone_number ~= nil then
        for _, m in ipairs(db.milestones(repo_row.id)) do
            if tostring(m.number) == tostring(milestone_number) then
                ms_row = m
                break
            end
        end
        ms_row = ms_row or { number = milestone_number }
    end
    local spec = backend.set_milestone_spec(ctx, kind, number, ms_row)
    spec.apply = function(rr, body)
        sync.apply_issue_sets(rr.id, body)
    end
    spec.emit = { kind = topic and topic.kind, number = number }
    spec.repo_row = repo_row
    sync.mutate(root, spec, cb)
end

-- ── reviewers (PR — diff the desired set against the current, POST additions / DELETE removals) ──────

--- Set a PR's requested-reviewer set to `desired` (logins). GitHub has no "replace" — the desired set is
--- diffed against the cached current set: removed reviewers are DELETEd, added ones POSTed, and the
--- final PR response replaces the cached review-request set (via `sync.apply_pr_reviewers`). A no-op when
--- the set is unchanged.
---@param root? string|integer
---@param number integer
---@param desired string[]
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? table
function M.set_reviewers(root, number, desired, cb, opts)
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    local backend = backend_for(repo_row, cb)
    if not backend then
        return
    end
    local topic = db.get_topic(repo_row.id, number)
    if not topic then
        return fail(cb, "no_topic", "topic #" .. tostring(number) .. " is not cached")
    end
    ctx.kind, ctx.number = "pullreq", number
    local current = db.topic_review_requests(topic.id)
    -- The backend PLANS the reviewer change as a sequence of specs (GitHub: a DELETE + a POST diff;
    -- GitLab: a single id-resolved replace PUT) + the apply that reconciles the set from the response.
    backend.plan_reviewers(ctx, number, desired or {}, current, function(plan, perr)
        if perr or not plan then
            return fail(cb, perr and perr.kind or "prepare", perr and perr.message or "could not plan reviewers")
        end
        local specs = plan.specs or {}
        if #specs == 0 then
            if cb then
                cb(true, nil)
            end
            return
        end
        local i = 0
        local function step()
            i = i + 1
            if i > #specs then
                if cb then
                    cb(true, nil)
                end
                return
            end
            local spec = specs[i]
            spec.apply = plan.apply
            spec.emit = { kind = "pullreq", number = number }
            spec.repo_row = repo_row
            sync.mutate(root, spec, function(ok, res)
                if not ok then
                    if cb then
                        cb(ok, res)
                    end
                    return
                end
                step()
            end)
        end
        step()
    end)
end

-- ── create issue ────────────────────────────────────────────────────────────────

--- Create an issue. Response: the new issue → a `topics` row. `cb(ok, res_or_err)` — on success
--- `res.body.number` is the new topic number (the composer opens it).
---@param root? string|integer
---@param title string
---@param body? string
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? table
function M.create_issue(root, title, body, cb, opts)
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    local backend = backend_for(repo_row, cb)
    if not backend then
        return
    end
    if type(title) ~= "string" or vim.trim(title) == "" then
        return fail(cb, "empty", "an issue title is required")
    end
    ctx.kind = "issue"
    local spec = backend.create_issue(ctx, title, body)
    spec.entity = "topic"
    spec.upsert_ctx = { repo_id = repo_row.id }
    -- number is unknown until the response; mutate derives kind/number via `model.response_ref`.
    spec.repo_row = repo_row
    sync.mutate(root, spec, cb)
end

-- ── create pull request ─────────────────────────────────────────────────────────

--- Create a pull request. `params = { base, head, title, body?, draft? }`. Response: the new pull object →
--- a `topics` "pullreq" + `pullreqs` extras + reviewer set (via `sync.apply_pull`). `cb(ok, res_or_err)` —
--- on success `res.body.number` is the new PR number (the composer opens it). Pushing the head branch when
--- it lacks an upstream is the COMPOSER's job (it owns the `create.push_head` confirm); this verb only
--- files the PR through `sync.mutate`.
---@param root? string|integer
---@param params { base: string, head: string, title: string, body?: string, draft?: boolean }
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? table
function M.create_pr(root, params, cb, opts)
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    local backend = backend_for(repo_row, cb)
    if not backend then
        return
    end
    params = params or {}
    if type(params.title) ~= "string" or vim.trim(params.title) == "" then
        return fail(cb, "empty", "a pull request title is required")
    end
    if type(params.base) ~= "string" or params.base == "" then
        return fail(cb, "empty", "a base branch is required")
    end
    if type(params.head) ~= "string" or params.head == "" then
        return fail(cb, "empty", "a head branch is required")
    end
    ctx.kind = "pullreq"
    local spec = backend.create_pull(ctx, {
        title = params.title,
        head = params.head,
        base = params.base,
        body = params.body,
        draft = params.draft and true or false,
    })
    spec.apply = function(rr, body)
        sync.apply_pull(rr.id, body)
    end
    spec.repo_row = repo_row
    sync.mutate(root, spec, cb)
end

-- ── merge (PR) + draft toggle ────────────────────────────────────────────────────

--- Coerce a stored boolean-ish flag (0/1 INTEGER, or a real bool) to a Lua boolean.
---@param v any
---@return boolean
local function truthy(v)
    return v == true or v == 1 or v == "1"
end

--- Re-sync lvim-git after a merge (the clean seam — never forge its event) and settle the merge callback.
---@param root? string|integer
---@param git_root? string
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param info table
local function finish_merge(root, git_root, cb, info)
    -- lvim-git re-derives the repo header + fires LvimGitRepoChanged{reason=external} so its panels/signs
    -- refresh after the merge (and any local branch/worktree removal). Soft: absent lvim-git → no-op.
    pcall(function()
        require("lvim-git").refresh(git_root or root)
    end)
    if cb then
        cb(true, info or {})
    end
end

--- Delete the merged PR's LOCAL checkout branch / worktree (Phase 7's `pr/<n>` or head-ref branch), when
--- present. Best-effort: a missing branch or a failed removal never fails the merge — it reports what was
--- removed (nil = nothing). A worktree is removed FIRST (then its branch); otherwise a matching local
--- branch that is not the current HEAD is deleted. `candidates` = the branch-name set a Phase-7 checkout
--- could have used.
---@param git_root string
---@param candidates table<string, boolean>
---@param cb fun(removed: string?)
local function cleanup_local(git_root, candidates, cb)
    git.worktrees(git_root, function(wts)
        for _, wt in ipairs(wts or {}) do
            if wt.branch and candidates[wt.branch] then
                local branch = wt.branch --[[@as string]]
                git.worktree_remove(git_root, wt.path, function(wok)
                    git.delete_branch(git_root, branch, function()
                        cb(wok and ("worktree " .. wt.path) or nil)
                    end)
                end)
                return
            end
        end
        -- No matching worktree: delete a matching local branch that is not currently checked out.
        git.current_branch(git_root, function(cur)
            git.local_branches(git_root, function(names)
                for _, n in ipairs(names or {}) do
                    if candidates[n] and n ~= cur then
                        git.delete_branch(git_root, n, function(dok)
                            cb(dok and ("branch " .. n) or nil)
                        end)
                        return
                    end
                end
                cb(nil)
            end)
        end)
    end)
end

--- Merge a pull request. `params = { method, delete_branch, commit_title?, commit_message? }` — `method` =
--- merge|squash|rebase (default `config.merge.default_method`). On the API's merge ack (no optimistic write)
--- the cached topic reconciles to `state = "merged"` and `LvimForgeTopicChanged` fires (via `sync.mutate`);
--- then, when `delete_branch` is set, the head ref is DELETEd on the forge and the LOCAL `pr/<n>`/head-ref
--- branch or worktree is cleaned up (best-effort), and lvim-git re-syncs. A non-mergeable PR / a disabled
--- method surfaces as a clean error via `cb`. `opts.git_root`/`opts.remote` bypass the filesystem detect
--- (the test seam); `opts.repo_row`/`opts.transport` thread the headless target + fake transport.
---@param root? string|integer
---@param number integer
---@param params { method?: "merge"|"squash"|"rebase", delete_branch?: boolean, commit_title?: string, commit_message?: string }
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? { git_root?: string, remote?: string, repo_row?: table, repo_id?: integer, transport?: table }
function M.merge(root, number, params, cb, opts)
    opts = opts or {}
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    local backend = backend_for(repo_row, cb)
    if not backend then
        return
    end
    number = tonumber(number) --[[@as integer]]
    if not number then
        return fail(cb, "no_number", "a pull request number is required")
    end
    local topic = db.get_topic(repo_row.id, number, "pullreq")
    if not topic or not topic.pullreq then
        return fail(cb, "no_pr", "pull request #" .. tostring(number) .. " is not cached")
    end
    ctx.kind, ctx.number = "pullreq", number
    params = params or {}
    local method = params.method or (config.merge and config.merge.default_method) or "merge"
    local head_ref = topic.pullreq.head_ref

    -- `delete_branch` is passed to the merge spec too: a forge that removes the branch as part of the merge
    -- (GitLab: `should_remove_source_branch`) bakes it in; a forge that deletes the head ref separately
    -- (GitHub) ignores it here and does the DELETE below.
    local spec = backend.merge_pull(ctx, number, {
        method = method,
        sha = topic.pullreq.head_sha,
        commit_title = params.commit_title,
        commit_message = params.commit_message,
        delete_branch = params.delete_branch and true or false,
    })
    -- The merge response is `{ sha, merged, message }` (no full topic) → reconcile the cached state.
    spec.apply = function(rr, body)
        if type(body) == "table" and truthy(body.merged) then
            local t = db.get_topic(rr.id, number, "pullreq")
            if t then
                db.set_topic_state(t.id, "merged")
            end
        end
    end
    spec.emit = { kind = "pullreq", number = number }
    spec.repo_row = repo_row
    sync.mutate(root, spec, function(ok, res)
        if not ok then
            if cb then
                cb(false, res)
            end
            return
        end
        local body = res and res.body
        if type(body) == "table" and body.merged == false then
            if cb then
                cb(false, { kind = "not_merged", message = body.message or "the merge did not complete" })
            end
            return
        end
        if not params.delete_branch then
            return finish_merge(root, opts.git_root, cb, { method = method })
        end

        -- Resolve the working git root for local cleanup (test path bypasses the filesystem detect).
        local git_root = opts.git_root
        if not git_root then
            local d = client.detect(root)
            git_root = d and d.root
        end

        local function local_step()
            if not git_root or type(head_ref) ~= "string" or head_ref == "" then
                return finish_merge(root, git_root, cb, { method = method, deleted_remote = head_ref })
            end
            local prefix = (config.checkout or {}).branch_prefix or "pr/"
            local candidates = { [prefix .. number] = true, [head_ref] = true }
            cleanup_local(git_root, candidates, function(removed)
                finish_merge(
                    root,
                    git_root,
                    cb,
                    { method = method, deleted_remote = head_ref, removed_local = removed }
                )
            end)
        end

        -- Delete the head ref on the forge (best-effort — a fork head / a protected ref just reports). A
        -- forge that removes the branch as part of the merge returns an `unsupported` sentinel → skipped.
        local dref = (type(head_ref) == "string" and head_ref ~= "") and backend.delete_ref(ctx, head_ref) or nil
        if type(dref) == "table" and dref.kind ~= "unsupported" and (dref.path or dref.url) then
            client.request(dref, function()
                local_step()
            end)
        else
            local_step()
        end
    end)
end

--- Toggle a pull request's DRAFT state. GitHub's REST API cannot flip draft — only the GraphQL
--- `convertPullRequestToDraft` / `markPullRequestReadyForReview` mutations can (keyed by the PR node id,
--- which is not cached → fetched via `pull_node_id`). Routed through `sync.mutate` as a `POST /graphql`
--- spec; on the ack (HTTP 200 with no `errors`) the cached `draft` flag flips and `LvimForgeTopicChanged`
--- fires. A GraphQL-level error (200 + `errors`) surfaces as a clean `cb(false, …)` without flipping the
--- cache. `opts.repo_row`/`opts.transport` thread the headless target + fake transport.
---@param root? string|integer
---@param number integer
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? { repo_row?: table, repo_id?: integer, transport?: table }
function M.toggle_draft(root, number, cb, opts)
    opts = opts or {}
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    local backend = backend_for(repo_row, cb)
    if not backend then
        return
    end
    number = tonumber(number) --[[@as integer]]
    if not number then
        return fail(cb, "no_number", "a pull request number is required")
    end
    local topic = db.get_topic(repo_row.id, number, "pullreq")
    if not topic or not topic.pullreq then
        return fail(cb, "no_pr", "pull request #" .. tostring(number) .. " is not cached")
    end
    ctx.kind, ctx.number = "pullreq", number
    local want_draft = not truthy(topic.pullreq.draft)

    -- The backend PREPARES the draft-toggle spec (async): GitHub fetches the PR node id then a GraphQL
    -- spec; GitLab returns a TITLE-edit PUT (`Draft:` prefix). The action layer is forge-blind.
    backend.draft_op(ctx, number, topic, want_draft, function(spec, derr)
        if derr or not spec then
            return fail(
                cb,
                derr and derr.kind or "no_node",
                derr and derr.message or "could not prepare the draft toggle"
            )
        end
        spec.emit = { kind = "pullreq", number = number }
        spec.repo_row = repo_row
        spec.apply = function(rr, body)
            -- A GraphQL ack (GitHub) can carry an error at HTTP 200 — only flip the cache on a clean ack;
            -- a REST title edit (GitLab) has no `errors` field, so it always flips.
            if type(body) == "table" and body.errors ~= nil then
                return
            end
            local t = db.get_topic(rr.id, number, "pullreq")
            if t then
                db.set_pr_draft(t.id, want_draft)
            end
        end
        sync.mutate(root, spec, function(ok, res)
            if not ok then
                if cb then
                    cb(false, res)
                end
                return
            end
            local body = res and res.body
            local errs = type(body) == "table" and body.errors
            if type(errs) == "table" and errs[1] then
                local msg = (type(errs[1]) == "table" and errs[1].message) or "the draft toggle failed"
                if cb then
                    cb(false, { kind = "graphql", message = msg })
                end
                return
            end
            if cb then
                cb(true, { draft = want_draft })
            end
        end)
    end)
end

-- ── PR checkout (fetch the PR head → a local branch, or a worktree) ──────────────

--- The remote-side refspec for a forge's PR head — the backend owns the forge-specific pattern (GitHub /
--- Gitea `pull/<n>/head`, GitLab `merge-requests/<n>/head`), so this is a dispatch, not a `forge ==`
--- branch. Falls back to the GitHub-style pattern for a backend that does not override it.
---@param forge string
---@param number integer
---@return string
local function pull_head_ref(forge, number)
    local b = client.backend(forge)
    if b and type(b.pull_head_refspec) == "function" then
        return b.pull_head_refspec(number)
    end
    return ("pull/%d/head"):format(number)
end

--- The local branch name for a checked-out PR: `config.checkout.branch = "head"` uses the PR's own head-ref
--- name (falling back to `<branch_prefix><n>` when a local branch already owns that name); any other value
--- uses the always-prefixed `<branch_prefix><n>`.
---@param head_ref? string
---@param number integer
---@param existing table<string, boolean>  the set of existing local branch names
---@return string
local function local_branch_name(head_ref, number, existing)
    local co = config.checkout or {}
    local prefix = co.branch_prefix or "pr/"
    if co.branch == "head" and type(head_ref) == "string" and head_ref ~= "" then
        if existing[head_ref] then
            return prefix .. number
        end
        return head_ref
    end
    return prefix .. number
end

--- The worktree directory for a checked-out PR — the `checkout.worktree_dir` template ({repo}/{branch}/{n})
--- resolved as a SIBLING of the repo root.
---@param git_root string
---@param branch string
---@param number integer
---@return string
local function worktree_path(git_root, branch, number)
    local template = (config.checkout or {}).worktree_dir or "{repo}-{branch}"
    local repo = vim.fn.fnamemodify(git_root, ":t")
    local name = template
        :gsub("{repo}", (repo:gsub("%%", "%%%%")))
        :gsub("{branch}", (branch:gsub("%%", "%%%%")))
        :gsub("{n}", tostring(number))
    return vim.fn.fnamemodify(git_root, ":h") .. "/" .. name
end

--- Re-sync lvim-git (the clean seam — never forge its event) and settle the checkout callback.
---@param git_root string
---@param branch string
---@param worktree? string
---@param cb? fun(ok: boolean, res_or_err: table?)
local function finish_checkout(git_root, branch, worktree, cb)
    -- lvim-git re-derives the repo header + fires LvimGitRepoChanged{reason=external} so its panels/signs
    -- refresh after we moved the working tree. Soft: absent lvim-git → nothing to refresh.
    pcall(function()
        require("lvim-git").refresh(git_root)
    end)
    if cb then
        cb(true, { branch = branch, worktree = worktree })
    end
end

--- Fetch the PR head into a stable ref and create/checkout the branch (or a worktree).
---@param git_root string
---@param remote string
---@param repo_row table
---@param number integer
---@param pr table  the `pullreqs` extras (head_ref/head_sha)
---@param opts table
---@param cb? fun(ok: boolean, res_or_err: table?)
local function do_checkout(git_root, remote, repo_row, number, pr, opts, cb)
    local co = config.checkout or {}
    local head_ref = pr.head_ref
    local stable = ("refs/forge/pr/%d"):format(number)
    local refspec = pull_head_ref(repo_row.forge, number) .. ":" .. stable
    git.fetch_ref(git_root, remote, refspec, function(fok, ferr)
        if not fok then
            return fail(cb, "fetch", "fetch of the pull request head failed: " .. (ferr or "?"))
        end
        git.local_branches(git_root, function(names)
            local existing = {}
            for _, n in ipairs(names or {}) do
                existing[n] = true
            end
            local branch = local_branch_name(head_ref, number, existing)
            if opts.worktree then
                local path = worktree_path(git_root, branch, number)
                local start = existing[branch] and nil or stable
                git.worktree_add(git_root, path, branch, start, function(wok, werr)
                    if not wok then
                        return fail(cb, "worktree", "worktree add failed: " .. (werr or "?"))
                    end
                    finish_checkout(git_root, branch, path, cb)
                end)
                return
            end
            ---@param bok boolean
            ---@param berr string?
            local function after_branch(bok, berr)
                if not bok then
                    return fail(cb, "checkout", "checkout failed: " .. (berr or "?"))
                end
                -- Best-effort upstream (same-repo PRs only): set it to remote/head_ref, ignore failure
                -- (a fork head has no branch on this remote).
                if co.track and type(head_ref) == "string" and head_ref ~= "" then
                    git.set_upstream(git_root, branch, remote, head_ref, function()
                        finish_checkout(git_root, branch, nil, cb)
                    end)
                else
                    finish_checkout(git_root, branch, nil, cb)
                end
            end
            if existing[branch] then
                git.checkout(git_root, branch, after_branch)
            else
                git.create_and_checkout(git_root, branch, stable, after_branch)
            end
        end)
    end)
end

--- Check out a PR locally. Resolves the PR's head ref/sha from the cache (pulling the topic detail first
--- when it is missing), fetches the PR head into `refs/forge/pr/<n>`, then creates/checks out a local
--- branch (or, with `opts.worktree`, adds a sibling worktree). On success it re-syncs lvim-git and calls
--- `cb(true, { branch, worktree? })`. `opts.git_root`/`opts.remote` bypass the filesystem detect (the test
--- seam); `opts.transport` threads a fake through the detail pull.
---@param root? string|integer
---@param number integer
---@param opts? { worktree?: boolean, git_root?: string, remote?: string, repo_row?: table, repo_id?: integer, transport?: table }
---@param cb? fun(ok: boolean, res_or_err: table?)
function M.checkout(root, number, opts, cb)
    opts = opts or {}
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    if not backend_for(repo_row, cb) then
        return
    end
    number = tonumber(number) --[[@as integer]]
    if not number then
        return fail(cb, "no_number", "a pull request number is required")
    end

    -- Resolve the working root + the forge remote name (test path bypasses the filesystem detect).
    local detected
    if opts.git_root then
        detected = { root = opts.git_root, remote = opts.remote }
    else
        detected = client.detect(root)
    end
    local git_root = detected and detected.root
    if not git_root then
        return fail(cb, "no_repo", "not inside a git working tree")
    end
    local remote = (detected and detected.remote) or "origin"

    ---@param pr_topic table?
    local function with_pr(pr_topic)
        local pr = pr_topic and pr_topic.pullreq
        if not pr or type(pr.head_ref) ~= "string" or pr.head_ref == "" then
            return fail(cb, "no_pr", "pull request #" .. number .. " has no cached head ref")
        end
        do_checkout(git_root, remote, repo_row, number, pr, opts, cb)
    end

    local topic = db.get_topic(repo_row.id, number, "pullreq")
    if topic and topic.pullreq and type(topic.pullreq.head_ref) == "string" and topic.pullreq.head_ref ~= "" then
        with_pr(topic)
    else
        -- The PR detail is not cached yet — pull it once (forced), then retry.
        sync.pull_topic(
            root,
            number,
            { repo_row = repo_row, transport = opts.transport, force = true },
            function(ok, err)
                if not ok then
                    return fail(cb, "detail", (err and (err.message or err.kind)) or "could not fetch the pull request")
                end
                with_pr(db.get_topic(repo_row.id, number, "pullreq"))
            end
        )
    end
end

-- ── pr_for_branch (this branch's PR: DB head-ref match, API fallback) ────────────

--- The PR for a branch (the statusline / status-section "this branch's PR"). Resolves the DB `head_ref`
--- match FIRST (offline, instant); on a miss falls back to the GitHub `pulls?head=owner:branch` endpoint
--- (and caches the hit). `branch` nil resolves the current git branch. `cb(true, { topic, number? })` on a
--- hit, `cb(false, err)` otherwise. `opts.git_root` bypasses the filesystem detect (the test seam).
---@param root? string|integer
---@param branch? string
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? { git_root?: string, repo_row?: table, repo_id?: integer, transport?: table }
function M.pr_for_branch(root, branch, cb, opts)
    opts = opts or {}
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end

    ---@param br? string
    local function lookup(br)
        if type(br) ~= "string" or br == "" or br == "HEAD" then
            return fail(cb, "no_branch", "not on a branch")
        end
        local t = db.topic_by_head_ref(repo_row.id, br)
        if t then
            if cb then
                cb(true, { topic = t, number = t.number })
            end
            return
        end
        local backend = client.backend(repo_row.forge)
        if not backend or type(backend.pulls_for_head) ~= "function" then
            return fail(cb, "not_found", "no cached pull request for branch '" .. br .. "'")
        end
        -- GitHub keys the head as `owner:branch`; GitLab reduces it to the bare branch internally.
        backend.pulls_for_head(ctx, ("%s:%s"):format(repo_row.owner, br), function(pulls, err)
            if err then
                return fail(cb, err.kind or "http", err.message or "pull request lookup failed")
            end
            local pr = pulls and pulls[1]
            if not pr then
                return fail(cb, "not_found", "no pull request for branch '" .. br .. "'")
            end
            sync.apply_pull(repo_row.id, pr)
            local num = require("lvim-forge.model").response_ref(repo_row.forge, pr).number
            if cb then
                cb(true, { topic = num and db.get_topic(repo_row.id, num, "pullreq"), number = num })
            end
        end)
    end

    if type(branch) == "string" and branch ~= "" then
        lookup(branch)
    else
        local git_root = opts.git_root
            or (function()
                local d = client.detect(root)
                return d and d.root
            end)()
        if not git_root then
            return fail(cb, "no_repo", "not inside a git working tree")
        end
        git.current_branch(git_root, function(br)
            lookup(br)
        end)
    end
end

-- ── review WRITE (the DB-backed pending review: draft comments/replies, resolve, submit, discard) ─────

--- Append a NEW draft line/range comment to the PR's LOCAL pending review — instant, offline, restart-safe
--- (nothing hits the network until `submit_review`). `params = { path, line, side?, start_line?, body }`;
--- `start_line` (< `line`) makes it a multi-line (range) comment. Fires `LvimForgeTopicChanged` so the
--- review overlay re-anchors the new `[pending]` comment. `cb(true, { post_id, pending })`.
---@param root? string|integer
---@param number integer
---@param params { path: string, line: integer, side?: string, start_line?: integer, body: string }
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? table
function M.add_review_comment(root, number, params, cb, opts)
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    if not backend_for(repo_row, cb) then
        return
    end
    params = params or {}
    if type(params.body) ~= "string" or vim.trim(params.body) == "" then
        return fail(cb, "empty", "an empty review comment was not added")
    end
    if type(params.path) ~= "string" or params.path == "" or not tonumber(params.line) then
        return fail(cb, "no_anchor", "a review comment needs a file + line")
    end
    local topic = db.get_topic(repo_row.id, number, "pullreq")
    if not topic or not topic.pullreq then
        return fail(cb, "no_pr", "pull request #" .. tostring(number) .. " is not cached")
    end
    local start_line = tonumber(params.start_line)
    if start_line and start_line >= tonumber(params.line) then
        start_line = nil -- not a real range → a single-line comment
    end
    local post_id = db.add_pending_comment({
        repo_id = repo_row.id,
        number = number,
        viewer = viewer_login(repo_row),
        path = params.path,
        line = math.floor(tonumber(params.line) --[[@as number]]),
        start_line = start_line and math.floor(start_line) or nil,
        side = params.side or "RIGHT",
        body = params.body,
    })
    if not post_id then
        return fail(cb, "db", "could not store the draft comment")
    end
    fire_topic_changed(root, repo_row, number)
    local review = db.pending_review(repo_row.id, number, viewer_login(repo_row))
    if cb then
        cb(true, { post_id = post_id, pending = review and #db.pending_comments(review) or 0 })
    end
end

--- Append a draft REPLY to a review thread to the PR's LOCAL pending review. `params = { root_comment_id,
--- path?, line?, side?, body }` — `root_comment_id` is the thread's root REST comment id (its `in_reply_to`
--- on submit); path/line/side anchor the draft on the same line as its thread. Fires `LvimForgeTopicChanged`.
---@param root? string|integer
---@param number integer
---@param params { root_comment_id: integer|string, path?: string, line?: integer, side?: string, body: string }
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? table
function M.reply_thread(root, number, params, cb, opts)
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    if not backend_for(repo_row, cb) then
        return
    end
    params = params or {}
    if type(params.body) ~= "string" or vim.trim(params.body) == "" then
        return fail(cb, "empty", "an empty reply was not added")
    end
    if params.root_comment_id == nil then
        return fail(cb, "no_thread", "no thread to reply to")
    end
    local topic = db.get_topic(repo_row.id, number, "pullreq")
    if not topic or not topic.pullreq then
        return fail(cb, "no_pr", "pull request #" .. tostring(number) .. " is not cached")
    end
    local post_id = db.add_pending_comment({
        repo_id = repo_row.id,
        number = number,
        viewer = viewer_login(repo_row),
        path = params.path,
        line = params.line and math.floor(tonumber(params.line) --[[@as number]]) or nil,
        side = params.side,
        body = params.body,
        reply_to = params.root_comment_id,
    })
    if not post_id then
        return fail(cb, "db", "could not store the draft reply")
    end
    fire_topic_changed(root, repo_row, number)
    local review = db.pending_review(repo_row.id, number, viewer_login(repo_row))
    if cb then
        cb(true, { post_id = post_id, pending = review and #db.pending_comments(review) or 0 })
    end
end

--- Resolve (or unresolve) a review thread. GitHub is GraphQL-only here: the thread's GraphQL `node_id` is
--- required, and the REST read pass did not know it — so when the cached thread has no `node_id` yet, the
--- GraphQL `reviewThreads` set is fetched first (which ALSO populates every thread's node id + real
--- `resolved` state, closing the read-phase gap), then the resolve/unresolve mutation runs via `sync.mutate`.
--- `thread = { id, forge_id, node_id? }` (the cached thread row's db id + its root REST comment id).
--- `resolve = true` resolves, `false` unresolves. `cb(true, { resolved })`.
---@param root? string|integer
---@param number integer
---@param thread { id: integer, forge_id?: integer|string, node_id?: string }
---@param do_resolve boolean  true = resolve; false = unresolve
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? table
function M.resolve_thread(root, number, thread, do_resolve, cb, opts)
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    local backend = backend_for(repo_row, cb)
    if not backend then
        return
    end
    local topic = db.get_topic(repo_row.id, number, "pullreq")
    if not topic or not topic.pullreq then
        return fail(cb, "no_pr", "pull request #" .. tostring(number) .. " is not cached")
    end
    ctx.kind, ctx.number = "pullreq", number

    ---@param node_id string?
    local function with_node(node_id)
        if type(node_id) ~= "string" or node_id == "" then
            return fail(cb, "no_node", "could not resolve the review thread's id")
        end
        -- The thread key is forge-specific: GitHub's GraphQL node id, GitLab's discussion id — both stored
        -- in the thread's `node_id` and passed to the backend's `resolve_thread` spec builder uniformly.
        local spec = backend.resolve_thread(ctx, node_id, do_resolve)
        spec.emit = { kind = "pullreq", number = number }
        spec.repo_row = repo_row
        spec.apply = function(_, body)
            -- A GraphQL ack (GitHub) can carry an error at HTTP 200 — only flip on a clean ack; a REST
            -- discussion resolve (GitLab) has no `errors` field, so it always flips.
            if type(body) == "table" and body.errors ~= nil then
                return
            end
            db.set_thread_resolved(thread.id, do_resolve)
        end
        sync.mutate(root, spec, function(ok, res)
            if not ok then
                if cb then
                    cb(false, res)
                end
                return
            end
            local body = res and res.body
            local errs = type(body) == "table" and body.errors
            if type(errs) == "table" and errs[1] then
                local msg = (type(errs[1]) == "table" and errs[1].message) or "the resolve mutation failed"
                if cb then
                    cb(false, { kind = "graphql", message = msg })
                end
                return
            end
            if cb then
                cb(true, { resolved = do_resolve })
            end
        end)
    end

    if type(thread.node_id) == "string" and thread.node_id ~= "" then
        with_node(thread.node_id)
        return
    end
    -- No cached thread node id. A backend that exposes `review_threads` (GitHub's GraphQL) fetches the set
    -- FIRST → populates node ids + resolved onto every cached thread, then continues. GitLab stores the
    -- discussion id as the node id at pull time, so it never reaches here.
    if type(backend.review_threads) ~= "function" then
        return fail(cb, "no_node", "could not resolve the review thread's id")
    end
    backend.review_threads(ctx, number, function(threads, err)
        if err then
            return fail(cb, err.kind or "http", err.message or "could not fetch the review threads")
        end
        local found
        for _, t in ipairs(threads or {}) do
            if t.root_comment_id ~= nil then
                db.set_thread_graphql(topic.id, t.root_comment_id, t.node_id, t.resolved, t.outdated)
                if thread.forge_id ~= nil and tostring(t.root_comment_id) == tostring(thread.forge_id) then
                    found = t.node_id
                end
            end
        end
        with_node(found)
    end)
end

--- Submit the PR's pending review as ONE batch. `params = { event, body? }` — `event` = "APPROVE" |
--- "REQUEST_CHANGES" | "COMMENT". Gathers the LOCAL draft comments (`db.pending_comments`), builds the
--- `POST /pulls/{n}/reviews { event, body, comments }` payload (new line/range comments + `in_reply_to`
--- replies), and drives it through `sync.mutate` (NO optimistic write). On the API response the returned
--- review is upserted, the LOCAL pending review is DISCARDED, a background detail re-pull fills the real
--- submitted comments/threads, and `LvimForgeReviewSubmitted { root, number, state }` fires.
---@param root? string|integer
---@param number integer
---@param params { event: string, body?: string }
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? table
function M.submit_review(root, number, params, cb, opts)
    opts = opts or {}
    local repo_row, ctx = resolve(root, opts)
    if not repo_row or not ctx then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    local backend = backend_for(repo_row, cb)
    if not backend then
        return
    end
    params = params or {}
    local event = params.event or "COMMENT"
    if not (event == "APPROVE" or event == "REQUEST_CHANGES" or event == "COMMENT") then
        return fail(cb, "bad_event", "the review verdict must be APPROVE / REQUEST_CHANGES / COMMENT")
    end
    local topic = db.get_topic(repo_row.id, number, "pullreq")
    if not topic or not topic.pullreq then
        return fail(cb, "no_pr", "pull request #" .. tostring(number) .. " is not cached")
    end
    ctx.kind, ctx.number = "pullreq", number

    local review = db.pending_review(repo_row.id, number, viewer_login(repo_row))
    local drafts = review and db.pending_comments(review) or {}
    local comments = {}
    for _, d in ipairs(drafts) do
        if d.reply_to and d.reply_to ~= "" then
            comments[#comments + 1] = { in_reply_to = tonumber(d.reply_to) or d.reply_to, body = d.body }
        elseif d.path and d.path ~= "" and d.line then
            local c = { path = d.path, body = d.body, line = math.floor(d.line), side = d.side or "RIGHT" }
            if d.start_line and d.start_line < d.line then
                c.start_line = math.floor(d.start_line)
                c.start_side = d.side or "RIGHT"
            end
            comments[#comments + 1] = c
        end
    end
    local body = (type(params.body) == "string" and vim.trim(params.body) ~= "") and params.body or nil
    if event == "COMMENT" and #comments == 0 and not body then
        return fail(cb, "empty", "a comment review needs a summary or at least one comment")
    end

    -- The backend RUNS the submit and calls back with the review object: GitHub's single
    -- `POST /pulls/{n}/reviews`; GitLab posts the drafts as discussions + a summary note + the verdict
    -- (approve/unapprove) and synthesizes the review. The response is then reconciled uniformly.
    backend.run_submit(
        ctx,
        number,
        { event = event, body = body, comments = comments, viewer = viewer_login(repo_row) },
        function(review_api, rerr)
            if rerr then
                if cb then
                    cb(false, rerr)
                end
                return
            end
            -- No optimistic write — reconcile from the response: upsert the real review header + discard
            -- the LOCAL pending review, then announce the change.
            if type(review_api) == "table" then
                sync.apply_submitted_review(repo_row.id, number, review_api)
            end
            vim.api.nvim_exec_autocmds("User", {
                pattern = "LvimForgeTopicChanged",
                data = { root = event_root(root, repo_row), kind = "pullreq", number = number },
            })
            -- Refresh the real submitted comments/threads (the submit returns only the review header).
            sync.pull_topic(root, number, { repo_row = repo_row, transport = opts.transport, force = true })
            local state_map = { APPROVE = "approved", REQUEST_CHANGES = "changes", COMMENT = "commented" }
            vim.api.nvim_exec_autocmds("User", {
                pattern = "LvimForgeReviewSubmitted",
                data = { root = event_root(root, repo_row), number = number, state = state_map[event] },
            })
            if cb then
                cb(true, { event = event, comments = #comments })
            end
        end
    )
end

--- Discard the PR's LOCAL pending review + all its draft comments (never submitted). Fires
--- `LvimForgeTopicChanged` so the overlay drops the `[pending]` comments. `cb(true, { discarded })`.
---@param root? string|integer
---@param number integer
---@param cb? fun(ok: boolean, res_or_err: table?)
---@param opts? table
function M.discard_review(root, number, cb, opts)
    local repo_row = resolve(root, opts)
    if not repo_row then
        return fail(cb, "not_tracked", "repository is not tracked (`:LvimForge add`)")
    end
    local removed = db.discard_pending(repo_row.id, number)
    fire_topic_changed(root, repo_row, number)
    if cb then
        cb(true, { discarded = removed })
    end
end

return M
