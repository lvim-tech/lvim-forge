-- lvim-forge: the in-house forge client — pull requests, issues, code review and notifications for
-- GitHub / GitLab / Gitea / Forgejo / Codeberg, as lvim-git's SIBLING. A local SQLite cache makes the
-- UI instant + offline; an explicit pull reconciles with the forge API; mutations go to the API and
-- upsert locally. On top of the cache: a filterable topic list, a rich topic buffer, PR checkout/diff/
-- merge, a code-review workspace, a notifications inbox, and a Forge section in lvim-git's status.
--
-- Internally lvim-forge is a SUITE of components (topics / topic / review / notifications / status
-- section / completion) over a shared core (client / db / sync / model / config / state / highlights). A
-- disabled component loads NOTHING. `setup()` merges user opts into the LIVE config, registers the
-- self-theming highlights, wires the `:LvimForge` command + `<Plug>` maps, and lazily bootstraps each
-- enabled component on first use.
--
-- This file is also the PUBLIC facade: the component openers, the sync entry (`pull`), the low-level
-- `request` seam, and the render-safe DB/cache reads. See the Public API section of the README /
-- `:help lvim-forge-api`.
--
-- The full feature set is live across GitHub / GitLab / Gitea / Forgejo / Codeberg: the client core
-- (detect / transport / auth / runner + the per-forge backends), the local DB (db.lua schema v3), the
-- normalization layer (model.lua), the pull-reconcile + mutate engine (sync.lua), and every UI component
-- (topics / topic / review / notifications / dispatch / composer / status-section / completion). The
-- render-safe reads read the DB; `M.request` and the openers are all wired.
--
---@module "lvim-forge"

local config = require("lvim-forge.config")
local highlights = require("lvim-forge.highlights")

local M = {}

---@type boolean  guards the one-time command / highlight / <Plug> registration
local registered = false

-- ── component openers (each routes through the command layer, which bootstraps its own component) ──

--- Open the topic list (issues + PRs).
---@param opts? table
function M.topics(opts)
    require("lvim-forge.commands").run("topics", opts)
end

--- Open the topic list pre-filtered to ISSUES.
---@param opts? table
function M.issues(opts)
    require("lvim-forge.commands").run("issues", opts)
end

--- Open the topic list pre-filtered to PULL REQUESTS.
---@param opts? table
function M.pulls(opts)
    require("lvim-forge.commands").run("pulls", opts)
end

--- Open a topic buffer by number.
---@param number? integer
---@param opts? table
function M.topic(number, opts)
    opts = opts or {}
    opts.args = { number and tostring(number) or nil }
    require("lvim-forge.commands").run("topic", opts)
end

--- Open the review workspace (optionally for a PR number).
---@param number? integer
function M.review(number)
    require("lvim-forge.commands").run("review", { args = { number and tostring(number) or nil } })
end

--- Open the notifications inbox.
function M.notifications()
    require("lvim-forge.commands").run("notifications")
end

--- Open the dispatch popup (the discoverable menu of everything).
function M.dispatch()
    require("lvim-forge.commands").run("dispatch")
end

--- Resolve the reference under the cursor and open it: `#123` → the topic buffer; a branch / commit → its
--- pull request. Bound to `<Plug>(LvimForgeOpenAtPoint)`; gated on `config.completion.enabled`.
function M.open_at_point()
    require("lvim-forge.refs").open_at_point()
end

--- Generic dispatch to any subcommand (the `:LvimForge` command layer path).
---@param sub string
---@param opts? table
function M.open(sub, opts)
    require("lvim-forge.commands").run(sub, opts)
end

-- ── sync + the low-level request seam ──

--- Pull (incremental sync of topics/posts/reviews/notifications into the cache). Async; resolves the
--- current buffer's tracked repo (or `opts.root`/`opts.repo_id`). `cb(ok, err)` on completion.
---@param opts? { root?: string|integer, repo_id?: integer, notifications_only?: boolean, selective?: boolean, full?: boolean }
---@param cb? fun(ok: boolean, err?: table)
function M.pull(opts, cb)
    opts = opts or {}
    require("lvim-forge.sync").pull(opts.root or 0, opts, cb)
end

--- Background staleness pull — a UI opener calls this: pulls when the cache is stale and
--- `config.pull.on_open`, returning immediately (the UI renders the cache, refreshes on PullDone).
---@param root_or_buf? string|integer
function M.maybe_pull(root_or_buf)
    require("lvim-forge.sync").maybe_pull(root_or_buf)
end

--- PUBLIC: the low-level client request seam — resolve forge/transport/auth for a repo and issue a
--- (optionally paginated) API request. Every forge impl + the sync engine calls this. `cb(res, err)`.
---@param spec table  see `lvim-forge.client.request`
---@param cb fun(res: table?, err: table?)
function M.request(spec, cb)
    require("lvim-forge.client").request(spec, cb)
end

-- ── render-safe reads (cache / detect; the network NEVER runs on these) ──

--- The detected forge-repo record for a buffer/path/cwd (render-safe): `{ forge, host, owner, name,
--- base, remote_url, root }` or nil when the path is not inside a recognized forge repo.
---@param root_or_buf? string|integer
---@return table?
function M.repo(root_or_buf)
    return require("lvim-forge.client").detect(root_or_buf)
end

--- Whether the repo for a buffer/path/cwd is TRACKED (present in the local DB). Detection alone is
--- NOT "tracked" — the user must `:LvimForge add`. Render-safe DB read.
---@param root_or_buf? string|integer
---@return boolean
function M.is_tracked(root_or_buf)
    local db = require("lvim-forge.db")
    local detect = require("lvim-forge.client").detect(root_or_buf)
    if not detect then
        return false
    end
    return db.repo_for_detect(detect) ~= nil
