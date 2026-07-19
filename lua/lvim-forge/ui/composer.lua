-- lvim-forge.ui.composer: the ONE editable-surface shape for every forge body. A canonical
-- lvim-ui.surface (never a raw float / `vim.ui.*`) with an EDITABLE
-- center block — a real `markdown` buffer with a PER-MODE cursor via `lvim-utils.cursor` (visible in
-- insert, hidden in normal/visual — the lvim-git commit-panel precedent) — a meta band, and a
-- submit/cancel footer. `<C-c><C-c>` submits, `<C-c><C-k>` (and normal-mode `q`) cancels (confirming a
-- dirty buffer so typed work is never lost).
--
-- MODES (opts.mode):
--   • `comment` — a new comment on a topic (a body block).
--   • `edit`    — edit an existing post OR the topic description (the block is PREFILLED); the caller
--                 (author-gated) passes `target = { kind = "description"|"comment"|"review-comment",
--                 forge_id? }`.
--   • `issue`   — create an issue: a TITLE input block (row 1) + a body block. A repo template pick would
--                 slot in here via `ui.select` — but no templates table is cached yet, so the pick is
--                 SKIPPED (an OPEN follow-up: fetch `.github/ISSUE_TEMPLATE` into a templates table).
--   • `pr`      — create a pull request (title + body); submit routes to the create-PR endpoint like the
--                 other verbs (base/head ref pickers are the remaining OPEN enhancement).
--
-- Submit routes to the right verb in `actions.lua` → `sync.mutate` (NO optimistic write: the API
-- response is the truth) → on success the composer closes, the response upserts, `LvimForgeTopicChanged`
-- fires and the topic/list refresh; a create-issue additionally OPENS the new topic buffer.
--
-- COMPLETION: the body block opts into the shared `lvim-forge.refs` component (`refs.attach`) — a DB-fed
-- `@login` / `#number` omnifunc (`<C-x><C-o>`, plus `<C-Space>`) + the optional lvim-cmp source — so
-- mentions + topic refs complete OFFLINE with no external engine. It degrades to no-completion cleanly when
-- the repo id is unknown (`refs.attach` is a no-op).
--
---@module "lvim-forge.ui.composer"

local api = vim.api
local config = require("lvim-forge.config")
local db = require("lvim-forge.db")
local actions = require("lvim-forge.actions")
local ui = require("lvim-ui")
local surface = require("lvim-ui.surface")
local cursor = require("lvim-utils.cursor")

local M = {}

-- ── glyphs (verified single-width Nerd Font, + the `➤` pointer canon) ──────────
local GLYPH = {
    issue = "\u{f41b}", --  nf-oct-issue_opened (composer title / new issue)
    comment = "\u{f075}", --  nf-fa-comment
    pull = "\u{e726}", --  nf-dev-git_pull_request
    pencil = "\u{f044}", --  nf-fa-pencil_square_o (edit)
    branch = "\u{e725}", --  nf-dev-git_branch (base ➤ head)
    review = "\u{f441}", --  nf-oct-eye (review comment / summary)
    arrow = "➤", -- the pointer canon
}

--- The active composer (a singleton — one composer at a time, like the commit panel).
---@class LvimForgeComposerState
---@field handle table?           the surface handle
---@field mode string?            "comment"|"edit"|"issue"|"pr"
---@field root string|integer|nil the repo root the verbs target
---@field repo_id integer?        the repo id (the completion source)
---@field number integer?         the topic number (comment / edit)
---@field kind string?            "issue"|"pullreq" (the topic being commented / edited)
---@field target table?           the edit target `{ kind, forge_id? }`
---@field title_buf integer?      the editable title buffer (issue / pr)
---@field body_buf integer?       the editable body buffer
---@field initial_title string?   the title prefill (dirty check)
---@field initial_body string?    the body prefill (dirty check)
---@field action_opts table?      trailing verb opts (transport / repo_row — the test seam)
---@field base string?            PR base branch (create-PR)
---@field head string?            PR head branch (create-PR)
---@field draft boolean?          PR draft flag (create-PR)
---@field on_submit fun(body: string, done: fun(ok: boolean, res?: table))|nil  review mode: the submit sink
---@field heading string?         review mode: the frame title text
---@field subtext string?         review mode: the subtitle line
local cstate = {}

