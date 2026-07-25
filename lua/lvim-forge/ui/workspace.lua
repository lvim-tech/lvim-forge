-- lvim-forge.ui.workspace: a thin adapter over the shared `lvim-ui.workspace` tab shell.
--
-- This module USED to be a byte-for-byte private copy of lvim-git's marker-based tab host (a sibling
-- couldn't depend on lvim-git's internal one). That host now lives ONCE in `lvim-ui.workspace`, so this is
-- a thin adapter that keeps lvim-forge's VIEW-keyed API (enter / exit / is_open / tab_for / current_view /
-- slot / focus) — every caller (topics / topic / notifications / review) is unchanged — while the tab
-- logic is shared. Each view gets its own tab, id-namespaced `lvim-forge:<view>`.
--
-- SURFACE views open their `lvim-ui` surface with `slot = M.slot()` so it FILLS the tab, and call
-- `exit(view)` from the surface's close callback.
--
-- PUBLIC: enter / exit / is_open / tab_for / current_view / slot / focus.
--
---@module "lvim-forge.ui.workspace"

local workspace = require("lvim-ui.workspace")

local M = {}

-- Every lvim-forge workspace tab is id-namespaced under this prefix in the shared shell.
local PREFIX = "lvim-forge:"

--- The shared-shell id for a view name.
---@param view string
---@return string
local function id(view)
    return PREFIX .. view
end

--- The tabpage hosting `view` (found by its shared marker), or nil.
---@param view string
---@return integer?
function M.tab_for(view)
    return workspace.tab_for(id(view))
end

--- The view hosted by the CURRENT tabpage (if it is an lvim-forge workspace), else nil.
---@return string?
function M.current_view()
    local cur = workspace.current()
    if cur and cur:sub(1, #PREFIX) == PREFIX then
        return cur:sub(#PREFIX + 1)
    end
    return nil
end

--- Whether `view` has an open workspace tab.
---@param view string
---@return boolean
function M.is_open(view)
    return workspace.is_open(id(view))
end

--- The fullscreen fill geometry — passed as `slot` to a surface opened in `tab` layout.
---@return { width: number, height: integer }
function M.slot()
    return workspace.slot()
end

--- Focus the workspace tab for `view` (no-op when it is not open).
---@param view string
function M.focus(view)
    workspace.focus(id(view))
end

--- Enter (create-or-focus) the view's tab; the caller then builds its view inside it. Returns true when
--- an existing tab was reused (the caller should refresh, not rebuild).
---@param view string
---@return boolean existing
function M.enter(view)
    local handle = workspace.open({
        id = id(view),
        editor = { name = (view:gsub("^%l", string.upper)) }, -- tabline reads "Topics" / "Notifications" / …
    })
    return handle.existing == true
end

--- Exit the view's tab: return to the origin tabpage, then close it. Idempotent + re-entry safe.
---@param view string
function M.exit(view)
    workspace.close(id(view))
end

return M
