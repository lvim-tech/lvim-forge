-- lvim-forge.sync: the offline-first pull-reconcile engine — Forge's `pull`. It reconciles the local
-- SQLite cache (db.lua) with the forge API (the per-forge backend reads, via `client.backend`) so the UI renders instantly from the
-- cache and this module refreshes it in the background. It NEVER normalizes (that is model.lua) and NEVER
-- writes rows directly (that is db.lua's upserts) — it only orchestrates read → normalize → upsert, in a
-- crash-safe order, asynchronously.
--
-- `pull(root, opts, cb)` runs FOUR stages IN ORDER (the plan's sync model):
--   1. repo metadata + labels + milestones + assignable users (cheap; every pull) — the offline pickers.
--   2. topics UPDATED since `topics_cursor` (incremental) → upsert each topic row, collect the DIRTY set
--      (a topic is dirty when it is NEW or its `updated_at` changed — an unchanged topic that reappears in
--      the window is upserted but NOT re-detailed).
--   3. for each DIRTY topic the full detail (body, comments, reviews, review threads, PR meta + files,
--      labels/assignees/reviewers) → upsert.
--   4. advance `topics_cursor` + `pulled_at` LAST — ONLY after every prior stage succeeded. A crashed or
--      aborted pull therefore leaves the cursor where it was and simply RE-FETCHES next time; it can
--      never advance past topics whose detail it failed to store. This is the make-or-break correctness
--      property, and it is a real ordering guarantee, not a retry kludge.
--
-- Events (payload in `data`): `LvimForgePullStart { root }` at the top, `LvimForgePullDone { root,
-- topics_changed, notifications, ok, error? }` at the end (ALSO on an early-return/error, with a clean
-- status), `LvimForgeTopicChanged { root, kind, number }` from `mutate`, and `LvimForgeNotificationsChanged
-- { unread }` after a notifications pull. Open panels bind these (the lvim-git `LvimGitRepoChanged`
-- reactive pattern) instead of polling.
--
-- Re-entry: ONE in-flight pull per repo (keyed in `state.pulling`). A second `pull` while one runs
-- coalesces — its callback is queued onto the running pull, no second fetch. Mutations are fail-fast
-- (no optimistic write): the API response IS the truth and is upserted in the same breath.
--
-- Forge-agnostic: every API call is dispatched through `client.backend(forge)` and every normalization
-- through `model.normalize(forge, …)`, so GitHub + GitLab share this engine unchanged; a forge without a
-- backend yet (gitea) returns a clean `unsupported` error, behind the SAME seam.
--
---@module "lvim-forge.sync"

local uv = vim.uv or vim.loop
local config = require("lvim-forge.config")
local state = require("lvim-forge.state")
local db = require("lvim-forge.db")
local model = require("lvim-forge.model")
local client = require("lvim-forge.client")
local detect = require("lvim-forge.client.detect")

local M = {}

--- The forge BACKEND for a ctx/repo — the dispatch seam (`client.github` / `client.gitlab` / …). Every
--- API read the engine drives goes through the backend this returns, never a named forge module, so a new
--- forge slots in behind `client.backend`.
---@param forge string
---@return table?
local function backend_of(forge)
    return client.backend(forge)
end

--- The forge of a tracked repo id (for the response-appliers, which take a repo_id, not a ctx).
---@param repo_id integer
---@return string
local function repo_forge(repo_id)
    local r = db.repository(repo_id)
    return (r and r.forge) or "github"
end

---@type uv.uv_timer_t?  the optional notifications poll timer (config.notifications.poll; OFF by default)
local poll_timer

-- ── small helpers ───────────────────────────────────────────────────────────

--- Fire a `User` autocmd (main loop; render-safe payload).
---@param name string
---@param data table
local function fire(name, data)
    vim.api.nvim_exec_autocmds("User", { pattern = name, data = data })
end

--- The current UTC time as an ISO-8601 string (matches how the APIs + `model.to_iso` render timestamps).
---@return string
local function now_iso()
    return os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]]
end

