-- lvim-forge.refs: the offline #topic / @user completion component + open-at-point navigation.
--
-- ONE candidate source (the local DB), TWO delivery surfaces so completion works with or without an
-- external engine:
--   • a buffer-local `omnifunc` (`<C-x><C-o>`, plus `<C-Space>`) — ALWAYS available, engine-free. This is
--     the same self-contained completion the composer shipped in Phase 6, GENERALIZED here so the composer
--     AND `gitcommit` buffers reuse it.
--   • an optional lvim-cmp source, registered via pcall ONLY when the engine is present (never a hard dep).
--     It shares the exact candidate builder with the omnifunc, gated to the same registered buffers.
-- `@<frag>` completes repo `users` logins; `#<frag>` completes repo `topics` (number or title match). Both
-- read the DB (the offline cache) — no network on a keystroke.
--
-- A buffer opts into completion via `M.attach(buf, repo_id)` (the composer body + every `gitcommit` buffer
-- in a tracked repo). `M._ctx[buf]` is the per-buffer completion context both surfaces read; `M.detach`
-- clears it. The `gitcommit` wiring is a FileType autocmd (gated `config.completion.gitcommit`).
--
-- OPEN-AT-POINT (`<Plug>(LvimForgeOpenAtPoint)`): the token under the cursor →
--   • `#123` (or `owner/name#123` for the current repo) → open that topic buffer;
--   • a branch name / commit sha → its pull request (DB head-ref match → the GitHub `pulls?head=` fallback,
--     via `actions.pr_for_branch`).
-- A clean notify when nothing under the cursor resolves. The whole component is gated `config.completion.enabled`.
--
---@module "lvim-forge.refs"

local api = vim.api
local config = require("lvim-forge.config")
local db = require("lvim-forge.db")

local M = {}

--- Per-buffer completion context (buf → `{ repo_id }`), read by BOTH the omnifunc and the cmp source. A
--- buffer with no entry offers no completion (the omnifunc cancels, the cmp source is not `enabled`).
---@type table<integer, { repo_id: integer }>
M._ctx = {}

---@type boolean  guards the one-time setup (cmp source registration + the gitcommit FileType autocmd)
local did_setup = false

---@type boolean  guards the one-time cmp-source registration
local cmp_registered = false

---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-forge: " .. msg, level or vim.log.levels.INFO)
end

--- Whether the completion component is enabled (default on).
---@return boolean
local function enabled()
    local c = config.completion
    return not (c and c.enabled == false)
end

-- ── the shared candidate builder (the ONE DB read, offline) ─────────────────────

