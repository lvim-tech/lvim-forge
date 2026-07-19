-- lvim-forge.commands: the `:LvimForge` command layer — parsing, completion, the layout token, and
-- dispatch to the (lazily-bootstrapped) component for each subcommand.
--
-- Grammar (works for EVERY view): `:LvimForge <subcommand> [area|float|bottom|tab] [args]`. The layout
-- token is recognised ANYWHERE in the args, so `:LvimForge topics area` opens the topic list in the area
-- layout and `:LvimForge review tab` opens the review workspace fullscreen. All four layouts are
-- first-class for every subcommand; a used token is sticky for the session (kept in state.layout). Each
-- subcommand bootstraps ONLY its own component — nothing else initializes.
--
-- Every feature verb has a live handler (topics/topic/create/comment/review/checkout/merge/pull/
-- notifications/add/remove/repos/dispatch); the few subcommands without a dedicated handler yet
-- (browse/yank/note/mark — reachable in-panel via `B`/`Y`/`t`/`T`) fall through to a clean notify.
--
---@module "lvim-forge.commands"

local state = require("lvim-forge.state")

local M = {}

---@type table<string, true>  the recognised layout tokens (accepted anywhere in the args)
local LAYOUTS = { area = true, float = true, bottom = true, tab = true }

--- Subcommands (also the completion source). `topics` is the default for a bare `:LvimForge`.
---@type string[]
local SUBCOMMANDS = {
    "topics",
    "issues",
    "pulls",
    "topic",
    "create",
    "comment",
    "review",
    "checkout",
    "merge",
    "pull",
    "notifications",
    "browse",
    "yank",
    "add",
    "remove",
    "repos",
    "note",
    "mark",
    "dispatch",
    "auth",
}

---@class LvimForgeCmd
---@field sub    string    the subcommand (defaults to "topics")
---@field layout? string   an explicit layout token (area|float|bottom|tab)
---@field args   string[]  the remaining positional args

