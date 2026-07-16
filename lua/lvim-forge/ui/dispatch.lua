-- lvim-forge.ui.dispatch: the DISPATCH transient (Magit-forge's `?` / `@`) — the discoverable top-level
-- menu of every forge command. It is ITSELF a transient (the shared lvim-ui `transient` engine + preset, the
-- SAME renderer every verb popup uses — never a bespoke menu): its groups' actions OPEN the panels (topics /
-- issues / pulls / notifications / review / a specific topic) and the verb transients (pull / list-filter /
-- topic-edit / merge / review-submit), so a user who does not remember a key can reach everything from one
-- place. This module also OWNS the three dispatch-coordinated verb transients that had no other home — `pull`
-- (repo sync), `list-filter` (a thin front-end over `ui/topics` `apply_filter`) and `topic-edit` (state +
-- lock over the topic at point); merge lives in `ui/topic` and review-submit in `ui/review` (this only opens
-- them).
--
-- The dispatch is CAPS-GATED and CONTEXT-aware: it is (re)registered on every open from the detected forge's
-- capability table (a forge without review / notifications hides those rows) and from the optional `topic`
-- scope (a topic/review panel's `?` seeds the topic-scoped verbs so merge / edit / review appear). It is
-- render-safe: every action resolves its repo lazily and reports the gap cleanly instead of erroring.
--
---@module "lvim-forge.ui.dispatch"

local transient = require("lvim-forge.transient")
local config = require("lvim-forge.config")

local M = {}

---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-forge: " .. msg, level or vim.log.levels.INFO)
end

--- The capability table for the repo the dispatch was opened over (an explicit `root`, else the current
--- buffer). An unknown / untracked repo yields `{}` (every cap false) — a caps gate then fails closed.
---@param root? string|integer
---@return table<string, boolean>
local function caps_for(root)
    local ok, client = pcall(require, "lvim-forge.client")
    if not ok then
        return {}
    end
    local d = client.detect(root or 0)
    if not d then
        return {}
    end
    return client.caps(d.forge)
end

--- Prompt for a topic/PR number through the canonical lvim-ui input, then run `cb(number)`.
---@param title string
---@param cb fun(number: integer)
local function prompt_number(title, cb)
    require("lvim-ui").input({
        title = { text = title },
        callback = function(confirmed, value)
            if not confirmed then
                return
            end
            local n = tonumber(vim.trim(value or ""))
            if not n then
                notify("not a number: " .. tostring(value), vim.log.levels.WARN)
                return
            end
            cb(n)
        end,
    })
end

-- ══ the PULL verb-transient (repo sync) ══════════════════════════════════════════
-- Switches `--notifications-only` / `--full` / `--selective`; option `=c closed-since` (the initial window
-- for closed topics, seeded from `config.pull.closed_since`). The action drives `sync.pull` /
-- `sync.pull_notifications` with the assembled args. Per-repo saved defaults ride the shared engine store.

--- Report a pull outcome.
---@param ok boolean
---@param err? table
local function pull_done(ok, err)
    if ok then
        notify("pull complete")
    else
        notify("pull failed: " .. ((err and (err.message or err.kind)) or "?"), vim.log.levels.WARN)
    end
end

--- The pull transient's action: read the switches/option from the live rows, then run the sync.
---@param _ string[]
---@param ctx LvimUiTransientCtx
local function pull_action(_, ctx)
    local rows = ctx.rows or {}
    local root = ctx.root or 0
    local sync = require("lvim-forge.sync")
    if rows["-n"] and rows["-n"].value == true then
        notify("pulling notifications …")
        sync.pull_notifications(root, {}, function(count, err)
            if err then
                notify("notifications pull failed: " .. ((err.message or err.kind) or "?"), vim.log.levels.WARN)
            else
                notify(("pulled %d notification%s"):format(count or 0, (count == 1) and "" or "s"))
            end
        end)
        return
    end
    local closed_since = rows["-c"] and rows["-c"].value
    notify("pull started …")
    sync.pull(root, {
        full = rows["-f"] and rows["-f"].value == true,
        selective = rows["-s"] and rows["-s"].value == true,
        closed_since = (type(closed_since) == "string" and closed_since ~= "") and closed_since or nil,
    }, pull_done)
end

---@type boolean
local pull_registered = false

--- Register the pull transient DEF once (idempotent — `define` replaces). Called from the dispatch action
--- so the `closed-since` default reads the EFFECTIVE config (after `setup()` merged it).
local function register_pull_transient()
    if pull_registered then
        return
    end
    pull_registered = true
    transient.define({
        id = "pull",
        title = "Pull (sync with the forge)",
        groups = {
            {
                title = "Switches",
                infix = {
                    {
                        kind = "switch",
                        key = "-n",
                        flag = "--notifications-only",
                        label = "Notifications only (the cheap standalone pull)",
                        level = 1,
                    },
                    {
                        kind = "switch",
                        key = "-f",
                        flag = "--full",
                        label = "Full re-pull (ignore the stored cursor)",
                        level = 1,
                    },
                    {
                        kind = "switch",
                        key = "-s",
                        flag = "--selective",
                        label = "Selective (only topics that involve me)",
                        level = 2,
                    },
                },
            },
            {
                title = "Options",
                infix = {
                    {
                        kind = "option",
                        key = "-c",
                        arg = "--closed-since",
                        label = "Initial window for closed topics",
                        choices = { "6m", "1y", "all" },
                        default = (config.pull and config.pull.closed_since) or "1y",
                        level = 2,
                    },
                },
            },
            {
                title = "Actions",
                actions = {
                    { key = "P", label = "Pull", run = pull_action },
                },
            },
        },
    })
end

-- ══ the LIST-FILTER verb-transient (a front-end over the topics filter model) ═════
-- Structured infixes (kind / state / involvement + label / author / milestone / mark / free text) that
-- assemble the SAME filter `ui/topics` consumes: kind/state/involvement pass through, the rest become the
-- structured query string `ui/topics.apply_filter` parses. Nothing here duplicates the query logic.

--- Read a live option row's non-empty string value, else nil.
---@param rows table<string, table>
---@param key string
---@return string?
local function opt(rows, key)
    local r = rows[key]
    local v = r and r.value
    if type(v) == "string" and v ~= "" then
        return v
    end
    return nil
end

--- The list-filter transient's action: assemble the query string + the band selections, then re-filter (or
--- open) the topic list through the shared `apply_filter` seam.
---@param _ string[]
---@param ctx LvimUiTransientCtx
local function filter_action(_, ctx)
    local rows = ctx.rows or {}
    local parts = {}
    local function add(prefix, key)
        local v = opt(rows, key)
        if v then
            parts[#parts + 1] = prefix .. v
        end
    end
    add("label:", "-l")
    add("author:", "-a")
    add("milestone:", "-M")
    add("mark:", "-k")
    local text = opt(rows, "-t")
    if text then
        parts[#parts + 1] = text
    end
    require("lvim-forge.ui.topics").apply_filter({
        kind = rows["-K"] and rows["-K"].value,
        state = rows["-s"] and rows["-s"].value,
        involvement = rows["-i"] and rows["-i"].value,
        query = table.concat(parts, " "), -- "" clears the query
    })
end

--- (Re)register the list-filter transient with the CURRENT sticky filter as its infix defaults, so it opens
--- pre-populated with the topic list's live filter (`define` replaces).
local function register_filter_transient()
    local seed = (require("lvim-forge.state").panel_state or {}).topics or {}
    local q = seed.query or {}
    transient.define({
        id = "list-filter",
        title = "Filter topics",
        groups = {
            {
                title = "Scope",
                infix = {
                    {
                        kind = "option",
                        key = "-K",
                        arg = "--kind",
                        label = "Kind",
                        choices = { "all", "issues", "pulls" },
                        default = seed.kind or "all",
                        level = 1,
                    },
                    {
                        kind = "option",
                        key = "-s",
                        arg = "--state",
                        label = "State",
                        choices = { "open", "closed", "all" },
                        default = seed.state or "open",
                        level = 1,
                    },
                    {
                        kind = "option",
                        key = "-i",
                        arg = "--involvement",
                        label = "Involvement",
                        choices = { "all", "mine", "assigned", "review-requested" },
                        default = seed.involvement or "all",
                        level = 1,
                    },
                },
            },
            {
                title = "Query",
                infix = {
                    { kind = "option", key = "-l", arg = "--label", label = "Label", default = q.label, level = 1 },
                    { kind = "option", key = "-a", arg = "--author", label = "Author", default = q.author, level = 1 },
                    {
                        kind = "option",
                        key = "-M",
                        arg = "--milestone",
                        label = "Milestone",
                        default = q.milestone,
                        level = 2,
                    },
                    { kind = "option", key = "-k", arg = "--mark", label = "Mark", default = q.mark, level = 2 },
                    {
                        kind = "option",
                        key = "-t",
                        arg = "--text",
                        label = "Free text",
                        default = (q.search ~= "" and q.search) or nil,
                        level = 1,
                    },
                },
            },
            {
                title = "Actions",
                actions = {
                    { key = "f", label = "Apply filter", run = filter_action },
                },
            },
        },
    })
end

-- ══ the TOPIC-EDIT verb-transient (state + lock, over the topic at point) ═════════
-- Close/reopen via `actions.set_state` (works on every forge); lock/unlock via `actions.set_lock`,
-- caps-gated (`caps.lock`) so the rows appear only where the forge wires it. The topic rides in on
-- `ctx.selection` (root / number / kind / state / locked).

--- Run `fn` behind a destructive-action confirm when `config.confirm_destructive`, else directly.
---@param prompt string
---@param fn fun()
local function guard(prompt, fn)
    if not config.confirm_destructive then
        fn()
        return
    end
    require("lvim-ui").confirm({
        prompt = prompt,
        default_no = true,
        callback = function(yes)
            if yes then
                fn()
            end
        end,
    })
end

--- The topic-edit "set state" action (close | reopen).
---@param new_state "closed"|"open"
---@param ctx LvimUiTransientCtx
local function set_state(new_state, ctx)
    local sel = ctx.selection or {}
    if not sel.number then
        return
    end
    local actions = require("lvim-forge.actions")
    local function run()
        actions.set_state(sel.root, sel.number, new_state, function(ok, res)
            if not ok then
                notify("state change failed: " .. ((res and (res.message or res.kind)) or "?"), vim.log.levels.WARN)
                return
            end
            notify(("#%d %s"):format(sel.number, new_state == "closed" and "closed" or "reopened"))
        end)
    end
    if new_state == "closed" then
        guard(("Close #%d?"):format(sel.number), run)
    else
        run()
    end
end

--- The topic-edit "lock / unlock" action.
---@param lock boolean
---@param ctx LvimUiTransientCtx
local function set_lock(lock, ctx)
    local sel = ctx.selection or {}
    if not sel.number then
        return
    end
    local actions = require("lvim-forge.actions")
    local function run()
        actions.set_lock(sel.root, sel.number, lock, function(ok, res)
            if not ok then
                notify("lock change failed: " .. ((res and (res.message or res.kind)) or "?"), vim.log.levels.WARN)
                return
            end
            notify(("#%d conversation %s"):format(sel.number, lock and "locked" or "unlocked"))
        end)
    end
    if lock then
        guard(("Lock the conversation on #%d?"):format(sel.number), run)
    else
        run()
    end
end

--- (Re)register the topic-edit transient for the topic at point, caps-gated. Returns whether it has any
--- action (a merged topic on a forge without `lock` has nothing to edit → the caller reports the gap).
---@param topic table  `{ root, number, kind, state, locked }`
---@param caps table<string, boolean>
---@return boolean has_actions
local function register_topic_edit_transient(topic, caps)
    local actions_list = {}
    if topic.state == "open" then
        actions_list[#actions_list + 1] = {
            key = "c",
            label = "Close",
            run = function(_, ctx)
                set_state("closed", ctx)
            end,
        }
    elseif topic.state == "closed" then
        actions_list[#actions_list + 1] = {
            key = "o",
            label = "Reopen",
            run = function(_, ctx)
                set_state("open", ctx)
            end,
        }
    end
    if caps.lock then
        if topic.locked then
            actions_list[#actions_list + 1] = {
                key = "u",
                label = "Unlock conversation",
                run = function(_, ctx)
                    set_lock(false, ctx)
                end,
            }
        else
            actions_list[#actions_list + 1] = {
                key = "l",
                label = "Lock conversation",
                run = function(_, ctx)
                    set_lock(true, ctx)
                end,
            }
        end
    end
    if #actions_list == 0 then
        return false
    end
    transient.define({
        id = "topic-edit",
        title = ("Edit #%d"):format(topic.number or 0),
        groups = {
            { title = "Actions", actions = actions_list },
        },
    })
    return true
end

--- Open the topic-edit transient over `topic` (the dispatch's `e` action).
---@param topic table
---@param caps table<string, boolean>
local function open_topic_edit(topic, caps)
    if not register_topic_edit_transient(topic, caps) then
        notify(("#%d cannot be edited (a merged topic on a forge without conversation locking)"):format(topic.number))
        return
    end
    transient.open("topic-edit", { root = topic.root, selection = topic })
end

-- ══ the DISPATCH transient (the main menu) ═══════════════════════════════════════

--- Open a topic through the composer create picker (issue | pull request).
---@param root? string|integer
local function do_create(root)
    require("lvim-ui").select({
        title = "Create",
        items = {
            { label = "Issue", icon = config.icons.issue, mode = "issue" },
            { label = "Pull request", icon = config.icons.pull, mode = "pr" },
        },
        callback = function(confirmed, idx)
            if not confirmed or not idx then
                return
            end
            require("lvim-forge.ui.composer").open({ mode = (idx == 2) and "pr" or "issue", root = root })
        end,
    })
end

--- (Re)build + register the dispatch DEF from the live caps + the optional topic scope. Rows the forge does
--- not support (review / notifications) are OMITTED; the topic-scoped group is present only when a topic
--- rode in. Re-registered on every open (`define` replaces), so it always reflects the current context.
---@param root? string|integer
---@param caps table<string, boolean>
---@param topic? table  `{ root, number, kind, state, is_pr, locked, pullreq }`
local function register_dispatch(root, caps, topic)
    local inspect = {
        {
            key = "t",
            label = "Topics",
            run = function()
                require("lvim-forge.ui.topics").open({ root = root })
            end,
        },
        {
            key = "i",
            label = "Issues",
            run = function()
                require("lvim-forge.ui.topics").open({ root = root, kind = "issues" })
            end,
        },
        {
            key = "p",
            label = "Pull requests",
            run = function()
                require("lvim-forge.ui.topics").open({ root = root, kind = "pulls" })
            end,
        },
    }
    if caps.notifications then
        inspect[#inspect + 1] = {
            key = "N",
            label = "Notifications",
            run = function()
                require("lvim-forge.ui.notifications").open()
            end,
        }
    end
    if caps.reviews then
        inspect[#inspect + 1] = {
            key = "v",
            label = "Review workspace",
            run = function()
                if topic and topic.is_pr and topic.number then
                    require("lvim-forge.ui.review").open(root, topic.number)
                else
                    prompt_number("Review pull request #", function(n)
                        require("lvim-forge.ui.review").open(root, n)
                    end)
                end
            end,
        }
    end
    inspect[#inspect + 1] = {
        key = "T",
        label = "Topic (by number)",
        run = function()
            prompt_number("Open topic #", function(n)
                require("lvim-forge.ui.topic").open(root, n)
            end)
        end,
    }

    local act = {
        {
            key = "c",
            label = "Create issue / pull request",
            run = function()
                do_create(root)
            end,
        },
        {
            key = "P",
            label = "Pull (sync)",
            run = function()
                register_pull_transient()
                transient.open("pull", { root = root })
            end,
        },
        {
            key = "f",
            label = "Filter topics",
            run = function()
                register_filter_transient()
                transient.open("list-filter", { root = root })
            end,
        },
    }

    local groups = {
        { title = "Inspect", actions = inspect },
        { title = "Act", actions = act },
    }

    -- The topic-scoped group — present only when the dispatch was opened over a topic (a topic/review `?`).
    if topic and topic.number then
        local topic_actions = {}
        if topic.is_pr and caps.pullreqs and topic.state == "open" then
            topic_actions[#topic_actions + 1] = {
                key = "m",
                label = ("Merge #%d"):format(topic.number),
                run = function()
                    require("lvim-forge.ui.topic").register_transients()
                    transient.open("merge", {
                        root = root,
                        selection = {
                            root = root,
                            number = topic.number,
                            mergeable = topic.pullreq and topic.pullreq.mergeable,
                            review_decision = topic.pullreq and topic.pullreq.review_decision,
                        },
                    })
                end,
            }
        end
        topic_actions[#topic_actions + 1] = {
            key = "e",
            label = ("Edit #%d (state / lock)"):format(topic.number),
            run = function()
                open_topic_edit(topic, caps)
            end,
        }
        if topic.is_pr and caps.reviews then
            topic_actions[#topic_actions + 1] = {
                key = "r",
                label = ("Review #%d"):format(topic.number),
                run = function()
                    require("lvim-forge.ui.review").open(root, topic.number)
                end,
            }
        end
        groups[#groups + 1] = { title = ("Topic #%d"):format(topic.number), actions = topic_actions }
    end

    transient.define({ id = "dispatch", title = "Forge dispatch", groups = groups })
end

--- Open the dispatch. `opts.root` targets a specific repo (threaded from a panel whose buffer can't be
--- detected); `opts.topic` seeds the topic-scoped verbs (merge / edit / review) when invoked over a topic
--- or review panel. Render-safe; caps-gates the actions per the current forge.
---@param opts? { root?: string|integer, topic?: table }
function M.open(opts)
    opts = opts or {}
    local root = opts.root
    register_dispatch(root, caps_for(root), opts.topic)
    transient.open("dispatch", { root = root, selection = opts.topic })
end

return M