--- A raw completion candidate — sigil-agnostic so each surface adds its own sigil/shape.
---@class LvimForgeRefCandidate
---@field token string  the inserted token WITHOUT the sigil (a login, or a topic number)
---@field title string  the descriptive text (a user's name, or a topic title)
---@field kind  "user"|"pr"|"issue"

--- Build the candidate list for a sigil from the DB (offline). `@` → repo `users` logins; `#` → repo
--- `topics` (matched on number OR title). `frag` (lower-cased, sigil stripped) narrows the list; a nil/empty
--- frag returns everything (the cmp engine does its own fuzzy filtering, so it passes nil).
---@param repo_id integer
---@param sigil string  "@" or "#"
---@param frag? string
---@return LvimForgeRefCandidate[]
local function candidates(repo_id, sigil, frag)
    local out = {}
    if sigil == "@" then
        for _, u in ipairs(db.users(repo_id)) do
            if u.login and (not frag or frag == "" or u.login:lower():find(frag, 1, true)) then
                out[#out + 1] = { token = u.login, title = u.name or "user", kind = "user" }
            end
        end
    elseif sigil == "#" then
        for _, t in ipairs(db.topics(repo_id, {})) do
            local nmatch = tostring(t.number):find(frag or "", 1, true)
            local tmatch = t.title and t.title:lower():find(frag or "", 1, true)
            if not frag or frag == "" or nmatch or tmatch then
                out[#out + 1] = {
                    token = tostring(t.number),
                    title = t.title or "",
                    kind = t.kind == "pullreq" and "pr" or "issue",
                }
            end
        end
    end
    return out
end

-- ── surface 1: the buffer-local omnifunc (engine-free, always available) ─────────

--- The `@`/`#` omnifunc. `findstart == 1` returns the 0-based col of the sigil (the completion word starts
--- there) or -3 to cancel; the second pass returns the candidate list. Self-contained — no external engine.
---@param findstart integer
---@param base string
---@return any
function M.omnifunc(findstart, base)
    local buf = api.nvim_get_current_buf()
    local octx = M._ctx[buf]
    if not octx then
        return findstart == 1 and -3 or {}
    end
    local line = api.nvim_get_current_line()
    local col = vim.fn.col(".") - 1 -- bytes before the cursor

    if findstart == 1 then
        local s = col
        while s >= 1 do
            local ch = line:sub(s, s)
            if ch == "@" or ch == "#" then
                return s - 1 -- 0-based col of the sigil = where the completion word starts
            elseif ch:match("[%w_%-/%.]") then
                s = s - 1
            else
                break
            end
        end
        return -3
    end

    local sigil = base:sub(1, 1)
    local frag = base:sub(2):lower()
    local out = {}
    for _, cand in ipairs(candidates(octx.repo_id, sigil, frag)) do
        out[#out + 1] = {
            word = sigil .. cand.token,
            abbr = sigil .. cand.token,
            menu = cand.title,
            kind = cand.kind == "user" and "user" or cand.kind, -- "user" | "pr" | "issue"
        }
    end
    return out
end

-- ── surface 2: the optional lvim-cmp source (registered via pcall, engine present only) ──

--- The lvim-cmp source contract, fed from the SAME `candidates` builder. `enabled` gates it to the
--- registered buffers (`M._ctx`); `@`/`#` are the trigger characters. Because the sigil is already typed
--- (it opens the context), the item INSERTS just the bare token (`login`/`number`) — the engine replaces
--- from the keyword start (after the sigil), so the buffer composes to `@login` / `#123`. The DISPLAY label
--- carries the sigil so the menu reads naturally.
---@return table  a LvimCmpSource
local function cmp_source()
    return {
        name = "lvim_forge",
        ---@param ctx table  LvimCmpContext
        enabled = function(ctx)
            return M._ctx[ctx.bufnr] ~= nil
        end,
        trigger_chars = function()
            return { ["@"] = true, ["#"] = true }
        end,
        ---@param ctx table  LvimCmpContext
        ---@param cb fun(items: table[], incomplete: boolean)
        get = function(ctx, cb)
            local octx = M._ctx[ctx.bufnr]
            local sigil = octx and ctx.line:sub(1, ctx.bounds.s):sub(-1) or ""
            if not octx or (sigil ~= "@" and sigil ~= "#") then
                vim.schedule(function()
                    cb({}, false)
                end)
                return nil
            end
            local items = {}
            for _, cand in ipairs(candidates(octx.repo_id, sigil, nil)) do
                items[#items + 1] = {
                    raw = { label = cand.token, detail = cand.title },
                    source_name = "lvim_forge",
                    label = sigil .. cand.token, -- menu display; insert is raw.label (the bare token)
                    filter_text = cand.token,
                    sort_text = cand.token,
                    kind = cand.kind == "user" and 6 or 18, -- LSP CompletionItemKind Variable / Reference
                }
            end
            vim.schedule(function()
                cb(items, false)
            end)
            return nil
        end,
    }
end

--- Register the lvim-cmp source ONCE, only when the engine is present (pcall — never a hard dependency).
--- The omnifunc remains the universal fallback for any other engine.
local function register_cmp_source()
    if cmp_registered then
        return
    end
    local ok, cmp = pcall(require, "lvim-cmp")
    if ok and type(cmp.register_source) == "function" then
        pcall(cmp.register_source, cmp_source(), { priority = 70 })
        cmp_registered = true
    end
end

-- ── attach / detach (the buffers that opt into completion) ──────────────────────

--- Wire the `@`/`#` completion on `buf`, sourced from `repo_id`'s DB rows: the buffer-local omnifunc + a
--- `<C-Space>` trigger, and (when the engine is present) the cmp source becomes `enabled` for it. Idempotent.
---@param buf integer
---@param repo_id integer
function M.attach(buf, repo_id)
    if not enabled() or not buf or not api.nvim_buf_is_valid(buf) or not repo_id then
        return
    end
    M._ctx[buf] = { repo_id = repo_id }
    vim.bo[buf].omnifunc = "v:lua.require'lvim-forge.refs'.omnifunc"
    pcall(vim.keymap.set, "i", "<C-Space>", "<C-x><C-o>", { buffer = buf, desc = "forge: complete @/#" })
    -- `_ctx` is keyed by bufnr and does NOT drop on wipe on its own — the gitcommit attach never calls
    -- detach, so a wiped buffer would leave a stale repo_id that a REUSED bufnr (in a different, untracked
    -- repo) then offers as completions. Drop the entry when the buffer is wiped.
    pcall(api.nvim_create_autocmd, "BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            M.detach(buf)
        end,
    })
end

--- Drop a buffer's completion context (the composer calls this on close; the attach BufWipeout autocmd also
--- calls it when the buffer is wiped).
---@param buf? integer
function M.detach(buf)
    if buf then
        M._ctx[buf] = nil
    end
end