---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-forge: " .. msg, level or vim.log.levels.INFO)
end

--- Whether a component is enabled (defaults on).
---@param key string
---@return boolean
local function enabled(key)
    local c = config[key]
    return not (c and c.enabled == false)
end

-- ── buffer helpers ────────────────────────────────────────────────────────────

--- The full text of an editable buffer (trailing blank lines trimmed).
---@param buf? integer
---@return string
local function buf_text(buf)
    if not buf or not api.nvim_buf_is_valid(buf) then
        return ""
    end
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    while #lines > 0 and vim.trim(lines[#lines]) == "" do
        lines[#lines] = nil
    end
    return table.concat(lines, "\n")
end

--- The first line of the title buffer (a title is one line).
---@param buf? integer
---@return string
local function title_text(buf)
    if not buf or not api.nvim_buf_is_valid(buf) then
        return ""
    end
    return vim.trim(api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
end

--- Whether the composer has unsaved edits (vs the prefill).
---@return boolean
local function is_dirty()
    if vim.trim(buf_text(cstate.body_buf)) ~= vim.trim(cstate.initial_body or "") then
        return true
    end
    if cstate.title_buf and title_text(cstate.title_buf) ~= vim.trim(cstate.initial_title or "") then
        return true
    end
    return false
end

--- Close the composer (guarded).
local function close()
    if cstate.handle and cstate.handle.close then
        pcall(cstate.handle.close)
    end
end

-- ── submit / cancel ────────────────────────────────────────────────────────────

--- Push the PR head branch when it has no upstream, honouring `config.create.push_head` (ask via
--- `ui.confirm` | always | never), then continue. GitHub needs the head branch on the remote before it
--- can open the PR, so a missing-upstream branch is pushed here (never inside the verb layer). `after(true)`
--- proceeds with the create, `after(false)` aborts (keeps the composer open with the typed text).
---@param root? string|integer
---@param head string
---@param after fun(proceed: boolean)
local function ensure_head_pushed(root, head, after)
    local git = require("lvim-forge.git")
    local policy = (config.create or {}).push_head or "ask"
    if policy == "never" then
        after(true)
        return
    end
    local detected = require("lvim-forge.client").detect(root)
    local git_root = detected and detected.root
    if not git_root then
        after(true) -- no working tree here; let create_pr surface any error cleanly
        return
    end
    local remote = (detected and detected.remote) or "origin"
    git.has_upstream(git_root, head, function(has)
        if has then
            after(true)
            return
        end
        local function push()
            notify("pushing " .. head .. " to " .. remote .. " …")
            git.push_set_upstream(git_root, remote, head, function(ok, err)
                if not ok then
                    notify("push failed: " .. (err or "?"), vim.log.levels.WARN)
                    after(false)
                    return
                end
                after(true)
            end)
        end
        if policy == "always" then
            push()
        else
            ui.confirm({
                prompt = ("Branch '%s' has no upstream. Push it to %s?"):format(head, remote),
                callback = function(yes)
                    if yes then
                        push()
                    else
                        notify(
                            "not pushed — GitHub needs the head branch on the remote to open the PR",
                            vim.log.levels.WARN
                        )
                        after(false)
                    end
                end,
            })
        end
    end)
end

--- Submit: read the buffers, route to the right `actions` verb, and on success close (+ open the new
--- issue / pull request). On failure keep the composer open so the typed text is not lost.
local function submit()
    local mode = cstate.mode
    local root = cstate.root
    local number = cstate.number
    local body = buf_text(cstate.body_buf)

    ---@param ok boolean
    ---@param res_or_err table?
    local function done(ok, res_or_err)
        if ok then
            close()
            if mode == "issue" or mode == "pr" then
                local new_num = res_or_err and res_or_err.body and res_or_err.body.number
                if new_num then
                    vim.schedule(function()
                        require("lvim-forge.ui.topic").open(root, new_num)
                    end)
                end
            end
        else
            notify(
                "submit failed: " .. ((res_or_err and (res_or_err.message or res_or_err.kind)) or "?"),
                vim.log.levels.WARN
            )
        end
    end

    if mode == "review" then
        -- The review body sinks into the caller's handler (a pending line/reply comment, or the submit
        -- summary). The sink owns validation + the network/DB write; `done` closes on success.
        if cstate.on_submit then
            cstate.on_submit(body, done)
        end
        return
    end

    if mode == "pr" then
        local title = title_text(cstate.title_buf)
        if title == "" then
            notify("a pull request title is required", vim.log.levels.WARN)
            return
        end
        local base, head = cstate.base, cstate.head
        if not base or base == "" then
            notify("choose a base branch (gb)", vim.log.levels.WARN)
            return
        end
        if not head or head == "" or head == "HEAD" then
            notify("no head branch — checkout a feature branch first", vim.log.levels.WARN)
            return
        end
        if base == head then
            notify("base and head are the same branch", vim.log.levels.WARN)
            return
        end
        ensure_head_pushed(root, head, function(proceed)
            if not proceed then
                return
            end
            actions.create_pr(
                root,
                { base = base, head = head, title = title, body = body, draft = cstate.draft },
                done,
                cstate.action_opts
            )
        end)
        return
    end

    if mode == "comment" or mode == "edit" then
        if not number then
            notify("no topic is bound to this composer", vim.log.levels.WARN)
            return
        end
        if mode == "comment" then
            if vim.trim(body) == "" then
                notify("nothing to send (the comment is empty)", vim.log.levels.WARN)
                return
            end
            actions.comment(root, number, body, done, cstate.action_opts)
        else
            actions.edit_post(root, number, cstate.target or {}, body, done, cstate.action_opts)
        end
    elseif mode == "issue" then
        local title = title_text(cstate.title_buf)
        if title == "" then
            notify("an issue title is required", vim.log.levels.WARN)
            return
        end
        actions.create_issue(root, title, body, done, cstate.action_opts)
    end
end

--- Cancel: confirm when the buffer is dirty (never silently drop typed work), then close.
local function cancel()
    if is_dirty() then
        ui.confirm({
            prompt = "Discard this composer buffer?",
            default_no = true,
            callback = function(yes)
                if yes then
                    close()
                end
            end,
        })
    else
        close()
    end
end

-- ── open ─────────────────────────────────────────────────────────────────────

--- Build an editable-block provider. `is_body` selects the body block (per-mode cursor + omnifunc) vs
--- the title block (per-mode cursor only). `prefill` is the initial line set.
---@param prefill string[]
---@param filetype string
---@param is_body boolean
---@return table
local function editable_provider(prefill, filetype, is_body)
    local painted = false
    return {
        editable = true,
        cursorline = false,
        filetype = filetype,
        update = function(pan)
            if not painted then
                painted = true
                if is_body then
                    cstate.body_buf = pan.buf
                else
                    cstate.title_buf = pan.buf
                end
                surface.paint(pan, #prefill > 0 and prefill or { "" }, {})
            end
        end,
        keys = function(_, pan)
            if is_body then
                cstate.body_buf = pan.buf
            else
                cstate.title_buf = pan.buf
            end
            -- Per-mode cursor: visible while inserting, hidden in normal/visual (the commit-panel precedent).
            cursor.mark_cursor_buffer(pan.buf, "n-v-c:ver1-LvimUtilsHiddenCursor")
            -- @-mention / #topic completion (the shared refs component: omnifunc + the optional cmp source).
            if is_body and cstate.repo_id then
                require("lvim-forge.refs").attach(pan.buf, cstate.repo_id)
            end
        end,
    }
end

--- The frame title box + subtitle lines per mode.
---@param mode string
---@param repo_label string
---@return table title, table[] subtitle
local function chrome(mode, repo_label)
    if mode == "comment" then
        return { icon = GLYPH.comment, text = "Comment" }, {
            { icon = GLYPH.arrow, text = ("on #%s in %s"):format(cstate.number, repo_label), hl = "LvimForgeMeta" },
        }
    elseif mode == "edit" then
        local what = (cstate.target and cstate.target.kind == "description") and "the description" or "a comment"
        return { icon = GLYPH.pencil, text = "Edit" }, {
            {
                icon = GLYPH.arrow,
                text = ("%s on #%s in %s"):format(what, cstate.number, repo_label),
                hl = "LvimForgeMeta",
            },
        }
    elseif mode == "review" then
        local sub = { { icon = GLYPH.arrow, text = cstate.subtext or repo_label, hl = "LvimForgeMeta" } }
        return { icon = GLYPH.review, text = cstate.heading or "Review" }, sub
    elseif mode == "pr" then
        local bh = ("%s %s %s"):format(cstate.base or "?", GLYPH.arrow, cstate.head or "?")
        return { icon = GLYPH.pull, text = "New pull request" .. (cstate.draft and " (draft)" or "") }, {
            { icon = GLYPH.branch, text = bh .. "  in " .. repo_label, hl = "LvimForgeMeta" },
            { text = "gb base · gh head · gd draft · <C-c><C-c> create", hl = "LvimForgeDate" },
        }
    end
    return { icon = GLYPH.issue, text = "New issue" }, {
        { icon = GLYPH.arrow, text = "in " .. repo_label, hl = "LvimForgeMeta" },
        { text = "@ mention · # topic complete with <C-x><C-o>", hl = "LvimForgeDate" },
    }
end

-- ── create-PR base/head pickers + draft toggle (canonical lvim-ui, self-contained git refs) ──────────

--- The branch names to offer in a base/head picker: local branches first, then remote-tracking branches
--- (short name, deduped, `HEAD` dropped). Self-contained via `lvim-forge.git` (`git branch` / `git branch
--- -r`); a standalone install with no lvim-git needs no ref seam.
---@param git_root string
---@param cb fun(refs: string[])
local function refs_for_pick(git_root, cb)
    local git = require("lvim-forge.git")
    git.local_branches(git_root, function(locals)
        git.remote_branches(git_root, function(remotes)
            local seen, out = {}, {}
            for _, b in ipairs(locals or {}) do
                if not seen[b] then
                    seen[b] = true
                    out[#out + 1] = b
                end
            end
            for _, r in ipairs(remotes or {}) do
                local short = r:gsub("^[^/]+/", "")
                if short ~= "HEAD" and not seen[short] then
                    seen[short] = true
                    out[#out + 1] = short
                end
            end
            cb(out)
        end)
    end)
end

--- Re-pick the PR base ("base") or head ("head") branch via `ui.select` (never `vim.ui.*`). Updates
--- `cstate` and notifies the new target; the submit reads `cstate.base`/`cstate.head`.
---@param which "base"|"head"
local function pick_ref(which)
    if cstate.mode ~= "pr" then
        return
    end
    local detected = require("lvim-forge.client").detect(cstate.root)
    local git_root = detected and detected.root
    if not git_root then
        notify("not inside a git working tree", vim.log.levels.WARN)
        return
    end
    refs_for_pick(git_root, function(refs)
        local items, current_item = {}, nil
        local current = (which == "base") and cstate.base or cstate.head
        for _, b in ipairs(refs) do
            local it = { label = b, ref = b }
            items[#items + 1] = it
            if b == current then
                current_item = it
            end
        end
        if #items == 0 then
            notify("no branches to choose from", vim.log.levels.WARN)
            return
        end
        ui.select({
            title = which == "base" and "Base branch" or "Head branch",
            items = items,
            current_item = current_item,
            callback = function(confirmed, idx)
                if not confirmed or not idx then
                    return
                end
                local ref = items[idx] and items[idx].ref
                if not ref then
                    return
                end
                if which == "base" then
                    cstate.base = ref
                else
                    cstate.head = ref
                end
                notify((which == "base" and "base = " or "head = ") .. ref)
            end,
        })
    end)
end

--- Toggle the PR draft flag (`gd`).
local function toggle_draft()
    if cstate.mode ~= "pr" then
        return
    end
    cstate.draft = not cstate.draft
    notify("draft = " .. tostring(cstate.draft))
end

--- Resolve the PR base/head + prefill title/body from the commits, then continue with `next(opts)`. Base
--- defaults to the repo default branch, head to the current git branch; the title is prefilled from the
--- latest commit subject and the body from the `base..head` commit list (a bullet per commit when several).
--- Aborts with a clean notify when there is no feature branch (detached / on the base).
---@param opts table
---@param repo_id integer?
---@param next fun(opts: table)
local function prepare_pr(opts, repo_id, next)
    local git = require("lvim-forge.git")
    local repo = repo_id and db.repository(repo_id)
    local base = (repo and type(repo.default_branch) == "string" and repo.default_branch ~= "" and repo.default_branch)
        or "main"
    local detected = require("lvim-forge.client").detect(opts.root)
    local git_root = detected and detected.root
    if not git_root then
        notify("not inside a git working tree — cannot open a pull request here", vim.log.levels.WARN)
        return
    end
    git.current_branch(git_root, function(head)
        if not head or head == "" or head == "HEAD" then
            notify("checkout a feature branch first (HEAD is detached)", vim.log.levels.WARN)
            return
        end
        if head == base then
            notify(
                ("you are on the base branch '%s' — checkout your feature branch first"):format(base),
                vim.log.levels.WARN
            )
            return
        end
        git.commits_between(git_root, base, head, function(commits)
            commits = commits or {}
            if (not opts.title_prefill or opts.title_prefill == "") and #commits > 0 then
                opts.title_prefill = commits[1].subject -- the latest commit subject
            end
            if not opts.prefill or opts.prefill == "" then
                if #commits == 1 then
                    opts.prefill = commits[1].body
                elseif #commits > 1 then
                    local ls = {}
                    for i = #commits, 1, -1 do -- oldest → newest so the body reads chronologically
                        ls[#ls + 1] = "- " .. commits[i].subject
                    end
                    opts.prefill = table.concat(ls, "\n")
                end
            end
            opts.base, opts.head = base, head
            next(opts)
        end)
    end)
end

--- Open the composer.
--- `opts = { mode, root?, repo_id?, number?, kind?, target?, prefill?, title_prefill?, repo_label?, action_opts?, base?, head?, draft?, on_submit?, heading?, subtext? }`.
--- The `review` mode is a GENERIC body editor: the caller passes `on_submit(body, done)` (a pending
--- line/reply comment, or the submit summary) + `heading`/`subtext` for the frame chrome.
---@param opts { mode: "comment"|"edit"|"issue"|"pr"|"review", root?: string|integer, repo_id?: integer, number?: integer, kind?: string, target?: table, prefill?: string, title_prefill?: string, repo_label?: string, action_opts?: table, base?: string, head?: string, draft?: boolean, on_submit?: fun(body: string, done: fun(ok: boolean, res?: table)), heading?: string, subtext?: string }
function M.open(opts)
    opts = opts or {}
    if not enabled("topic") and (opts.mode == "comment" or opts.mode == "edit") then
        notify("the topic component is disabled (config.topic.enabled = false)")
        return
    end
    if not db.available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end
    if cstate.handle then
        close()
    end

    local mode = opts.mode or "comment"
    -- Resolve the repo id for the completion source (best-effort; nil degrades to no completion).
    local repo_id = opts.repo_id
    local repo_label = opts.repo_label
    if not repo_id or not repo_label then
        local d = require("lvim-forge.client").detect(opts.root)
        local rr = d and db.repo_for_detect(d)
        if rr then
            repo_id = repo_id or rr.id
            repo_label = repo_label or ("%s/%s"):format(rr.owner, rr.name)
        end
    end

    -- Build the surface from the (possibly PR-prepared) opts. For PR mode `prepare_pr` first fills
    -- opts.base/head + the title/body prefill asynchronously, so the surface open is deferred to here.
    local function open_surface()
        cstate = {
            mode = mode,
            root = opts.root,
            repo_id = repo_id,
            number = opts.number and tonumber(opts.number) or nil,
            kind = opts.kind,
            target = opts.target,
            action_opts = opts.action_opts,
            base = opts.base,
            head = opts.head,
            draft = opts.draft or false,
            on_submit = opts.on_submit,
            heading = opts.heading,
            subtext = opts.subtext,
            initial_title = opts.title_prefill or "",
            initial_body = opts.prefill or "",
        }

        local body_lines = vim.split((opts.prefill or ""), "\n", { plain = true })
        local title_lines = vim.split((opts.title_prefill or ""), "\n", { plain = true })
        local title, subtitle = chrome(mode, repo_label or "this repo")

        local blocks = {}
        local want_title = mode == "issue" or mode == "pr"
        if want_title then
            blocks[#blocks + 1] = {
                id = "title",
                provider = editable_provider(title_lines, "text", false),
                size = { height = { fixed = 1 } },
            }
        end
        blocks[#blocks + 1] = { id = "body", provider = editable_provider(body_lines, "markdown", true) }

        -- Base keymaps + the PR-only base/head/draft pickers (canonical ui.select; normal-mode g-prefixed).
        local keymaps = {
            { key = { "<C-c><C-c>" }, run = submit },
            { key = { "<C-c><C-k>" }, run = cancel },
            { key = { "q" }, run = cancel },
        }
        if mode == "pr" then
            keymaps[#keymaps + 1] = {
                key = { "gb" },
                run = function()
                    pick_ref("base")
                end,
            }
            keymaps[#keymaps + 1] = {
                key = { "gh" },
                run = function()
                    pick_ref("head")
                end,
            }
            keymaps[#keymaps + 1] = { key = { "gd" }, run = toggle_draft }
        end

        cstate.handle = surface.open({
            mode = "float",
            enter = true,
            title = title,
            title_pos = "center",
            subtitle = subtitle,
            size = { width = { fixed = 0.7 }, height = { fixed = 0.7 } },
            content = { blocks = blocks },
            -- No bare q/<Esc> close: the body is editable and a normal-mode `q` maps to the dirty-guarded
            -- cancel (below); Esc just leaves insert. This keeps typed work from being dropped by a stray key.
            close_keys = {},
            keymaps = keymaps,
            footer = {
                bars = {
                    {
                        align = "center",
                        items = {
                            surface.button(
                                { name = "submit", key = "<C-c><C-c>", style = "action", run = submit },
                                "action"
                            ),
                            surface.button(
                                { name = "cancel", key = "<C-c><C-k>", style = "action", run = cancel },
                                "action"
                            ),
                        },
                    },
                },
            },
            on_close = function()
                if cstate.body_buf then
                    require("lvim-forge.refs").detach(cstate.body_buf)
                end
                cstate = {}
            end,
        })

        if not cstate.handle then
            return
        end

        -- Land the cursor: the title first for a new issue/PR, else the body; insert for a fresh (empty) block.
        vim.schedule(function()
            if not (cstate.handle and cstate.handle.focus_block) then
                return
            end
            if want_title then
                pcall(cstate.handle.focus_block, "title")
                vim.cmd("startinsert")
            else
                pcall(cstate.handle.focus_block, "body")
                if mode == "comment" or mode == "review" then
                    vim.cmd("startinsert")
                end
            end
        end)
    end

    if mode == "pr" then
        -- Resolve base/head + the commit-derived prefill, THEN open (aborts cleanly with a notify when
        -- there is no feature branch to open the PR from).
        prepare_pr(opts, repo_id, function()
            open_surface()
        end)
    else
        open_surface()
    end
end

--- Whether the composer is open.
---@return boolean
function M.is_open()
    return cstate.handle ~= nil
end

return M
