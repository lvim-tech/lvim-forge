-- lvim-forge.ui.topics: the TOPIC LIST panel — issues + pull requests for the current tracked repo,
-- rendered from the local SQLite cache ONLY (instant + offline). Built on the `lvim-ui.tabs` menu surface
-- (the lvim-git logpanel chassis pattern): one selectable row per topic
-- (state icon + `#number` + title + label CHIPS + dim `author · rel-date` + an unread dot), a filter band
-- of three groups (kind ● state ● involvement) with LIVE per-button counts from DB predicates, a `/` query
-- with structured terms, and a `shown/total` counter.
--
-- Nothing here touches the network on a render path: rows, counts and the query all read `db.lua`. Opening
-- kicks `sync.maybe_pull` (a background staleness pull) and the panel REFRESHES from the DB when
-- `User LvimForgePullDone` / `LvimForgeTopicChanged` fire for this repo — the lvim-git `LvimGitRepoChanged`
-- reactive pattern. `<CR>` opens a topic through `open_topic`, the single seam the Phase-5 topic buffer
-- replaces; `a`/`n`/`N`/`?` route to named "not built yet" stubs until their phases land.
--
-- Layouts area | float | bottom | tab (per-command token → `config.layouts.topics` → default); `tab` hosts
-- the panel in the dedicated-tabpage workspace (`ui/workspace.lua`) sized to fill the tab via `slot()`.
--
---@module "lvim-forge.ui.topics"

local api = vim.api
local config = require("lvim-forge.config")
local commands = require("lvim-forge.commands")
local state = require("lvim-forge.state")
local db = require("lvim-forge.db")
local sync = require("lvim-forge.sync")
local highlights = require("lvim-forge.highlights")
local hl = require("lvim-utils.highlight")
local detect = require("lvim-forge.client.detect")
local workspace = require("lvim-forge.ui.workspace")
local ui = require("lvim-ui")
local ui_filters = require("lvim-ui.filters")

local M = {}

--- The logical view id (layout resolution, the sticky filter, the open-panel registry, the workspace tab).
---@type string
local VIEW = "topics"

-- ── glyphs (verified single-width Nerd Font, + the `➤` pointer canon) ──────────
local GLYPH = {
    repo = "\u{ea62}", --  nf-cod-repo (title + repo band)
    arrow = "➤", -- band segment separator (the pointer canon)
    unread = "\u{f444}", --  nf-oct-dot_fill (the unread accent dot)
}

---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-forge: " .. msg, level or vim.log.levels.INFO)
end

-- ── time helpers ─────────────────────────────────────────────────────────────

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

-- ── the state icon (open/closed/merged/draft, per kind) ───────────────────────

--- The state glyph + its highlight for a topic row. PRs distinguish merged / closed / draft / open;
--- issues distinguish closed / open. `draft` rides on the row from the `pullreqs` LEFT JOIN in `db.topics`.
---@param t table  a topics row (kind/state/draft)
---@return string icon, string hl
local function state_icon(t)
    local icons = config.icons
    if t.kind == "pullreq" then
        if t.state == "merged" then
            return icons.merged, "LvimForgeMerged"
        elseif t.state == "closed" then
            return icons.closed, "LvimForgeClosed"
        elseif t.draft == 1 or t.draft == true then
            return icons.draft, "LvimForgeDraft"
        end
        return icons.pull, "LvimForgeOpen"
    end
    if t.state == "closed" then
        return icons.closed, "LvimForgeClosed"
    end
    return icons.issue, "LvimForgeOpen"
end

-- ── the structured query model (shared by the `/` input, the panel `set_filter`, and the list-filter
--    transient — the SAME model `query_rows` consumes, so nothing duplicates the filter logic) ──

