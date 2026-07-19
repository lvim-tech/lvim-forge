-- lvim-forge.ui.section: the SOFT lvim-git status-buffer integration — a trailing "Forge" section listing
-- this repo's open pull requests, assigned issues, and review requests.
--
-- It self-registers with lvim-git's Phase-0 hook `require("lvim-git.ui.status").register_section(provider)`
-- ONLY when lvim-git is installed (pcall). Without lvim-git there is no section and no error — the topic
-- list is the entry point instead. The provider renders through the SAME `ui.section` fold machinery as
-- lvim-git's built-in submodules / sparse sections, so it is folded, navigated and themed uniformly (and
-- its rows are inert to lvim-git's s/u/x staging, per the Phase-0 `ext-section` guarantee).
--
-- `rows(root)` is SYNCHRONOUS and RENDER-SAFE (a DB read only — the status surface calls it on every
-- rebuild). It resolves the tracked repo for `root`, returns nil for an untracked / undetectable root (the
-- section simply hides, content-gated), and otherwise returns: a header row
-- `<N> open pull requests ➤ <M> assigned issues ➤ <K> review requests` + the top few rows per bucket
-- (`config.status_section.max_rows`, deduped), each row carrying its topic number so `<CR>` / click opens
-- the lvim-forge topic buffer.
--
-- The "assigned" / "review-requested" buckets are viewer-relative, so they need the authenticated login.
-- It is read from `state.viewer` (the shared lazy cache the topics list also fills); when unknown, a ONE-TIME
-- background probe resolves it (never on the render path — fire-and-forget) and then nudges a status rebuild,
-- so those buckets fill in on the next paint. The probe is gated on `config.pull.on_open` (offline mode makes
-- no network from a status render — the open-PRs bucket is viewer-independent and still shows).
--
-- Refresh: on `User LvimForgePullDone` / `LvimForgeTopicChanged` the section re-renders IF the status view is
-- open — via lvim-git's own `require("lvim-git.ui.status").refresh()` (the view's rebuild path, self-gated on
-- `is_open`; our pull touched only the DB, not the working tree, so this is the precise seam rather than the
-- `refresh(root)` external-change facade). Registration is guarded so it happens once.
--
---@module "lvim-forge.ui.section"

local config = require("lvim-forge.config")
local db = require("lvim-forge.db")
local state = require("lvim-forge.state")

local M = {}

-- ── glyphs (verified single-width Nerd Font, + the `➤` separator canon) ─────────
local GLYPH = {
    pull = config.icons.pull or "\u{f407}", --  git pull request
    issue = config.icons.issue or "\u{f41b}", --  issue
    arrow = "➤", -- the count-group / segment separator (the pointer canon)
}

---@type boolean  guards the one-time register + autocmd wiring
local registered = false

---@type table<string, boolean>  per-host guard so the background viewer probe runs at most once in flight
local viewer_inflight = {}

--- Kick a ONE-TIME background probe for the authenticated viewer login, then nudge a status rebuild so the
--- assigned / review buckets resolve. Never blocks; guarded per host + gated on `config.pull.on_open`
--- (offline mode makes no network from a passive status render). Forge-blind — the backend is resolved via
--- the dispatch seam, so any forge exposing a `viewer` read participates.
---@param repo table    the tracked repo row (`{ id, forge, host, owner, name }`)
---@param detect table  the detect result (`{ root, ... }`)
local function ensure_viewer(repo, detect)
    local host = repo.host
    if not host or state.viewer[host] or viewer_inflight[host] then
        return
    end
    if config.pull and config.pull.on_open == false then
        return
    end
    local backend = require("lvim-forge.client").backend(repo.forge)
    if not backend or type(backend.viewer) ~= "function" then
        return
    end
    -- Claim the probe SYNCHRONOUSLY so a burst of rebuilds only ever schedules it once...
    viewer_inflight[host] = true
    -- ...but run it OFF the render path. `rows()` is called while the lvim-git status panel is PAINTING, and
    -- resolving a transport asks `auth.cli_authed`, whose FIRST call is a blocking CLI `auth status`
    -- (measured ~700 ms for `gh`) — running that inline stalled the whole panel behind this fire-and-forget
    -- probe. Deferring a tick, and warming the CLI-auth cache asynchronously before touching the transport,
    -- honours what this probe already documents about itself: never on the render path.
    vim.schedule(function()
        require("lvim-forge.client.auth").prewarm_cli(repo.forge, function()
            local dt = require("lvim-forge.client.detect")
            backend.viewer({
                owner = repo.owner,
                name = repo.name,
                forge = repo.forge,
                host = host,
                base = dt.api_base(repo.forge, host),
                root = detect.root,
            }, function(login)
                viewer_inflight[host] = nil
                if not login then
                    return
                end
                state.viewer[host] = login
                vim.schedule(function()
                    local ok2, st = pcall(require, "lvim-git.ui.status")
                    if ok2 and type(st.is_open) == "function" and st.is_open() and type(st.refresh) == "function" then
                        pcall(st.refresh)
                    end
                end)
            end)
        end)
    end)
