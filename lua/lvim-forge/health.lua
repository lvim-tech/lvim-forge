-- lvim-forge: :checkhealth lvim-forge.
-- Reports what makes a forge client silently misbehave: the API transport binaries (curl required; gh /
-- glab optional but preferred), each forge's resolved transport + token SOURCE (never the token itself),
-- the ecosystem deps the panels are built on, the optional lvim-git seam, the current buffer's forge
-- detection, the persistence backend (sqlite, for the topic cache), the enabled-components report, and a
-- Public-API self-check. Read-only — never mutates state, never logs a secret.
--
---@module "lvim-forge.health"

local config = require("lvim-forge.config")
local auth = require("lvim-forge.client.auth")

local M = {}

--- The version of an executable as `major*100 + minor`, or 0 when absent / unparseable.
---@param cmd string
---@param arg string
---@return integer
local function version(cmd, arg)
    if vim.fn.executable(cmd) ~= 1 then
        return 0
    end
    local ok, out = pcall(vim.fn.systemlist, { cmd, arg })
    local maj, min = ((ok and out and out[1]) or ""):match("(%d+)%.(%d+)")
    return (maj and tonumber(maj) * 100 + tonumber(min)) or 0
end

--- The forge families with a component/auth footprint, for the per-forge transport + token report.
---@type string[]
local FORGES = { "github", "gitlab", "gitea", "codeberg" }

--- The components that carry an `enabled` flag, for the enabled-report.
---@type string[]
local COMPONENTS = { "topics", "topic", "review", "notifications", "status_section", "completion" }