--- Parse a query string into structured terms: `label:` `author:` `milestone:` `mark:` `#n`, and the
--- remaining bare words as a free-text LIKE. `milestone:` resolves its title to a local id against the
--- given repo (`-1` = no such milestone → no matches). Returns nil for an empty query (clears the filter).
---@param repo_id integer
---@param text? string
---@return table?
local function parse_query(repo_id, text)
    text = vim.trim(text or "")
    if text == "" then
        return nil
    end
    local q = { raw = text, terms = {} }
    for tok in text:gmatch("%S+") do
        local num = tok:match("^#(%d+)$")
        local k, v = tok:match("^(%w+):(.+)$")
        if num then
            q.number = tonumber(num)
        elseif k == "label" then
            q.label = v
        elseif k == "author" then
            q.author = v
        elseif k == "mark" then
            q.mark = v
        elseif k == "milestone" then
            q.milestone = v
        else
            q.terms[#q.terms + 1] = tok
        end
    end
    q.search = table.concat(q.terms, " ")
    if q.milestone then
        q.milestone_id = -1
        for _, ms in ipairs(db.milestones(repo_id)) do
            if ms.title == q.milestone then
                q.milestone_id = ms.id
                break
            end
        end
    end
    return q
end

-- ── the panel (one closure per open) ──────────────────────────────────────────

--- Open the topic list for the current tracked repo.
---@param opts? { layout?: string, kind?: "all"|"issues"|"pulls", root?: string|integer }
function M.open(opts)
    opts = opts or {}
    if not db.available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end

    local client = require("lvim-forge.client")
    local detected = client.detect(opts.root or 0)
    if not detected then
        notify("not inside a recognized forge repository", vim.log.levels.WARN)
        return
    end
    local repo_row = db.repo_for_detect(detected)
    if not repo_row then
        notify(
            ("%s/%s is not tracked — `:LvimForge add` to track it"):format(
                detected.owner or "?",
                detected.name or "?"
            ),
            vim.log.levels.WARN
        )
        return
    end

    local repo_id = repo_row.id
    local repo_host = repo_row.host
    local root = detected.root
    ---@type table  the github ctx for a lazy viewer probe (involvement filters)
    local ctx = {
        owner = repo_row.owner,
        name = repo_row.name,
        forge = repo_row.forge,
        host = repo_row.host,
        base = detect.api_base(repo_row.forge, repo_row.host),
        root = root,
    }

    -- Focus / re-target an already-open panel instead of stacking a second one.
    local open_rec = state.panels[VIEW]
    if open_rec and open_rec.handle and open_rec.handle.valid and open_rec.handle.valid() then
        if open_rec.repo_id == repo_id then
            if opts.kind then
                open_rec.set_kind(opts.kind)
            end
            open_rec.focus()
            return
        end
        open_rec.close()
    end

    -- Sticky per-session filter (state.lua), the layout-token precedent. `opts.kind` overrides the kind.
    local persisted = state.panel_state[VIEW] or {}
    local sel = {
        kind = opts.kind or persisted.kind or "all",
        state = persisted.state or "open",
        involvement = persisted.involvement or "all",
        query = persisted.query, ---@type table?  a parsed query (label/author/milestone_id/mark/number/search/raw)
    }
    local function persist()
        state.panel_state[VIEW] = {
            kind = sel.kind,
            state = sel.state,
            involvement = sel.involvement,
            query = sel.query,
        }
    end

    local layout = commands.layout_for(VIEW, opts.layout)
    local is_tab = layout == "tab"

    ---@class LvimForgeTopicsState
    local st = {
        registry = {}, ---@type table<string, table>  row name → topic
        groups = nil, ---@type table[]?  the current filter-group specs (for on_select gi → dim)
        shown = 0, ---@type integer  # topic rows currently rendered (the counter's numerator)
        tabs = nil, ---@type table[]?
        handle = nil, ---@type table?
        augroup = nil, ---@type integer?
    }

    local function is_open()
        return st.handle ~= nil and st.handle.valid and st.handle.valid()
    end

    -- ── the DB query (renders from the cache only) ───────────────────────────
    --- The topic rows for a filter selection: kind/state/involvement + the parsed query terms, composed
    --- into a `db.topics` filter (+ a `#n` post-filter). Involvement needs the viewer login; unknown → no
    --- rows (it populates once the lazy probe resolves).
    ---@param s table  a `{ kind, state, involvement, query }` selection
    ---@return table[]
    local function query_rows(s)
        local f = {}
        if s.kind == "issues" then
            f.kind = "issue"
        elseif s.kind == "pulls" then
            f.kind = "pullreq"
        end
        if s.state and s.state ~= "all" then
            f.state = s.state
        end
        if s.involvement and s.involvement ~= "all" then
            local login = repo_host and state.viewer[repo_host]
            if not login then
                return {}
            end
            if s.involvement == "mine" then
                f.author = login
            elseif s.involvement == "assigned" then
                f.assignee = login
            elseif s.involvement == "review-requested" then
                f.reviewer = login
            end
        end
        local number
        local q = s.query
        if q then
            if q.label then
                f.label = q.label
            end
            if q.author then
                f.author = q.author
            end
            if q.mark then
                f.mark = q.mark
            end
            if q.milestone_id then
                f.milestone_id = q.milestone_id
            end
            if q.search and q.search ~= "" then
                f.search = q.search
            end
            number = q.number
        end
        local rows = db.topics(repo_id, f)
        if number then
            local out = {}
            for _, r in ipairs(rows) do
                if r.number == number then
                    out[#out + 1] = r
                end
            end
            return out
        end
        return rows
    end

    --- Total topics in the repo (the counter denominator).
    ---@return integer
    local function total_count()
        return #db.topics(repo_id, {})
    end

    -- ── the filter groups (kind ● state ● involvement) ───────────────────────
    --- The three filter-group specs, `active` read from the live `sel`. `group.id` matches the `sel` key.
    ---@return table[]
    local function filter_groups()
        return {
            {
                id = "kind",
                active = sel.kind,
                buttons = {
                    { id = "all", label = "All" },
                    { id = "issues", label = "Issues" },
                    { id = "pulls", label = "Pulls" },
                },
            },
            {
                id = "state",
                active = sel.state,
                buttons = {
                    { id = "all", label = "All" },
                    { id = "open", label = "Open" },
                    { id = "closed", label = "Closed" },
                },
            },
            {
                id = "involvement",
                active = sel.involvement,
                buttons = {
                    { id = "all", label = "All" },
                    { id = "mine", label = "Mine" },
                    { id = "assigned", label = "Assigned" },
                    { id = "review-requested", label = "Review" },
                },
            },
        }
    end

    local rebuild -- forward decl (the filter select + the query input call it)

    --- Resolve the authenticated viewer login (once, cached in state) then run `after`. A background,
    --- best-effort, forge-blind probe (the backend is resolved via the dispatch seam) — the ONE network
    --- touch the involvement filters need; unresolved (offline / a backend-less forge) leaves those
    --- buttons empty.
    ---@param after fun()
    local function ensure_viewer_then(after)
        if repo_host and state.viewer[repo_host] then
            return after()
        end
        local backend = require("lvim-forge.client").backend(repo_row.forge)
        if not backend or type(backend.viewer) ~= "function" then
            return after()
        end
        backend.viewer(ctx, function(login)
            if login and repo_host then
                state.viewer[repo_host] = login
            end
            vim.schedule(after)
        end)
    end

    --- Apply a filter selection in a group and re-render (resolving the viewer first for involvement).
    ---@param dim string  the group id ("kind"|"state"|"involvement")
    ---@param id string   the chosen button id
    local function select(dim, id)
        if sel[dim] == id then
            return
        end
        sel[dim] = id
        persist()
        if dim == "involvement" and id ~= "all" and not (repo_host and state.viewer[repo_host]) then
            ensure_viewer_then(rebuild)
        else
            rebuild()
        end
    end

    --- The filter band (one `type="bar"` header sector; three groups with `●` separators + live counts).
    ---@return table
    local function filter_bar()
        st.groups = filter_groups()
        local fb = ui_filters.bar(st.groups, {
            count = function(group, btn)
                local variant = {
                    kind = sel.kind,
                    state = sel.state,
                    involvement = sel.involvement,
                    query = sel.query,
                }
                variant[group.id] = btn.id
                return #query_rows(variant)
            end,
            on_select = function(gi, id)
                local group = st.groups[gi]
                if group then
                    select(group.id, id)
                end
            end,
        })
        return { type = "bar", name = "filters", align = "center", items = fb.band.items }
    end

    -- ── the topic rows ───────────────────────────────────────────────────────
    --- Build one topic row: unread dot + state icon + `#number` + title + label chips + dim author/date,
    --- all in the label with per-segment `label_spans` (byte ranges → highlights).
    ---@param i integer
    ---@param t table  a topics row
    ---@param labels table[]  the topic's label rows (name + color)
    ---@return table
    local function topic_row(i, t, labels)
        local name = "t" .. i
        st.registry[name] = t
        local spans = {}
        local label = ""
        local function seg(text, hl)
            local start = #label
            label = label .. text
            if hl then
                spans[#spans + 1] = { start, #label, hl }
            end
        end
        -- unread dot (aligned: dot+space when unread, two spaces otherwise)
        if t.unread == 1 or t.unread == true then
            seg(GLYPH.unread, "LvimForgeUnread")
            seg(" ")
        else
            seg("  ")
        end
        local icon, ihl = state_icon(t)
        seg(icon, ihl)
        seg(" ")
        seg("#" .. tostring(t.number), "LvimForgeNumber")
        seg(" ")
        seg(t.title or "", "LvimForgeTitle")
        for _, l in ipairs(labels) do
            seg(" ")
            seg(" " .. (l.name or "") .. " ", highlights.label_hl(l.color))
        end
        local rel = rel_date(t.updated)
        seg("  ")
        seg(t.author or "", "LvimForgeAuthor")
        if rel ~= "" then
            seg(" " .. GLYPH.arrow .. " ", "LvimForgeDate")
            seg(rel, "LvimForgeDate")
        end
        return {
            type = "action",
            name = name,
            flat = true,
            tight = true,
            icon = "",
            label = label,
            label_spans = spans,
            _item = { topic = t },
            run = function()
                M._open_topic(t.number, t.kind)
            end,
        }
    end

    ---@return table[]
    local function build_rows()
        st.registry = {}
        local rows = { filter_bar() }
        local topics = query_rows(sel)
        local limit = (config.topics and config.topics.limit) or 500
        local labels_map = db.topic_labels_by_repo(repo_id)
        st.shown = math.min(#topics, limit)
        if #topics == 0 then
            rows[#rows + 1] = {
                type = "spacer",
                name = "empty",
                label = "  No topics match this filter",
                hl = { inactive = "LvimForgeDate" },
            }
            return rows
        end
        for i = 1, st.shown do
            local t = topics[i]
            rows[#rows + 1] = topic_row(i, t, labels_map[t.id] or {})
        end
        if #topics > limit then
            rows[#rows + 1] = {
                type = "spacer",
                name = "truncated",
                label = ("  … %d more (raise topics.limit)"):format(#topics - limit),
                hl = { inactive = "LvimForgeDate" },
            }
        end
        return rows
    end

    -- ── rebuild / refresh ────────────────────────────────────────────────────
    function rebuild()
        if not is_open() then
            return
        end
        st.tabs[1].rows = build_rows()
        local idx = st.handle.cursor_index()
        st.handle.recalc()
        st.handle.focus_index(idx)
    end

    -- ── the query input (`/`) ────────────────────────────────────────────────
    local function prompt_query()
        ui.input({
            title = { icon = GLYPH.repo, text = "Filter topics" },
            subtitle = "label:x author:y milestone:z mark:w #123 + free text",
            default = sel.query and sel.query.raw or "",
            callback = function(confirmed, value)
                if not confirmed then
                    return
                end
                sel.query = parse_query(repo_id, value)
                persist()
                rebuild()
            end,
        })
    end

    -- ── the cursor topic ─────────────────────────────────────────────────────
    local function cur_topic()
        local name = st.handle and st.handle.cursor_name and st.handle.cursor_name()
        return name and st.registry[name] or nil
    end

    -- ── the help window (canonical cheatsheet) ───────────────────────────────
    local function show_help()
        ui.help({
            title = "Forge topics keymaps",
            items = {
                { "j / k", "next / previous topic" },
                { "<CR>", "open the topic (or fire the focused filter button)" },
                { "/", "search (label: author: milestone: mark: #n + text)" },
                { "P", "pull (sync with the forge)" },
                { "a", "topic actions" },
                { "n", "create a topic" },
                { "N", "notifications" },
                { "?", "dispatch (all commands)" },
                { "g?", "this help" },
                { "q / <Esc>", "close" },
            },
            close_keys = { "q", "<Esc>" },
        })
    end

    -- ── stubs for the seams later phases fill (each a clean notify) ───────────
    local function stub_actions()
        local t = cur_topic()
        notify(("topic actions%s land in a later phase"):format(t and (" for #" .. t.number) or ""))
    end
    --- `n` — create a topic: a tiny canonical picker for issue OR pull request, routing to the composer
    --- (PR mode seeds the base/head pickers + the commit-derived prefill).
    local function do_create()
        ui.select({
            title = "Create",
            items = {
                { label = "Issue", icon = config.icons.issue, mode = "issue" },
                { label = "Pull request", icon = config.icons.pull, mode = "pr" },
            },
            callback = function(confirmed, idx)
                if not confirmed or not idx then
                    return
                end
                local mode = (idx == 2) and "pr" or "issue"
                require("lvim-forge.ui.composer").open({
                    mode = mode,
                    root = root,
                    repo_id = repo_id,
                    repo_label = ("%s/%s"):format(repo_row.owner, repo_row.name),
                })
            end,
        })
    end
    --- `N` — open the notifications inbox (spans every tracked repo; opens on its own layout).
    local function open_notifications()
        require("lvim-forge.ui.notifications").open()
    end
    --- `?` — open the dispatch (the discoverable menu of every command), scoped to this repo.
    local function open_dispatch()
        require("lvim-forge.ui.dispatch").open({ root = root })
    end

    -- ── pull (`P`) ───────────────────────────────────────────────────────────
    local function do_pull()
        notify("pull started…")
        sync.pull(root, {}, function(ok, err)
            if ok then
                notify("pull complete")
            else
                notify("pull failed: " .. ((err and (err.message or err.kind)) or "?"), vim.log.levels.WARN)
            end
        end)
    end

    -- ── keymaps ──────────────────────────────────────────────────────────────
    -- NOTE: the filter band claims NO keys. A filter is switched by moving onto its button and pressing <CR>
    -- (or clicking it) — as in every other lvim-tech panel (lvim-git binds no filter keys either). Bare
    -- letters stay free for the panel's own actions.
    local function build_keymaps()
        return {
            { key = "/", run = prompt_query },
            { key = "P", run = do_pull },
            { key = "a", run = stub_actions },
            { key = "n", run = do_create },
            { key = "N", run = open_notifications },
            { key = "?", run = open_dispatch },
            { key = "g?", run = show_help },
        }
    end

    -- ── the subtitle repo band ───────────────────────────────────────────────
    ---@return table[]
    local function subtitle()
        local r = db.repository(repo_id) or repo_row
        -- Per-part palette (the info-band canon): repo green · host teal · tracked branch cyan · pulled date
        -- purple · unread badge orange — distinct hues via inline `hls`, never one flat colour.
        ---@type { text: string, accent?: string }[]
        local parts = {
            { text = GLYPH.repo .. " " .. ("%s/%s"):format(r.owner, r.name), accent = "green" },
            { text = r.host, accent = "teal" },
            { text = r.tracked, accent = "cyan" },
        }
        local pulled = rel_date(r.pulled_at)
        if pulled ~= "" then
            parts[#parts + 1] = { text = "pulled " .. pulled, accent = "purple" }
        end
        -- The unread-notifications badge (the topics-title surface for the Phase-11 badge reader) — shown
        -- only when this repo has unread notifications; reactive via LvimForgePullDone (notifications
        -- piggyback the pull) + LvimForgeTopicChanged refreshes.
        local unread = db.notifications_unread(repo_id)
        if unread > 0 then
            parts[#parts + 1] = { text = ("%s %d"):format(config.icons.notification, unread), accent = "orange" }
        end
        local text, hls = hl.band_line(parts, " " .. GLYPH.arrow .. " ")
        return { { text = text, hls = hls } }
    end

    -- ── autocmds (refresh from the DB on the sync events, for THIS repo) ──────
    local function setup_autocmds()
        if st.augroup then
            pcall(api.nvim_del_augroup_by_id, st.augroup)
        end
        st.augroup = api.nvim_create_augroup("lvim-forge.topics", { clear = true })
        local mine = { [("%s/%s"):format(repo_row.owner, repo_row.name)] = true }
        if type(root) == "string" and root ~= "" then
            mine[root] = true
        end
        api.nvim_create_autocmd("User", {
            group = st.augroup,
            pattern = { "LvimForgePullDone", "LvimForgeTopicChanged" },
            callback = function(ev)
                local d = ev.data
                if not d or not d.root or mine[d.root] then
                    rebuild()
                end
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
        { label = "Topics", icon = GLYPH.repo, menu = true, rows = build_rows() },
    }

    -- The row of `opts.focus_number`, if that topic is in the (filtered) list. Drilling into a topic CLOSES
    -- this list and its `q` reopens it, so without this the cursor would land back on the first row every
    -- time — the list is rebuilt, not restored. Resolved by NUMBER (not by the row index/name, which shifts
    -- with the filter and with any topic pulled in meanwhile). `build_rows()` above filled the registry.
    ---@param n? integer
    ---@return string?
    local function row_for_number(n)
        if not n then
            return nil
        end
        for name, t in pairs(st.registry) do
            if type(t) == "table" and t.number == n then
                return name
            end
        end
        return nil
    end

    -- A `tab` layout enters the dedicated workspace tabpage first (so the surface opens inside it).
    if is_tab then
        workspace.enter(VIEW)
    end

    st.handle = ui.tabs({
        title = { icon = GLYPH.repo, text = "Forge topics" },
        title_pos = "center",
        subtitle = subtitle,
        tabs = st.tabs,
        layout = is_tab and "float" or layout,
        slot = is_tab and workspace.slot() or nil,
        pad = 0,
        initial_row = row_for_number(opts.focus_number),
        -- The NEUTRAL bg-only cursorline (as every rich lvim-tech panel uses): a topic row carries its own
        -- per-segment colours (`#number` green, title yellow, label chips, author/date), and the peek variant's
        -- yellow fg would repaint the whole focused row one flat colour.
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
                workspace.exit(VIEW)
            end
        end,
    })

    if not st.handle then
        if is_tab then
            workspace.exit(VIEW)
        end
        return
    end

    -- The background staleness pull (renders the cache NOW; refreshes on LvimForgePullDone).
    sync.maybe_pull(root)

    state.panels[VIEW] = {
        repo_id = repo_id,
        root = root, -- threaded to the Phase-5 topic buffer (the panel buffer can't be detected in a tab)
        handle = st.handle,
        set_kind = function(k)
            sel.kind = k
            persist()
            rebuild()
        end,
        -- Re-target the LIVE panel's filter (the list-filter transient's apply path). `f` = a partial
        -- `{ kind?, state?, involvement?, query? }`; `query` is a RAW string (parsed here against this
        -- repo) or "" to clear. An involvement change resolves the viewer first (like `select`).
        set_filter = function(f)
            f = f or {}
            if f.kind ~= nil then
                sel.kind = f.kind
            end
            if f.state ~= nil then
                sel.state = f.state
            end
            if f.involvement ~= nil then
                sel.involvement = f.involvement
            end
            if f.query ~= nil then
                sel.query = (f.query ~= "") and parse_query(repo_id, f.query) or nil
            end
            persist()
            if sel.involvement ~= "all" and not (repo_host and state.viewer[repo_host]) then
                ensure_viewer_then(rebuild)
            else
                rebuild()
            end
        end,
        focus = function()
            if is_tab then
                workspace.focus(VIEW)
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

--- Whether the topic list is open.
---@return boolean
function M.is_open()
    local rec = state.panels[VIEW]
    return rec ~= nil and rec.handle ~= nil and rec.handle.valid and rec.handle.valid()
end

--- Close the topic list (no-op when closed).
function M.close()
    local rec = state.panels[VIEW]
    if rec and rec.close then
        rec.close()
    end
end

--- Toggle the topic list.
---@param opts? table
function M.toggle(opts)
    if M.is_open() then
        M.close()
    else
        M.open(opts)
    end
end

--- Apply a structured filter to the topic list — the list-filter transient's action target. `filter` is a
--- partial `{ kind?, state?, involvement?, query? }` (`query` = a RAW query string, or "" to clear). When
--- the list is already open for the current repo it re-targets that live panel; otherwise it seeds the
--- session-sticky filter (`state.panel_state.topics`) and opens the list with it. So the transient is a
--- thin front-end over the SAME filter model the `/` input and the band drive — no duplicated query logic.
---@param filter? { kind?: string, state?: string, involvement?: string, query?: string }
function M.apply_filter(filter)
    filter = filter or {}
    local rec = state.panels[VIEW]
    if rec and rec.handle and rec.handle.valid and rec.handle.valid() and rec.set_filter then
        rec.set_filter(filter)
        rec.focus()
        return
    end
    -- Not open: seed the sticky filter (parsing the query against the detected repo), then open the list.
    local detected = detect.detect(0)
    local repo_row = detected and db.repo_for_detect(detected)
    if repo_row then
        local prev = state.panel_state[VIEW] or {}
        local query = prev.query
        if filter.query ~= nil then
            query = (filter.query ~= "") and parse_query(repo_row.id, filter.query) or nil
        end
        state.panel_state[VIEW] = {
            kind = filter.kind or prev.kind or "all",
            state = filter.state or prev.state or "open",
            involvement = filter.involvement or prev.involvement or "all",
            query = query,
        }
    end
    M.open({ kind = filter.kind })
end

--- The `<CR>` SEAM: open a topic's read-only buffer (`ui/topic.lua`, Phase 5). Deliberately a single
--- named entry so the list's `<CR>` binding never changes. The list's repo `root` is threaded through the
--- panel record (the tab-hosted panel buffer can't be detected) so the topic buffer targets the right repo.
---@param number integer
---@param kind? string
function M._open_topic(number, kind)
    local rec = state.panels[VIEW]
    local root = rec and rec.root
    -- Drill-in REPLACES the list view (the Magit-forge `RET` model). The list surface is a focus-TRAPPING
    -- modal: opening the topic buffer from inside its `<CR>` callback would have the trap bounce focus back
    -- to the list (the intermediate window a `tab` workspace creates reads as "the user tried to leave").
    -- Closing the list first releases the trap and returns to the origin, so the topic buffer opens focused;
    -- `q` on the topic then lands back on the code, not a stuck half-focused list. Scheduled so the open runs
    -- after the list's own teardown settles.
    M.close()
    vim.schedule(function()
        -- `from_list`: the topic's `q` reopens THIS list (Magit `RET` returns to the list, not the code).
        require("lvim-forge.ui.topic").open(root, number, { kind = kind, from_list = true })
    end)
end

return M