end

--- The section's summary header row (an inert leaf — no navigation).
---@param np integer
---@param na integer
---@param nk integer
---@return table
local function header_row(np, na, nk)
    local function plural(n, word)
        return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
    end
    local text = ("%s %s %s %s %s"):format(
        plural(np, "open pull request"),
        GLYPH.arrow,
        plural(na, "assigned issue"),
        GLYPH.arrow,
        plural(nk, "review request")
    )
    return {
        type = "action",
        name = "forge:summary",
        flat = true,
        tight = true,
        icon = " " .. GLYPH.pull .. " ",
        icon_hl = "LvimForgeNumber",
        label = text,
        text_hl = "LvimForgeMeta",
        run = function() end,
    }
end

--- One topic row (`#number  title`), opening the lvim-forge topic buffer on `<CR>` / click.
---@param root string|integer
---@param t table  a `db.topics` row (`{ id, kind, number, title, state, draft }`)
---@return table
local function topic_row(root, t)
    local is_pr = t.kind == "pullreq"
    local icon_hl = "LvimForgeOpen"
    if t.state == "merged" then
        icon_hl = "LvimForgeMerged"
    elseif t.state == "closed" then
        icon_hl = "LvimForgeClosed"
    elseif is_pr and t.draft == 1 then
        icon_hl = "LvimForgeDraft"
    end
    return {
        type = "action",
        name = ("forge:%s:%d"):format(t.kind, t.number),
        flat = true,
        tight = true,
        icon = " " .. (is_pr and GLYPH.pull or GLYPH.issue) .. " ",
        icon_hl = icon_hl,
        label = ("#%d  %s"):format(t.number, t.title or ""),
        text_hl = "LvimForgeTitle",
        run = function()
            require("lvim-forge.ui.topic").open(root, t.number, { kind = t.kind })
        end,
    }
end

--- PUBLIC (to lvim-git via the hook): the section's child rows for `root`. SYNCHRONOUS + render-safe (a DB
--- read only). Returns nil for an untracked / undetectable root (the section hides) or when every bucket is
--- empty; otherwise the header + the top rows per bucket (deduped across buckets).
---@param root string  the status view's repo root
---@return table[]?
function M.rows(root)
    if not db.available() then
        return nil
    end
    local detect = require("lvim-forge.client").detect(root)
    local repo = detect and db.repo_for_detect(detect)
    if not detect or not repo then
        return nil
    end

    local viewer = repo.host and state.viewer[repo.host]
    if not viewer then
        ensure_viewer(repo, detect) -- background, once; the buckets fill in on the next rebuild
    end

    local open_prs = db.topics(repo.id, { kind = "pullreq", state = "open" })
    local assigned = viewer and db.topics(repo.id, { kind = "issue", state = "open", assignee = viewer }) or {}
    local reviews = viewer and db.topics(repo.id, { kind = "pullreq", state = "open", reviewer = viewer }) or {}

    if #open_prs == 0 and #assigned == 0 and #reviews == 0 then
        return nil -- nothing to show → the section hides (no header-only ghost)
    end

    local max = (config.status_section and config.status_section.max_rows) or 5
    local children = { header_row(#open_prs, #assigned, #reviews) }
    local seen = {}
    --- Append up to `max` NEW (not-yet-listed) rows from a bucket.
    ---@param list table[]
    local function add_bucket(list)
        local n = 0
        for _, t in ipairs(list) do
            if n >= max then
                break
            end
            if not seen[t.id] then
                seen[t.id] = true
                children[#children + 1] = topic_row(root, t)
                n = n + 1
            end
        end
    end
    add_bucket(open_prs)
    add_bucket(assigned)
    add_bucket(reviews)
    return children
end

--- Register the Forge status section with lvim-git (once), IF lvim-git is installed and the component is
--- enabled. Fully degrades (no section, no error) when lvim-git's hook is absent. Also wires the refresh
--- nudge so the section re-renders on a pull / topic change while the status view is open.
function M.setup()
    if registered then
        return
    end
    if not (config.status_section and config.status_section.enabled) then
        return
    end
    local ok, status = pcall(require, "lvim-git.ui.status")
    if not ok or type(status.register_section) ~= "function" then
        return -- lvim-git absent → no section
    end
    registered = true
    status.register_section({
        id = "forge",
        title = "Forge",
        position = "trailing",
        accent = "blue",
        rows = function(root)
            return M.rows(root)
        end,
    })

    -- Re-render the section (only while the status view is open) when the cache changes: a pull refreshes
    -- the bucket counts; a mutation (close / merge) changes what belongs in each bucket.
    local group = vim.api.nvim_create_augroup("LvimForgeSection", { clear = true })
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = { "LvimForgePullDone", "LvimForgeTopicChanged" },
        desc = "lvim-forge: refresh the lvim-git status Forge section",
        callback = function()
            local ok2, st = pcall(require, "lvim-git.ui.status")
            if ok2 and type(st.is_open) == "function" and st.is_open() and type(st.refresh) == "function" then
                pcall(st.refresh)
            end
        end,
    })
end

return M