-- ── open-at-point ───────────────────────────────────────────────────────────────

--- The reference token under the cursor. First matches a `#123` (optionally `owner/name#123`) occurrence
--- covering the cursor → a topic reference; otherwise the contiguous ref word under the cursor (a branch /
--- sha). Returns nil when the cursor is not on a resolvable token.
---@return { kind: "topic", owner_name?: string, number: integer }|{ kind: "ref", word: string }|nil
local function token_under_cursor()
    local line = api.nvim_get_current_line()
    local col = vim.fn.col(".") -- 1-based byte col of the cursor

    -- `#number`, with an optional `owner/name` prefix (only treated as a repo qualifier when it has a `/`).
    local init = 1
    while true do
        local s, e, prefix, num = line:find("([%w%._%-/]*)#(%d+)", init)
        if not s then
            break
        end
        if col >= s and col <= e then
            local owner_name = prefix:find("/", 1, true) and prefix or nil
            return { kind = "topic", owner_name = owner_name, number = tonumber(num) }
        end
        init = e + 1
    end

    -- the contiguous ref word (branch / sha) under the cursor
    local n = #line
    local function isref(i)
        local c = line:sub(i, i)
        return c ~= "" and c:match("[%w%._%-/]") ~= nil
    end
    local a = math.min(math.max(col, 1), math.max(n, 1))
    if not isref(a) then
        a = a - 1
    end
    if a < 1 or not isref(a) then
        return nil
    end
    local lo, hi = a, a
    while lo > 1 and isref(lo - 1) do
        lo = lo - 1
    end
    while hi < n and isref(hi + 1) do
        hi = hi + 1
    end
    local word = line:sub(lo, hi)
    if word == "" then
        return nil
    end
    return { kind = "ref", word = word }
end

--- PUBLIC: resolve the reference under the cursor and open it. `#123` → the topic buffer; a branch / sha →
--- its pull request (via `actions.pr_for_branch`: DB head-ref match → GitHub `pulls?head=` fallback). Bound
--- to `<Plug>(LvimForgeOpenAtPoint)`. A clean notify when nothing resolvable is under the cursor.
function M.open_at_point()
    if not enabled() then
        notify("completion / open-at-point is disabled (config.completion.enabled = false)")
        return
    end
    if not db.available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end
    local detect = require("lvim-forge.client").detect(0)
    local repo = detect and db.repo_for_detect(detect)
    if not detect or not repo then
        notify("not inside a tracked forge repository (`:LvimForge add`)", vim.log.levels.WARN)
        return
    end
    local root = detect.root
    local tok = token_under_cursor()
    if not tok then
        notify("nothing under the cursor to open (put it on a #number, a branch, or a commit)", vim.log.levels.WARN)
        return
    end

    if tok.kind == "topic" then
        local this = ("%s/%s"):format(repo.owner, repo.name):lower()
        if tok.owner_name and tok.owner_name:lower() ~= this then
            notify(
                ("#%d is in %s — cross-repo open is not yet supported (open that repo and `:LvimForge topic %d`)"):format(
                    tok.number,
                    tok.owner_name,
                    tok.number
                ),
                vim.log.levels.WARN
            )
            return
        end
        require("lvim-forge.ui.topic").open(root, tok.number)
        return
    end

    -- a branch / sha → its PR
    notify(("resolving the pull request for '%s' …"):format(tok.word))
    require("lvim-forge.actions").pr_for_branch(root, tok.word, function(ok, res)
        if ok and res and res.number then
            require("lvim-forge.ui.topic").open(root, res.number)
        else
            notify(("no pull request found for '%s' under the cursor"):format(tok.word), vim.log.levels.WARN)
        end
    end)
end

-- ── setup (the FileType wiring + the cmp source, once) ──────────────────────────

--- Wire the completion component (once, guarded): register the optional lvim-cmp source and — when
--- `config.completion.gitcommit` — attach the `@`/`#` completion to every `gitcommit` buffer in a tracked
--- repo via a FileType autocmd. Fully gated on `config.completion.enabled` (a no-op when disabled).
function M.setup()
    if did_setup or not enabled() then
        return
    end
    did_setup = true
    register_cmp_source()

    if config.completion and config.completion.gitcommit then
        local group = api.nvim_create_augroup("LvimForgeRefs", { clear = true })
        api.nvim_create_autocmd("FileType", {
            group = group,
            pattern = "gitcommit",
            desc = "lvim-forge: @/# completion in commit buffers",
            callback = function(ev)
                if not db.available() then
                    return
                end
                local d = require("lvim-forge.client").detect(ev.buf)
                local repo = d and db.repo_for_detect(d)
                if repo then
                    M.attach(ev.buf, repo.id)
                end
            end,
        })
    end
end

return M