--- Run the health report.
function M.check()
    local health = vim.health
    health.start("lvim-forge")

    -- Neovim.
    if vim.fn.has("nvim-0.10") == 1 then
        health.ok("Neovim >= 0.10 (vim.system, vim.uv, vim.json)")
    else
        health.error("Neovim >= 0.10 is required")
    end

    -- Transport binaries.
    local cv = version("curl", "--version")
    if cv == 0 then
        health.error("curl not found on PATH — the REST transport (and the gitea/codeberg path) cannot run")
    else
        health.ok(("curl %d.%d (REST transport)"):format(math.floor(cv / 100), cv % 100))
    end
    local gv = version("gh", "--version")
    if gv == 0 then
        health.info("gh not found — the GitHub CLI transport is unavailable (REST/curl is used instead)")
    else
        local authed = auth.cli_authed("github")
        if authed then
            health.ok(("gh %d.%d — authenticated (CLI transport available)"):format(math.floor(gv / 100), gv % 100))
        else
            health.info(
                ("gh %d.%d found but NOT authenticated (`gh auth login`) — REST/curl is used"):format(
                    math.floor(gv / 100),
                    gv % 100
                )
            )
        end
    end
    local lv = version("glab", "--version")
    if lv == 0 then
        health.info("glab not found — the GitLab CLI transport is unavailable (REST/curl is used instead)")
    else
        local authed = auth.cli_authed("gitlab")
        if authed then
            health.ok(("glab %d.%d — authenticated (CLI transport available)"):format(math.floor(lv / 100), lv % 100))
        else
            health.info(
                ("glab %d.%d found but NOT authenticated (`glab auth login`) — REST/curl is used"):format(
                    math.floor(lv / 100),
                    lv % 100
                )
            )
        end
    end

    -- Gitea/Forgejo/Codeberg have no raw-API-passthrough CLI (transport is always REST/curl); the `tea`
    -- CLI is OPTIONAL and only consulted for a login token when `config.auth.gitea.tea` is set.
    local tv = version("tea", "--version")
    if tv == 0 then
        health.info("tea not found — optional (only read for a gitea/codeberg token when auth.gitea.tea = true)")
    elseif config.auth and config.auth.gitea and config.auth.gitea.tea then
        health.ok(
            ("tea %d.%d — logins read for a gitea/codeberg token (auth.gitea.tea = true)"):format(
                math.floor(tv / 100),
                tv % 100
            )
        )
    else
        health.info(
            ("tea %d.%d found — set auth.gitea.tea = true to read its logins for a token"):format(
                math.floor(tv / 100),
                tv % 100
            )
        )
    end

    -- Ecosystem deps.
    local ok_ui = pcall(require, "lvim-ui.surface")
    local ok_utils, hl = pcall(require, "lvim-utils.highlight")
    if ok_ui and ok_utils and type(hl.blend) == "function" then
        health.ok("lvim-ui + lvim-utils found (surface chassis + palette)")
    else
        health.error("lvim-ui / lvim-utils not found — the panels cannot render")
    end
    if pcall(require, "lvim-ui.transient") then
        health.ok("lvim-ui.transient engine found (the verb popups)")
    else
        health.warn("lvim-ui.transient engine not found — the verb transients are unavailable")
    end
    if pcall(require, "lvim-utils.icons") then
        health.ok("lvim-utils.icons found (file devicons in rows)")
    else
        health.info("lvim-utils.icons unavailable — rows show no file icons")
    end
    if pcall(require, "lvim-git.browse") then
        health.ok("lvim-git found — remote parsing + diff/refresh seams used (soft dep)")
    else
        health.info("lvim-git not found — using the bundled remote parser (diff hand-off degrades)")
    end

    -- Persistence backend (the topic cache — MANDATORY; the DB is the plugin).
    local ok_store, store = pcall(require, "lvim-utils.store")
    if ok_store and type(store.health) == "function" then
        store.health(health, true)
    elseif ok_store and store.available and store.available() then
        health.ok("sqlite backend available (topic cache)")
    else
        health.error("lvim-utils.store / sqlite.lua not found — the topic cache (mandatory) is unavailable")
    end

    -- The local database: file path, on-disk schema version, tracked-repo count.
    local ok_db, db = pcall(require, "lvim-forge.db")
    if ok_db then
        if db.available() and db.is_open() then
            health.ok(("database: %s (schema v%d)"):format(db.path() or "?", db.schema_version()))
            health.info(("tracked repositories: %d"):format(db.repo_count()))
            -- Last-pull watermark per tracked repo (the sync engine's cursor/pulled_at) — a never-pulled
            -- tracked repo is a hint to run `:LvimForge pull`.
            for _, r in ipairs(db.repositories()) do
                if r.pulled_at and r.pulled_at ~= "" then
                    health.info(
                        ("  %s/%s — last pull %s (topics cursor: %s)"):format(
                            r.owner,
                            r.name,
                            r.pulled_at,
                            r.topics_cursor or "none"
                        )
                    )
                else
                    health.info(("  %s/%s — never pulled (`:LvimForge pull`)"):format(r.owner, r.name))
                end
            end
        elseif not db.available() then
            health.error("the local database cannot open — sqlite.lua is required")
        else
            health.warn(("database file is not writable: %s"):format(db.path() or "?"))
        end
    end

    -- Current-buffer forge detection.
    local ok_client, client = pcall(require, "lvim-forge.client")
    if ok_client then
        local d = client.detect(0)
        if d then
            local mode = client.resolve_transport(d.forge, d.host)
            health.ok(
                ("forge detected: %s/%s on %s (%s) — transport: %s"):format(d.owner, d.name, d.host, d.forge, mode)
            )
        else
            health.info("current buffer is not inside a tracked forge repository")
        end
    end

    -- Per-forge transport pick + token SOURCE (never the token).
    for _, forge in ipairs(FORGES) do
        local mode = client and client.resolve_transport(forge)
        if mode == "cli" then
            health.info(("%s: transport = cli (the CLI owns its auth)"):format(forge))
        else
            -- REST: report where a token WOULD come from (probes the default host for the family).
            local host = ({ github = "github.com", gitlab = "gitlab.com", codeberg = "codeberg.org" })[forge]
                or (forge .. ".example")
            local source = auth.source(forge, host)
            if source == "none" then
                health.info(("%s: transport = rest, no token found (public reads only, rate-limited)"):format(forge))
            else
                health.ok(("%s: transport = rest, token source = %s"):format(forge, source))
            end
        end
    end

    -- Enabled-components report.
    local enabled = {}
    for _, name in ipairs(COMPONENTS) do
        local c = config[name]
        if type(c) == "table" and c.enabled then
            enabled[#enabled + 1] = name
        end
    end
    health.info("enabled components: " .. (next(enabled) and table.concat(enabled, ", ") or "none"))

    -- Public-API self-check: the facade accessors resolve.
    local api = require("lvim-forge")
    local missing = {}
    for _, fn in ipairs({ "setup", "topics", "topic", "review", "notifications", "dispatch", "pull", "request" }) do
        if type(api[fn]) ~= "function" then
            missing[#missing + 1] = fn
        end
    end
    if #missing == 0 then
        health.ok("public API surface present (facade accessors resolve)")
    else
        health.error("public API missing: " .. table.concat(missing, ", "))
    end

    -- Config sanity.
    if not vim.tbl_contains({ "auto", "cli", "rest" }, config.transport) then
        health.error('transport must be "auto", "cli" or "rest"')
    elseif not vim.tbl_contains({ "6m", "1y", "all" }, config.pull.closed_since) then
        health.warn('pull.closed_since should be "6m", "1y" or "all"')
    else
        health.ok("config valid")
    end
end

return M
