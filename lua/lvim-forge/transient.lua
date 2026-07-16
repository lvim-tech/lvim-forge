-- lvim-forge.transient: the plugin's ONE transient seam — a THIN wrapper over the shared lvim-ui transient
-- ENGINE (`require("lvim-ui.transient").new{…}`, the Phase-0 extraction). It binds the engine to
-- lvim-forge's OWN couplings: the session-snapshot table (`state.transient`), the persisted saved-defaults
-- store (a per-plugin json store, gated on `config.transient.save_defaults`), the live default level, and
-- the repo-root resolver (the forge detect). Every verb popup in the plugin — merge (Phase 8), and the
-- later pull / create-options / review-submit / dispatch transients — `define`s its DATA and `open`s it
-- through THIS module, so there is a single engine instance + a single persisted store for the whole plugin.
--
-- The engine is the same implementation lvim-git consumes; the rendering is the shared lvim-ui `transient`
-- PRESET. This module adds NO behaviour — it only supplies the host couplings once (the `lvim-utils.store`
-- extraction pattern), then forwards `define`/`open`/`args`/`has` to the instance.
--
---@module "lvim-forge.transient"

local M = {}

--- The lazily-built engine instance (one per session). Built on first use — AFTER `setup()` has merged the
--- live config — so `save_defaults` / `level` are read from the effective config, and the json store file is
--- only ever created when persistence is enabled.
---@type LvimUiTransientEngine?
local engine

--- The lvim-forge saved-defaults store (a per-plugin json KV, the same shape lvim-git's transient uses):
--- the shared engine indexes it by "<id>@<root>". nil when `config.transient.save_defaults` is off — then
--- nothing is persisted and the store file is never created. Built once alongside the engine.
---@return table?
local function build_store()
    local config = require("lvim-forge.config")
    if not (config.transient and config.transient.save_defaults) then
        return nil
    end
    return require("lvim-utils.store").new({ backend = "json", name = "lvim-forge" })
end

--- The engine instance, built lazily on first use over lvim-forge's own state/store + live config.
---@return LvimUiTransientEngine
local function get_engine()
    if engine then
        return engine
    end
    local config = require("lvim-forge.config")
    local state = require("lvim-forge.state")
    engine = require("lvim-ui.transient").new({
        name = "lvim-forge",
        state = state.transient, -- the per-prefix session snapshots (Phase-0 parameterization)
        store = build_store(), -- persisted saved defaults (per-repo), or nil
        level = function()
            return (config.transient and config.transient.level) or 4
        end,
        layout = "float", -- the modal verb popup (the merge/pull/… popups are centered floats)
        min_level = 1,
        max_level = 7,
        -- Resolve the repo root when a caller opens without an explicit `ctx.root` — the forge detect.
        resolve_root = function(ctx)
            local ok, client = pcall(require, "lvim-forge.client")
            if not ok then
                return nil
            end
            local target = (ctx and ctx.root) or (ctx and ctx.buf) or 0
            local d = client.detect(target)
            return d and d.root or nil
        end,
    })
    return engine
end

--- Register (or replace) a transient definition (a verb popup's DATA: groups of infixes + actions).
---@param def LvimUiTransientDef
function M.define(def)
    get_engine():define(def)
end

--- Whether a transient id is registered.
---@param id string
---@return boolean
function M.has(id)
    return get_engine():has(id)
end

--- The registered def for an id (nil when unknown) — introspection for the dispatch (which builds its groups
--- from the live caps/topic) and for tests.
---@param id string
---@return LvimUiTransientDef?
function M.def(id)
    return get_engine():def(id)
end

--- The assembled argv for a prefix's SESSION default (invoke a verb WITHOUT opening the popup).
---@param id string
---@param root? string
---@return string[]
function M.args(id, root)
    return get_engine():args(id, root)
end

--- Open a transient prefix's popup (the shared lvim-ui `transient` preset renders it). `ctx` carries the
--- invoking scope forwarded verbatim to the engine: `root` (the repo root), an optional `selection` (the
--- thing the actions operate on — a PR for the merge transient), and any extra `args`.
---@param id string
---@param ctx? table  `{ root?, buf?, lens?, args?, selection? }` — passed straight to the engine's `open`
function M.open(id, ctx)
    get_engine():open(id, ctx)
end

return M
