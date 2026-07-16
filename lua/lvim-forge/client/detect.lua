-- lvim-forge.client.detect: classify a repository's FORGE from its git remote — the first thing the
-- client seam resolves. Preferred path: `require("lvim-git.browse")`'s Phase-0 PUBLIC reads
-- (`parse_remote` / `forge_of`) so the remote-parsing is NOT duplicated between the siblings. When
-- lvim-git is absent we degrade gracefully to a bundled ~40-line remote parser + host classifier here
-- (documented; the only loss is lvim-git's self-hosted `browse.hosts` map, replaced by our own
-- `config.hosts`).
--
-- The output normalizes to `{ forge, host, owner, name, base, remote_url, remote }` where `forge` is one
-- of "github" | "gitlab" | "gitea" | "codeberg" and `base` is the API base URL for that forge/host. The
-- rest of the plugin never re-parses a remote — it reads this result (cached per root in state).
--
---@module "lvim-forge.client.detect"

local config = require("lvim-forge.config")
local state = require("lvim-forge.state")
local runner = require("lvim-forge.client.runner")

local M = {}

--- The forge families lvim-forge speaks. Bitbucket is out of v1 (the caps model admits it later).
---@alias LvimForgeForge "github"|"gitlab"|"gitea"|"codeberg"

--- A resolved forge-repository record — the detect result the rest of the plugin reads. `root` is set by
--- the full `detect` (present for a filesystem detection, absent from a pure `classify_url`).
---@class LvimForgeRepo
---@field forge      LvimForgeForge
---@field host       string
---@field owner      string
---@field name       string
---@field base       string   the REST API base URL for this forge/host
---@field remote_url string
---@field remote?    string   the git remote name this URL came from
---@field root?      string   the absolute repo root (set by `detect`)

--- Fallback remote-URL parser, used ONLY when lvim-git is not installed. Mirrors the shape of
--- `lvim-git.browse.parse_remote`: `{ host, path }` (path = "owner/repo", no `.git`, no slashes).
--- Handles scp-like `git@host:owner/repo.git`, `scheme://[user@]host[:port]/owner/repo`. Pure.
---@param url string
---@return { host: string, path: string }?
local function parse_remote_fallback(url)
    url = vim.trim(url or "")
    if url == "" then
        return nil
    end
    local host, path
    -- scp-like: [user@]host:owner/repo(.git)
    host, path = url:match("^[%w._%-]+@([%w._%-]+):(.+)$")
    if not host then
        -- scheme://[user@]host[:port]/owner/repo(.git)
        local rest = url:match("^%w+://(.+)$")
        if rest then
            rest = rest:gsub("^[^@/]+@", "") -- strip a user@ credential
            host, path = rest:match("^([^/]+)/(.+)$")
            if host then
                host = host:gsub(":%d+$", "") -- strip a :port
            end
        end
    end
    if not host or not path then
        return nil
    end
    path = path:gsub("%.git$", ""):gsub("^/", ""):gsub("/$", "")
    if path == "" then
        return nil
    end
    return { host = host, path = path }
end

--- Classify a host into a forge family. `config.hosts` (a `{ ["host"] = "github"|… }` map) wins for
--- self-hosted instances; codeberg.org is Forgejo → "codeberg" (surfaced as a first-class named forge,
--- served by the gitea impl); else a substring match; else nil (an UNKNOWN host — the caller reports it
--- rather than guessing, since a wrong forge means a wrong API base). Pure.
---@param host string
---@return LvimForgeForge?
function M.classify(host)
    local map = config.hosts or {}
    if map[host] then
        return map[host]
    end
    if host == "codeberg.org" or host:find("codeberg", 1, true) then
        return "codeberg"
    elseif host == "github.com" or host:find("github", 1, true) then
        return "github"
    elseif host == "gitlab.com" or host:find("gitlab", 1, true) then
        return "gitlab"
    elseif host:find("gitea", 1, true) or host:find("forgejo", 1, true) then
        return "gitea"
    end
    return nil
end

--- The REST API base URL for a forge on a host. GitHub uses the split `api.<host>` (github.com →
--- api.github.com; GHE `<host>/api/v3`); GitLab `<host>/api/v4`; Gitea/Forgejo/Codeberg `<host>/api/v1`.
---@param forge LvimForgeForge
---@param host string
---@return string
function M.api_base(forge, host)
    if forge == "github" then
        if host == "github.com" then
            return "https://api.github.com"
        end
        return "https://" .. host .. "/api/v3" -- GitHub Enterprise
    elseif forge == "gitlab" then
        return "https://" .. host .. "/api/v4"
    else -- gitea / codeberg (Forgejo)
        return "https://" .. host .. "/api/v1"
    end
end

--- Parse a remote URL into `{ host, path }` — via lvim-git's PUBLIC `browse.parse_remote` when present,
--- else the bundled fallback. Pure.
---@param url string
---@return { host: string, path: string }?
function M.parse_remote(url)
    local ok, browse = pcall(require, "lvim-git.browse")
    if ok and type(browse.parse_remote) == "function" then
        return browse.parse_remote(url)
    end
    return parse_remote_fallback(url)
