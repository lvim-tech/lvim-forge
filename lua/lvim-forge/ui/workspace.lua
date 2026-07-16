-- lvim-forge.ui.workspace: the dedicated-TABPAGE host for the heavy forge views (`layout = "tab"`).
--
-- A `tab` open moves a whole forge view (the topic list, later the topic buffer / review workspace) into
-- its OWN fullscreen tabpage — never over your code. This is lvim-forge's OWN clone of lvim-git's
-- marker-based host: the plan mandates a private copy (lvim-git's host is lvim-git-internal, so a sibling
-- must not depend on it). It owns ONLY the tab lifecycle (create / find / close + return-focus); the view
-- builds ITS surface inside the tab exactly as it does in float/area/bottom.
--
-- The tab is marked with a tab-scoped var (`t:lvim_forge_workspace = <view>`) and ALWAYS found by that
-- marker, NEVER by a stored handle — a stray `:tabclose` from elsewhere can't dangle it. Only the ORIGIN
-- tab (where focus returns on close) is remembered, in `state.workspace[view]`. The view's own module keeps
-- the DATA (filters / selection), so a `close`→reopen restores the workspace as it was left — only the
-- windows are torn down, the model persists.
--
-- SURFACE views open their normal `lvim-ui` surface with `slot = M.slot()` so the centred float FILLS the
-- empty tab (fullscreen), and call `exit(view)` from the surface's close callback.
--
-- PUBLIC: enter / exit / is_open / tab_for / current_view / slot / focus.
--
---@module "lvim-forge.ui.workspace"

local api = vim.api
local state = require("lvim-forge.state")

local M = {}

--- The tab-scoped marker var; its value is the hosted VIEW name.
---@type string
local MARK = "lvim_forge_workspace"

--- Re-entry guard for `exit` (closing the tab fires the hosted surface's close callback, which calls
--- `exit` again — the guard makes the second call a no-op instead of chasing an already-gone tab).
---@type table<string, boolean>
local exiting = {}

--- The tabpage hosting `view`, found by its marker var (never a cached handle). nil when not open.
---@param view string
---@return integer? tabpage
function M.tab_for(view)
    for _, t in ipairs(api.nvim_list_tabpages()) do
        local ok, v = pcall(api.nvim_tabpage_get_var, t, MARK)
        if ok and v == view then
            return t
        end
    end
    return nil
end

--- The view hosted by the CURRENT tabpage (if it is a workspace), else nil.
---@return string? view
function M.current_view()
    local ok, v = pcall(api.nvim_tabpage_get_var, api.nvim_get_current_tabpage(), MARK)
    return (ok and type(v) == "string") and v or nil
end

--- Whether `view` has an open workspace tab.
---@param view string
---@return boolean
function M.is_open(view)
    return M.tab_for(view) ~= nil
end

--- The per-open ANCHORED geometry override that makes a centred-float surface FILL the workspace tab
--- (near-full width/height). Passed as `opts.slot` to `lvim-ui.tabs` by the surface-based views when they
--- open in `tab` layout.
---@return { width: number, height: number }
function M.slot()
    return { width = 0.98, height = 0.96 }
end

--- Focus the workspace tab for `view` (no-op when it is not open).
---@param view string
function M.focus(view)
    local t = M.tab_for(view)
    if t and api.nvim_tabpage_is_valid(t) then
        api.nvim_set_current_tabpage(t)
    end
end

--- Enter the workspace tab for `view`: switch to the existing one, or create a fresh dedicated tabpage,
--- mark it, park a scratch buffer in its window and remember the origin tab. The caller then builds its
--- view (a surface float with `M.slot()`) in the now-current tab.
---@param view string
---@return boolean existing  true when an existing workspace tab was reused (the caller should refresh, not rebuild)
function M.enter(view)
    local existing = M.tab_for(view)
    if existing and api.nvim_tabpage_is_valid(existing) then
        api.nvim_set_current_tabpage(existing)
        return true
    end
    state.workspace[view] = { origin_tab = api.nvim_get_current_tabpage() }
    vim.cmd("tabnew")
    local tab = api.nvim_get_current_tabpage()
    api.nvim_tabpage_set_var(tab, MARK, view)
    -- A throwaway scratch buffer as the tab's background (so a fill-slot surface float has a clean,
    -- code-free backdrop rather than a real [No Name] buffer).
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    pcall(api.nvim_win_set_buf, api.nvim_get_current_win(), buf)
    return false
end

--- Exit the workspace tab for `view`: return to the origin tabpage, then close the workspace tab. Found by
--- its marker, so it is robust to a stray `:tabclose`. Idempotent + re-entry safe (the hosted surface's
--- close callback re-enters this).
---@param view string
function M.exit(view)
    if exiting[view] then
        return
    end
    exiting[view] = true
    local t = M.tab_for(view)
    local origin = (state.workspace[view] or {}).origin_tab
    if t and api.nvim_tabpage_is_valid(t) then
        -- Leave the tab BEFORE closing it so focus lands where the user came from (not nvim's default
        -- neighbour) when the workspace tab is the current one.
        if api.nvim_get_current_tabpage() == t and origin and api.nvim_tabpage_is_valid(origin) then
            pcall(api.nvim_set_current_tabpage, origin)
        end
        pcall(function()
            vim.cmd(api.nvim_tabpage_get_number(t) .. "tabclose")
        end)
    end
    if origin and api.nvim_tabpage_is_valid(origin) and api.nvim_get_current_tabpage() ~= origin then
        pcall(api.nvim_set_current_tabpage, origin)
    end
    state.workspace[view] = nil
    exiting[view] = nil
end

return M