--- Parse fargs into an LvimForgeCmd: pull the layout token out from anywhere, leave the rest as
--- positional args. The first non-token word is the subcommand.
---@param fargs string[]
---@return LvimForgeCmd
local function parse(fargs)
    local out = { sub = nil, args = {} }
    for _, w in ipairs(fargs) do
        if LAYOUTS[w] and not out.layout then
            out.layout = w
        elseif not out.sub then
            out.sub = w
        else
            out.args[#out.args + 1] = w
        end
    end
    out.sub = out.sub or "topics"
    return out
end

--- Resolve the layout for a view: an explicit token (also made sticky) → the session sticky → config.
---@param view string
---@param token? string
---@return string
function M.layout_for(view, token)
    if token then
        state.layout[view] = token
    end
    if state.layout[view] then
        return state.layout[view]
    end
    local config = require("lvim-forge.config")
    return (config.layouts or {})[view] or "float"
end

--- Fallback for a subcommand with no dedicated handler yet (browse/yank/note/mark — reachable in-panel
--- via `B`/`Y`/`t`/`T`). Reports cleanly (never an error) so the command stays discoverable.
---@param sub string
local function not_built(sub)
    vim.notify(
        ("lvim-forge: `%s` has no dedicated command handler yet (use the in-panel key)"):format(sub),
        vim.log.levels.INFO
    )
end

--- Notify prefix helper.
---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-forge: " .. msg, level or vim.log.levels.INFO)
end

-- ── repo tracking (register/track the repo in the DB; `:LvimForge pull` then syncs it over the network) ──

--- Resolve the repo the `add` verb should track: no positional spec → the current repo (detect);
--- an `owner/name` spec → the current repo's host/forge with the owner/name overridden; a bare
--- `<remote>` spec → that specific git remote classified. Returns a `LvimForgeRepo` or nil + reason.
---@param spec? string
---@return table? repo, string? err
local function resolve_add_target(spec)
    local detect = require("lvim-forge.client.detect")
    if not spec then
        return detect.detect(0), "not inside a recognized forge repository"
    end
    if spec:find("/", 1, true) then
        local base = detect.detect(0)
        if not base then
            return nil, "an owner/name override must be run inside a forge repository (its host/forge is used)"
        end
        local owner, name = spec:match("^(.+)/([^/]+)$")
        if not owner then
            return nil, "could not parse '" .. spec .. "' as owner/name"
        end
        local repo = vim.tbl_extend("force", {}, base)
        repo.owner, repo.name = owner, name
        repo.base = detect.api_base(base.forge, base.host)
        return repo, nil
    end
    return detect.classify_remote(spec, 0), "no git remote '" .. spec .. "' (or its host is not a recognized forge)"
end

--- `:LvimForge add [remote|owner/name] [full|selective]` — register (or update) the current repo in
--- the local DB. Classifies the forge via `client/detect`, upserts a `repositories` row and sets its
--- tracked mode. NO network pull here (that is the sync engine, a later phase).
---@param p LvimForgeCmd
local function do_add(p)
    local db = require("lvim-forge.db")
    if not db.available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end
    local tracked, spec = "full", nil
    for _, a in ipairs(p.args) do
        if a == "selective" or a == "full" then
            tracked = a
        else
            spec = a
        end
    end
    local repo, reason = resolve_add_target(spec)
    if not repo then
        notify(reason or "could not resolve a forge repository to track", vim.log.levels.WARN)
        return
    end
    local existed = db.repo_by_remote(repo.host, repo.owner, repo.name) ~= nil
    local repo_id = db.upsert_repository({
        forge = repo.forge,
        host = repo.host,
        owner = repo.owner,
        name = repo.name,
        remote_url = repo.remote_url,
        tracked = tracked,
    })
    if not repo_id then
        notify("failed to register the repository in the database", vim.log.levels.ERROR)
        return
    end
    db.set_tracked(repo_id, tracked)
    notify(
        ("%s %s/%s on %s (tracked = %s) — run `:LvimForge pull` to sync it"):format(
            existed and "updated" or "tracked",
            repo.owner,
            repo.name,
            repo.host,
            tracked
        )
    )
end

--- `:LvimForge remove` — untrack the current repo, deleting its row and everything under it (FK
--- cascade). Confirmed via lvim-ui when `confirm_destructive`.
---@param p LvimForgeCmd
local function do_remove(p)
    local db = require("lvim-forge.db")
    if not db.available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end
    local detect = require("lvim-forge.client.detect").detect(0)
    local repo = detect and db.repo_for_detect(detect)
    if not repo then
        notify("the current repository is not tracked", vim.log.levels.WARN)
        return
    end
    local function proceed()
        if db.remove_repository(repo.id) then
            notify(("untracked %s/%s (its cached topics were removed)"):format(repo.owner, repo.name))
        else
            notify("failed to remove the repository", vim.log.levels.ERROR)
        end
    end
    local config = require("lvim-forge.config")
    local ok_ui, ui = pcall(require, "lvim-ui")
    if config.confirm_destructive and ok_ui and type(ui.confirm) == "function" then
        ui.confirm({
            prompt = ("Untrack %s/%s and delete its cached topics?"):format(repo.owner, repo.name),
            default_no = true,
            callback = function(yes)
                if yes then
                    proceed()
                end
            end,
        })
    else
        proceed()
    end
end

--- `:LvimForge pull [--notifications] [selective|full]` — reconcile the current repo's cache with the
--- forge API via the sync engine (async). `--notifications` pulls only the notifications; `selective`
--- forces the involves-me demand-based pull for this run. Reports the outcome (topics changed) on done.
---@param p LvimForgeCmd
local function do_pull(p)
    local db = require("lvim-forge.db")
    if not db.available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end
    local opts = {}
    for _, a in ipairs(p.args) do
        if a == "--notifications" or a == "notifications" then
            opts.notifications_only = true
        elseif a == "selective" then
            opts.selective = true
        elseif a == "full" then
            opts.full = true
        end
    end
    local sync = require("lvim-forge.sync")
    if opts.notifications_only then
        sync.pull_notifications(0, {}, function(count, err)
            if err then
                notify("notifications pull failed: " .. (err.message or err.kind or "?"), vim.log.levels.WARN)
            else
                notify(("pulled %d notification%s"):format(count, count == 1 and "" or "s"))
            end
        end)
        return
    end
    notify("pull started…")
    sync.pull(0, opts, function(ok, err)
        if ok then
            notify("pull complete")
        else
            notify("pull failed: " .. ((err and (err.message or err.kind)) or "?"), vim.log.levels.WARN)
        end
    end)
end

--- `:LvimForge topics|issues|pulls [layout]` — open the topic list for the current tracked repo. `issues`
--- and `pulls` pre-set the kind filter. Renders from the local cache (instant, offline); a background
--- staleness pull refreshes it. Gated on `config.topics.enabled`.
---@param p LvimForgeCmd
local function do_topics(p)
    local config = require("lvim-forge.config")
    if not (config.topics and config.topics.enabled) then
        notify("the topics component is disabled (config.topics.enabled = false)")
        return
    end
    if not require("lvim-forge.db").available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end
    local kind = (p.sub == "issues" and "issues") or (p.sub == "pulls" and "pulls") or "all"
    require("lvim-forge.ui.topics").open({ layout = p.layout, kind = kind })
end

--- `:LvimForge topic <n> [layout]` — open the read-only topic buffer for issue/PR number `n` in the
--- current tracked repo. Renders from the local cache (instant, offline); a background detail pull
--- refreshes it. Gated on `config.topic.enabled`.
---@param p LvimForgeCmd
local function do_topic(p)
    local config = require("lvim-forge.config")
    if not (config.topic and config.topic.enabled) then
        notify("the topic component is disabled (config.topic.enabled = false)")
        return
    end
    if not require("lvim-forge.db").available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end
    local number = tonumber(p.args[1])
    if not number then
        notify("usage: `:LvimForge topic <number> [area|float|bottom|tab]`", vim.log.levels.WARN)
        return
    end
    require("lvim-forge.ui.topic").open(0, number, { layout = p.layout })
end

--- `:LvimForge create [issue|pr]` — open the composer to create a topic. `issue` (default) creates an
--- issue; `pr` opens the composer in its create-PR shape (base/head pickers seeded from the git branches,
--- title/body prefilled from the commits, a draft toggle, and the head branch pushed on submit when it has
--- no upstream). Gated on `config.topic.enabled`.
---@param p LvimForgeCmd
local function do_create(p)
    local config = require("lvim-forge.config")
    if not (config.topic and config.topic.enabled) then
        notify("the topic component is disabled (config.topic.enabled = false)")
        return
    end
    if not require("lvim-forge.db").available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end
    local mode = (p.args[1] == "pr") and "pr" or "issue"
    require("lvim-forge.ui.composer").open({ mode = mode, root = 0 })
end

--- `:LvimForge comment <n>` — open the composer to add a comment to topic `n` in the current repo.
---@param p LvimForgeCmd
local function do_comment(p)
    local config = require("lvim-forge.config")
    if not (config.topic and config.topic.enabled) then
        notify("the topic component is disabled (config.topic.enabled = false)")
        return
    end
    if not require("lvim-forge.db").available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end
    local number = tonumber(p.args[1])
    if not number then
        notify("usage: `:LvimForge comment <number>`", vim.log.levels.WARN)
        return
    end
    require("lvim-forge.ui.composer").open({ mode = "comment", root = 0, number = number })
end

--- `:LvimForge checkout <n> [worktree]` — check out pull request `n` locally (fetch its head → a local
--- branch, or with `worktree` add a sibling worktree). Reports the resulting branch / worktree path and
--- re-syncs lvim-git. Gated on `config.topic.enabled`.
---@param p LvimForgeCmd
local function do_checkout(p)
    local db = require("lvim-forge.db")
    if not (require("lvim-forge.config").topic or {}).enabled then
        notify("the topic component is disabled (config.topic.enabled = false)")
        return
    end
    if not db.available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end
    local number = tonumber(p.args[1])
    if not number then
        notify("usage: `:LvimForge checkout <number> [worktree]`", vim.log.levels.WARN)
        return
    end
    local worktree = false
    for _, a in ipairs(p.args) do
        if a == "worktree" or a == "--worktree" then
            worktree = true
        end
    end
    notify(("checking out #%d%s …"):format(number, worktree and " in a worktree" or ""))
    require("lvim-forge.actions").checkout(0, number, { worktree = worktree }, function(ok, res)
        if not ok then
            notify("checkout failed: " .. ((res and (res.message or res.kind)) or "?"), vim.log.levels.WARN)
            return
        end
        if res and res.worktree then
            notify(("checked out #%d → worktree %s (branch %s)"):format(number, res.worktree, res.branch))
        else
            notify(("checked out #%d → branch %s"):format(number, (res and res.branch) or "?"))
        end
    end)
end

--- `:LvimForge merge <n> [method]` — merge pull request `n` in the current repo. With no `method` (or a
--- non-method arg) it opens the MERGE transient (method / delete-branch / commit message); a `method`
--- (merge|squash|rebase) merges directly (still gated by `confirm_destructive`). Gated on `config.topic.enabled`.
---@param p LvimForgeCmd
local function do_merge(p)
    local db = require("lvim-forge.db")
    local config = require("lvim-forge.config")
    if not (config.topic or {}).enabled then
        notify("the topic component is disabled (config.topic.enabled = false)")
        return
    end
    if not db.available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end
    local number = tonumber(p.args[1])
    if not number then
        notify("usage: `:LvimForge merge <number> [merge|squash|rebase]`", vim.log.levels.WARN)
        return
    end
    local methods = { merge = true, squash = true, rebase = true }
    local method
    for _, a in ipairs(p.args) do
        if methods[a] then
            method = a
        end
    end
    if method then
        -- A direct method merge (still confirmed when confirm_destructive): merge with the config
        -- delete-branch default.
        local actions = require("lvim-forge.actions")
        local function run()
            notify(("merging #%d (%s) …"):format(number, method))
            actions.merge(0, number, {
                method = method,
                delete_branch = (config.merge or {}).delete_branch == true,
            }, function(ok, res)
                if not ok then
                    notify("merge failed: " .. ((res and (res.message or res.kind)) or "?"), vim.log.levels.WARN)
                    return
                end
                notify(("merged #%d (%s)"):format(number, method))
            end)
        end
        local ok_ui, ui = pcall(require, "lvim-ui")
        if config.confirm_destructive and ok_ui and type(ui.confirm) == "function" then
            ui.confirm({
                prompt = ("Merge #%d (%s)?"):format(number, method),
                default_no = true,
                callback = function(yes)
                    if yes then
                        run()
                    end
                end,
            })
        else
            run()
        end
        return
    end
    -- No method given: open the merge transient for this PR (built from the cache).
    local d = require("lvim-forge.client").detect(0)
    local repo_row = d and db.repo_for_detect(d)
    if not d or not repo_row then
        notify("not inside a tracked forge repository (`:LvimForge add`)", vim.log.levels.WARN)
        return
    end
    local topic = db.get_topic(repo_row.id, number, "pullreq")
    if not topic or not topic.pullreq then
        notify(("pull request #%d is not cached — `:LvimForge pull` first"):format(number), vim.log.levels.WARN)
        return
    end
    require("lvim-forge.ui.topic").register_transients()
    require("lvim-forge.transient").open("merge", {
        root = d.root,
        selection = {
            root = d.root,
            number = number,
            repo_row = repo_row,
            mergeable = topic.pullreq.mergeable,
            review_decision = topic.pullreq.review_decision,
        },
    })
end

--- `:LvimForge review [n] [layout]` — open the READ review workspace for pull request `n` in the current
--- tracked repo: threads overlaid on lvim-git's diff (with a plain hunk-panel fallback when lvim-git is
--- absent). With no `n` it reviews the PR whose head is the current branch (`pr_for_branch`). Gated on
--- `config.review.enabled`.
---@param p LvimForgeCmd
local function do_review(p)
    local config = require("lvim-forge.config")
    if not (config.review and config.review.enabled) then
        notify("the review component is disabled (config.review.enabled = false)")
        return
    end
    if not require("lvim-forge.db").available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end
    -- `:LvimForge review submit [n]` → the SUBMIT transient for a PR standalone (no workspace needed).
    local submit = p.args[1] == "submit"
    local number = tonumber(submit and p.args[2] or p.args[1])
    if not number then
        -- No explicit number → the current branch's PR (head_ref match), if any.
        local pr = require("lvim-forge").pr_for_branch(nil, 0)
        number = pr and pr.number
    end
    if not number then
        notify(
            submit and "usage: `:LvimForge review submit <pull-number>`"
                or "usage: `:LvimForge review <pull-number> [area|float|bottom|tab]`",
            vim.log.levels.WARN
        )
        return
    end
    if submit then
        require("lvim-forge.ui.review").submit(0, number)
        return
    end
    require("lvim-forge.ui.review").open(0, number, { layout = p.layout })
