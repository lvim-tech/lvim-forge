-- lvim-forge.client.runner: the async process runner shared by every transport (curl + gh/glab).
-- The HTTP/CLI analogue of lvim-git's `backend.system`: run an argv off the main thread via
-- `vim.system`, marshal the completion back onto the main loop via `vim.schedule`, and NEVER block the
-- UI. A transport (`client/http`, `client/cli`) builds the argv + parses the result; the runner only
-- owns the process lifecycle (spawn, stdin, timeout, cancel). The network NEVER runs on a render path —
-- every read is issued through here from an event/command handler.
--
-- This is the ONE place a subprocess is spawned; the transports are pure argv-builders + parsers on top,
-- so a test can inject a fake transport into `client/init` and exercise the whole seam without a runner.
--
---@module "lvim-forge.client.runner"

local M = {}

---@class LvimForgeRunResult
---@field code   integer  the process exit code (-1 when spawn failed / timed out)
---@field signal integer
---@field stdout string
---@field stderr string

--- Run an argv off the main thread and marshal `cb(res)` back onto the main loop. Returns the
--- `vim.SystemObj` so a long request can be cancelled (`obj:kill(15)`); nil when the spawn itself failed
--- (the callback still fires with `code = -1` so a caller never hangs).
---@param argv string[]                              full argv (executable first)
---@param opts? { stdin?: string|string[], timeout?: integer, env?: table<string,string>, cwd?: string }
---@param cb? fun(res: LvimForgeRunResult)           completion callback (main loop)
---@return vim.SystemObj?
function M.run(argv, opts, cb)
    opts = opts or {}
    local sopts = {
        text = true,
        stdin = opts.stdin,
        timeout = opts.timeout,
        env = opts.env,
        cwd = opts.cwd,
    }
    local ok, obj = pcall(vim.system, argv, sopts, function(res)
        if not cb then
            return
        end
        vim.schedule(function()
            cb({
                code = res.code,
                signal = res.signal or 0,
                stdout = res.stdout or "",
                stderr = res.stderr or "",
            })
        end)
    end)
    if not ok then
        if cb then
            vim.schedule(function()
                cb({ code = -1, signal = 0, stdout = "", stderr = tostring(obj) })
            end)
        end
        return nil
    end
    return obj
end

--- Run an argv and BLOCK for its result (up to `timeout` ms). Used ONLY off the render path for cheap
--- one-time probes (a CLI `auth status` / `--version`), never for a request. Returns nil on spawn
--- failure / timeout.
---@param argv string[]
---@param timeout? integer  default 3000 ms
---@param opts? { env?: table<string,string>, cwd?: string }
---@return LvimForgeRunResult?
function M.run_sync(argv, timeout, opts)
    opts = opts or {}
    local ok, obj = pcall(vim.system, argv, { text = true, env = opts.env, cwd = opts.cwd })
    if not ok then
        return nil
    end
    local ok_wait, res = pcall(function()
        return obj:wait(timeout or 3000)
    end)
    if not ok_wait or not res then
        pcall(function()
            obj:kill(15)
        end)
        return nil
    end
    return {
        code = res.code,
        signal = res.signal or 0,
        stdout = res.stdout or "",
        stderr = res.stderr or "",
    }
end

return M
