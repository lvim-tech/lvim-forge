-- lvim-forge.client.auth: resolve the API token for a forge/host, and probe whether the forge CLI
-- (gh/glab) is installed AND authenticated. Two independent concerns the client seam needs:
--
--   * REST transport (curl) needs a TOKEN. Resolution order (first hit wins, reported by health,
--     NEVER persisted / logged): (1) `config.auth.<forge>.token` (a string OR a function returning one,
--     so the user can shell out to a secret manager without us building one); (2) the env var
--     `config.auth.<forge>.env` (GITHUB_TOKEN / GITLAB_TOKEN / …, per-forge overridable for enterprise);
--     (3) `~/.netrc` (`machine <host> … password <token>`) when `config.auth.netrc`; (4) for gitea the
--     `tea` CLI logins when `config.auth.gitea.tea`.
--   * CLI transport (gh/glab api) needs NO token from us — the CLI owns its auth. We only PROBE it once
--     (a `gh auth status` / `glab auth status` exit code, cached) so the "auto" transport can pick it.
--
-- The resolver returns the SOURCE (env / config / netrc / tea) alongside the token so health can report
-- WHERE a token came from without ever exposing the token itself.
--
---@module "lvim-forge.client.auth"

local config = require("lvim-forge.config")
local state = require("lvim-forge.state")
local runner = require("lvim-forge.client.runner")

local M = {}

--- The CLI executable per forge (gitea/codeberg have no raw-API-passthrough CLI → nil).
---@type table<string, string>
local CLI = { github = "gh", gitlab = "glab" }

--- The `auth status` argv per CLI (both exit non-zero when not logged in).
---@type table<string, string[]>
local CLI_STATUS = {
    gh = { "gh", "auth", "status" },
    glab = { "glab", "auth", "status" },
}

--- The forge CLI name for a forge, or nil (gitea/codeberg).
---@param forge string
---@return string?
function M.cli_for(forge)
    return CLI[forge]
end

--- Probe (once, cached) whether the forge's CLI is installed AND authenticated. Runs a synchronous
--- `auth status` the FIRST time only (off any render path — called from transport resolution / health),
--- then caches the boolean in `state.cli_auth`. Returns false for a forge with no CLI (gitea/codeberg).
---@param forge string
---@return boolean
function M.cli_authed(forge)
    if state.cli_auth[forge] ~= nil then
        return state.cli_auth[forge]
    end
    local cli = CLI[forge]
    local authed = false
    if cli and vim.fn.executable(cli) == 1 then
        local res = runner.run_sync(CLI_STATUS[cli], 4000)
        authed = res ~= nil and res.code == 0
    end
    state.cli_auth[forge] = authed
    return authed
end

--- Warm the `cli_authed` cache ASYNCHRONOUSLY, then call `cb`. `cli_authed` otherwise runs a BLOCKING
--- `auth status` the first time it is asked — measured ~700 ms for `gh` (CLI start-up plus its own network
--- check) — and the first thing that asks is the transport resolve behind a viewer probe, which the status
--- section triggers while the panel is PAINTING. Warming it off the render path keeps that cost off the main
--- loop entirely. Returns immediately (calling `cb`) once the cache holds a value, or when the forge has no
--- CLI / it is not installed.
---@param forge string
---@param cb fun()
function M.prewarm_cli(forge, cb)
    if state.cli_auth[forge] ~= nil then
        cb()
        return
    end
    local cli = CLI[forge]
    if not (cli and vim.fn.executable(cli) == 1) then
        state.cli_auth[forge] = false
        cb()
        return
    end
    runner.run(CLI_STATUS[cli], { timeout = 4000 }, function(res)
        if state.cli_auth[forge] == nil then
            state.cli_auth[forge] = res ~= nil and res.code == 0
        end
        cb()
    end)
end