end

--- Normalize a buffer number / path / nil into an absolute directory to start the repo walk from.
---@param root_or_buf? string|integer
---@return string dir
local function start_dir(root_or_buf)
    if type(root_or_buf) == "number" then
        local name = vim.api.nvim_buf_get_name(root_or_buf)
        if name ~= "" and not name:match("^%w+://") then
            return vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(name, ":p")))
        end
        return vim.fn.getcwd()
    elseif type(root_or_buf) == "string" and root_or_buf ~= "" then
        local p = vim.fs.normalize(vim.fn.fnamemodify(root_or_buf, ":p"))
        if vim.fn.isdirectory(p) == 1 then
            return p
        end
        return vim.fs.dirname(p)
    end
    return vim.fn.getcwd()
end

--- Resolve the repo root for a directory — lvim-git's PUBLIC `backend.repo/detect` when present, else a
--- plain walk-up for a `.git`. Returns nil when the path is not inside a git repo.
---@param dir string
---@return string?
local function repo_root(dir)
    local ok, backend = pcall(require, "lvim-git.backend")
    if ok and type(backend.detect) == "function" then
        local root = backend.detect(dir)
        if root then
            return root
        end
    end
    local git = vim.fs.find(".git", { path = dir, upward = true, limit = 1 })[1]
    if git then
        return vim.fs.dirname(git)
    end
    return nil
end

--- The remote name to read, per `config.remote`: the configured value, else "upstream" when that remote
--- exists (a fork checkout), else "origin".
---@param root string
---@return string
local function remote_name(root)
    if config.remote and config.remote ~= "" then
        return config.remote
    end
    local res = runner.run_sync({ "git", "-C", root, "remote" }, 2000)
    if res and res.code == 0 and res.stdout:find("upstream", 1, true) then
        for line in res.stdout:gmatch("[^\r\n]+") do
            if vim.trim(line) == "upstream" then
                return "upstream"
            end
        end
    end
    return "origin"
end

--- The remote URL for `remote` under `root`, or nil.
---@param root string
---@param remote string
---@return string?
local function remote_url(root, remote)
    local res = runner.run_sync({ "git", "-C", root, "remote", "get-url", remote }, 2000)
    if res and res.code == 0 then
        local url = vim.trim(res.stdout)
        if url ~= "" then
            return url
        end
    end
    return nil
end

--- Classify a remote URL directly (no filesystem / git) into a full detect result — the pure core, used
--- by the full `detect` and directly by tests. Returns nil when the URL is unparseable or the host is an
--- unknown forge.
---@param url string
---@param remote? string  the remote name this URL came from (recorded for reporting)
---@return LvimForgeRepo?
function M.classify_url(url, remote)
    local parsed = M.parse_remote(url)
    if not parsed then
        return nil
    end
    local forge = M.classify(parsed.host)
    if not forge then
        return nil
    end
    local owner, name = parsed.path:match("^(.+)/([^/]+)$")
    if not owner then
        return nil
    end
    return {
        forge = forge,
        host = parsed.host,
        owner = owner,
        name = name,
        base = M.api_base(forge, parsed.host),
        remote_url = url,
        remote = remote,
    }
end

--- Classify a SPECIFIC named git remote of the repo containing `root_or_buf` — bypasses the
--- config.remote / upstream-vs-origin default (used by `:LvimForge add <remote>`). Returns a full
--- `LvimForgeRepo` (with `root`) or nil when there is no such repo/remote or the host is unknown.
---@param remote string
---@param root_or_buf? string|integer
---@return LvimForgeRepo?
function M.classify_remote(remote, root_or_buf)
    local root = repo_root(start_dir(root_or_buf))
    if not root then
        return nil
    end
    local url = remote_url(root, remote)
    if not url then
        return nil
    end
    local result = M.classify_url(url, remote)
    if result then
        result.root = root
    end
    return result
end

--- Detect the forge repository for a buffer/path/cwd: resolve the repo root, read the forge remote's
--- URL, classify it. Cached per root in `state.repos` (keyed by root) + `state.root_of` (dir → root).
--- Returns nil when the path is not inside a git repo OR the remote is not a recognized forge.
---@param root_or_buf? string|integer
---@return LvimForgeRepo?
function M.detect(root_or_buf)
    local dir = start_dir(root_or_buf)
    local cached_root = state.root_of[dir]
    local root
    if cached_root == nil then
        root = repo_root(dir)
        state.root_of[dir] = root or false
    elseif cached_root == false then
        return nil
    else
        root = cached_root
    end
    if not root then
        return nil
    end
    if state.repos[root] then
        return state.repos[root]
    end
    local remote = remote_name(root)
    local url = remote_url(root, remote)
    if not url then
        return nil
    end
    local result = M.classify_url(url, remote)
    if not result then
        return nil
    end
    result.root = root
    state.repos[root] = result
    return result
end

return M
