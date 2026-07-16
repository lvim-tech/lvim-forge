-- lvim-forge.ui.topic: the READ-ONLY TOPIC BUFFER — one issue or pull request rendered in full from the
-- local SQLite cache ONLY (instant + offline). Built on the `lvim-ui.tabs` menu surface (the lvim-git
-- status chassis pattern): two header CHIP bands (a topic band
-- `<state-icon> #N ➤ <title>` + a state chip; a META band of label/milestone/assignee/reviewer chips, +
-- for PRs the `+adds/-dels`, base ← head, and mergeable/review-decision glyph), then ONE scrollable panel
-- of collapsible `ui.section` fold headers (fold-header canon — the plugin passes only the accent, the
-- tints are global via `lvim-utils.highlight.section_accent`):
--   • Description — the topic body as plain styled lines.
--   • Timeline — chronological: each comment as its own section, each review as a section in its VERDICT
--     accent (approved green / changes red / commented blue) with its body + inline review-comments grouped
--     under it, and system events (opened / merged / closed) as DIM one-liners.
--   • For PRs additionally: Commits, Files changed (rows from `pr_files`; `<CR>` diffs the file via the
--     lvim-git seam), Checks, and Review threads (unresolved first, resolved folded).
--
-- Nothing here touches the network on a render path: every row reads `db.lua`. Opening renders the cache
-- NOW, then kicks `sync.pull_topic` (a staleness-aware background detail fetch for THIS topic) and REFRESHES
-- from the DB when `User LvimForgeTopicChanged` / `LvimForgePullDone` fire for this repo+number — the
-- lvim-git `LvimGitRepoChanged` reactive pattern. If the topic is not cached yet, the pull fills it and the
-- refresh renders it.
--
-- Phase 5 is READ + navigation. LIVE keys: `<CR>` (fold a section · diff a file row), `]]`/`[[` (jump
-- between sections), `B` browse the topic on the web, `Y` yank the URL, `g?` help, `q`/`<Esc>` close.
-- STUBBED (named seams a later phase swaps the body of): `c`/`e`/`E` composer (Phase 6); `L`/`A`/`M`/`R`
-- `s`/`m`/`o`/`O`/`d`/`W`/`t`/`T` actions (Phase 7); `v` review workspace (Phase 9).
--
-- Layouts area | float | bottom | tab (per-command token → `config.layouts.topic` → default); `tab` hosts
-- the buffer in the dedicated-tabpage workspace (`ui/workspace.lua`) sized to fill the tab via `slot()`.
--
---@module "lvim-forge.ui.topic"

local api = vim.api
local config = require("lvim-forge.config")
local commands = require("lvim-forge.commands")
local state = require("lvim-forge.state")
local db = require("lvim-forge.db")
local sync = require("lvim-forge.sync")
local actions = require("lvim-forge.actions")
local transient = require("lvim-forge.transient")
local highlights = require("lvim-forge.highlights")
local detect = require("lvim-forge.client.detect")
local workspace = require("lvim-forge.ui.workspace")
local ui = require("lvim-ui")
local hl = require("lvim-utils.highlight")

local M = {}