end

--- The topic list model for a filter (DB read; render-safe). `filter.repo_id` targets a repo
--- explicitly; otherwise the current buffer's tracked repo is used. Empty when there is no tracked
--- repo in context.
---@param filter? { repo_id?: integer, root_or_buf?: string|integer, state?: string, kind?: string, label?: string, assignee?: string, author?: string, milestone_id?: integer, mark?: string, search?: string }
---@return table[]
function M.topics_list(filter)
    filter = filter or {}
    local db = require("lvim-forge.db")
    local repo_id = filter.repo_id
    if not repo_id then
        local detect = require("lvim-forge.client").detect(filter.root_or_buf)
        local repo = detect and db.repo_for_detect(detect)
        if not repo then
            return {}
        end
        repo_id = repo.id
    end
    return db.topics(repo_id, filter)
end

--- A single topic by number in the current buffer's tracked repo (DB read; render-safe). nil when
--- there is no tracked repo or no such topic.
---@param number integer
---@param kind? "issue"|"pullreq"
---@param root_or_buf? string|integer
---@return table?
function M.get_topic(number, kind, root_or_buf)
    local db = require("lvim-forge.db")
    local detect = require("lvim-forge.client").detect(root_or_buf)
    local repo = detect and db.repo_for_detect(detect)
    if not repo then
        return nil
    end
    return db.get_topic(repo.id, number, kind)
end

--- The PR whose head ref matches a branch (the statusline "this branch's PR") — a render-safe DB read. The
--- branch defaults to the current one via lvim-git's cached `backend.branch` seam (soft); nil when the repo
--- is untracked, the branch is unknown, or no cached PR has that head ref. The async resolve (git branch +
--- the GitHub `pulls?head=` fallback) is `require("lvim-forge.actions").pr_for_branch(root, branch, cb)`.
---@param branch? string
---@param root_or_buf? string|integer
---@return table?
function M.pr_for_branch(branch, root_or_buf)
    local db = require("lvim-forge.db")
    local detect = require("lvim-forge.client").detect(root_or_buf)
    local repo = detect and db.repo_for_detect(detect)
    if not detect or not repo then
        return nil
    end
    local br = branch
    if (not br or br == "") and detect.root then
        local ok, backend = pcall(require, "lvim-git.backend")
        if ok and type(backend.branch) == "function" then
            br = backend.branch(detect.root)
        end
    end
    if type(br) ~= "string" or br == "" or br == "HEAD" then
        return nil
    end
    return db.topic_by_head_ref(repo.id, br)
end

--- The unread-notification count (the statusline / dispatch-title badge source). Render-safe DB read.
--- All tracked repos when `root_or_buf` is nil; scoped to one repo when a buffer/path is given (0 when
--- that path is not a tracked forge repo). Consumers refresh on `User LvimForgeNotificationsChanged` /
--- `LvimForgePullDone` (notifications piggyback the pull) instead of polling.
---@param root_or_buf? string|integer
---@return integer
function M.unread_count(root_or_buf)
    local db = require("lvim-forge.db")
    if not db.available() then
        return 0
    end
    if root_or_buf == nil then
        return db.notifications_unread()
    end
    local detect = require("lvim-forge.client").detect(root_or_buf)
    local repo = detect and db.repo_for_detect(detect)
    return repo and db.notifications_unread(repo.id) or 0
end

--- The unread-notification count across every tracked repo (the statusline badge source). Render-safe DB
--- read. `unread_count(root)` scopes it to one repo.
---@return integer
function M.notifications_unread()
    return M.unread_count()
end

-- ── setup ──

--- Merge user options into the LIVE config (in place) and wire ONLY the enabled components.
---@param opts? LvimForgeConfig
function M.setup(opts)
    require("lvim-utils.utils").merge(config, opts or {})
    if registered then
        return
    end
    registered = true
    require("lvim-utils.highlight").bind(highlights.build)
    require("lvim-forge.commands").setup()

    -- Register the `forge/` parent with the wallet (if installed), so `:LvimKeyring` renders forge tokens
    -- under a code-fork icon + accent. pcall-guarded: lvim-forge never hard-depends on lvim-keyring.
    pcall(function()
        require("lvim-keyring").register_namespace("forge", { icon = "", accent = "magenta" })
    end)

    -- User-bindable <Plug> maps (none installed by default). They route through the facade so a user maps
    -- them without knowing the command layer.
    local map = function(lhs, fn)
        vim.keymap.set("n", lhs, fn, { desc = "lvim-forge", silent = true })
    end
    map("<Plug>(LvimForgeTopics)", function()
        M.topics()
    end)
    map("<Plug>(LvimForgePull)", function()
        M.pull()
    end)
    map("<Plug>(LvimForgeNotifications)", function()
        M.notifications()
    end)
    map("<Plug>(LvimForgeOpenAtPoint)", function()
        M.open_at_point()
    end)

    -- The always-on components that self-wire at setup (each gated + guarded internally, no-op when off):
    --   • the completion + open-at-point component (refs): registers the optional cmp source + the
    --     gitcommit FileType autocmd.
    --   • the lvim-git status Forge section: self-registers with lvim-git's hook when both are installed
    --     (a soft pcall — nothing happens without lvim-git).
    pcall(function()
        require("lvim-forge.refs").setup()
    end)
    pcall(function()
        require("lvim-forge.ui.section").setup()
    end)

    -- The optional notifications poll timer (OFF unless config.notifications.poll) — a guarded no-op
    -- when disabled. Deferred so it never runs a request on the setup hot path.
    vim.schedule(function()
        pcall(function()
            require("lvim-forge.sync").setup_poll()
        end)
    end)
end

return M