end

--- `:LvimForge notifications [pull] [area|float|bottom|tab]` — `pull` fetches the notifications endpoint
--- (the cheap standalone pull); a bare `notifications` opens the inbox (spans every tracked repo, grouped;
--- `unread ● all` filter, `<CR>` open + mark read, `r`/`R` mark read, `P` pull). Gated on `caps.notifications`.
---@param p LvimForgeCmd
local function do_notifications(p)
    if p.args[1] == "pull" then
        do_pull({ sub = "pull", args = { "--notifications" } })
        return
    end
    local config = require("lvim-forge.config")
    if not (config.notifications and config.notifications.enabled) then
        notify("the notifications component is disabled (config.notifications.enabled = false)")
        return
    end
    if not require("lvim-forge.db").available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end
    require("lvim-forge.ui.notifications").open({ layout = p.layout })
end

--- `:LvimForge repos` — list the tracked repositories (a notify summary; the picker UI lands in a
--- later phase).
local function do_repos()
    local db = require("lvim-forge.db")
    if not db.available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end
    local repos = db.repositories()
    if #repos == 0 then
        notify("no tracked repositories — `:LvimForge add` to track this one")
        return
    end
    local lines = {}
    for _, r in ipairs(repos) do
        lines[#lines + 1] = ("  %s/%s  (%s, %s)"):format(r.owner, r.name, r.host, r.tracked)
    end
    notify(("tracked repositories (%d):\n%s"):format(#repos, table.concat(lines, "\n")))
end

--- `:LvimForge dispatch` — open the DISPATCH transient (Magit-forge's `?`): the discoverable menu of every
--- command. Also reachable via `?` inside any forge panel. Bare `:LvimForge` keeps opening the topic list
--- (the primary view, the Magit `magit-status` default) — the dispatch is the explicit `?`/`dispatch` entry.
local function do_dispatch()
    require("lvim-forge.ui.dispatch").open()
end

--- `:LvimForge auth store [host]` — store an API token for `host` in the lvim-keyring wallet (masked
--- prompt), so `M.resolve` reads it from source "keyring". Prompts for the host when omitted.
---@param p LvimForgeCmd
local function do_auth(p)
    local args = p.args or {}
    if args[1] ~= "store" then
        notify("usage: :LvimForge auth store [host]")
        return
    end
    local auth = require("lvim-forge.client.auth")
    local host = args[2]
    if host and host ~= "" then
        auth.store(host)
        return
    end
    require("lvim-ui").input({
        title = "Forge host (e.g. github.com)",
        callback = function(ok, value)
            if ok and value and value ~= "" then
                auth.store(vim.trim(value))
            end
        end,
    })
end

--- The dispatch table: subcommand → handler. Each handler lazily requires only its own component. The
--- few verbs without a dedicated handler (browse/yank/note/mark) fall through to the not-built notify.
---@type table<string, fun(p: LvimForgeCmd)>
local HANDLERS = {}
for _, sub in ipairs(SUBCOMMANDS) do
    HANDLERS[sub] = function(_)
        not_built(sub)
    end
end
HANDLERS.add = do_add
HANDLERS.remove = do_remove
HANDLERS.repos = do_repos
HANDLERS.pull = do_pull
HANDLERS.notifications = do_notifications
HANDLERS.topics = do_topics
HANDLERS.issues = do_topics
HANDLERS.pulls = do_topics
HANDLERS.topic = do_topic
HANDLERS.create = do_create
HANDLERS.comment = do_comment
HANDLERS.checkout = do_checkout
HANDLERS.merge = do_merge
HANDLERS.review = do_review
HANDLERS.dispatch = do_dispatch
HANDLERS.auth = do_auth

--- Run a subcommand programmatically (the facade path).
---@param sub string
---@param opts? { layout?: string, args?: string[] }
function M.run(sub, opts)
    opts = opts or {}
    local h = HANDLERS[sub]
    if not h then
        vim.notify("lvim-forge: unknown subcommand " .. tostring(sub), vim.log.levels.ERROR)
        return
    end
    h({ sub = sub, layout = opts.layout, args = opts.args or {} })
end

--- Dispatch a parsed `:LvimForge` invocation.
---@param p LvimForgeCmd
local function dispatch(p)
    local h = HANDLERS[p.sub]
    if not h then
        vim.notify("lvim-forge: unknown subcommand " .. tostring(p.sub), vim.log.levels.ERROR)
        return
    end
    local ok, err = pcall(h, p)
    if not ok then
        vim.notify("lvim-forge: " .. tostring(err), vim.log.levels.ERROR)
    end
end

--- `:LvimForge` completion: subcommands, then the layout tokens (+ open topic numbers once the DB lands).
---@param arglead string
---@param cmdline string
---@return string[]
local function complete(arglead, cmdline)
    local has_sub = false
    for word in cmdline:gmatch("%S+") do
        if word ~= "LvimForge" and vim.tbl_contains(SUBCOMMANDS, word) then
            has_sub = true
        end
    end
    local candidates = has_sub and { "area", "float", "bottom", "tab" } or SUBCOMMANDS
    local out = {}
    for _, c in ipairs(candidates) do
        if c:find(arglead, 1, true) == 1 then
            out[#out + 1] = c
        end
    end
    return out
end

--- Register the `:LvimForge` user command (once).
function M.setup()
    vim.api.nvim_create_user_command("LvimForge", function(cmd)
        dispatch(parse(cmd.fargs))
    end, {
        nargs = "*",
        complete = complete,
        desc = "lvim-forge: topics | issues | pulls | topic | review | pull | notifications | add | remove | repos | … (+ area|float|bottom|tab)",
    })
end

return M