--- Read `~/.netrc` for the password of `machine <host>`. Best-effort line parser (handles the one-line
--- `machine h login l password p` form and the multi-token spread form). Returns nil on any miss.
---@param host string
---@return string?
local function netrc_token(host)
    local path = vim.fn.expand("~/.netrc")
    if vim.fn.filereadable(path) ~= 1 then
        return nil
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or not lines then
        return nil
    end
    -- Tokenize the whole file (netrc entries may span lines), then scan for `machine <host> … password`.
    local toks = {}
    for _, line in ipairs(lines) do
        for tok in line:gmatch("%S+") do
            toks[#toks + 1] = tok
        end
    end
    local i, want_host = 1, nil
    while i <= #toks do
        local t = toks[i]
        if t == "machine" then
            want_host = toks[i + 1]
            i = i + 2
        elseif t == "password" and want_host == host then
            return toks[i + 1]
        else
            i = i + 1
        end
    end
    return nil
end

--- Read the `tea` CLI config (~/.config/tea/config.yml) for a login token matching `host`. Opt-in
--- (`config.auth.gitea.tea`), read-only, best-effort (a shallow scan of the YAML `logins:` block for a
--- `url:` that contains the host and its neighbouring `token:`). Returns nil on any miss.
---@param host string
---@return string?
local function tea_token(host)
    local path = vim.fn.expand("~/.config/tea/config.yml")
    if vim.fn.filereadable(path) ~= 1 then
        return nil
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or not lines then
        return nil
    end
    -- Scan for a login block whose url contains the host; capture the nearest token within a small window.
    for idx, line in ipairs(lines) do
        if line:find("url", 1, true) and line:find(host, 1, true) then
            for j = math.max(1, idx - 4), math.min(#lines, idx + 4) do
                local tok = lines[j]:match("token:%s*['\"]?([%w%-_%.]+)")
                if tok then
                    return tok
                end
            end
        end
    end
    return nil
end

--- Resolve the token for a forge/host, with its source. Returns nil when no token is found (the caller
--- then errors cleanly / falls back to the CLI transport). NEVER logs or returns the token in a message.
---@param forge string
---@param host string
---@return { token: string, source: "config"|"keyring"|"env"|"netrc"|"tea" }?
function M.resolve(forge, host)
    local a = (config.auth or {})[forge] or {}

    -- (1) config.auth.<forge>.token — a string or a function returning one.
    local tok = a.token
    if type(tok) == "function" then
        local ok, val = pcall(tok)
        tok = ok and val or nil
    end
    if type(tok) == "string" and tok ~= "" then
        return { token = tok, source = "config" }
    end

    -- (2) the lvim-keyring wallet (a per-user encrypted secrets agent), when installed AND unlocked.
    -- pcall-required so forge NEVER hard-depends on it; `get_sync` does not prompt (a locked wallet
    -- returns nothing and we fall through), so this never blocks the request behind a modal.
    local ok_kr, kr = pcall(require, "lvim-keyring")
    if ok_kr then
        local val = kr.get_sync("forge/" .. host, 2000)
        if type(val) == "string" and val ~= "" then
            return { token = val, source = "keyring" }
        end
    end

    -- (3) the env var (per-forge overridable).
    local env = a.env
    if type(env) == "string" and env ~= "" then
        local val = vim.env[env] or os.getenv(env)
        if type(val) == "string" and val ~= "" then
            return { token = val, source = "env" }
        end
    end

    -- (4) ~/.netrc.
    if config.auth and config.auth.netrc then
        local val = netrc_token(host)
        if val then
            return { token = val, source = "netrc" }
        end
    end

    -- (5) the tea CLI logins (gitea/codeberg, opt-in).
    if (forge == "gitea" or forge == "codeberg") and a.tea then
        local val = tea_token(host)
        if val then
            return { token = val, source = "tea" }
        end
    end

    return nil
end

--- Store a token for `host` in the lvim-keyring wallet (prompts masked), so future resolves read it
--- from source "keyring". Errors cleanly when lvim-keyring is not installed.
---@param host string
function M.store(host)
    local ok_kr, kr = pcall(require, "lvim-keyring")
    if not ok_kr then
        vim.notify("lvim-forge: lvim-keyring is not installed", vim.log.levels.WARN)
        return
    end
    kr.ensure_unlocked(function(unlocked, uerr)
        if not unlocked then
            if uerr and uerr ~= "" then
                vim.notify("lvim-forge: " .. uerr, vim.log.levels.WARN)
            end
            return
        end
        require("lvim-ui").input({
            title = ("Token for %s"):format(host),
            mask = true,
            callback = function(confirmed, value)
                if not confirmed or value == "" then
                    return
                end
                kr.set("forge/" .. host, value, nil, function(sok, serr)
                    vim.notify(
                        sok and ("lvim-forge: token stored in the keyring for " .. host)
                            or ("lvim-forge: " .. (serr or "failed to store")),
                        sok and vim.log.levels.INFO or vim.log.levels.WARN
                    )
                end)
            end,
        })
    end)
end

--- Report the token SOURCE for a forge/host without exposing the token (for health). Returns the source
--- string, or "none" when nothing resolves. When the CLI is authed, that is reported preferentially by
--- the caller since the CLI owns auth (this only inspects the REST token chain).
---@param forge string
---@param host string
---@return "config"|"keyring"|"env"|"netrc"|"tea"|"none"
function M.source(forge, host)
    local r = M.resolve(forge, host)
    return r and r.source or "none"
end

return M