--- The epoch seconds of a UTC ISO-8601 string (its fields are UTC; correct `os.time`'s local-time
--- interpretation by the machine's UTC offset). Returns nil when unparseable.
---@param iso string
---@return integer?
local function utc_epoch(iso)
    local Y, Mo, D, h, m, s = iso:match("(%d+)-(%d+)-(%d+)[T ](%d+):(%d+):(%d+)")
    if not Y then
        return nil
    end
    local as_local = os.time({
        year = tonumber(Y) or 1970,
        month = tonumber(Mo) or 1,
        day = tonumber(D) or 1,
        hour = tonumber(h) or 0,
        min = tonumber(m) or 0,
        sec = tonumber(s) or 0,
    })
    if not as_local then
        return nil
    end
    -- os.time(os.date("!*t")) reads a UTC wallclock AS local → the difference is the local↔UTC offset.
    local offset = os.time(os.date("!*t") --[[@as osdateparam]]) - os.time()
    return as_local - offset
end

--- Whether a repository row's cache is stale (never pulled, or older than `stale_after` seconds).
---@param repo table  a `repositories` row
---@param stale_after integer
---@return boolean
local function is_stale(repo, stale_after)
    if not repo.pulled_at or repo.pulled_at == "" then
        return true
    end
    local pulled = utc_epoch(repo.pulled_at)
    if not pulled then
        return true
    end
    return (os.time() - pulled) > (stale_after or 300)
end

--- The initial-pull `since` watermark from `config.pull.closed_since`: "all" → nil (no lower bound);
--- "6m"/"1y" → that many days ago. Only used when a repo has no `topics_cursor` yet.
---@param closed_since string
---@return string?
local function initial_since(closed_since)
    if closed_since == "all" then
        return nil
    end
    local days = closed_since == "6m" and 182 or 365
    return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - days * 86400) --[[@as string]]
end

--- Resolve the tracked `repositories` row + a github ctx for a pull. Targets by `opts.repo_id` /
--- `opts.repo_row` (the poll + test path — no filesystem needed), else the current buffer's detected repo
--- (`opts.transport` threads the test fake through). Returns `repo_row, ctx` or `nil, nil, err`.
---@param root? string|integer
---@param opts table
---@return table? repo_row, LvimForgeGithubCtx? ctx, table? err
local function resolve_target(root, opts)
    local repo_row
    if opts.repo_id then
        repo_row = db.repository(opts.repo_id)
    elseif opts.repo_row then
        repo_row = opts.repo_row
    else
        local d = require("lvim-forge.client").detect(root)
        repo_row = d and db.repo_for_detect(d)
    end
    if not repo_row then
        return nil, nil, { kind = "not_tracked", message = "repository is not tracked (`:LvimForge add`)" }
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
    return repo_row, ctx, nil
end

--- A human/event-facing root label for a target (the real root, else `owner/name`).
---@param root? string|integer
---@param repo_row table
---@return string
local function event_root(root, repo_row)
    if type(root) == "string" and root ~= "" then
        return root
    end
    return ("%s/%s"):format(repo_row.owner, repo_row.name)
end

-- ── detail upsert (stage 3 body) ─────────────────────────────────────────────

