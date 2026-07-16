-- lvim-forge.git: the SELF-CONTAINED async git-op layer for the PR checkout / create flows. These are
-- plain working-tree git operations (fetch a PR head, create / checkout a branch, add a worktree, list
-- branches, read commits for a PR-body prefill), NOT a git UI — lvim-git owns all git PORCELAIN
-- (status/diff/log/blame). lvim-forge runs these itself because they are cheap plumbing on the repo it
-- already tracks; where lvim-git exposes a render-safe seam (branch / repo detect) the UI prefers it, but
-- the mutating ops (fetch/branch/worktree/push) are ours and never belong in another plugin.
--
-- Every op is async through `client/runner` (the same `vim.system` + `vim.schedule` runner every transport
-- uses — mirroring lvim-git's `backend.system` style: run off the main thread, marshal completion back).
-- Each returns via `cb(data, err)` — `data` is the parsed result (nil on failure), `err` a clean human
-- string (nil on success). A failure is SURFACED, never thrown; nothing here opens a window.
--
-- The git argv is repo-scoped with `-C <root>` and hardened with `--no-optional-locks` + `-c
-- color.ui=false` (never race a concurrent process; never parse coloured output) — the lvim-git backend
-- convention, since these run beside a live lvim-git.
--
---@module "lvim-forge.git"

local runner = require("lvim-forge.client.runner")

local M = {}

-- Field separator (unit separator \x1f) inside a machine-readable `git log` format.
local US = "\31"

--- Build the repo-scoped git argv (executable + repo-agnostic globals + `-C <root>`).
---@param root string
---@param args string[]
---@return string[]
local function git_argv(root, args)
    local argv = { "git", "--no-optional-locks", "-c", "color.ui=false", "-C", root }
    vim.list_extend(argv, args)
    return argv
end

--- Run a git subcommand under `root` and hand back `cb(stdout, err)`. A non-zero exit → a clean `err`
--- string (stderr, else stdout, else a generic message); the process runs off the main loop.
---@param root string
---@param args string[]
---@param cb fun(out: string?, err: string?)
---@param opts? { stdin?: string|string[] }
local function run(root, args, cb, opts)
    if type(root) ~= "string" or root == "" then
        cb(nil, "no repository root")
        return
    end
    runner.run(git_argv(root, args), { cwd = root, stdin = opts and opts.stdin }, function(res)
        if res.code == 0 then
            cb(res.stdout or "", nil)
            return
        end
        local msg = vim.trim((res.stderr ~= "" and res.stderr) or res.stdout or "")
        cb(nil, msg ~= "" and msg or ("git " .. (args[1] or "?") .. " failed"))
    end)
end

--- Split output into non-empty trimmed lines.
---@param out? string
---@return string[]
local function lines(out)
    local list = {}
    for line in ((out or "") .. "\n"):gmatch("(.-)\n") do
        local t = vim.trim(line)
        if t ~= "" then
            list[#list + 1] = t
        end
    end
    return list
end

-- ── reads ───────────────────────────────────────────────────────────────────

--- The current branch (`rev-parse --abbrev-ref HEAD`). `cb("HEAD", …)` on a detached HEAD.
---@param root string
---@param cb fun(branch: string?, err: string?)
function M.current_branch(root, cb)
    run(root, { "rev-parse", "--abbrev-ref", "HEAD" }, function(out, err)
        cb(out and vim.trim(out) or nil, err)
    end)
end

--- Local branch names (`for-each-ref refs/heads`). `cb(names, err)`.
---@param root string
---@param cb fun(names: string[]?, err: string?)
function M.local_branches(root, cb)
    run(root, { "for-each-ref", "--format=%(refname:short)", "refs/heads" }, function(out, err)
        cb(err and nil or lines(out), err)
    end)
end

--- Remote-tracking branch names (`for-each-ref refs/remotes`). `cb(names, err)`.
---@param root string
---@param cb fun(names: string[]?, err: string?)
function M.remote_branches(root, cb)
    run(root, { "for-each-ref", "--format=%(refname:short)", "refs/remotes" }, function(out, err)
        cb(err and nil or lines(out), err)
    end)
end

--- Whether a ref resolves in this repo (`rev-parse --verify --quiet <ref>`). Never errors — a missing ref
--- is `cb(false)`, not a failure.
---@param root string
---@param ref string
---@param cb fun(exists: boolean)
function M.ref_exists(root, ref, cb)
    run(root, { "rev-parse", "--verify", "--quiet", ref .. "^{commit}" }, function(out)
        cb(out ~= nil and vim.trim(out) ~= "")
    end)
end

--- Whether `branch` has an upstream configured (`rev-parse --abbrev-ref <branch>@{upstream}`). Never
--- errors — no upstream is `cb(false)`.
---@param root string
---@param branch string
---@param cb fun(has_upstream: boolean)
function M.has_upstream(root, branch, cb)
    run(root, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", branch .. "@{upstream}" }, function(out)
        cb(out ~= nil and vim.trim(out) ~= "")
    end)
end

--- The commits in `base..head` (newest first), for the PR-body prefill. Each is `{ sha, subject, body }`.
--- `cb(commits, err)`; an empty range (`head` not ahead of `base`) → an empty list.
---@param root string
---@param base string
---@param head string
---@param cb fun(commits: { sha: string, subject: string, body: string }[]?, err: string?)
function M.commits_between(root, base, head, cb)
    local fmt = "%H" .. US .. "%s" .. US .. "%b"
    -- `%x1e` record separator between commits so a multi-line body cannot be mistaken for the next record.
    run(root, { "log", "--no-merges", "--format=" .. fmt .. "%x1e", base .. ".." .. head }, function(out, err)
        if err then
            cb(nil, err)
            return
        end
        ---@type { sha: string, subject: string, body: string }[]
        local commits = {}
        for rec in ((out or "") .. "\30"):gmatch("(.-)\30") do
            local t = vim.trim(rec)
            if t ~= "" then
                local f = vim.split(t, US, { plain = true })
                commits[#commits + 1] = { sha = f[1] or "", subject = f[2] or "", body = vim.trim(f[3] or "") }
            end
        end
        cb(commits, nil)
    end)
end

--- The unified diff text for a `base...head` range (`diff --no-color -U3 <range>`), used ONLY by the
--- review workspace's no-lvim-git fallback to render per-file hunks (a plain read, not a diff UI — lvim-git
--- owns the diffview when present). `cb(text, err)`; an empty range → an empty string.
---@param root string
---@param range string  e.g. "origin/main...refs/forge/pr/42"
---@param cb fun(text: string?, err: string?)
function M.diff_range(root, range, cb)
    run(root, { "diff", "--no-color", "-U3", range }, function(out, err)
        cb(out, err)
    end)
end

-- ── mutations ─────────────────────────────────────────────────────────────────

--- Fetch `refspec` from `remote` (e.g. a PR head `pull/42/head:refs/forge/pr/42`). `cb(true, err)`.
---@param root string
---@param remote string
---@param refspec string
---@param cb fun(ok: boolean, err: string?)
function M.fetch_ref(root, remote, refspec, cb)
    run(root, { "fetch", "--no-tags", remote, refspec }, function(_, err)
        cb(err == nil, err)
    end)
end

--- Create a local branch `name` at `start` (a ref/sha) WITHOUT checking it out (`branch <name> <start>`).
---@param root string
---@param name string
---@param start string
---@param cb fun(ok: boolean, err: string?)
function M.create_branch(root, name, start, cb)
    run(root, { "branch", name, start }, function(_, err)
        cb(err == nil, err)
    end)
end

--- Create `name` at `start` and check it out (`checkout -b <name> <start>`). `cb(true, err)`.
---@param root string
---@param name string
---@param start string
---@param cb fun(ok: boolean, err: string?)
function M.create_and_checkout(root, name, start, cb)
    run(root, { "checkout", "-b", name, start }, function(_, err)
        cb(err == nil, err)
    end)
end

--- Check out an EXISTING branch (`checkout <name>`). `cb(true, err)`.
---@param root string
---@param name string
---@param cb fun(ok: boolean, err: string?)
function M.checkout(root, name, cb)
    run(root, { "checkout", name }, function(_, err)
        cb(err == nil, err)
    end)
end

--- Add a worktree at `path`. When `start` is given a NEW branch `branch` is created there
--- (`worktree add -b <branch> <path> <start>`); otherwise an existing `branch` is checked out
--- (`worktree add <path> <branch>`). `cb(true, err)`.
---@param root string
---@param path string
---@param branch string
---@param start? string
---@param cb fun(ok: boolean, err: string?)
function M.worktree_add(root, path, branch, start, cb)
    local args = start and { "worktree", "add", "-b", branch, path, start } or { "worktree", "add", path, branch }
    run(root, args, function(_, err)
        cb(err == nil, err)
    end)
end

--- Push `branch` to `remote` and set it as the upstream (`push -u <remote> <branch>`). `cb(true, err)`.
---@param root string
---@param remote string
---@param branch string
---@param cb fun(ok: boolean, err: string?)
function M.push_set_upstream(root, remote, branch, cb)
    run(root, { "push", "-u", remote, branch }, function(_, err)
        cb(err == nil, err)
    end)
end

--- Set `branch`'s upstream to `remote/upstream_branch` (best-effort; the PR-checkout `track` option).
--- `cb(true, err)`.
---@param root string
---@param branch string
---@param remote string
---@param upstream_branch string
---@param cb fun(ok: boolean, err: string?)
function M.set_upstream(root, branch, remote, upstream_branch, cb)
    run(root, { "branch", "--set-upstream-to=" .. remote .. "/" .. upstream_branch, branch }, function(_, err)
        cb(err == nil, err)
    end)
end

--- Force-delete a local branch (`branch -D <name>`) — the post-merge cleanup of a PR checkout branch. A
--- force delete because the merge happened on the FORGE, so the local branch is not "merged into HEAD"
--- from git's point of view. `cb(true, err)`.
---@param root string
---@param name string
---@param cb fun(ok: boolean, err: string?)
function M.delete_branch(root, name, cb)
    run(root, { "branch", "-D", name }, function(_, err)
        cb(err == nil, err)
    end)
end

--- The registered worktrees (`worktree list --porcelain`), each `{ path, branch? }` — `branch` is the
--- short ref name a worktree has checked out (nil for a detached/bare entry). Used to find a PR's
--- checkout worktree so it can be removed after the merge. `cb(worktrees, err)`.
---@param root string
---@param cb fun(worktrees: { path: string, branch?: string }[]?, err: string?)
function M.worktrees(root, cb)
    run(root, { "worktree", "list", "--porcelain" }, function(out, err)
        if err then
            cb(nil, err)
            return
        end
        ---@type { path: string, branch?: string }[]
        local list = {}
        local cur
        for line in ((out or "") .. "\n"):gmatch("(.-)\n") do
            local path = line:match("^worktree%s+(.+)$")
            if path then
                cur = { path = vim.trim(path) }
                list[#list + 1] = cur
            elseif cur then
                local ref = line:match("^branch%s+(.+)$")
                if ref then
                    -- `refs/heads/foo` → the short name `foo`.
                    cur.branch = (vim.trim(ref):gsub("^refs/heads/", ""))
                end
            end
        end
        cb(list, nil)
    end)
end

--- Remove a worktree at `path` (`worktree remove --force <path>`) — force because the checked-out branch
--- may be behind the merged remote. `cb(true, err)`.
---@param root string
---@param path string
---@param cb fun(ok: boolean, err: string?)
function M.worktree_remove(root, path, cb)
    run(root, { "worktree", "remove", "--force", path }, function(_, err)
        cb(err == nil, err)
    end)
end

return M
