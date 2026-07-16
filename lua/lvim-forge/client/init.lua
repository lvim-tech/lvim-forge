-- lvim-forge.client: THE client seam — the ONE `request(spec, cb)` a forge impl (client/github, …) or
-- the sync engine calls; every transport / auth / pagination / rate-limit concern is resolved here so the
-- callers never touch a curl string or a page cursor.
--
-- Per request it resolves: the FORGE + API base (from `client/detect`, or an explicit `spec.forge`/
-- `spec.base`), the TRANSPORT ("auto" = the CLI when installed+authed, else curl; "cli"/"rest" forced;
-- gitea/codeberg always curl), and the AUTH (a token from `client/auth` for the curl path; the CLI owns
-- its own). It then drives the transport page by page: PAGINATION accumulates array bodies across
-- `Link rel="next"` / `x-next-page` up to `max_pages`, and RATE-LIMIT handling reads the budget headers,
-- fires `User LvimForgeRateLimit` below the floor, and surfaces a clean `rate_limit` error on a 403/429
-- exhaustion instead of a raw HTTP failure.
--
-- Testability (the plan's contract): `spec.transport` may be an INJECTED transport table (a fake that
-- replays fixtures) with the same `request(ctx, single_spec, cb)` interface as `client/http`/`client/cli`
-- — so the whole seam (resolution + pagination + rate-limit) is exercised headless with NO network.
--
---@module "lvim-forge.client"

local config = require("lvim-forge.config")
local state = require("lvim-forge.state")
local detect = require("lvim-forge.client.detect")
local auth = require("lvim-forge.client.auth")

local M = {}

-- Re-export detect so callers use one client entry point.
M.detect = detect.detect
M.classify = detect.classify
M.classify_url = detect.classify_url