--- Upsert one topic's full detail (from the backend's `topic_detail`) through model→db. Writes the topic
--- row, the PR extras (when a PR), the remote label/assignee/reviewer SETS, the timeline posts (comments +
--- review bodies + review line-comments), the reviews, the review threads, and the PR file set. Only calls
--- the Phase-2 upserts, which already preserve the user's LOCAL columns/marks. Forge-blind: `forge` picks
--- the normalizer set, and the forge-varying reads (assignee/reviewer handles) go through `model.*`.
---@param forge string
---@param repo_id integer
---@param detail table  `{ issue, pull?, comments, reviews?, review_comments?, threads?, files? }`
---@param ms_map table<string, integer>  milestone forge_id → local milestones.id
local function upsert_detail(forge, repo_id, detail, ms_map)
    local topic_api = detail.pull or detail.issue
    if type(topic_api) ~= "table" then
        return
    end
    local row = model.normalize(forge, "topic", topic_api, { repo_id = repo_id })
    if type(topic_api.milestone) == "table" and topic_api.milestone.id ~= nil then
        row.milestone_id = ms_map[tostring(topic_api.milestone.id)]
    end
    local topic_id = db.upsert_topic(row)
    if not topic_id then
        return
    end

    local is_pr = detail.pull ~= nil
    if is_pr then
        db.upsert_pullreq(model.normalize(forge, "pullreq", detail.pull, { topic_id = topic_id }))
    end

    -- Remote label set (resolve each to a local labels.id, upserting a not-yet-seen one).
    local label_ids = {}
    for _, l in ipairs(topic_api.labels or {}) do
        local lid = db.upsert_label(model.normalize(forge, "label", l, { repo_id = repo_id }))
        if lid then
            label_ids[#label_ids + 1] = lid
        end
    end
    db.set_labels(topic_id, label_ids)

    -- Remote assignee set (the handle field is forge-specific — resolved via the model accessor).
    db.set_assignees(topic_id, model.assignee_logins(forge, topic_api))

    -- Remote requested-reviewer set (PR only).
    if is_pr then
        db.set_review_requests(topic_id, model.reviewer_logins(forge, detail.pull))
    end

    -- Issue comments → posts.
    for _, c in ipairs(detail.comments or {}) do
        db.upsert_post(model.normalize(forge, "post", c, { topic_id = topic_id, kind = "comment" }))
    end

    -- Reviews (+ their summary body as a review-body post, when the forge carries one).
    for _, rv in ipairs(detail.reviews or {}) do
        db.upsert_review(model.normalize(forge, "review", rv, { topic_id = topic_id }))
        if type(rv.body) == "string" and rv.body ~= "" then
            db.upsert_post(model.normalize(forge, "post", {
                id = rv.id,
                user = rv.user,
                created_at = rv.submitted_at,
                updated_at = rv.submitted_at,
                body = rv.body,
                pull_request_review_id = rv.id,
            }, { topic_id = topic_id, kind = "review-body" }))
        end
    end

    -- Review line-comments → posts (thread_id stamped by the backend's detail assembly).
    for _, rc in ipairs(detail.review_comments or {}) do
        db.upsert_post(model.normalize(forge, "post", rc, { topic_id = topic_id, kind = "review-comment" }))
    end

    -- Review threads.
    for _, th in ipairs(detail.threads or {}) do
        db.upsert_thread(model.normalize(forge, "thread", th, { topic_id = topic_id }))
    end

    -- PR file set.
    for _, f in ipairs(detail.files or {}) do
        db.upsert_pr_file(model.normalize(forge, "pr_file", f, { topic_id = topic_id }))
    end
end

-- ── mutation-response appliers (the "apply" hook the action layer hands to `mutate`) ──────────────

--- Apply a mutation's ISSUE/PR response object to the cache: upsert the topic row, then RE-DERIVE the
--- remote label / assignee sets and the milestone soft-ref from the response (the authoritative post-
--- mutation state). Used by the label / assignee / milestone / state / title / body verbs, whose PATCH
--- returns the full issue object. Only the Phase-2 upserts run (they preserve the user's LOCAL columns
--- and marks). Returns the topic id (nil when the row could not be written).
---@param repo_id integer
---@param issue_api table  a GitHub issue/pull object
---@return integer? topic_id
function M.apply_issue_sets(repo_id, issue_api)
    if type(issue_api) ~= "table" then
        return nil
    end
    local forge = repo_forge(repo_id)
    local row = model.normalize(forge, "topic", issue_api, { repo_id = repo_id })
    row.milestone_id = nil -- resolved + written explicitly below (so a CLEARED milestone actually clears)
    local topic_id = db.upsert_topic(row)
    if not topic_id then
        return nil
    end

    -- Milestone: upsert the (possibly new) milestone, resolve its local id, and write it explicitly so a
    -- null milestone (choosing "None") clears the column.
    local ms = issue_api.milestone
    local ms_id
    if type(ms) == "table" and ms.id ~= nil then
        db.upsert_milestone(model.normalize(forge, "milestone", ms, { repo_id = repo_id }))
        for _, m in ipairs(db.milestones(repo_id)) do
            if m.forge_id == tostring(ms.id) then
                ms_id = m.id
                break
            end
        end
    end
    db.set_milestone(topic_id, ms_id)

    -- Labels (REPLACE the remote set).
    local label_ids = {}
    for _, l in ipairs(issue_api.labels or {}) do
        local lid = db.upsert_label(model.normalize(forge, "label", l, { repo_id = repo_id }))
        if lid then
            label_ids[#label_ids + 1] = lid
        end
    end
    db.set_labels(topic_id, label_ids)

    -- Assignees (REPLACE the remote set; the handle field is forge-specific).
    db.set_assignees(topic_id, model.assignee_logins(forge, issue_api))
    return topic_id
end

--- Apply a reviewers-mutation's PULL response to the cache: REPLACE the topic's requested-reviewer set
--- from the pull object's `requested_reviewers`. `number` targets the cached topic (the response is a
--- pull object without our db id).
---@param repo_id integer
---@param number integer
---@param pull_api table  a GitHub pull object (carries `requested_reviewers`)
function M.apply_pr_reviewers(repo_id, number, pull_api)
    local topic = db.get_topic(repo_id, number)
    if not topic then
        return
    end
    db.set_review_requests(topic.id, model.reviewer_logins(repo_forge(repo_id), pull_api))
end

--- Apply a CREATE-PR response (a pull object) to the cache: upsert the topic + its label/assignee sets +
--- milestone (via `apply_issue_sets`, which normalizes a pull object as a pullreq topic), then the PR
--- extras (`pullreqs`: base/head/sha/draft/…) and the requested-reviewer set. Returns the topic id. Used
--- by the `create_pr` verb's `apply` hook — the response IS the truth (no optimistic write). Only the
--- Phase-2 upserts run (they preserve the user's LOCAL columns/marks).
---@param repo_id integer
---@param pull_api table  a GitHub pull object
---@return integer? topic_id
function M.apply_pull(repo_id, pull_api)
    if type(pull_api) ~= "table" then
        return nil
    end
    local forge = repo_forge(repo_id)
    local topic_id = M.apply_issue_sets(repo_id, pull_api)
    if not topic_id then
        return nil
    end
    db.upsert_pullreq(model.normalize(forge, "pullreq", pull_api, { topic_id = topic_id }))
    db.set_review_requests(topic_id, model.reviewer_logins(forge, pull_api))
    return topic_id
end

--- Apply a SUBMITTED review's response (the `POST /pulls/{n}/reviews` object) to the cache: upsert the
--- real review header (with its assigned forge_id + verdict state), then DISCARD the LOCAL pending review
--- + its draft comments — they are now submitted, and the real per-line comments are re-pulled by the
--- caller (the reviews endpoint returns only the review header, not its comments). Used by the
--- `submit_review` verb's `apply` hook.
---@param repo_id integer
---@param number integer
---@param review_api table  a GitHub review object
function M.apply_submitted_review(repo_id, number, review_api)
    local forge = repo_forge(repo_id)
    local topic = db.get_topic(repo_id, number, "pullreq")
    if topic and type(review_api) == "table" then
        db.upsert_review(model.normalize(forge, "review", review_api, { topic_id = topic.id }))
        if type(review_api.body) == "string" and review_api.body ~= "" and review_api.id ~= nil then
            db.upsert_post(model.normalize(forge, "post", {
                id = review_api.id,
                user = review_api.user,
                created_at = review_api.submitted_at,
                updated_at = review_api.submitted_at,
                body = review_api.body,
                pull_request_review_id = review_api.id,
            }, { topic_id = topic.id, kind = "review-body" }))
        end
    end
    db.discard_pending(repo_id, number)
end

-- ── notifications ────────────────────────────────────────────────────────────

--- Resolve a notification's subject to a cached topic id (parse the trailing number off the subject url,
--- e.g. `.../issues/123` / `.../pulls/123` / GitLab `.../merge_requests/5`). nil when the topic is not
--- cached / the url is unparseable. The subject-url field is forge-specific (via `model.notification_url`).
---@param forge string
---@param repo_id integer
---@param n table  a forge notification/todo object
---@return integer?
local function notification_topic_id(forge, repo_id, n)
    local url = model.notification_url(forge, n)
    if type(url) ~= "string" then
        return nil
    end
    local num = tonumber(url:match("/(%d+)%s*$"))
    if not num then
        return nil
    end
    local topic = db.get_topic(repo_id, num)
    return topic and topic.id or nil
end

--- Pull the repo's notifications, upsert them, advance the notifications cursor, and fire
--- `LvimForgeNotificationsChanged`. `done(count, err)` — best-effort (an error is reported, not fatal to a
--- topic pull that piggybacks this).
---@param repo_row table
---@param ctx LvimForgeGithubCtx
---@param done fun(count: integer, err: table?)
local function run_notifications(repo_row, ctx, done)
    local forge = ctx.forge
    local backend = backend_of(forge)
    if not backend then
        done(0, { kind = "unsupported", message = forge .. " notifications are not built yet" })
        return
    end
    backend.notifications(ctx, repo_row.notifications_cursor, function(res, err)
        if err or not res then
            done(0, err)
            return
        end
        for _, n in ipairs(res.notifications) do
            local tid = notification_topic_id(forge, repo_row.id, n)
            db.upsert_notification(model.normalize(forge, "notification", n, { repo_id = repo_row.id, topic_id = tid }))
        end
        if res.watermark then
            db.set_cursors(repo_row.id, { notifications_cursor = res.watermark })
        end
        fire("LvimForgeNotificationsChanged", { unread = db.notifications_unread() })
        done(#res.notifications, nil)
    end)
end

-- ── pull (the 4-stage engine) ─────────────────────────────────────────────────

--- Pull (incremental sync of topics/posts/reviews/notifications into the cache). Async, offline-first,
--- crash-safe (cursor advances LAST). One in-flight pull per repo (a re-entrant call coalesces).
---@param root? string|integer  a repo root / buffer (nil when targeting by `opts.repo_id`)
---@param opts? { repo_id?: integer, repo_row?: table, transport?: table, notifications_only?: boolean, selective?: boolean, full?: boolean, closed_since?: string }
---@param cb? fun(ok: boolean, err?: table)
function M.pull(root, opts, cb)
    opts = opts or {}
    if not db.available() then
        if cb then
            cb(false, { kind = "no_db", message = "the local database needs sqlite.lua" })
        end
        return
    end

    local repo_row, ctx, err = resolve_target(root, opts)
    if not repo_row or not ctx then
        if cb then
            cb(false, err)
        end
        return
    end
    local backend = backend_of(repo_row.forge)
    if not backend then
        if cb then
            cb(false, { kind = "unsupported", message = repo_row.forge .. " sync is not built yet" })
        end
        return
    end

    local key = (type(root) == "string" and root ~= "" and root) or ("repo:" .. tostring(repo_row.id))
    local inflight = state.pulling[key]
    if inflight then
        -- Coalesce: queue the callback onto the running pull, do NOT start a second fetch.
        if cb then
            inflight.cbs[#inflight.cbs + 1] = cb
        end
        return
    end

    ---@type { started: integer, cbs: fun(ok: boolean, err?: table)[], notifications_only?: boolean }
    local rec = { started = uv.now(), cbs = {}, notifications_only = opts.notifications_only }
    if cb then
        rec.cbs[1] = cb
    end
    state.pulling[key] = rec

    local eroot = event_root(root, repo_row)
    local repo_id = repo_row.id
    fire("LvimForgePullStart", { root = eroot })

    --- Settle the pull: clear the in-flight guard, fire PullDone, flush queued callbacks.
    ---@param ok boolean
    ---@param topics_changed integer
    ---@param notif_count integer
    ---@param ferr? table
    local function finish(ok, topics_changed, notif_count, ferr)
        state.pulling[key] = nil
        fire("LvimForgePullDone", {
            root = eroot,
            topics_changed = topics_changed,
            notifications = notif_count,
            ok = ok,
            error = ferr,
        })
        for _, c in ipairs(rec.cbs) do
            c(ok, ferr)
        end
    end

    -- notifications-only pull (the `:LvimForge pull --notifications` / piggyback-alone path).
    if opts.notifications_only then
        run_notifications(repo_row, ctx, function(count, nerr)
            finish(nerr == nil, 0, count, nerr)
        end)
        return
    end

    local selective = opts.selective or repo_row.tracked == "selective"

    -- Stage 4: advance the cursor LAST, then piggyback notifications, then settle.
    ---@param watermark string?
    ---@param changed integer
    local function stage4(watermark, changed)
        db.set_cursors(repo_id, { topics_cursor = watermark or repo_row.topics_cursor, pulled_at = now_iso() })
        run_notifications(repo_row, ctx, function(count)
            finish(true, changed, count, nil)
        end)
    end

    -- Stage 3: fetch + upsert each dirty topic's detail, sequentially. Any error aborts BEFORE stage 4,
    -- so the cursor is NOT advanced (the crash-safe guarantee).
    ---@param dirty { number: integer, kind: string }[]
    ---@param watermark string?
    ---@param ms_map table<string, integer>
    local function stage3(dirty, watermark, ms_map)
        local i = 0
        local function step()
            i = i + 1
            if i > #dirty then
                stage4(watermark, #dirty)
                return
            end
            -- Stamp the known kind so a backend whose detail endpoint is kind-specific (GitLab: MR vs issue)
            -- fetches the right one without a probe; GitHub ignores it.
            ctx.kind = dirty[i].kind
            backend.topic_detail(ctx, dirty[i].number, function(detail, derr)
                if derr or not detail then
                    finish(false, 0, 0, derr or { kind = "detail", message = "topic detail fetch failed" })
                    return
                end
                upsert_detail(ctx.forge, repo_id, detail, ms_map)
                step()
            end)
        end
        step()
    end

    -- Stage 2: incremental topic list → upsert + collect the dirty set.
    local function stage2()
        local since = repo_row.topics_cursor
        -- A `--full` re-pull (or an explicit `closed_since` from the pull transient) ignores the stored
        -- cursor so the initial-window watermark drives the fetch from scratch.
        if opts.full then
            since = nil
        end
        if not since or since == "" then
            since = initial_since(opts.closed_since or config.pull.closed_since or "1y")
        end
        --- Run the topic list (optionally involves-me for a selective repo).
        ---@param viewer string?
        local function fetch(viewer)
            backend.topics_since(
                ctx,
                since,
                { selective = selective and viewer ~= nil, viewer = viewer },
                function(tres, terr)
                    if terr or not tres then
                        finish(false, 0, 0, terr or { kind = "topics", message = "topics list failed" })
                        return
                    end
                    -- milestone forge_id → local id map (for the topic.milestone_id resolution).
                    local ms_map = {}
                    for _, ms in ipairs(db.milestones(repo_id)) do
                        if ms.forge_id then
                            ms_map[ms.forge_id] = ms.id
                        end
                    end
                    local dirty = {}
                    for _, it in ipairs(tres.topics) do
                        local row = model.normalize(ctx.forge, "topic", it, { repo_id = repo_id })
                        if type(it.milestone) == "table" and it.milestone.id ~= nil then
                            row.milestone_id = ms_map[tostring(it.milestone.id)]
                        end
                        local existing = db.get_topic(repo_id, row.number, row.kind)
                        local is_dirty = (not existing) or (existing.updated ~= row.updated)
                        db.upsert_topic(row)
                        if is_dirty then
                            dirty[#dirty + 1] = { number = row.number, kind = row.kind }
                        end
                    end
                    stage3(dirty, tres.watermark, ms_map)
                end
            )
        end
        if selective then
            backend.viewer(ctx, function(login)
                fetch(login) -- a viewer error falls back to a non-selective fetch (login = nil)
            end)
        else
            fetch(nil)
        end
    end

    -- Stage 1: repo metadata + labels + milestones + assignable users.
    backend.repo(ctx, function(repo_api, e1)
        if e1 then
            finish(false, 0, 0, e1)
            return
        end
        if type(repo_api) == "table" then
            db.upsert_repository(model.normalize(ctx.forge, "repository", repo_api, {
                forge = ctx.forge,
                host = ctx.host,
                owner = ctx.owner,
                name = ctx.name,
            }))
        end
        backend.labels(ctx, function(labels, e2)
            if e2 then
                finish(false, 0, 0, e2)
                return
            end
            for _, l in ipairs(labels or {}) do
                db.upsert_label(model.normalize(ctx.forge, "label", l, { repo_id = repo_id }))
            end
            backend.milestones(ctx, function(milestones, e3)
                if e3 then
                    finish(false, 0, 0, e3)
                    return
                end
                for _, ms in ipairs(milestones or {}) do
                    db.upsert_milestone(model.normalize(ctx.forge, "milestone", ms, { repo_id = repo_id }))
                end
                backend.assignable_users(ctx, function(users, e4)
                    if e4 then
                        finish(false, 0, 0, e4)
                        return
                    end
                    for _, u in ipairs(users or {}) do
                        db.upsert_user(model.normalize(ctx.forge, "user", u, { repo_id = repo_id }))
                    end
                    stage2()
                end)
            end)
        end)
    end)
end

--- Pull ONLY the notifications for a repo (the cheap standalone endpoint + cursor). Also piggybacked at
--- the end of every `pull`.
---@param root? string|integer
---@param opts? { repo_id?: integer, repo_row?: table, transport?: table }
---@param cb? fun(count: integer, err?: table)
function M.pull_notifications(root, opts, cb)
    opts = opts or {}
    if not db.available() then
        if cb then
            cb(0, { kind = "no_db", message = "the local database needs sqlite.lua" })
        end
        return
    end
    local repo_row, ctx, err = resolve_target(root, opts)
    if not repo_row or not ctx then
        if cb then
            cb(0, err)
        end
        return
    end
    if not backend_of(repo_row.forge) then
        if cb then
            cb(0, { kind = "unsupported", message = repo_row.forge .. " notifications are not built yet" })
        end
        return
    end
    run_notifications(repo_row, ctx, function(count, nerr)
        if cb then
            cb(count, nerr)
        end
    end)
end

--- Staleness trigger a UI opener calls: pull in the BACKGROUND when the cache is stale (older than
--- `config.pull.stale_after`) and `config.pull.on_open`. Returns immediately — the UI renders the cache
--- and refreshes on `LvimForgePullDone`. A no-op when disabled, not tracked, or already fresh.
---@param root? string|integer
function M.maybe_pull(root)
    if not (config.pull and config.pull.on_open) then
        return
    end
    if not db.available() then
        return
    end
    local d = require("lvim-forge.client").detect(root)
    local repo = d and db.repo_for_detect(d)
    if not repo or not backend_of(repo.forge) then
        return
    end
    if not is_stale(repo, config.pull.stale_after or 300) then
        return
    end
    M.pull(root, {}, nil)
end

-- ── single-topic detail pull (the topic buffer's on-open refresh) ──────────────

---@type table<string, fun(ok: boolean, err?: table)[]>  in-flight per-topic detail pulls ("<repo_id>#<n>")
local topic_inflight = {}

--- Pull the FULL detail of ONE topic (body, comments, reviews, review threads, PR meta + files, and the
--- label/assignee/reviewer sets) into the cache, then fire `LvimForgeTopicChanged { root, kind, number }`
--- so an open topic buffer refreshes from the DB. It REUSES the shared stage-3 detail path
--- (`upsert_detail`) — nothing is re-normalized or re-written here. The topic buffer opens on the cache and
--- triggers this in the BACKGROUND; it is staleness-aware — a repeat pull of the same topic within
--- `opts.min_interval` seconds (default 30) is skipped unless `opts.force`. One in-flight pull per topic
--- (a re-entrant call coalesces its callback). GitHub-only this phase (the review phases carry the
--- GraphQL thread-resolved upgrade behind the same seam).
---@param root? string|integer  a repo root / buffer (nil when targeting by `opts.repo_id`/`opts.repo_row`)
---@param number integer        the topic number
---@param opts? { repo_id?: integer, repo_row?: table, transport?: table, force?: boolean, min_interval?: integer }
---@param cb? fun(ok: boolean, err?: table)
function M.pull_topic(root, number, opts, cb)
    opts = opts or {}
    if not db.available() then
        if cb then
            cb(false, { kind = "no_db", message = "the local database needs sqlite.lua" })
        end
        return
    end
    local repo_row, ctx, err = resolve_target(root, opts)
    if not repo_row or not ctx then
        if cb then
            cb(false, err)
        end
        return
    end
    local backend = backend_of(repo_row.forge)
    if not backend then
        if cb then
            cb(false, { kind = "unsupported", message = repo_row.forge .. " sync is not built yet" })
        end
        return
    end

    local key = ("%d#%d"):format(repo_row.id, number)
    -- Staleness gate: skip a repeat detail pull within the window (the buffer already rendered the cache).
    if not opts.force then
        local last = state.topic_pulled[key]
        if last and (os.time() - last) < (opts.min_interval or 30) then
            if cb then
                cb(true, nil)
            end
            return
        end
    end
    -- Coalesce: a second in-flight pull for the same topic queues its callback onto the running one.
    if topic_inflight[key] then
        if cb then
            topic_inflight[key][#topic_inflight[key] + 1] = cb
        end
        return
    end
    ---@type fun(ok: boolean, err?: table)[]
    local cbs = {}
    if cb then
        cbs[1] = cb
    end
    topic_inflight[key] = cbs

    -- milestone forge_id → local id map (for the topic.milestone_id resolution inside upsert_detail).
    local ms_map = {}
    for _, ms in ipairs(db.milestones(repo_row.id)) do
        if ms.forge_id then
            ms_map[ms.forge_id] = ms.id
        end
    end

    -- Stamp the cached topic's kind so a kind-specific detail endpoint (GitLab) hits the right one; nil
    -- lets the backend probe (GitHub ignores it).
    local cached = db.get_topic(repo_row.id, number)
    ctx.kind = cached and cached.kind or nil

    backend.topic_detail(ctx, number, function(detail, derr)
        local queued = topic_inflight[key] or {}
        topic_inflight[key] = nil
        if derr or not detail then
            local e = derr or { kind = "detail", message = "topic detail fetch failed" }
            for _, c in ipairs(queued) do
                c(false, e)
            end
            return
        end
        upsert_detail(repo_row.forge, repo_row.id, detail, ms_map)
        state.topic_pulled[key] = os.time()
        local kind = (detail.pull ~= nil) and "pullreq" or "issue"
        fire("LvimForgeTopicChanged", { root = event_root(root, repo_row), kind = kind, number = number })
        for _, c in ipairs(queued) do
            c(true, nil)
        end
    end)
end

-- ── mutation seam ──────────────────────────────────────────────────────────────

--- The mutation seam later action phases (comment / close / label / merge / review) use. NO optimistic
--- write: it issues the mutation, and ONLY on success normalizes + upserts the returned object and fires
--- `LvimForgeTopicChanged { root, kind, number }` — the API response is the truth. `spec` is a
--- `client.request` spec PLUS optional meta: `spec.entity` (the model/db entity to upsert the response
--- as, e.g. "topic"/"post"), `spec.upsert_ctx` (the ctx that upsert needs, default `{ repo_id }`), and
--- `spec.emit = { kind, number }` (what to announce; else derived from the response). `on_response(ok,
--- res_or_err)`.
---
--- `spec.apply = fun(repo_row, body)` is an OPTIONAL hook that OWNS the DB write for the response (called
--- with the decoded body before the event fires) — for a verb whose response needs more than a single
--- `db.upsert_<entity>` (e.g. labels / assignees / milestone / reviewers, which also rewrite join sets
--- via `M.apply_issue_sets` / `M.apply_pr_reviewers`). When `apply` is given it REPLACES the `entity`
--- upsert; the "no optimistic write" contract is unchanged — apply only ever sees the real response.
---
--- Phase 3 shipped the SEAM (real upsert→event pipe, tested); Phase 6 wires the concrete topic verbs
--- (comment/edit/title/close/labels/assignees/milestone/reviewers/create-issue) through `actions.lua`.
---@param root? string|integer
---@param spec table  a client.request spec (+ optional `entity` / `upsert_ctx` / `emit` / `apply` / `repo_id` / `transport`)
---@param on_response? fun(ok: boolean, res_or_err: table?)
function M.mutate(root, spec, on_response)
    spec = spec or {}
    if not db.available() then
        if on_response then
            on_response(false, { kind = "no_db", message = "the local database needs sqlite.lua" })
        end
        return
    end
    local repo_row, ctx, err = resolve_target(root, spec)
    if not repo_row or not ctx then
        if on_response then
            on_response(false, err)
        end
        return
    end

    -- Peel the meta keys off the wire spec, then route it to this repo (+ the injected transport).
    local entity = spec.entity
    local emit = spec.emit
    local upsert_ctx = spec.upsert_ctx
    local apply = spec.apply
    local rspec = {}
    for k, v in pairs(spec) do
        rspec[k] = v
    end
    rspec.entity, rspec.emit, rspec.upsert_ctx, rspec.apply = nil, nil, nil, nil
    rspec.repo_id, rspec.repo_row = nil, nil
    rspec.forge, rspec.host, rspec.base = ctx.forge, ctx.host, ctx.base
    if ctx.transport ~= nil then
        rspec.transport = ctx.transport
    end

    require("lvim-forge.client").request(rspec, function(res, rerr)
        if rerr then
            if on_response then
                on_response(false, rerr)
            end
            return
        end
        local body = res and res.body
        if type(apply) == "function" then
            if type(body) == "table" then
                apply(repo_row, body)
            end
        elseif entity and type(body) == "table" then
            local row = model.normalize(repo_row.forge, entity, body, upsert_ctx or { repo_id = repo_row.id })
            local upsert = db["upsert_" .. entity]
            if type(upsert) == "function" then
                upsert(row)
            end
        end
        -- Announce the change so open panels re-render from the DB. The response's kind/number shape is
        -- forge-specific (GitHub `number`/`pull_request`, GitLab `iid`/`source_branch`) → resolved via the
        -- model when a verb did not pass an explicit `emit`.
        local ref = (type(body) == "table") and model.response_ref(repo_row.forge, body) or {}
        local kind = (emit and emit.kind) or ref.kind
        local number = (emit and emit.number) or ref.number
        if number then
            fire("LvimForgeTopicChanged", { root = event_root(root, repo_row), kind = kind, number = number })
        end
        if on_response then
            on_response(true, res)
        end
    end)
end

-- ── optional notifications poll timer (OFF by default) ─────────────────────────

--- Start the notifications poll timer when `config.notifications.poll` is on (default OFF). Guarded: a
--- second call is a no-op while the timer runs. Polls every tracked GitHub repo's notifications on the
--- interval. `M.stop_poll()` tears it down.
function M.setup_poll()
    local n = config.notifications or {}
    if not n.poll then
        return
    end
    if poll_timer then
        return
    end
    poll_timer = uv.new_timer()
    local interval = math.max(1, (n.interval or 300)) * 1000
    poll_timer:start(interval, interval, function()
        vim.schedule(function()
            if not db.available() then
                return
            end
            for _, r in ipairs(db.repositories()) do
                if backend_of(r.forge) then
                    M.pull_notifications(nil, { repo_id = r.id })
                end
            end
        end)
    end)
end

--- Stop + release the notifications poll timer.
function M.stop_poll()
    if poll_timer then
        pcall(function()
            poll_timer:stop()
        end)
        pcall(function()
            poll_timer:close()
        end)
        poll_timer = nil
    end
end

return M
