-- lvim-forge.ui.notifications: the NOTIFICATIONS INBOX — the forge's notification threads (review
-- requests, mentions, assignments, …) across EVERY tracked repository, rendered from the local SQLite
-- cache ONLY (instant + offline). Built on the `lvim-ui.tabs` menu surface (the lvim-git logpanel chassis
-- pattern), mirroring `ui/topics.lua` 1:1: a filter band (`unread ● all`
-- with LIVE per-button counts from DB predicates), per-repo GROUP sections (`ui.section` fold headers),
-- one selectable row per notification (unread dot + reason BADGE + `#n title` + dim rel-date), and a
-- `shown/total` counter.
--
-- Nothing here touches the network on a render path: rows, counts and grouping all read `db.lua`. Opening
-- kicks `sync.pull_notifications` (a cheap background pull of the context repo, gated on `pull.on_open`)
-- and the panel REFRESHES from the DB when `User LvimForgePullDone` / `LvimForgeTopicChanged` /
-- `LvimForgeNotificationsChanged` fire — the lvim-git `LvimGitRepoChanged` reactive pattern. `<CR>` marks
-- the notification read and opens its topic (`ui/topic.lua`); `r` toggles a row read/unread; `R` marks all
-- read; `P` pulls. The inbox is GATED on `caps.notifications` — a forge without a notifications API gets a
-- clean "not supported" notify instead of an empty panel.
--
-- Layouts area | float | bottom | tab (per-command token → `config.layouts.notifications` → `area`); `tab`
-- hosts the panel in the dedicated-tabpage workspace (`ui/workspace.lua`).
--
---@module "lvim-forge.ui.notifications"

local api = vim.api
local config = require("lvim-forge.config")
local commands = require("lvim-forge.commands")
local state = require("lvim-forge.state")
local db = require("lvim-forge.db")
local sync = require("lvim-forge.sync")
local client = require("lvim-forge.client")
local ui = require("lvim-ui")
local ui_filters = require("lvim-ui.filters")
local hl = require("lvim-utils.highlight")

local M = {}

--- The logical view id (layout resolution, the sticky filter, the open-panel registry, the workspace tab).
---@type string
local VIEW = "notifications"

--- How many unread notifications trigger a confirm on "mark all read" (when `confirm_destructive`).
---@type integer
local MANY = 3

-- ── glyphs (verified single-width Nerd Font, + the `➤` pointer canon) ──────────
local GLYPH = {
    bell = "\u{f0f3}", --  nf-fa-bell (title + repo band)
    arrow = "➤", -- band / row segment separator (the pointer canon)
    unread = "\u{f444}", --  nf-oct-dot_fill (the unread accent dot)
    fold_open = "\u{f0d7}", --  nf-fa-caret_down  (section expanded)
    fold_closed = "\u{f0da}", --  nf-fa-caret_right (section collapsed)
}

---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-forge: " .. msg, level or vim.log.levels.INFO)
end

---@param v any
---@return boolean
local function truthy(v)
    return v == 1 or v == true
end

-- ── time helpers (a UTC ISO-8601 timestamp → a short relative date) ────────────

