-- lvim-forge.client.cli: the CLI transport — `gh api` (GitHub) / `glab api` (GitLab) behind the same
-- transport interface as `client/http`, returning the identical normalized `{ status, headers, body,
-- raw, next, rate }` page shape so the forge impls and `client/init`'s pagination loop are transport-
-- blind. ZERO-CONFIG auth: the CLI owns its own token (SSO / enterprise setups work out of the box), so
-- this transport resolves NO token — `client/init` picks it only when `auth.cli_authed(forge)` is true.
--
-- The `-i` / `--include` flag makes the CLI emit the HTTP response headers ahead of the JSON body (like
-- `curl -i`); we split the header block from the body, parse the status + `Link`/`x-ratelimit` headers
-- exactly as the curl transport does, and compute the absolute `next` URL — the CLI accepts a full URL
-- as its endpoint, so paging re-issues with `spec.url = res.next`.
--
-- Gitea/Forgejo/Codeberg have NO raw-API-passthrough CLI → they always use the curl transport; this
-- module only ever runs for github/gitlab.
--
---@module "lvim-forge.client.cli"

local runner = require("lvim-forge.client.runner")

local M = {}

--- The CLI executable per forge.
---@type table<string, string>
local CLI = { github = "gh", gitlab = "glab" }

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

--- Build a `?k=v&…` query string (stable order for testability). Empty → "".
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

--- The absolute next-page URL from the parsed headers, or nil (`Link: rel="next"`).
---@param headers table<string, string>
---@return string?
local function next_url(headers)
    local link = headers["link"]
    if link then
        for url, rel in link:gmatch('<([^>]+)>;%s*rel="([^"]+)"') do
            if rel == "next" then
                return url
            end
        end
    end
    return nil
end

--- The rate-limit budget from the parsed headers.
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

--- Split a combined header+body stream (CLI `-i` output) into `header_block, body`. The boundary is the
--- first blank line; a stacked block (redirect) keeps only the final HTTP block's headers via the parser.
---@param out string
---@return string header_block, string body
local function split_message(out)
    local sep = out:find("\r?\n\r?\n")
    if not sep then
        return out, ""
    end
    local head = out:sub(1, sep - 1)
    local body = out:gsub("^.-\r?\n\r?\n", "", 1)
    return head, body
end

--- Parse a header block into a lowercased header map + the numeric status. Resets on each `HTTP/` line
--- so a stacked block keeps only the last response's headers.
---@param block string
---@return table<string, string> headers, integer? status
local function parse_headers(block)
    local headers, status = {}, nil
    for line in block:gmatch("[^\r\n]+") do
        local code = line:match("^HTTP/[%d%.]+%s+(%d%d%d)")
        if code then
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

--- Perform ONE request page via the forge CLI. `ctx = { forge }`; `spec = { method?, path?, url?,
--- query?, body?, timeout? }` (`spec.url` — a full next-page URL — wins over path+query). `cb(res, err)`
--- with the same normalized shape as the curl transport.
---@param ctx { forge: string }
---@param spec { method?: string, path?: string, url?: string, query?: table, body?: string|table, timeout?: integer }
---@param cb fun(res: table?, err: table?)
function M.request(ctx, spec, cb)
    local cli = CLI[ctx.forge]
    if not cli then
        cb(nil, { kind = "transport", message = "no CLI transport for forge " .. tostring(ctx.forge) })
        return
    end
    if vim.fn.executable(cli) ~= 1 then
        cb(nil, { kind = "transport", message = cli .. " not found on PATH" })
        return
    end
    local endpoint = spec.url or ((spec.path or "") .. querystring(spec.query))
    local method = (spec.method or "GET"):upper()
    local argv = { cli, "api", "-i", "--method", method, endpoint }

    local body = spec.body
    if body ~= nil then
        if type(body) == "table" then
            body = vim.json.encode(body)
        end
        -- gh/glab read a raw JSON body from a file; `-` = stdin.
        vim.list_extend(argv, { "--input", "-" })
    end

    runner.run(argv, {
        stdin = type(body) == "string" and body or nil,
        timeout = spec.timeout or 30000,
    }, function(res)
        local out = res.stdout or ""
        if out == "" and res.code ~= 0 then
            cb(nil, { kind = "transport", message = cli .. " exit " .. res.code .. ": " .. vim.trim(res.stderr) })
            return
        end
        local head, raw = split_message(out)
        local headers, status = parse_headers(head)
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
            next = next_url(headers),
            rate = rate_of(headers),
        }, nil)
    end)
end

return M