--- Close / reopen a topic (the `s` verb), gated by `config.confirm_destructive` on a CLOSE. Extracted to
--- the module surface so it is testable without the panel: a merged PR refuses; an open topic closes
--- (behind `ui.confirm` when `confirm_destructive`); a closed topic reopens (no confirm). `opts.cb` is the
--- mutation callback; `opts.action_opts` threads the test transport/repo_row.
---@param root? string|integer
---@param number integer
---@param cur_state? string  the topic's current state ("open"|"closed"|"merged")
---@param opts? { cb?: fun(ok: boolean, err: table?), action_opts?: table }
function M.toggle_state(root, number, cur_state, opts)
    opts = opts or {}
    local config = require("lvim-forge.config")
    local actions = require("lvim-forge.actions")
    local ui = require("lvim-ui")
    local new_state
    if cur_state == "open" then
        new_state = "closed"
    elseif cur_state == "closed" then
        new_state = "open"
    else
        vim.notify("lvim-forge: a merged pull request cannot be reopened", vim.log.levels.INFO)
        return
    end
    local function run()
        actions.set_state(root, number, new_state, opts.cb, opts.action_opts)
    end
    if new_state == "closed" and config.confirm_destructive then
        ui.confirm({
            prompt = ("Close #%d?"):format(number),
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
end

--- The author gate for editing a post: allowed when the viewer is unknown (can't verify offline — the
--- API enforces it server-side) OR the viewer IS the author; refused (false) only when a KNOWN viewer is
--- not the author. Pure + testable (the `e` verb calls it).
---@param viewer? string  the authenticated viewer login (nil = unknown)
---@param author? string  the post/description author login
---@return boolean allowed
function M.author_gate(viewer, author)
    if viewer == nil or author == nil then
        return true
    end
    return viewer == author
end

--- The logical view id (layout resolution, the open-panel registry, the workspace tab).
---@type string
local VIEW = "topic"

-- ── glyphs (verified single-width Nerd Font, + the `➤` pointer canon) ──────────
local GLYPH = {
    repo = "\u{ea62}", --  nf-cod-repo (border title)
    arrow = "➤", -- band segment separator / pointer (the canon)
    fold_open = "\u{f0d7}", --  nf-fa-caret_down  (section expanded)
    fold_closed = "\u{f0da}", --  nf-fa-caret_right (section collapsed)
    dot = "\u{f444}", --  nf-oct-dot_fill (system event)
    milestone = "\u{f51b}", --  nf-oct-milestone
    person = "\u{f007}", --  nf-fa-user (assignees)
    eye = "\u{f441}", --  nf-oct-eye (reviewers)
    file_added = "\u{f457}", --  nf-oct-diff_added
    file_modified = "\u{f459}", --  nf-oct-diff_modified
    file_removed = "\u{f458}", --  nf-oct-diff_removed
    file_renamed = "\u{f47c}", --  nf-oct-diff_renamed
    branch = "\u{e725}", --  nf-dev-git_branch (base ← head)
}

---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-forge: " .. msg, level or vim.log.levels.INFO)
end

-- ── time helpers (UTC ISO-8601 → epoch / a short relative date) ────────────────

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

--- Truthy for a sqlite boolean column (1 / true).
---@param v any
---@return boolean
local function truthy(v)
    return v == 1 or v == true
end

-- ── state chip + PR file status glyphs ─────────────────────────────────────────

--- The state word + its chip highlight (icon + block) for a topic.
---@param topic table  a topics row (kind/state + optional pullreq extras)
---@param is_pr boolean
---@param pr? table    the pullreqs extras (draft flag)
---@return string icon, string word, string chip_hl
local function state_chip(topic, is_pr, pr)
    local icons = config.icons
    if is_pr then
        if topic.state == "merged" then
            return icons.merged, "Merged", "LvimForgeChipMerged"
        elseif topic.state == "closed" then
            return icons.closed, "Closed", "LvimForgeChipClosed"
        elseif pr and truthy(pr.draft) then
            return icons.draft, "Draft", "LvimForgeChipDraft"
        end
        return icons.pull, "Open", "LvimForgeChipOpen"
    end
    if topic.state == "closed" then
        return icons.closed, "Closed", "LvimForgeChipClosed"
    end
    return icons.issue, "Open", "LvimForgeChipOpen"
end

--- The status glyph + highlight for a PR file row.
---@param status? string
---@return string glyph, string hl
local function file_status(status)
    if status == "added" then
        return GLYPH.file_added, "LvimForgeMetaAdd"
    elseif status == "removed" then
        return GLYPH.file_removed, "LvimForgeMetaDel"
    elseif status == "renamed" then
        return GLYPH.file_renamed, "LvimForgeBranch"
    end
    return GLYPH.file_modified, "LvimForgeCheckPending"
end

-- ── the merge transient (the shared engine — one STATIC def; the live PR rides in on ctx.selection) ──

--- The merge transient's ACTION: read the chosen method + delete-branch + optional commit title/message
--- from the live infix rows, gate a non-mergeable / changes-requested PR (and any merge when
--- `confirm_destructive`) behind `ui.confirm`, then drive `actions.merge`. `ctx.selection` carries the PR
--- (root / number / mergeable / review_decision) the topic buffer opened the transient with.
---@param _ string[]  the assembled argv (unused — the forge merge reads the typed rows directly)
---@param ctx LvimUiTransientCtx
local function merge_action(_, ctx)
    local sel = ctx.selection or {}
    local rows = ctx.rows or {}
    local number = sel.number
    if not number then
        notify("no pull request selected for merge", vim.log.levels.WARN)
        return
    end
    local method = (rows["-m"] and rows["-m"].value) or (config.merge and config.merge.default_method) or "merge"
    local delete_branch = rows["-d"] and rows["-d"].value == true
    local title = rows["-t"] and rows["-t"].value
    local message = rows["-e"] and rows["-e"].value
    local params = {
        method = method,
        delete_branch = delete_branch,
        commit_title = (type(title) == "string" and title ~= "") and title or nil,
        commit_message = (type(message) == "string" and message ~= "") and message or nil,
    }

    local function run()
        notify(("merging #%d (%s%s) …"):format(number, method, delete_branch and ", delete branch" or ""))
        actions.merge(sel.root, number, params, function(ok, res)
            if not ok then
                notify("merge failed: " .. ((res and (res.message or res.kind)) or "?"), vim.log.levels.WARN)
                return
            end
            local extra = ""
            if res and res.removed_local then
                extra = " " .. GLYPH.arrow .. " removed " .. res.removed_local
            elseif res and res.deleted_remote then
                extra = " " .. GLYPH.arrow .. " deleted " .. res.deleted_remote
            end
            notify(("merged #%d (%s)%s"):format(number, method, extra))
        end, sel.action_opts)
    end

    -- Gate: a non-mergeable / changes-requested PR warns in the confirm; any merge confirms when
    -- `confirm_destructive`. `mergeable == 0` = conflicts; nil = the forge has not computed it (no warn).
    local reasons = {}
    if sel.mergeable == 0 then
        reasons[#reasons + 1] = "not mergeable (conflicts)"
    end
    if sel.review_decision == "changes_requested" then
        reasons[#reasons + 1] = "changes requested"
    end
    if #reasons > 0 or config.confirm_destructive then
        local prompt = (#reasons > 0) and ("Merge #%d anyway? (%s)"):format(number, table.concat(reasons, ", "))
            or ("Merge #%d?"):format(number)
        ui.confirm({
            prompt = prompt,
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
end

--- Register the merge transient DEF once (idempotent — `define` replaces). Called from `M.open` so the
--- infix defaults (method / delete-branch) read the EFFECTIVE config (after `setup()` merged it). The def
--- is STATIC; per-PR data rides in on `ctx.selection`, the typed choices come from the live infix rows.
local merge_registered = false
local function register_merge_transient()
    if merge_registered then
        return
    end
    merge_registered = true
    local methods = (config.merge and config.merge.methods) or { "merge", "squash", "rebase" }
    transient.define({
        id = "merge",
        title = "Merge pull request",
        groups = {
            {
                title = "Method",
                infix = {
                    {
                        kind = "option",
                        key = "-m",
                        arg = "--method",
                        label = "Merge method",
                        choices = methods,
                        default = (config.merge and config.merge.default_method) or "merge",
                        level = 1,
                    },
                },
            },
            {
                title = "Arguments",
                infix = {
                    {
                        kind = "switch",
                        key = "-d",
                        flag = "--delete-branch",
                        label = "Delete branch after merge",
                        default = (config.merge and config.merge.delete_branch) == true,
                        level = 1,
                    },
                    {
                        kind = "option",
                        key = "-t",
                        arg = "--title",
                        label = "Commit title (merge / squash)",
                        level = 2,
                    },
                    {
                        kind = "option",
                        key = "-e",
                        arg = "--message",
                        label = "Commit message (merge / squash)",
                        level = 2,
                    },
                },
            },
            {
                title = "Actions",
                actions = {
                    { key = "m", label = "Merge", run = merge_action },
                },
            },
        },
    })
end

--- Ensure the merge transient DEF is registered (idempotent). Public so the `:LvimForge merge <n>` command
--- can open the merge popup without first opening a topic buffer.
function M.register_transients()
    register_merge_transient()
end

-- ── the panel (one closure per open) ──────────────────────────────────────────

--- Open the read-only topic buffer for `number` in the current tracked repo. `root` (a path) targets the
--- repo the topic list resolved (a `tab`-hosted list's current buffer is the panel scratch, so the root is
--- threaded through); nil detects from the current buffer (the `:LvimForge topic <n>` path).
---@param root? string|integer
---@param number integer|string
---@param opts? { layout?: string, kind?: "issue"|"pullreq" }
function M.open(root, number, opts)
    opts = opts or {}
    register_merge_transient() -- idempotent; ensures the merge popup def exists (config is merged by now)
    if not (config.topic and config.topic.enabled) then
        notify("the topic component is disabled (config.topic.enabled = false)")
        return
    end
    if not db.available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end
    local num = tonumber(number)
    if not num then
        notify("a topic number is required (`:LvimForge topic <n>`)", vim.log.levels.WARN)
        return
    end
    ---@type integer  a clean integer topic number (shadows the loosely-typed param)
    local number = math.floor(num)

    local client = require("lvim-forge.client")
    local detected = client.detect(root or 0)
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
    root = detected.root
    ---@type LvimForgeGithubCtx
    local ctx = {
        owner = repo_row.owner,
        name = repo_row.name,
        forge = repo_row.forge,
        host = repo_row.host,
        base = detect.api_base(repo_row.forge, repo_row.host),
        root = root,
    }

    -- Focus / re-target an already-open topic buffer (a different number replaces it).
    local view_key = VIEW
    local open_rec = state.panels[view_key]
    if open_rec and open_rec.handle and open_rec.handle.valid and open_rec.handle.valid() then
        if open_rec.repo_id == repo_id and open_rec.number == number then
            open_rec.focus()
            return
        end
        open_rec.close()
    end

    local layout = commands.layout_for(VIEW, opts.layout)
    local is_tab = layout == "tab"

    ---@class LvimForgeTopicState
    local st = {
        folds = {}, ---@type table<string, boolean>  captured expanded-state per section/accordion id
        rowsById = {}, ---@type table<string, table>  id → its live row (fold-state capture before rebuild)
        section_names = {}, ---@type string[]  top-level section header names, in render order (]]/[[ nav)
        tabs = nil, ---@type table[]?
        handle = nil, ---@type table?
        augroup = nil, ---@type integer?
    }

    local function is_open()
        return st.handle ~= nil and st.handle.valid and st.handle.valid()
    end

    -- ── the DB model snapshot (re-read on every rebuild; renders from the cache only) ──
    ---@return table?
    local function load_model()
        local topic = db.get_topic(repo_id, number, opts.kind)
        if not topic then
            return nil
        end
        local is_pr = topic.kind == "pullreq"
        local ms
        if topic.milestone_id then
            for _, m in ipairs(db.milestones(repo_id)) do
                if m.id == topic.milestone_id then
                    ms = m
                    break
                end
            end
        end
        return {
            topic = topic,
            is_pr = is_pr,
            pr = topic.pullreq,
            posts = db.posts(topic.id),
            reviews = db.reviews(topic.id),
            threads = db.threads(topic.id),
            files = db.pr_files(topic.id),
            labels = db.topic_labels(topic.id),
            assignees = db.topic_assignees(topic.id),
            reviewers = db.topic_review_requests(topic.id),
            milestone = ms,
        }
    end

    -- ── fold-state helpers (a manual <CR>/l/h fold survives a data refresh) ──
    ---@param name string
    ---@param default boolean
    ---@return boolean
    local function expanded_of(name, default)
        local f = st.folds[name]
        if f ~= nil then
            return f == true
        end
        return default
    end

    -- ── row primitives ──────────────────────────────────────────────────────
    --- A read-only leaf row (a body line, an info line).
    ---@param name string
    ---@param text string
    ---@param text_hl string
    ---@return table
    local function leaf(name, text, text_hl)
        return {
            type = "action",
            name = name,
            flat = true,
            tight = true,
            icon = "",
            label = text == "" and " " or text,
            text_hl = text_hl,
            run = function() end,
        }
    end

    --- A collapsible section header (fold-header canon: only the accent is passed; tints are global).
    ---@param name string
    ---@param label string
    ---@param accent string  a palette accent NAME ("blue"/"green"/…) or "#rrggbb"
    ---@param count integer?
    ---@param children table[]
    ---@param default_exp boolean
    ---@param track_toc? boolean  register the header for the ]]/[[ table-of-contents nav (top-level only)
    ---@return table
    local function section(name, label, accent, count, children, default_exp, track_toc)
        local exp = expanded_of(name, default_exp)
        local sa = hl.section_accent(accent)
        local row = ui.section({
            name = name,
            icon = " " .. (exp and GLYPH.fold_open or GLYPH.fold_closed) .. " ",
            box_hl = sa.text,
            label = label,
            count = count,
            accent = accent,
            expanded = exp,
            children = children,
        })
        st.rowsById[name] = row
        if track_toc ~= false then
            st.section_names[#st.section_names + 1] = name
        end
        return row
    end

    --- Render a markdown body as plain styled child rows (headings/bullets/fences get a light accent; the
    --- rest is plain text — NOT a nested markdown buffer). Empty body → a single dim placeholder.
    ---@param prefix string  a unique row-name namespace
    ---@param body? string
    ---@param empty_text? string
    ---@return table[]
    local function body_rows(prefix, body, empty_text)
        local text = body and vim.trim(body) or ""
        if text == "" then
            return { leaf(prefix .. "empty", empty_text or "(no description)", "LvimForgeDate") }
        end
        local out = {}
        local i = 0
        for line in (text:gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
            i = i + 1
            local group = "LvimForgeTitle"
            if line:match("^#+%s") then
                group = "LvimForgeNumber"
            elseif line:match("^%s*```") then
                group = "LvimForgeDate"
            elseif line:match("^%s*[-*+]%s") or line:match("^%s*%d+%.%s") then
                group = "LvimForgeAuthor"
            end
            out[#out + 1] = leaf(prefix .. "l" .. i, line, group)
        end
        return out
    end

    -- ── the header chip bands (topic band + META band; `type="bar"` header sectors) ──
    ---@param text string
    ---@param group string
    ---@return table  a static separator-box chip
    local function chip(text, group)
        return { type = "separator", text = text, style = { padding = { 0, 0 }, hl = group } }
    end
    ---@return table  a small spacer between chips
    local function gap()
        return { type = "separator", text = "  ", style = { hl = "LvimForgeMeta" } }
    end

    --- The topic band: `<state-icon> #N ➤ <title>` + a state chip.
    ---@param m table
    ---@return table
    local function topic_band(m)
        local icon, word, chip_hl = state_chip(m.topic, m.is_pr, m.pr)
        local items = {
            chip(" " .. icon .. " ", chip_hl),
            gap(),
            chip("#" .. tostring(m.topic.number), "LvimForgeNumber"),
            chip("  " .. GLYPH.arrow .. "  ", "LvimForgeMeta"),
            chip(m.topic.title or "(untitled)", "LvimForgeTitle"),
            gap(),
            chip(" " .. word .. " ", chip_hl),
        }
        return { type = "bar", name = "band-topic", align = "center", items = items }
    end

    --- The META band: label chips ● milestone ● assignees ● reviewers ● (PR) +/- ● base ← head ● decision.
    ---@param m table
    ---@return table
    local function meta_band(m)
        local items = {}
        local function add(it)
            items[#items + 1] = it
        end
        local function bullet()
            if #items > 0 then
                add({ type = "separator", text = "  " .. GLYPH.arrow .. "  ", style = { hl = "LvimForgeMeta" } })
            end
        end
        -- labels (data-driven chip colours via the Phase-4 highlights.label_hl)
        for _, l in ipairs(m.labels) do
            add(chip(" " .. (l.name or "") .. " ", highlights.label_hl(l.color)))
            add({ type = "separator", text = " ", style = { hl = "LvimForgeMeta" } })
        end
        if m.milestone then
            bullet()
            add(chip(GLYPH.milestone .. " " .. (m.milestone.title or ""), "LvimForgeMeta"))
        end
        if #m.assignees > 0 then
            bullet()
            add(chip(GLYPH.person .. " " .. table.concat(m.assignees, ", "), "LvimForgeAuthor"))
        end
        if #m.reviewers > 0 then
            bullet()
            add(chip(GLYPH.eye .. " " .. table.concat(m.reviewers, ", "), "LvimForgeCommented"))
        end
        if m.is_pr and m.pr then
            bullet()
            add(chip("+" .. (m.pr.additions or 0), "LvimForgeMetaAdd"))
            add({ type = "separator", text = " ", style = { hl = "LvimForgeMeta" } })
            add(chip("-" .. (m.pr.deletions or 0), "LvimForgeMetaDel"))
            if m.pr.base_ref then
                bullet()
                add(
                    chip(
                        GLYPH.branch
                            .. " "
                            .. (m.pr.base_ref or "?")
                            .. " "
                            .. GLYPH.arrow
                            .. " "
                            .. (m.pr.head_ref or "?"),
                        "LvimForgeBranch"
                    )
                )
            end
            local dec = m.pr.review_decision
            if dec then
                bullet()
                local dmap = {
                    approved = { config.icons.check_pass .. " approved", "LvimForgeApproved" },
                    changes_requested = { config.icons.check_fail .. " changes requested", "LvimForgeChanges" },
                    review_required = { config.icons.check_pending .. " review required", "LvimForgePending" },
                }
                local d = dmap[dec] or { dec, "LvimForgeMeta" }
                add(chip(d[1], d[2]))
            end
        end
        if #items == 0 then
            add(chip("no labels · no assignees", "LvimForgeMeta"))
        end
        return { type = "bar", name = "band-meta", align = "center", items = items }
    end

    -- ── timeline ─────────────────────────────────────────────────────────────
    --- A system event: a DIM one-line row (opened / merged / closed).
    ---@param name string
    ---@param glyph string
    ---@param text string
    ---@param iso? string
    ---@return table
    local function system_row(name, glyph, text, iso)
        local rel = rel_date(iso)
        local label = text .. (rel ~= "" and ("  " .. GLYPH.arrow .. " " .. rel) or "")
        return {
            type = "action",
            name = "sys:" .. name,
            flat = true,
            tight = true,
            icon = " " .. glyph .. " ",
            icon_hl = "LvimForgeDate",
            label = label,
            text_hl = "LvimForgeDate",
            run = function() end,
        }
    end

    --- A comment as its own section (author ➤ rel-date header + body).
    ---@param p table  a posts row (kind = comment)
    ---@return table
    local function comment_section(p)
        local label = (p.author or "?") .. "  " .. GLYPH.arrow .. " " .. rel_date(p.created)
        return section(
            "cmt:" .. tostring(p.id),
            label,
            "yellow",
            nil,
            body_rows("cmt" .. tostring(p.id) .. ":", p.body, "(empty comment)"),
            true,
            false
        )
    end

    --- The verdict styling for a review state.
    ---@type table<string, { accent: string, word: string, glyph: string }>
    local VERDICT = {
        approved = { accent = "green", word = "approved", glyph = config.icons.check_pass },
        changes = { accent = "red", word = "requested changes", glyph = config.icons.check_fail },
        commented = { accent = "blue", word = "commented", glyph = config.icons.comment },
        pending = { accent = "yellow", word = "pending", glyph = config.icons.check_pending },
    }

    --- A review as a section in its VERDICT accent: its body + the inline review-comments grouped under it.
    ---@param rv table  a reviews row
    ---@param m table   the model (for the review-comment posts)
    ---@return table
    local function review_section(rv, m)
        local v = VERDICT[rv.state] or VERDICT.commented
        local label = ("%s  %s %s  %s %s"):format(
            rv.author or "?",
            GLYPH.arrow,
            v.word,
            GLYPH.arrow,
            rel_date(rv.submitted_at)
        )
        local name = "rev:" .. tostring(rv.id)
        local children = {}
        if rv.body and vim.trim(rv.body) ~= "" then
            vim.list_extend(children, body_rows(name .. ":b", rv.body))
        end
        -- Inline review-comments belonging to THIS review (review_id == the review forge_id).
        for _, p in ipairs(m.posts) do
            if p.kind == "review-comment" and rv.forge_id ~= nil and p.review_id == rv.forge_id then
                local anchor = (p.path or "?") .. (p.line and (":" .. p.line) or "")
                if truthy(p.outdated) then
                    anchor = anchor .. "  (outdated)"
                end
                children[#children + 1] = {
                    type = "action",
                    name = name .. ":a" .. tostring(p.id),
                    flat = true,
                    tight = true,
                    icon = " " .. GLYPH.arrow .. " ",
                    icon_hl = "LvimForgeThread",
                    label = anchor,
                    text_hl = truthy(p.outdated) and "LvimForgeThreadOutdated" or "LvimForgeBranch",
                    run = function() end,
                }
                vim.list_extend(children, body_rows(name .. ":c" .. tostring(p.id) .. ":", p.body))
            end
        end
        if #children == 0 then
            children = { leaf(name .. ":empty", "(no review comment)", "LvimForgeDate") }
        end
        return section(name, label, v.accent, nil, children, true, false)
    end

    --- The chronological timeline rows: opened event, comments + reviews (sorted by time), close/merge.
    ---@param m table
    ---@return table[]
    local function timeline_rows(m)
        ---@type { e: integer, i: integer, row: table }[]
        local entries = {}
        local function add(iso, row)
            entries[#entries + 1] = { e = iso_epoch(iso) or 0, i = #entries, row = row }
        end
        add(
            m.topic.created,
            system_row(
                "opened",
                GLYPH.dot,
                ("%s opened this %s"):format(m.topic.author or "?", m.is_pr and "pull request" or "issue"),
                m.topic.created
            )
        )
        for _, p in ipairs(m.posts) do
            if p.kind == "comment" then
                add(p.created, comment_section(p))
            end
        end
        for _, rv in ipairs(m.reviews) do
            -- A LOCAL pending review (forge_id unset — the review workspace's draft) is not a timeline
            -- entry; it lives only in the review overlay as `[pending]` comments.
            if not (rv.state == "pending" and rv.forge_id == nil) then
                add(rv.submitted_at, review_section(rv, m))
            end
        end
        if m.topic.state == "merged" then
            local by = m.pr and m.pr.merged_by
            add(
                m.topic.closed_at,
                system_row("merged", config.icons.merged, "merged" .. (by and (" by " .. by) or ""), m.topic.closed_at)
            )
        elseif m.topic.state == "closed" then
            add(
                m.topic.closed_at,
                system_row(
                    "closed",
                    config.icons.closed,
                    "closed this " .. (m.is_pr and "pull request" or "issue"),
                    m.topic.closed_at
                )
            )
        end
        table.sort(entries, function(a, b)
            if a.e ~= b.e then
                return a.e < b.e
            end
            return a.i < b.i
        end)
        local out = {}
        for _, en in ipairs(entries) do
            out[#out + 1] = en.row
        end
        return out
    end

    -- ── PR-only sections ─────────────────────────────────────────────────────
    --- Commits: the count from the PR extras + a follow-up note (the per-commit endpoint is not cached
    --- yet — the commits fetch is an OPEN follow-up; NOT inventing a commits table here).
    ---@param m table
    ---@return table
    local function commits_section(m)
        local n = (m.pr and m.pr.commits) or 0
        local children = {
            leaf(
                "commits:info",
                ("%d commit%s in this pull request"):format(n, n == 1 and "" or "s"),
                "LvimForgeTitle"
            ),
            leaf(
                "commits:todo",
                "per-commit sha + subject is a follow-up (the commits endpoint is not cached yet)",
                "LvimForgeDate"
            ),
        }
        return section("commits", "Commits", "blue", n, children, false, true)
    end

    --- Files changed: one row per `pr_files` (status glyph + path + `+adds/-dels`); `<CR>` diffs the file.
    ---@param m table
    ---@return table
    local function files_section(m)
        local children = {}
        for _, f in ipairs(m.files) do
            local g, ghl = file_status(f.status)
            local spans = {}
            local label = ""
            local function seg(t, group)
                local s = #label
                label = label .. t
                if group then
                    spans[#spans + 1] = { s, #label, group }
                end
            end
            seg(f.path or "?", "LvimUiPathName")
            seg("  ")
            seg("+" .. (f.additions or 0), "LvimForgeMetaAdd")
            seg(" ")
            seg("-" .. (f.deletions or 0), "LvimForgeMetaDel")
            children[#children + 1] = {
                type = "action",
                name = "file:" .. (f.path or tostring(#children)),
                flat = true,
                tight = true,
                icon = " " .. g .. " ",
                icon_hl = ghl,
                label = label,
                label_spans = spans,
                run = function()
                    M._diff_file(root, m, f)
                end,
            }
        end
        if #children == 0 then
            children = { leaf("files:none", "(no files cached)", "LvimForgeDate") }
        end
        return section("files", "Files changed", "magenta", #m.files, children, false, true)
    end

    --- Checks: the DB has no check-run table yet (the checks endpoint is not fetched — an OPEN follow-up),
    --- so render an explicit empty section rather than inventing a table.
    ---@return table
    local function checks_section()
        local children = {
            leaf("checks:none", "no check runs cached (the checks endpoint is a follow-up)", "LvimForgeDate"),
        }
        return section("checks", "Checks", "cyan", 0, children, false, true)
    end

    --- Review threads: unresolved first, resolved folded. Each thread is an accordion — a `path:line`
    --- header + its comments; nil when there are no threads (the section is omitted).
    ---@param m table
    ---@return table?
    local function threads_section(m)
        if #m.threads == 0 then
            return nil
        end
        local children = {}
        local unresolved = 0
        for _, th in ipairs(m.threads) do
            local resolved = truthy(th.resolved)
            if not resolved then
                unresolved = unresolved + 1
            end
            local tname = "thread:" .. tostring(th.id)
            local anchor = (th.path or "?") .. (th.line and (":" .. th.line) or "")
            if resolved then
                anchor = anchor .. "  (resolved)"
            end
            if truthy(th.outdated) then
                anchor = anchor .. "  (outdated)"
            end
            local tchildren = {}
            for _, p in ipairs(m.posts) do
                if p.kind == "review-comment" and th.forge_id ~= nil and p.thread_id == th.forge_id then
                    tchildren[#tchildren + 1] = leaf(
                        tname .. ":h" .. tostring(p.id),
                        (p.author or "?") .. "  " .. GLYPH.arrow .. " " .. rel_date(p.created),
                        "LvimForgeAuthor"
                    )
                    vim.list_extend(tchildren, body_rows(tname .. ":c" .. tostring(p.id) .. ":", p.body))
                end
            end
            if #tchildren == 0 then
                tchildren = { leaf(tname .. ":empty", "(no comments)", "LvimForgeDate") }
            end
            local exp = expanded_of(tname, not resolved)
            local trow = {
                type = "action",
                name = tname,
                flat = true,
                tight = true,
                icon = " " .. (exp and GLYPH.fold_open or GLYPH.fold_closed) .. " ",
                icon_hl = resolved and "LvimForgeThreadResolved" or "LvimForgeApproved",
                label = anchor,
                text_hl = resolved and "LvimForgeThreadResolved" or "LvimForgeTitle",
                expanded = exp,
                children = tchildren,
            }
            st.rowsById[tname] = trow
            children[#children + 1] = trow
        end
        return section("threads", "Review threads", "blue", unresolved, children, true, true)
    end

    -- ── build the tab rows ───────────────────────────────────────────────────
    ---@return table[]
    local function build_rows()
        st.rowsById = {}
        st.section_names = {}
        local m = load_model()
        if not m then
            return {
                {
                    type = "spacer",
                    name = "loading",
                    label = "  Loading topic #" .. number .. " …",
                    hl = { inactive = "LvimForgeDate" },
                },
            }
        end
        local rows = { topic_band(m), meta_band(m) }
        rows[#rows + 1] = section("desc", "Description", "blue", nil, body_rows("desc:", m.topic.body), true, true)
        vim.list_extend(rows, timeline_rows(m))
        if m.is_pr then
            rows[#rows + 1] = commits_section(m)
            rows[#rows + 1] = files_section(m)
            rows[#rows + 1] = checks_section()
            local threads = threads_section(m)
            if threads then
                rows[#rows + 1] = threads
            end
        end
        return rows
    end

    -- ── rebuild / refresh ────────────────────────────────────────────────────
    local function rebuild()
        if not is_open() then
            return
        end
        -- Capture the live fold state so a manual <CR>/l/h fold survives the data refresh.
        for id, row in pairs(st.rowsById) do
            st.folds[id] = row.expanded == true
        end
        st.tabs[1].rows = build_rows()
        local idx = st.handle.cursor_index()
        st.handle.recalc()
        st.handle.focus_index(idx)
    end

    -- ── section-to-section nav (]]/[[) ───────────────────────────────────────
    ---@param delta integer
    local function jump_section(delta)
        if not is_open() then
            return
        end
        local cur = st.handle.cursor_name and st.handle.cursor_name()
        local names = st.section_names
        if #names == 0 then
            return
        end
        local at = 0
        for i, n in ipairs(names) do
            if n == cur then
                at = i
                break
            end
        end
        local target
        if at == 0 then
            target = delta > 0 and names[1] or names[#names]
        else
            local nx = at + delta
            if nx >= 1 and nx <= #names then
                target = names[nx]
            end
        end
        if target and st.handle.focus then
            st.handle.focus(target)
        end
    end

    -- ── the topic URL (browse / yank) ────────────────────────────────────────
    ---@return string?
    local function topic_url()
        local t = db.get_topic(repo_id, number, opts.kind)
        return t and t.html_url or nil
    end

    local function do_browse()
        local url = topic_url()
        if not url then
            notify("no web URL cached for this topic yet (pull to fetch it)", vim.log.levels.WARN)
            return
        end
        -- Prefer the stored html_url and hand it to the OS handler (what lvim-git's browse does
        -- internally). lvim-git.browse builds URLs from the git remote, not an arbitrary topic URL, so the
        -- cached html_url is the correct source here; degrade to a yank when there is no opener.
        local ok = pcall(vim.ui.open, url)
        if ok then
            notify("browse: " .. url)
        else
            pcall(vim.fn.setreg, "+", url)
            notify("browse (no opener; yanked): " .. url, vim.log.levels.WARN)
        end
    end

    local function do_yank()
        local url = topic_url()
        if not url then
            notify("no web URL cached for this topic yet (pull to fetch it)", vim.log.levels.WARN)
            return
        end
        pcall(vim.fn.setreg, "+", url)
        pcall(vim.fn.setreg, '"', url)
        notify("yanked " .. url)
    end

    -- ── stubs for the seams later phases fill (each a clean, well-named notify) ──
    local function stub(msg)
        return function()
            notify(msg)
        end
    end
    local stub_marks = stub("marks land in a later phase")
    local stub_note = stub("the private note lands in a later phase")

    -- `v` — open the READ review workspace for this PR (threads overlaid on the lvim-git diff; a plain
    -- hunk-panel fallback without lvim-git). PR-only.
    local function do_review()
        local m = load_model()
        if not m then
            notify("the topic is still loading — try again in a moment")
            return
        end
        if not m.is_pr then
            notify("the review workspace applies to pull requests only")
            return
        end
        require("lvim-forge.ui.review").open(root, number)
    end

    -- ── Phase 7: PR checkout (`o` branch / `O` worktree) + full diff (`d`) ────────────────────────────
    --- Checkout the PR locally (fetch its head → a local branch, or a worktree). PR-only; a clean notify
    --- reports the resulting branch / worktree path (or the failure), and lvim-git re-syncs via the seam.
    ---@param worktree boolean
    local function do_checkout(worktree)
        local m = load_model()
        if not m then
            notify("the pull request is still loading — try again in a moment")
            return
        end
        if not m.is_pr then
            notify("checkout applies to pull requests only")
            return
        end
        notify(("checking out #%d%s …"):format(number, worktree and " in a worktree" or ""))
        actions.checkout(root, number, { worktree = worktree }, function(ok, res)
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

    --- The full PR diff (`d`): fetch the PR head, then hand off the `base...head` range to lvim-git's
    --- diffview (PUBLIC seam). Degrades to a clean notify when lvim-git is absent / not a git repo.
    local function do_full_diff()
        local m = load_model()
        if not m or not m.is_pr then
            notify("the full diff applies to pull requests only")
            return
        end
        local pr = m.pr
        if not pr or not pr.base_ref then
            notify("this pull request has no cached base ref (pull it first)")
            return
        end
        local ok_git, diff = pcall(require, "lvim-git.ui.diff")
        if not ok_git or type(diff.open) ~= "function" then
            notify("the full PR diff needs lvim-git (not installed)")
            return
        end
        local detected = require("lvim-forge.client").detect(root)
        local git_root = detected and detected.root
        if not git_root then
            notify("not inside a git working tree", vim.log.levels.WARN)
            return
        end
        local remote = (detected and detected.remote) or "origin"
        local git = require("lvim-forge.git")
        local stable = ("refs/forge/pr/%d"):format(number)
        notify("fetching #" .. number .. " head for the diff …")
        git.fetch_ref(git_root, remote, ("pull/%d/head:%s"):format(number, stable), function(fok, ferr)
            if not fok then
                notify("fetch of the pull head failed: " .. (ferr or "?"), vim.log.levels.WARN)
                return
            end
            local range = ("%s/%s...%s"):format(remote, pr.base_ref, stable)
            if not pcall(diff.open, { range = range }) then
                notify("could not open the PR diff", vim.log.levels.WARN)
            end
        end)
    end

    -- ── Phase 8: merge (`m` → the shared merge transient) + draft toggle (`W`) ───────────────────────
    --- `m` — open the MERGE transient for this PR (the shared lvim-ui transient engine). PR-only, open-only;
    --- the live PR (number / mergeable / review_decision) is passed as the transient's `selection`.
    local function do_merge()
        local m = load_model()
        if not m then
            notify("the pull request is still loading — try again in a moment")
            return
        end
        if not m.is_pr then
            notify("merge applies to pull requests only")
            return
        end
        if m.topic.state ~= "open" then
            notify(("#%d is %s — only an open pull request can be merged"):format(number, m.topic.state))
            return
        end
        local pr = m.pr or {}
        transient.open("merge", {
            root = root,
            selection = {
                root = root,
                number = number,
                repo_row = repo_row,
                mergeable = pr.mergeable, -- 0 = conflicts; nil = not yet computed
                review_decision = pr.review_decision, -- "changes_requested" gates the merge
            },
        })
    end

    --- `W` — toggle the PR's draft state (GraphQL, via actions.toggle_draft). PR-only, open-only; no confirm
    --- (it is reversible). Refresh follows from `LvimForgeTopicChanged`.
    local function do_draft()
        local m = load_model()
        if not m then
            notify("the pull request is still loading — try again in a moment")
            return
        end
        if not m.is_pr then
            notify("the draft toggle applies to pull requests only")
            return
        end
        if m.topic.state ~= "open" then
            notify("only an open pull request can toggle its draft state")
            return
        end
        local want = not truthy(m.pr and m.pr.draft)
        notify((want and "converting #%d to draft …" or "marking #%d ready for review …"):format(number))
        actions.toggle_draft(root, number, function(ok, res)
            if not ok then
                notify("draft toggle failed: " .. ((res and (res.message or res.kind)) or "?"), vim.log.levels.WARN)
                return
            end
            notify(
                (res and res.draft) and ("#%d is now a draft"):format(number)
                    or ("#%d is ready for review"):format(number)
            )
        end)
    end

    -- ── Phase 6: the live topic-write verbs (composer + mutations via actions → sync.mutate) ─────────
    ---@return string
    local function repo_label()
        return ("%s/%s"):format(repo_row.owner, repo_row.name)
    end

    --- Resolve the authenticated viewer login (once, cached in state) then run `after`. Background,
    --- best-effort, forge-blind (the backend is resolved via the dispatch seam) — the author gate needs
    --- "me"; an unresolved viewer just leaves the gate open.
    ---@param after fun()
    local function ensure_viewer_then(after)
        if state.viewer[repo_host] then
            return after()
        end
        local backend = require("lvim-forge.client").backend(repo_row.forge)
        if not backend or type(backend.viewer) ~= "function" then
            return after()
        end
        backend.viewer(ctx, function(login)
            if login then
                state.viewer[repo_host] = login
            end
            vim.schedule(after)
        end)
    end

    --- Identify the post (or the description) under the cursor from its row name. Comment rows are
    --- `cmt:<post.id>` / `cmt<post.id>:…`; description rows are `desc…`; review rows are deferred to the
    --- review phase. Returns `{ kind, author?, forge_id?, body? }` or nil.
    ---@param m table
    ---@return table?
    local function post_under_cursor(m)
        local name = st.handle and st.handle.cursor_name and st.handle.cursor_name()
        if not name then
            return nil
        end
        if name:match("^desc") then
            return { kind = "description", author = m.topic.author, body = m.topic.body }
        end
        local pid = tonumber(name:match("^cmt:(%d+)") or name:match("^cmt(%d+):"))
        if pid then
            for _, p in ipairs(m.posts) do
                if p.id == pid and p.kind == "comment" then
                    return { kind = "comment", author = p.author, forge_id = p.forge_id, body = p.body }
                end
            end
        end
        if name:match("^rev") then
            return { kind = "review" }
        end
        return nil
    end

    --- Common mutation callback → a WARN notify on failure (success refreshes via LvimForgeTopicChanged).
    ---@param what string
    ---@return fun(ok: boolean, err: table?)
    local function mut_cb(what)
        return function(ok, err)
            if not ok then
                notify((what .. " failed: %s"):format((err and (err.message or err.kind)) or "?"), vim.log.levels.WARN)
            end
        end
    end

    -- `c` — comment on this topic (composer).
    local function do_comment()
        local m = load_model()
        if not m then
            notify("the topic is still loading — try again in a moment")
            return
        end
        require("lvim-forge.ui.composer").open({
            mode = "comment",
            root = root,
            repo_id = repo_id,
            number = number,
            kind = m.topic.kind,
            repo_label = repo_label(),
        })
    end

    -- `e` — edit the post/description under the cursor (author-gated).
    local function do_edit()
        local m = load_model()
        if not m then
            return
        end
        local target = post_under_cursor(m)
        if not target then
            notify("place the cursor on the description or a comment to edit it")
            return
        end
        if target.kind == "review" then
            notify("editing review comments lands in the review phase (Phase 10)")
            return
        end
        ensure_viewer_then(function()
            if not M.author_gate(state.viewer[repo_host], target.author) then
                notify(("you can only edit your own posts (this one is %s's)"):format(target.author or "?"))
                return
            end
            require("lvim-forge.ui.composer").open({
                mode = "edit",
                root = root,
                repo_id = repo_id,
                number = number,
                kind = m.topic.kind,
                target = { kind = target.kind, forge_id = target.forge_id },
                prefill = target.body or "",
                repo_label = repo_label(),
            })
        end)
    end

    -- `E` — edit the title (a canonical ui.input → the update-title mutation).
    local function do_edit_title()
        local m = load_model()
        if not m then
            return
        end
        ui.input({
            title = { icon = GLYPH.repo, text = "Edit title" },
            default = m.topic.title or "",
            callback = function(confirmed, value)
                if not confirmed then
                    return
                end
                if vim.trim(value or "") == "" then
                    notify("an empty title was not sent", vim.log.levels.WARN)
                    return
                end
                actions.set_title(root, number, value, mut_cb("title edit"))
            end,
        })
    end

    -- `s` — close / reopen toggle (confirm on close when confirm_destructive) via the testable seam.
    local function do_state()
        local m = load_model()
        if not m then
            return
        end
        M.toggle_state(root, number, m.topic.state, { cb = mut_cb("state change") })
    end

    -- `L` — labels (ui.multiselect seeded from the repo labels, preselected from the topic's set).
    local function do_labels()
        local m = load_model()
        if not m then
            return
        end
        local all = db.labels(repo_id)
        if #all == 0 then
            notify("no labels cached — `:LvimForge pull` first")
            return
        end
        local current = {}
        for _, l in ipairs(m.labels) do
            current[l.name] = true
        end
        local items = {}
        for _, l in ipairs(all) do
            items[#items + 1] = { label = l.name, name = l.name, checked = current[l.name] or nil }
        end
        ui.multiselect({
            title = "Labels",
            items = items,
            callback = function(confirmed, selected)
                if not confirmed then
                    return
                end
                local names = {}
                for _, it in ipairs(items) do
                    if selected[it] then
                        names[#names + 1] = it.name
                    end
                end
                actions.set_labels(root, number, names, mut_cb("labels"))
            end,
        })
    end

    -- `A` — assignees (ui.multiselect of the repo users, preselected from the topic's set).
    local function do_assignees()
        local m = load_model()
        if not m then
            return
        end
        local users = db.users(repo_id)
        if #users == 0 then
            notify("no assignable users cached — `:LvimForge pull` first")
            return
        end
        local current = {}
        for _, a in ipairs(m.assignees) do
            current[a] = true
        end
        local items = {}
        for _, u in ipairs(users) do
            items[#items + 1] = { label = u.login, login = u.login, checked = current[u.login] or nil }
        end
        ui.multiselect({
            title = "Assignees",
            items = items,
            callback = function(confirmed, selected)
                if not confirmed then
                    return
                end
                local logins = {}
                for _, it in ipairs(items) do
                    if selected[it] then
                        logins[#logins + 1] = it.login
                    end
                end
                actions.set_assignees(root, number, logins, mut_cb("assignees"))
            end,
        })
    end

    -- `R` — request reviewers (PR only; ui.multiselect of the repo users, preselected from the set).
    local function do_reviewers()
        local m = load_model()
        if not m then
            return
        end
        if not m.is_pr then
            notify("reviewers apply to pull requests only")
            return
        end
        local users = db.users(repo_id)
        if #users == 0 then
            notify("no assignable users cached — `:LvimForge pull` first")
            return
        end
        local current = {}
        for _, r in ipairs(m.reviewers) do
            current[r] = true
        end
        local items = {}
        for _, u in ipairs(users) do
            items[#items + 1] = { label = u.login, login = u.login, checked = current[u.login] or nil }
        end
        ui.multiselect({
            title = "Reviewers",
            items = items,
            callback = function(confirmed, selected)
                if not confirmed then
                    return
                end
                local logins = {}
                for _, it in ipairs(items) do
                    if selected[it] then
                        logins[#logins + 1] = it.login
                    end
                end
                actions.set_reviewers(root, number, logins, mut_cb("reviewers"))
            end,
        })
    end

    -- `M` — milestone (ui.select of the repo milestones + a "None" row; current preselected).
    local function do_milestone()
        local m = load_model()
        if not m then
            return
        end
        local mss = db.milestones(repo_id)
        local items = { { label = "(none)", number = nil } }
        local current_item
        for _, ms in ipairs(mss) do
            local it = { label = ms.title or ("#" .. tostring(ms.number or "?")), number = ms.number }
            items[#items + 1] = it
            if m.milestone and ms.id == m.milestone.id then
                current_item = it
            end
        end
        ui.select({
            title = "Milestone",
            items = items,
            current_item = current_item,
            callback = function(confirmed, idx)
                if not confirmed or not idx then
                    return
                end
                local it = items[idx]
                actions.set_milestone(root, number, it and it.number, mut_cb("milestone"))
            end,
        })
    end

    -- ── the help window (canonical cheatsheet — lists later-phase keys too) ───
    local function show_help()
        ui.help({
            title = "Forge topic keymaps",
            items = {
                { "j / k", "next / previous line" },
                { "]] / [[", "next / previous section" },
                { "<CR>", "fold a section · diff the file under the cursor" },
                { "l / h", "expand / collapse the fold under the cursor" },
                { "B", "browse the topic on the web" },
                { "Y", "yank the topic URL" },
                { "c / e / E", "comment / edit post (author-gated) / edit title" },
                { "L / A / M / R", "labels / assignees / milestone / reviewers" },
                { "s", "close / reopen" },
                { "m / W", "merge (transient) / draft toggle" },
                { "o / O", "checkout the PR / in a worktree" },
                { "d", "full PR diff base…head" },
                { "v", "review workspace (threads on the diff)" },
                { "t / T", "marks / private note (later)" },
                { "?", "dispatch (all commands)" },
                { "g?", "this help" },
                { "q / <Esc>", "close" },
            },
            close_keys = { "q", "<Esc>" },
        })
    end

    --- `?` — open the dispatch, SCOPED to this topic so it offers the topic verbs (merge / edit / review)
    --- alongside the global views. The live PR gating data (mergeable / review-decision) rides along so the
    --- dispatch's merge action opens the merge transient with the right selection.
    local function do_dispatch()
        local topic = { root = root, number = number }
        local m = load_model()
        if m then
            topic.kind = m.topic and m.topic.kind
            topic.is_pr = m.is_pr
            topic.state = m.topic and m.topic.state
            if m.pr then
                topic.pullreq = { mergeable = m.pr.mergeable, review_decision = m.pr.review_decision }
            end
        end
        require("lvim-forge.ui.dispatch").open({ root = root, topic = topic })
    end

    -- ── keymaps ──────────────────────────────────────────────────────────────
    local function build_keymaps()
        return {
            { key = "?", run = do_dispatch },
            {
                key = "]]",
                run = function()
                    jump_section(1)
                end,
            },
            {
                key = "[[",
                run = function()
                    jump_section(-1)
                end,
            },
            { key = "B", run = do_browse },
            { key = "Y", run = do_yank },
            { key = "g?", run = show_help },
            -- composer + mutations (Phase 6 — live)
            { key = "c", run = do_comment },
            { key = "e", run = do_edit },
            { key = "E", run = do_edit_title },
            { key = "L", run = do_labels },
            { key = "A", run = do_assignees },
            { key = "M", run = do_milestone },
            { key = "R", run = do_reviewers },
            { key = "s", run = do_state },
            -- actions
            { key = "m", run = do_merge },
            {
                key = "o",
                run = function()
                    do_checkout(false)
                end,
            },
            {
                key = "O",
                run = function()
                    do_checkout(true)
                end,
            },
            { key = "d", run = do_full_diff },
            { key = "W", run = do_draft },
            { key = "t", run = stub_marks },
            { key = "T", run = stub_note },
            -- review workspace (Phase 9 — live)
            { key = "v", run = do_review },
        }
    end

    -- ── the border-title subtitle (repo band) ────────────────────────────────
    ---@return table[]
    local function subtitle()
        local r = db.repository(repo_id) or repo_row
        local segs = { ("%s/%s"):format(r.owner, r.name), r.host }
        local pulled = rel_date(r.pulled_at)
        if pulled ~= "" then
            segs[#segs + 1] = "pulled " .. pulled
        end
        return { { icon = GLYPH.repo, text = table.concat(segs, " " .. GLYPH.arrow .. " "), hl = "LvimForgeAuthor" } }
    end

    -- ── autocmds (refresh from the DB on the sync events, for THIS repo + topic) ──
    local function setup_autocmds()
        if st.augroup then
            pcall(api.nvim_del_augroup_by_id, st.augroup)
        end
        st.augroup = api.nvim_create_augroup("lvim-forge.topic", { clear = true })
        local mine = { [("%s/%s"):format(repo_row.owner, repo_row.name)] = true }
        if type(root) == "string" and root ~= "" then
            mine[root] = true
        end
        api.nvim_create_autocmd("User", {
            group = st.augroup,
            pattern = { "LvimForgeTopicChanged", "LvimForgePullDone" },
            callback = function(ev)
                local d = ev.data
                -- Refresh when the event has no root (unknown), or names THIS repo. A TopicChanged for a
                -- DIFFERENT number in the same repo still re-reads (cheap, and keeps meta chips fresh).
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

    -- ── footer: the action bar (how-build-panels canon) — the key legend as chips, kind-aware (the PR-only
    -- verbs appear only on a pull request), always ending in `g? help ● q close` so the panel is never a
    -- dead-end without a visible way out. ──
    local function build_footer()
        local function chip(key, label, run)
            return { key = key, label = label, no_hotkey = true, run = run }
        end
        local sep = { type = "separator", text = GLYPH.dot, style = { padding = { 1, 1 }, hl = "LvimUiFooterSep" } }
        local topic = db.get_topic(repo_id, number, opts.kind)
        local is_pr = topic and topic.kind == "pullreq"
        local f = { chip("c", "comment", do_comment), chip("e", "edit", do_edit), chip("s", "state", do_state) }
        if is_pr then
            f[#f + 1] = sep
            f[#f + 1] = chip("m", "merge", do_merge)
            f[#f + 1] = chip("d", "diff", do_full_diff)
            f[#f + 1] = chip("v", "review", do_review)
        end
        f[#f + 1] = sep
        f[#f + 1] = chip("g?", "help", show_help)
        f[#f + 1] = chip("q", "close", function(handle)
            handle.close()
        end)
        return f
    end

    st.tabs = {
        { label = "Topic", icon = GLYPH.repo, menu = true, rows = build_rows(), footer = build_footer() },
    }

    if is_tab then
        workspace.enter(VIEW)
    end

    st.handle = ui.tabs({
        title = { icon = GLYPH.repo, text = ("Forge #%d"):format(number) },
        title_pos = "center",
        subtitle = subtitle,
        tabs = st.tabs,
        layout = is_tab and "float" or layout,
        slot = is_tab and workspace.slot() or nil,
        pad = 0,
        cursorline_hl = "LvimUiCursorLine",
        close_keys = { "q", "<Esc>" },
        keymaps = build_keymaps(),
        on_open = function()
            setup_autocmds()
        end,
        callback = function()
            teardown()
            state.panels[view_key] = nil
            if is_tab then
                workspace.exit(VIEW)
            end
            -- Opened from the topic list (the Magit `RET` drill-in): closing RETURNS to the list, not the code
            -- underneath — reopen it (it rebuilds instantly from the DB + the session-sticky filter/layout).
            -- Scheduled so this topic's teardown + workspace-exit settle first.
            if opts.from_list then
                vim.schedule(function()
                    require("lvim-forge.ui.topics").open({})
                end)
            end
        end,
    })

    if not st.handle then
        if is_tab then
            workspace.exit(VIEW)
        end
        return
    end

    -- The on-open detail pull: render the cache NOW, fetch THIS topic's full detail in the background
    -- (forced when it is not cached yet, so the buffer fills in), and refresh on LvimForgeTopicChanged.
    local cached = db.get_topic(repo_id, number, opts.kind) ~= nil
    sync.pull_topic(root, number, { force = not cached })

    state.panels[view_key] = {
        repo_id = repo_id,
        number = number,
        handle = st.handle,
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

--- Diff a PR file via the lvim-git seam (soft dependency). For a PR it fetches the PR head and scopes the
--- lvim-git diffview to that file over the `base...head` range; for a non-PR (or when the base ref / git
--- root is unknown) it falls back to the working-tree diff of the path. Degrades to a clean notify when
--- lvim-git is absent.
---@param root? string
---@param m table   the topic model (m.pr carries base_ref; m.topic.number the PR number)
---@param f table   a pr_files row
function M._diff_file(root, m, f)
    local path = f and f.path
    if not path then
        return
    end
    local ok_git, diff = pcall(require, "lvim-git.ui.diff")
    if not ok_git or type(diff.open) ~= "function" then
        notify("diffing " .. path .. " needs lvim-git (not installed)")
        return
    end
    local pr = m and m.pr
    local number = m and m.topic and m.topic.number
    if not (m and m.is_pr and pr and pr.base_ref and number) then
        -- Non-PR / missing base ref → the working-tree scoped diff (best effort).
        pcall(diff.open, { paths = { path } })
        return
    end
    local detected = require("lvim-forge.client").detect(root)
    local git_root = detected and detected.root
    if not git_root then
        pcall(diff.open, { paths = { path } })
        return
    end
    local remote = (detected and detected.remote) or "origin"
    local git = require("lvim-forge.git")
    local stable = ("refs/forge/pr/%d"):format(number)
    -- Fetch the PR head, then diff the file over base...head; a failed fetch falls back to the working diff.
    git.fetch_ref(git_root, remote, ("pull/%d/head:%s"):format(number, stable), function(fok)
        if fok then
            local range = ("%s/%s...%s"):format(remote, pr.base_ref, stable)
            pcall(diff.open, { range = range, paths = { path } })
        else
            pcall(diff.open, { paths = { path } })
        end
    end)
end

--- Whether the topic buffer is open.
---@return boolean
function M.is_open()
    local rec = state.panels[VIEW]
    return rec ~= nil and rec.handle ~= nil and rec.handle.valid and rec.handle.valid()
end

--- Close the topic buffer (no-op when closed).
function M.close()
    local rec = state.panels[VIEW]
    if rec and rec.close then
        rec.close()
    end
end

return M
