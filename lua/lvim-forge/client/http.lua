-- lvim-forge.client.http: the curl transport — one implementation of the transport interface behind the
-- `client/init` seam. Builds a curl argv from a normalized request spec (method / url|path / query /
-- body / headers), runs it through `client/runner`, and parses ONE page into the normalized response
-- shape `{ status, headers, body, raw, next, rate }` — exactly what the CLI transport also returns, so
-- the forge impls (and `client/init`'s pagination/rate-limit loop) never know which transport ran.
--
-- This is the fallback transport everywhere and the ONLY transport for Gitea/Forgejo/Codeberg (their
-- `tea` CLI has no raw-API passthrough). It needs a resolved TOKEN (from `client/auth`) — passed in the
-- ctx; the transport itself never resolves auth.
--
-- Header/body separation: curl writes the header block to a PRIVATE dump tempfile (`-D <file>`, read +
-- deleted in the callback) — not stderr, so stderr stays purely transport errors and the two never
-- interleave — and the HTTP status is appended to stdout via `-w`, so the JSON body on stdout stays clean
-- (no `-i` inlining to split). `next` is computed from `Link: rel="next"` (GitHub/Gitea) or `x-next-page`
-- (GitLab) as an ABSOLUTE next-page URL, so `client/init` can page by just re-issuing with `spec.url =
-- res.next`.
--
-- Token safety: the auth header is NEVER placed in curl's argv (argv is world-readable via `ps` /
-- `/proc/<pid>/cmdline`). It is written to a 0600 curl config file (`-K <file>`, `header = "…"`) that
-- exists only for the duration of the request and is deleted in the callback. Non-secret headers stay in
-- argv.
--
---@module "lvim-forge.client.http"

local runner = require("lvim-forge.client.runner")

local uv = vim.uv or vim.loop

local M = {}

--- URL-encode a query value (RFC 3986 unreserved kept).
---@param s string
---@return string
local function urlencode(s)
    return (
        tostring(s):gsub("[^%w%-_%.~]", function(ch)
            return string.format("%%%02X", string.byte(ch))
        end)
    )
end

--- Build a `?k=v&…` query string from a table (stable order for testability). Empty → "".
---@param query? table<string, any>
---@return string
local function querystring(query)
    if not query or vim.tbl_isempty(query) then
        return ""
    end
    local keys = vim.tbl_keys(query)
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = urlencode(k) .. "=" .. urlencode(query[k])
    end
    return "?" .. table.concat(parts, "&")
end

