-- lvim-forge.util: the small pure helpers every view needs.
--
-- These lived as verbatim copies in four `ui/*` modules (`iso_epoch` and `rel_date` four times each,
-- `truthy` four times counting actions.lua). Copies are not just noise here: a forge timestamp is fiddly
-- enough that a correction to the parsing — or to what a missing value should mean — has to be made in
-- every copy or the views quietly disagree with each other. One home, one behaviour.
--
---@module "lvim-forge.util"

local M = {}

--- Epoch seconds of a UTC ISO-8601 string. The string's fields are UTC, but `os.time` interprets a
--- broken-down table as LOCAL time, so the machine's UTC offset is measured (`os.date("!*t")` re-read
--- through `os.time`) and subtracted back out. nil when the value is missing or unparseable.
---@param iso? string
---@return integer?
function M.iso_epoch(iso)
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

--- A short relative date ("3h", "2d", "5mo", "1y") for the dim row meta. Empty string when the
--- timestamp is missing or unparseable — callers render it inline, so a placeholder would be noise.
---@param iso? string
---@return string
function M.rel_date(iso)
    local t = M.iso_epoch(iso)
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

--- Truthy for a sqlite boolean column: the driver hands back `1`/`0`, not `true`/`false`.
---@param v any
---@return boolean
function M.truthy(v)
    return v == 1 or v == true
end

return M