--- Epoch seconds of a UTC ISO-8601 string (its fields are UTC; correct `os.time`'s local interpretation
--- by the machine's UTC offset). nil when unparseable.
---@param iso? string
---@return integer?
local function iso_epoch(iso)
    if type(iso) ~= "string" then
        return nil
    end
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
    local offset = os.time(os.date("!*t") --[[@as osdateparam]]) - os.time()
    return as_local - offset
end

--- A short relative date ("3h", "2d", "5mo", "1y") from a UTC ISO-8601 timestamp (the dim row meta).
---@param iso? string
---@return string
local function rel_date(iso)
    local t = iso_epoch(iso)
    if not t then
        return ""
    end
    local d = os.time() - t
    if d < 60 then
        return d .. "s"
    elseif d < 3600 then
        return math.floor(d / 60) .. "m"
    elseif d < 86400 then
        return math.floor(d / 3600) .. "h"
    elseif d < 86400 * 30 then
        return math.floor(d / 86400) .. "d"
    elseif d < 86400 * 365 then
        return math.floor(d / (86400 * 30)) .. "mo"
    end
    return math.floor(d / (86400 * 365)) .. "y"
end

-- ── the subject → topic mapping (parsed off the notification's API subject url) ──

--- The topic NUMBER a notification points at (parsed off the trailing number of `subject.url`,
--- e.g. `.../issues/123` / `.../pulls/123`). nil when the url is absent / unparseable.
---@param n table  a notifications row
---@return integer?
local function note_number(n)
    local url = n.url
    if type(url) ~= "string" then
        return nil
    end
    return tonumber(url:match("/(%d+)%s*$"))
end

--- The topic KIND (`pullreq`|`issue`) inferred from the notification's subject url (`/pulls/` → PR).
---@param n table  a notifications row
---@return "pullreq"|"issue"
local function note_kind(n)
    local url = n.url or ""
    if url:match("/pulls?/%d+") then
        return "pullreq"
    end
    return "issue"
end

--- The reason BADGE text (a Nerd glyph + a short label) for a notification reason, from
--- `config.notifications.reasons`; an unknown reason falls back to the generic bell + the raw reason.
---@param reason? string
---@return string
local function reason_badge(reason)
    local reasons = (config.notifications and config.notifications.reasons) or {}
    local r = reason and reasons[reason]
    local icon = (r and r.icon) or config.icons.notification or GLYPH.bell
    local label = (r and r.label) or reason or "notification"
    return icon .. " " .. label
end

-- ── the panel (one closure per open) ──────────────────────────────────────────

--- Open the notifications inbox. Spans EVERY tracked repository (grouped by repo); the current buffer's
--- repo (when tracked) is the context for the background pull + a same-repo topic open.
---@param opts? { layout?: string, root?: string|integer }
function M.open(opts)
    opts = opts or {}
    if not (config.notifications and config.notifications.enabled) then
        notify("the notifications component is disabled (config.notifications.enabled = false)")
        return
    end
    if not db.available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end

    -- Context = the current buffer's tracked repo (when any). The inbox still spans ALL tracked repos; the
    -- context only drives the on-open pull + a same-repo `<CR>` topic open (repos are not path-anchored, so
    -- a cross-repo topic cannot be opened from here — it is marked read + the user is pointed at its repo).
    local context_detected = client.detect(opts.root or 0)
    local context_repo = context_detected and db.repo_for_detect(context_detected)
    local context_root = context_detected and context_detected.root
    local context_repo_id = context_repo and context_repo.id

    -- Caps gate: a forge without a notifications API gets a clean notify (never an empty/misleading panel).
    -- Gate on the CONTEXT forge when known; with no forge context the aggregate cache is shown as-is (its
    -- rows only exist because some forge that supports notifications cached them).
    local forge = (context_repo and context_repo.forge) or (context_detected and context_detected.forge)
    if forge and not client.caps(forge).notifications then
        notify(("notifications are not supported on %s"):format(forge))
        return
    end

    -- Focus / re-target an already-open panel instead of stacking a second one.
    local open_rec = state.panels[VIEW]
    if open_rec and open_rec.handle and open_rec.handle.valid and open_rec.handle.valid() then
        open_rec.focus()
        return
    end

    -- Sticky per-session filter (state.lua), the layout-token precedent.
    local persisted = state.panel_state[VIEW] or {}
    local sel = { filter = persisted.filter or "unread" }
    local function persist()
        state.panel_state[VIEW] = { filter = sel.filter }
    end

    local layout = commands.layout_for(VIEW, opts.layout)
    local is_tab = layout == "tab"

    ---@class LvimForgeNotifState
    local st = {
        registry = {}, ---@type table<string, table>  row name → { id, repo_id, unread, number, kind }
        folds = {}, ---@type table<string, boolean>  captured expanded-state per repo section
        groups = nil, ---@type table[]?  the current filter-group specs
        shown = 0, ---@type integer  # notification rows currently rendered (the counter numerator)
        tabs = nil, ---@type table[]?
        handle = nil, ---@type table?
        augroup = nil, ---@type integer?
    }

    local function is_open()
        return st.handle ~= nil and st.handle.valid and st.handle.valid()
    end

    local rebuild -- forward decl (filter select + mutations call it)
    local open_notification -- forward decl (the row `run`)

    -- ── the DB query (renders from the cache only) ───────────────────────────
    --- The notification rows for a filter ("unread" | "all"). Newest-updated first, across every repo.
    ---@param filter string
    ---@return table[]
    local function query_rows(filter)
        local f = {}
        if filter == "unread" then
            f.unread = true
        end
        return db.notifications(f)
    end

    --- Total cached notifications (the counter denominator).
    ---@return integer
    local function total_count()
        return #db.notifications({})
    end

    -- ── the fold state (per repo section) ────────────────────────────────────
    ---@param name string
    ---@param default boolean
    ---@return boolean
    local function expanded_of(name, default)
        local v = st.folds[name]
        if v == nil then
            return default
        end
        return v
    end

    --- A collapsible repo section header (fold-header canon: only the accent is passed; tints are global).
    ---@param name string
    ---@param label string
    ---@param count integer
    ---@param children table[]
    ---@return table
    local function section(name, label, count, children)
        local exp = expanded_of(name, true)
        local sa = hl.section_accent("blue")
        return ui.section({
            name = name,
            icon = " " .. (exp and GLYPH.fold_open or GLYPH.fold_closed) .. " ",
            box_hl = sa.text,
            label = label,
            count = count,
            accent = "blue",
            expanded = exp,
            children = children,
        })
    end

    -- ── the filter band (unread ● all) ───────────────────────────────────────
    ---@return table[]
    local function filter_groups()
        return {
            {
                id = "filter",
                active = sel.filter,
                buttons = {
                    { id = "unread", label = "Unread" },
                    { id = "all", label = "All" },
                },
            },
        }
    end

    --- Apply the filter selection and re-render.
    ---@param id string
    local function select(id)
        if sel.filter == id then
            return
        end
        sel.filter = id
        persist()
        rebuild()
    end

    --- The filter band (one `type="bar"` header sector; `●` separators + live counts).
    ---@return table
    local function filter_bar()
        st.groups = filter_groups()
        local fb = ui_filters.bar(st.groups, {
            count = function(_, btn)
                return #query_rows(btn.id)
            end,
            on_select = function(_, id)
                select(id)
            end,
        })
        return { type = "bar", name = "filters", align = "center", items = fb.band.items }
    end

    -- ── one notification row ─────────────────────────────────────────────────
    --- Build a notification row: unread dot + reason BADGE + `#number` + title + dim rel-date, with
    --- per-segment `label_spans` (byte ranges → highlights). The registry entry carries everything the
    --- verbs need (id / repo_id / unread / number / kind).
    ---@param name string  a unique row name
    ---@param n table  a notifications row
    ---@return table
    local function note_row(name, n)
        local unread = truthy(n.unread)
        st.registry[name] = {
            id = n.id,
            repo_id = n.repo_id,
            unread = unread,
            number = note_number(n),
            kind = note_kind(n),
            title = n.title,
        }
        local spans = {}
        local label = ""
        local function seg(text, group)
            local start = #label
            label = label .. text
            if group then
                spans[#spans + 1] = { start, #label, group }
            end
        end
        -- unread dot (aligned: dot+space when unread, two spaces otherwise)
        if unread then
            seg(GLYPH.unread, "LvimForgeUnread")
            seg(" ")
        else
            seg("  ")
        end
        seg(" " .. reason_badge(n.reason) .. " ", "LvimForgeNotifReason")
        seg(" ")
        local num = note_number(n)
        if num then
            seg("#" .. tostring(num), "LvimForgeNumber")
            seg(" ")
        end
        seg(n.title or "(no title)", unread and "LvimForgeNotifTitle" or "LvimForgeNotifRead")
        local rel = rel_date(n.updated)
        if rel ~= "" then
            seg("  " .. GLYPH.arrow .. " ", "LvimForgeNotifDate")
            seg(rel, "LvimForgeNotifDate")
        end
        return {
            type = "action",
            name = name,
            flat = true,
            tight = true,
            icon = "",
            label = label,
            label_spans = spans,
            run = function()
                open_notification(st.registry[name])
            end,
        }
    end

    -- ── build the rows (filter band + per-repo group sections) ───────────────
    ---@return table[]
    local function build_rows()
        st.registry = {}
        local rows = { filter_bar() }
        local notes = query_rows(sel.filter)
        st.shown = #notes
        if #notes == 0 then
            rows[#rows + 1] = {
                type = "spacer",
                name = "empty",
                label = (sel.filter == "unread") and "  No unread notifications" or "  No notifications",
                hl = { inactive = "LvimForgeNotifDate" },
            }
            return rows
        end
        -- Group by repo, preserving the newest-first order (the first note seen for a repo fixes its rank).
        local repos = {}
        for _, r in ipairs(db.repositories()) do
            repos[r.id] = r
        end
        local order, groups = {}, {}
        for _, n in ipairs(notes) do
            local g = groups[n.repo_id]
            if not g then
                g = {}
                groups[n.repo_id] = g
                order[#order + 1] = n.repo_id
            end
            g[#g + 1] = n
        end
        local idx = 0
        for _, repo_id in ipairs(order) do
            local g = groups[repo_id]
            local r = repos[repo_id]
            local label = r and ("%s/%s"):format(r.owner, r.name) or ("repo #" .. tostring(repo_id))
            local children = {}
            for _, n in ipairs(g) do
                idx = idx + 1
                children[#children + 1] = note_row("n" .. idx, n)
            end
            rows[#rows + 1] = section("repo:" .. tostring(repo_id), label, #g, children)
        end
        return rows
    end

    -- ── rebuild / refresh ────────────────────────────────────────────────────
    function rebuild()
        if not is_open() then
            return
        end
        -- Capture the live fold state so a manual <CR> fold survives the data refresh.
        for _, row in pairs(st.tabs[1].rows) do
            if type(row) == "table" and row.name and row.name:match("^repo:") then
                st.folds[row.name] = row.expanded == true
            end
        end
        st.tabs[1].rows = build_rows()
        local at = st.handle.cursor_index()
        st.handle.recalc()
        st.handle.focus_index(at)
    end

    -- ── the cursor notification ──────────────────────────────────────────────
    ---@return table?
    local function cur_notification()
        local name = st.handle and st.handle.cursor_name and st.handle.cursor_name()
        return name and st.registry[name] or nil
    end

    -- ── fire the reactive event (badge consumers + this panel refresh) ───────
    local function fire_changed()
        pcall(api.nvim_exec_autocmds, "User", {
            pattern = "LvimForgeNotificationsChanged",
            data = { unread = db.notifications_unread() },
        })
    end

    -- ── verbs ────────────────────────────────────────────────────────────────
    --- `<CR>` — mark the notification read and open its topic. Same-repo topics drill in (the list is a
    --- focus-trapping modal, so close first then open — the topics `_open_topic` model); a cross-repo topic
    --- cannot be opened from here (repos are not path-anchored) → it is marked read + the user is pointed at
    --- its repo.
    ---@param rec? table  a registry entry
    function open_notification(rec)
        if not rec then
            return
        end
        if rec.unread then
            db.set_notification_unread(rec.id, false)
            fire_changed()
        end
        local number = rec.number
        if not number then
            notify("this notification has no linked topic")
            rebuild()
            return
        end
        if context_repo_id and rec.repo_id == context_repo_id and context_root then
            M.close()
            vim.schedule(function()
                require("lvim-forge.ui.topic").open(context_root, number, { kind = rec.kind })
            end)
            return
        end
        local r = db.repository(rec.repo_id)
        notify(
            ("#%d is in %s — open that repository to view the topic"):format(
                number,
                r and ("%s/%s"):format(r.owner, r.name) or "another tracked repo"
            )
        )
        rebuild()
    end

    --- `r` — toggle the cursor notification's read/unread state.
    local function do_toggle()
        local rec = cur_notification()
        if not rec then
            notify("place the cursor on a notification")
            return
        end
        local want_unread = not rec.unread
        db.set_notification_unread(rec.id, want_unread)
        fire_changed()
        rebuild()
    end

    --- `R` — mark ALL notifications read (across every tracked repo). Confirms when destructive + many.
    local function do_mark_all()
        local count = db.notifications_unread()
        if count == 0 then
            notify("no unread notifications")
            return
        end
        local function apply()
            db.mark_all_notifications_read()
            fire_changed()
            rebuild()
            notify(("marked %d notification%s read"):format(count, count == 1 and "" or "s"))
        end
        if config.confirm_destructive and count >= MANY then
            ui.confirm({
                title = " Mark all read",
                prompt = ("Mark all %d unread notifications read?"):format(count),
                callback = function(yes)
                    if yes then
                        apply()
                    end
                end,
            })
        else
            apply()
        end
    end

    --- `P` — pull notifications for the context repo (cheap endpoint + cursor). Requires a tracked repo in
    --- context; the panel refreshes from `LvimForgeNotificationsChanged`.
    local function do_pull()
        if not (context_repo and context_root) then
            notify("open the inbox inside a tracked repository to pull its notifications", vim.log.levels.WARN)
            return
        end
        if not client.caps(context_repo.forge).notifications then
            notify(("notifications are not supported on %s"):format(context_repo.forge))
            return
        end
        notify("pulling notifications…")
        sync.pull_notifications(context_root, {}, function(cnt, err)
            if err then
                notify("notifications pull failed: " .. ((err.message or err.kind) or "?"), vim.log.levels.WARN)
            else
                notify(("pulled %d notification%s"):format(cnt or 0, (cnt == 1) and "" or "s"))
            end
        end)
    end

    -- ── the help window (canonical cheatsheet) ───────────────────────────────
    local function show_help()
        ui.help({
            title = "Forge notifications keymaps",
            items = {
                { "j / k", "next / previous notification" },
                { "<CR>", "open the topic (marks it read; or fire the focused filter button)" },
                { "r", "toggle read / unread" },
                { "R", "mark all read" },
                { "P", "pull notifications" },
                { "?", "dispatch (all commands)" },
                { "g?", "this help" },
                { "q / <Esc>", "close" },
            },
            close_keys = { "q", "<Esc>" },
        })
    end

    --- `?` — open the dispatch (the discoverable menu of every command). The inbox spans repos, so no
    --- single root is seeded — the dispatch detects the current buffer's repo for its caps-gated actions.
    local function open_dispatch()
        require("lvim-forge.ui.dispatch").open()
    end

    -- ── keymaps ──────────────────────────────────────────────────────────────
    -- NOTE: the filter band claims NO keys. A filter is switched by moving onto its button and pressing <CR>
    -- (or clicking it) — as in every other lvim-tech panel. Bare letters stay free for the panel's actions.
    local function build_keymaps()
        return {
            { key = "r", run = do_toggle },
            { key = "R", run = do_mark_all },
            { key = "P", run = do_pull },
            { key = "?", run = open_dispatch },
            { key = "g?", run = show_help },
        }
    end

    -- ── the subtitle repo band ───────────────────────────────────────────────
    ---@return table[]
    local function subtitle()
        local unread = db.notifications_unread()
        local scope = context_repo and ("%s/%s"):format(context_repo.owner, context_repo.name)
            or "all tracked repositories"
        -- Info-band canon: scope green · unread count orange (the unread accent).
        local text, hls = hl.band_line({
            { text = GLYPH.bell .. " " .. scope, accent = "green" },
            { text = ("%d unread"):format(unread), accent = "orange" },
        }, " " .. GLYPH.arrow .. " ")
        return { { text = text, hls = hls } }
    end

    -- ── autocmds (refresh from the DB on the sync events — the inbox spans repos) ──
    local function setup_autocmds()
        if st.augroup then
            pcall(api.nvim_del_augroup_by_id, st.augroup)
        end
        st.augroup = api.nvim_create_augroup("lvim-forge.notifications", { clear = true })
        api.nvim_create_autocmd("User", {
            group = st.augroup,
            pattern = { "LvimForgePullDone", "LvimForgeTopicChanged", "LvimForgeNotificationsChanged" },
            callback = function()
                rebuild()
            end,
        })
    end

    -- ── teardown / open ──────────────────────────────────────────────────────
    local function teardown()
        if st.augroup then
            pcall(api.nvim_del_augroup_by_id, st.augroup)
            st.augroup = nil
        end
        st.handle = nil
        st.tabs = nil
    end

    st.tabs = {
        { label = "Notifications", icon = GLYPH.bell, menu = true, rows = build_rows() },
    }

    -- A `tab` layout enters the dedicated workspace tabpage first (so the surface opens inside it).
    if is_tab then
        require("lvim-forge.ui.workspace").enter(VIEW)
    end

    st.handle = ui.tabs({
        title = { icon = GLYPH.bell, text = "Forge notifications" },
        title_pos = "center",
        subtitle = subtitle,
        tabs = st.tabs,
        layout = is_tab and "float" or layout,
        slot = is_tab and require("lvim-forge.ui.workspace").slot() or nil,
        pad = 0,
        -- The NEUTRAL bg-only cursorline (as every rich lvim-tech panel uses): a notification row carries its
        -- own per-segment colours (repo, reason badge, title, dim date), and the peek variant's yellow fg would
        -- repaint the whole focused row one flat colour.
        cursorline_hl = "LvimUiCursorLine",
        title_count = function()
            return { current = st.shown, total = total_count() }
        end,
        counter = "footer",
        keymaps = build_keymaps(),
        on_open = function()
            setup_autocmds()
        end,
        callback = function()
            teardown()
            state.panels[VIEW] = nil
            if is_tab then
                require("lvim-forge.ui.workspace").exit(VIEW)
            end
        end,
    })

    if not st.handle then
        if is_tab then
            require("lvim-forge.ui.workspace").exit(VIEW)
        end
        return
    end

    -- The background pull (renders the cache NOW; refreshes on LvimForgeNotificationsChanged). Gated on
    -- `pull.on_open` + the context forge's notifications cap — a cheap cursor-based endpoint.
    if
        config.pull
        and config.pull.on_open
        and context_repo
        and context_root
        and client.caps(context_repo.forge).notifications
    then
        sync.pull_notifications(context_root)
    end

    state.panels[VIEW] = {
        handle = st.handle,
        focus = function()
            if is_tab then
                require("lvim-forge.ui.workspace").focus(VIEW)
            elseif st.handle and st.handle.win then
                local w = st.handle.win()
                if w and api.nvim_win_is_valid(w) then
                    api.nvim_set_current_win(w)
                end
            end
        end,
        close = function()
            if is_open() then
                st.handle.close()
            end
        end,
    }
end

--- Whether the notifications inbox is open.
---@return boolean
function M.is_open()
    local rec = state.panels[VIEW]
    return rec ~= nil and rec.handle ~= nil and rec.handle.valid and rec.handle.valid()
end

--- Close the notifications inbox (no-op when closed).
function M.close()
    local rec = state.panels[VIEW]
    if rec and rec.close then
        rec.close()
    end
end

--- Toggle the notifications inbox.
---@param opts? table
function M.toggle(opts)
    if M.is_open() then
        M.close()
    else
        M.open(opts)
    end
end

--- PUBLIC: the unread-notification count — the badge source for other UI (the topics/dispatch title, a
--- statusline). All tracked repos, or one repo when `repo_id` is given. Render-safe DB read.
---@param repo_id? integer
---@return integer
function M.unread(repo_id)
    if not db.available() then
        return 0
    end
    return db.notifications_unread(repo_id)
end

return M