--- The per-forge CAPABILITY matrix (the plan's caps model). The UI gates features on these caps, NEVER on
--- a `forge == "github"` string check. This central table is the v1 source of truth; when a forge's impl
--- (`client/<forge>.lua`) lands it MAY expose its own `caps` table which `M.caps` prefers (a version probe
--- can refine `thread_resolve` etc. per instance). Bitbucket is out of v1 — its row is omitted (an unknown
--- forge yields `{}` = every cap false, so a caps gate fails closed).
---@type table<string, table<string, boolean>>
local CAPS = {
    github = {
        issues = true,
        pullreqs = true,
        reviews = true,
        review_threads = true,
        thread_resolve = true,
        pending_review = true,
        draft = true,
        notifications = true,
        graphql = true,
        lock = true, -- PUT/DELETE /issues/{n}/lock
    },
    gitlab = {
        issues = true,
        pullreqs = true,
        reviews = true,
        review_threads = true,
        thread_resolve = true, -- discussions resolve over REST
        pending_review = true, -- batched client-side (the DB-pending model), submitted as discussions + approval
        draft = true, -- via the Draft: title prefix (a title edit)
        notifications = true, -- the todos inbox
        graphql = false, -- v1 uses REST exclusively
        merge = true,
        rebase = true,
        squash = true,
    },
    -- gitea/codeberg: the fallback (the built `client/gitea` impl's own `caps` is preferred by M.caps).
    -- Gitea supports the widest merge set (merge/rebase/squash/rebase-merge/fast-forward), draft via the
    -- WIP: title prefix, and the notifications inbox; conversation RESOLVE has no stable REST endpoint →
    -- thread_resolve gated off. Codeberg IS hosted Forgejo → the same row (its backend re-exports gitea).
    gitea = {
        issues = true,
        pullreqs = true,
        reviews = true,
        review_threads = true,
        thread_resolve = false,
        pending_review = true,
        draft = true,
        notifications = true,
        graphql = false,
        merge = true,
        rebase = true,
        squash = true,
        rebase_merge = true,
        fast_forward = true,
        lock = true, -- PUT/DELETE /issues/{index}/lock
    },
    codeberg = {
        issues = true,
        pullreqs = true,
        reviews = true,
        review_threads = true,
        thread_resolve = false,
        pending_review = true,
        draft = true,
        notifications = true,
        graphql = false,
        merge = true,
        rebase = true,
        squash = true,
        rebase_merge = true,
        fast_forward = true,
        lock = true, -- PUT/DELETE /issues/{index}/lock
    },
}

--- The capability table for a forge. Prefers the forge impl's own `caps` (forward-compat: an impl / a
--- version probe may refine caps per instance) and falls back to the central matrix; an unknown forge →
--- `{}` (every cap false — a gate fails closed). Never nil.
---@param forge? string
---@return table<string, boolean>
function M.caps(forge)
    if type(forge) ~= "string" or forge == "" then
        return {}
    end
    local impl = M.backend(forge)
    if impl and type(impl.caps) == "table" then
        return impl.caps
    end
    return CAPS[forge] or {}
end

---@type table<string, table|false>  cached forge backend modules (github/gitlab/…); false = no such backend
local BACKENDS = {}

--- THE forge-dispatch seam: the backend MODULE for a forge (`client/github`, `client/gitlab`, …), each
--- exposing the SAME read + write surface (`repo`/`topics_since`/`topic_detail`/… ; `create_issue`/
--- `update_issue`/`merge_pull`/…). The sync engine and the action layer route EVERY forge call through
--- this — never `require("lvim-forge.client.github")` directly — so a new forge slots in by adding its
--- module + normalizers, with no change to sync/actions/UI. A forge without a backend (unbuilt, e.g.
--- gitea until Phase 14) returns nil, which the callers surface as a clean `unsupported`.
---@param forge? string
---@return table?
function M.backend(forge)
    if type(forge) ~= "string" or forge == "" then
        return nil
    end
    local cached = BACKENDS[forge]
    if cached ~= nil then
        return cached or nil
    end
    local ok, impl = pcall(require, "lvim-forge.client." .. forge)
    BACKENDS[forge] = (ok and type(impl) == "table") and impl or false
    return BACKENDS[forge] or nil
end

--- Resolve (and cache) the transport for a forge/host per `config.transport`. "rest" everywhere / for
--- gitea/codeberg (no CLI passthrough); "cli" when forced or when "auto" AND the CLI is installed+authed
--- (probed once via `auth.cli_authed`), else "rest".
---@param forge string
---@param host? string
---@return "cli"|"rest"
function M.resolve_transport(forge, host)
    if state.transport[forge] then
        return state.transport[forge]
    end
    local mode
    local t = config.transport
    if forge == "gitea" or forge == "codeberg" then
        mode = "rest" -- no raw-API-passthrough CLI
    elseif t == "rest" then
        mode = "rest"
    elseif t == "cli" then
        mode = auth.cli_for(forge) and "cli" or "rest"
    else -- "auto"
        mode = auth.cli_authed(forge) and "cli" or "rest"
    end
    state.transport[forge] = mode
    return mode
end

--- The transport MODULE for a resolved mode.
---@param mode "cli"|"rest"
---@return table
local function transport_module(mode)
    return mode == "cli" and require("lvim-forge.client.cli") or require("lvim-forge.client.http")
end

--- Fire the rate-limit event for a host (main loop; render-safe payload).
---@param host string
---@param rate { remaining?: integer, reset?: integer, limit?: integer }
local function fire_rate_limit(host, rate)
    vim.api.nvim_exec_autocmds("User", {
        pattern = "LvimForgeRateLimit",
        data = { host = host, remaining = rate.remaining, reset = rate.reset },
    })
end

--- Classify a response into a clean error, or nil when it is a 2xx success. A 429, or a 403 with the
--- rate-limit budget exhausted, is a `rate_limit` error; any other >= 400 is an `http` error carrying
--- the API's `message` when present.
---@param res table
---@param host string
---@return table?
local function response_error(res, host)
    local status = res.status
    if status and status >= 200 and status < 300 then
        return nil
    end
    local rate = res.rate or {}
    local exhausted = rate.remaining ~= nil and rate.remaining <= 0
    if status == 429 or (status == 403 and exhausted) then
        fire_rate_limit(host, rate)
        return {
            kind = "rate_limit",
            status = status,
            reset = rate.reset,
            message = "API rate limit reached"
                .. (rate.reset and (" (resets at " .. tostring(rate.reset) .. ")") or ""),
        }
    end
    local message
    if type(res.body) == "table" and type(res.body.message) == "string" then
        message = res.body.message
    else
        message = "HTTP " .. tostring(status)
    end
    return { kind = "http", status = status, message = message, body = res.body }
end

--- Whether a decoded body is a JSON array (a paginated collection we accumulate).
---@param body any
---@return boolean
local function is_array(body)
    return type(body) == "table" and (vim.islist and vim.islist(body) or vim.tbl_islist(body))
end

--- Drive the transport page by page, accumulating array bodies. `first` is the resolved head-spec;
--- `ctx` carries forge/base/token. On the final page (or an error) calls `cb(res, err)`.
---@param transport table
---@param ctx table
---@param first table
---@param host string
---@param follow boolean    whether to accumulate across `next` pages (spec.paginate)
---@param max_pages integer
---@param cb fun(res: table?, err: table?)
local function paginate(transport, ctx, first, host, follow, max_pages, cb)
    local acc = nil ---@type any accumulated body (array) across pages
    local last_headers, last_status, last_rate
    local pages = 0

    local function step(spec)
        transport.request(ctx, spec, function(res, err)
            if err then
                cb(nil, err)
                return
            end
            pages = pages + 1
            last_headers, last_status, last_rate = res.headers, res.status, res.rate or {}
            -- Track the live budget + warn below the floor (does not abort the request).
            if last_rate.remaining ~= nil then
                state.rate[host] = last_rate
                if last_rate.remaining <= (config.limits.floor or 0) then
                    fire_rate_limit(host, last_rate)
                end
            end
            local rerr = response_error(res, host)
            if rerr then
                cb(nil, rerr)
                return
            end
            -- Accumulate: an array body concatenates across pages; a non-array returns as-is.
            if acc == nil then
                acc = res.body
            elseif is_array(acc) and is_array(res.body) then
                vim.list_extend(acc, res.body)
            end
            if follow and res.next and is_array(acc) and pages < max_pages then
                step({ url = res.next, timeout = first.timeout })
            else
                cb({
                    status = last_status,
                    headers = last_headers,
                    body = acc,
                    rate = last_rate,
                    pages = pages,
                    truncated = follow and res.next ~= nil and pages >= max_pages,
                }, nil)
            end
        end)
    end

    step(first)
end

--- THE request seam. Resolve forge/base/transport/auth for `spec.root` (or the explicit
--- `spec.forge`/`spec.base`/`spec.host`), then drive the request (with pagination when `spec.paginate`).
--- `cb(res, err)`: on success `res = { status, headers, body, rate, pages, truncated }` (body JSON-
--- decoded; an accumulated array when paginated); on failure `err = { kind, status?, message, … }` where
--- `kind` is "detect" | "transport" | "http" | "rate_limit".
---@param spec { root?: string|integer, forge?: string, host?: string, base?: string, method?: string, path?: string, url?: string, query?: table, body?: string|table, headers?: table<string,string>, paginate?: boolean, max_pages?: integer, timeout?: integer, transport?: table }
---@param cb fun(res: table?, err: table?)
function M.request(spec, cb)
    spec = spec or {}
    local forge, host, base = spec.forge, spec.host, spec.base
    if not (forge and base) then
        local d = detect.detect(spec.root)
        if not d then
            cb(nil, { kind = "detect", message = "not inside a tracked forge repository" })
            return
        end
        forge, host, base = d.forge, d.host, d.base
    end
    host = host or ""

    -- An INJECTED transport (a test double / a caller-provided fake) bypasses transport resolution + auth.
    if spec.transport then
        local ctx = { forge = forge, host = host, base = base }
        local first = {
            method = spec.method,
            path = spec.path,
            url = spec.url,
            query = spec.query,
            body = spec.body,
            headers = spec.headers,
            timeout = spec.timeout,
        }
        paginate(
            spec.transport,
            ctx,
            first,
            host,
            spec.paginate == true,
            spec.max_pages or config.pull.max_pages or 10,
            cb
        )
        return
    end

    local mode = M.resolve_transport(forge, host)
    local transport = transport_module(mode)
    local ctx = { forge = forge, host = host, base = base }
    -- The curl transport needs a token; the CLI owns its own auth.
    if mode == "rest" then
        local tok = auth.resolve(forge, host)
        ctx.token = tok and tok.token or nil
    end
    local first = {
        method = spec.method,
        path = spec.path,
        url = spec.url,
        query = spec.query,
        body = spec.body,
        headers = spec.headers,
        timeout = spec.timeout,
    }
    paginate(transport, ctx, first, host, spec.paginate == true, spec.max_pages or config.pull.max_pages or 10, cb)
end

return M