--- Return `url` with its `page` query parameter set to `page` (adds or replaces). Used to build the
--- GitLab next-page URL from `x-next-page`.
---@param url string
---@param page string|integer
---@return string
local function with_page(url, page)
    local base, q = url:match("^([^?]*)%??(.*)$")
    local parts, seen = {}, false
    for pair in (q or ""):gmatch("[^&]+") do
        local k = pair:match("^([^=]+)=")
        if k == "page" then
            parts[#parts + 1] = "page=" .. tostring(page)
            seen = true
        elseif pair ~= "" then
            parts[#parts + 1] = pair
        end
    end
    if not seen then
        parts[#parts + 1] = "page=" .. tostring(page)
    end
    return base .. (#parts > 0 and ("?" .. table.concat(parts, "&")) or "")
end

--- Parse a curl `-D` header dump (the LAST HTTP response block — redirects/100-continue may stack) into
--- a lowercased header map + the numeric status line. Values for repeated keys keep the last seen.
---@param dump string
---@return table<string, string> headers, integer? status_line
local function parse_headers(dump)
    local headers = {}
    local status
    for line in dump:gmatch("[^\r\n]+") do
        local code = line:match("^HTTP/[%d%.]+%s+(%d%d%d)")
        if code then
            -- A new response block: reset so only the final block's headers survive (proxy/redirect).
            headers = {}
            status = tonumber(code)
        else
            local k, v = line:match("^([%w%-]+):%s*(.*)$")
            if k then
                headers[k:lower()] = v
            end
        end
    end
    return headers, status
end

--- The absolute next-page URL from the response headers, or nil. `Link: <url>; rel="next"` (GitHub /
--- Gitea) wins; else GitLab's `x-next-page` (a page number) rebuilt onto the current URL.
---@param headers table<string, string>
---@param current_url string
---@return string?
local function next_url(headers, current_url)
    local link = headers["link"]
    if link then
        for url, rel in link:gmatch('<([^>]+)>;%s*rel="([^"]+)"') do
            if rel == "next" then
                return url
            end
        end
    end
    local xnext = headers["x-next-page"]
    if xnext and xnext ~= "" and xnext ~= "0" then
        return with_page(current_url, xnext)
    end
    return nil
end

--- The rate-limit budget from the response headers (GitHub/Gitea `x-ratelimit-*`, GitLab `ratelimit-*`).
---@param headers table<string, string>
---@return { remaining?: integer, reset?: integer, limit?: integer }
local function rate_of(headers)
    local remaining = headers["x-ratelimit-remaining"] or headers["ratelimit-remaining"]
    local reset = headers["x-ratelimit-reset"] or headers["ratelimit-reset"]
    local limit = headers["x-ratelimit-limit"] or headers["ratelimit-limit"]
    return {
        remaining = remaining and tonumber(remaining) or nil,
        reset = reset and tonumber(reset) or nil,
        limit = limit and tonumber(limit) or nil,
    }
end

--- The authorization header value for a forge's token (GitHub/Gitea use `token`/`Bearer`; GitLab uses
--- `PRIVATE-TOKEN`, returned separately by the caller). Here we return the standard `Authorization`
--- bearer used by GitHub (`Bearer`) and Gitea (`token`); GitLab is handled via a distinct header.
---@param forge string
---@param token string
---@return string header, string value
local function auth_header(forge, token)
    if forge == "gitlab" then
        return "PRIVATE-TOKEN", token
    elseif forge == "github" then
        return "Authorization", "Bearer " .. token
    else -- gitea / codeberg
        return "Authorization", "token " .. token
    end
end

--- Escape a string for a double-quoted curl config value (`header = "…"`). Backslash and double-quote are
--- the only bytes curl treats specially inside the quotes.
---@param s string
---@return string
local function cfg_escape(s)
    return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

--- Write `content` to `path` with mode 0600, creating it owner-only from the outset (no post-chmod race).
--- Used for the auth-token curl config so the secret is never group/other-readable.
---@param path string
---@param content string
---@return boolean ok
local function write_private(path, content)
    local fd = uv.fs_open(path, "w", tonumber("600", 8))
    if not fd then
        return false
    end
    uv.fs_write(fd, content)
    uv.fs_close(fd)
    return true
end

--- Read the whole of `path` (or "" when it is absent / unreadable). Used for the header dump tempfile.
---@param path string
---@return string
local function read_file(path)
    local fd = uv.fs_open(path, "r", tonumber("600", 8))
    if not fd then
        return ""
    end
    local stat = uv.fs_fstat(fd)
    local data = stat and uv.fs_read(fd, stat.size, 0) or ""
    uv.fs_close(fd)
    return data or ""
end

--- Delete `path`, ignoring a missing file (curl may not have created the dump on a spawn failure).
---@param path? string
local function unlink(path)
    if path then
        pcall(uv.fs_unlink, path)
    end
end

--- Perform ONE request page via curl. `ctx = { forge, host, base, token? }`; `spec = { method?, path?,
--- url?, query?, body?, headers?, timeout? }` (`spec.url` — a full next-page URL — wins over path+query).
--- `cb(res, err)`: on success `res = { status, headers, body, raw, next, rate }` (body is JSON-decoded
--- when possible, else the raw string); on transport failure `err = { kind, message }`.
---@param ctx { forge: string, host: string, base: string, token?: string }
---@param spec { method?: string, path?: string, url?: string, query?: table, body?: string|table, headers?: table<string,string>, timeout?: integer }
---@param cb fun(res: table?, err: table?)
function M.request(ctx, spec, cb)
    if vim.fn.executable("curl") ~= 1 then
        cb(nil, { kind = "transport", message = "curl not found on PATH" })
        return
    end
    local url = spec.url or (ctx.base .. (spec.path or "") .. querystring(spec.query))
    local method = (spec.method or "GET"):upper()
    local timeout_s = math.max(1, math.floor((spec.timeout or 30000) / 1000))

    -- Header dump goes to its own tempfile (not stderr), so stderr carries only transport errors.
    local dump_path = vim.fn.tempname()

    local argv = {
        "curl",
        "-sS",
        "--max-time",
        tostring(timeout_s),
        "-X",
        method,
        "-D",
        dump_path, -- dump headers to a private file; body stays clean on stdout, stderr stays errors-only
        "-w",
        "\n%{http_code}", -- append the status as the final stdout line
        "-H",
        "Accept: application/json",
    }
    -- Auth — the token header is written to a 0600 curl config (`-K`), NEVER argv, so it can't be read out
    -- of `ps` / `/proc/<pid>/cmdline` for the life of the request.
    local cfg_path
    if ctx.token and ctx.token ~= "" then
        local h, v = auth_header(ctx.forge, ctx.token)
        cfg_path = vim.fn.tempname()
        if not write_private(cfg_path, ('header = "%s"\n'):format(cfg_escape(h .. ": " .. v))) then
            unlink(dump_path)
            cb(nil, { kind = "transport", message = "could not create a secure curl config for the auth token" })
            return
        end
        vim.list_extend(argv, { "-K", cfg_path })
    end
    -- Caller headers.
    for k, v in pairs(spec.headers or {}) do
        vim.list_extend(argv, { "-H", k .. ": " .. tostring(v) })
    end
    -- Body (a table is JSON-encoded).
    local body = spec.body
    if body ~= nil then
        if type(body) == "table" then
            body = vim.json.encode(body)
        end
        vim.list_extend(argv, { "-H", "Content-Type: application/json", "--data-binary", "@-" })
    end
    argv[#argv + 1] = url

    runner.run(argv, { stdin = type(body) == "string" and body or nil }, function(res)
        -- Read the header dump, then delete both tempfiles regardless of outcome (secret never lingers).
        local dump = read_file(dump_path)
        unlink(dump_path)
        unlink(cfg_path)
        if res.code ~= 0 and (res.stdout == "" or res.stdout == nil) then
            cb(nil, { kind = "transport", message = "curl exit " .. res.code .. ": " .. vim.trim(res.stderr) })
            return
        end
        -- Split the appended status line off the tail of stdout.
        local out = res.stdout or ""
        local raw, status_str = out:match("^(.*)\n(%d%d%d)%s*$")
        if not raw then
            raw, status_str = out, nil
        end
        local status = status_str and tonumber(status_str) or nil
        local headers, header_status = parse_headers(dump)
        status = status or header_status
        -- JSON-decode the body when it parses; else keep the raw string.
        local decoded = raw
        if raw and vim.trim(raw) ~= "" then
            local ok, val = pcall(vim.json.decode, raw)
            if ok then
                decoded = val
            end
        end
        cb({
            status = status,
            headers = headers,
            body = decoded,
            raw = raw,
            next = next_url(headers, url),
            rate = rate_of(headers),
        }, nil)
    end)
end

return M
