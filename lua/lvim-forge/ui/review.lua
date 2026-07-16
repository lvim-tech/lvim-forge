-- lvim-forge.ui.review: the code-review workspace — the PR's review THREADS overlaid on the actual diff,
-- plus the WRITE layer. It DISPLAYS every thread (and the LOCAL pending review's draft comments) anchored at
-- its file/line, and drives the write verbs: `cc` a new line/range comment, `cr` a reply, `cx` resolve /
-- unresolve (GraphQL, caps-gated), `cs` the SUBMIT transient (Approve / Request changes / Comment + a
-- summary via the composer). `cc`/`cr` APPEND to a DB-backed pending review (instant, offline, restart-safe);
-- `cs` submits the whole batch through `actions.submit_review` → `sync.mutate`. All write verbs go through
-- `actions.lua` (never a request built here) and refresh the overlay from the cache on `LvimForgeTopicChanged`.
--
-- PRIMARY PATH (lvim-git present) — the plugin NEVER renders its own diff (a non-goal): it fetches the PR
-- head (`git fetch pull/<n>/head`) and hands the `base...head` range to `require("lvim-git.ui.diff").open`
-- (the exact Phase-7 seam), then OVERLAYS the review layer onto the diff's real file buffers as `virt_lines`
-- extmarks. lvim-git's diff shows ONE file at a time in unnamed scratch buffers, so the buffer↔path mapping
-- can't be discovered from outside — it is exposed by the Phase-9 lvim-git seam: the diff fires
-- `User LvimGitDiffFileLoaded { path, mode, buf_base, buf_work, buf_inline }` when a file renders (our anchor
-- hook) and offers `diff.show_file(path)` to jump the diff across files (drives `]t`/`[t`). We add nothing to
-- the diff itself — only listen + call.
--
-- Each thread renders collapsed as a one-liner (`➤ author  first-body-line  [resolved]/[outdated]  ▸ (N)`);
-- `<Tab>`/`za`/`<CR>` on the thread's line toggles the FULL thread (every comment: author · rel-date + body).
-- `]t`/`[t` walk every thread across all files in file→line order (jumping the diff to another file via the
-- seam when needed). Unresolved threads show by default; resolved ones are hidden unless
-- `config.review.show_resolved`.
--
-- FALLBACK PATH (no lvim-git) — a plain `lvim-ui.tabs` surface in the workspace tab renders per-file unified
-- hunks (from `git diff base...head`, split per file) with the SAME thread anchors interleaved at the matching
-- line (read-only, minimal). Threads with no matching diff line are listed under their file.
--
-- Renders from the local SQLite cache ONLY; refreshes on `LvimForgeTopicChanged`/`LvimForgePullDone` for this
-- PR (re-pull threads → re-place overlays). Layout `tab` by default (the diff owns its own tabpage; the
-- fallback uses `ui/workspace.lua`).
--
-- PUBLIC: open / is_open / close. The model builders (build_anchors / virt_for / parse_unified /
-- build_unified_model) are exposed for the headless overlay-model tests.
--
---@module "lvim-forge.ui.review"

local api = vim.api
local config = require("lvim-forge.config")
local commands = require("lvim-forge.commands")
local state = require("lvim-forge.state")
local db = require("lvim-forge.db")
local sync = require("lvim-forge.sync")
local git = require("lvim-forge.git")
local actions = require("lvim-forge.actions")
local composer = require("lvim-forge.ui.composer")
local transient = require("lvim-forge.transient")
local workspace = require("lvim-forge.ui.workspace")
local ui = require("lvim-ui")

local M = {}

--- The logical view id (layout resolution, the workspace tab marker, the open-panel registry).
---@type string
local VIEW = "review"

-- ── glyphs (verified single-width Nerd Font, + the `➤` pointer canon) ──────────
local GLYPH = {
    review = "\u{f441}", --  nf-oct-eye (border title)
    pointer = "➤", -- comment author pointer (the canon)
    collapsed = "\u{f0da}", --  nf-fa-caret_right (collapsed thread)
    expanded = "\u{f0d7}", --  nf-fa-caret_down (expanded thread)
    file_added = "\u{f457}", --  nf-oct-diff_added
    file_modified = "\u{f459}", --  nf-oct-diff_modified
    file_removed = "\u{f458}", --  nf-oct-diff_removed
    file_renamed = "\u{f47c}", --  nf-oct-diff_renamed
}

---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-forge: " .. msg, level or vim.log.levels.INFO)
end

--- Truthy for a sqlite boolean column (1 / true).
---@param v any
---@return boolean
local function truthy(v)
    return v == 1 or v == true
end

-- ── time helpers (UTC ISO-8601 → a short relative date; mirrors ui/topic.lua) ──
---@param iso? string
---@return integer?
local function iso_epoch(iso)
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

---@param iso? string
---@return string
local function rel_date(iso)
    local t = iso_epoch(iso)
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

--- The first non-empty line of a body (the collapsed one-liner preview).
---@param body? string
---@return string
local function first_line(body)
    for line in ((body or "") .. "\n"):gmatch("(.-)\n") do
        local t = vim.trim(line)
        if t ~= "" then
            return t
        end
    end
    return ""
end

--- Body split into non-empty trimmed lines (the expanded comment body).
---@param body? string
---@return string[]
local function body_lines(body)
    local out = {}
    for line in ((body or ""):gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
        out[#out + 1] = line
    end
    -- drop trailing blank lines
    while #out > 0 and vim.trim(out[#out]) == "" do
        out[#out] = nil
    end
    if #out == 0 then
        out[1] = "(empty comment)"
    end
    return out
end

--- Truncate for the collapsed one-liner (byte-safe enough for ASCII/UTF-8 previews).
---@param s string
---@param n integer
---@return string
local function trunc(s, n)
    if #s <= n then
        return s
    end
    return s:sub(1, n - 1) .. "…"
end

-- ── the overlay MODEL (pure — the headless tests drive these) ──────────────────

--- The diff SIDE a thread/comment anchors to: GitHub's LEFT = the old (base) side, everything else
--- (RIGHT / unset) = the new (head) side.
---@param side? string
---@return "new"|"old"
function M.side_of(side)
    return side == "LEFT" and "old" or "new"
end

---@class LvimForgeReviewAnchor
---@field id         string   the stable overlay id ("th:<thread.id>" / "pend:<post.id>")
---@field thread_db_id?    integer       the cached `threads` row id (a real thread — the `cx` target)
---@field thread_forge_id? integer|string the thread's root REST comment id (the `cr` in_reply_to target)
---@field node_id?   string   the thread's GraphQL node id when known (the `cx` resolve key; else fetched)
---@field path       string   the file the thread anchors to
---@field line       integer  the 1-based line on its side
---@field side       "new"|"old"
---@field resolved   boolean
---@field outdated   boolean
---@field pending    boolean  a draft (pending-review) comment — the user's own, not yet submitted
---@field comments   { author?: string, created?: string, body?: string }[]
---@field count      integer

--- Build the ordered anchor list from a PR's threads + posts + reviews. Each THREAD becomes an anchor whose
--- comments are the review-comment posts linked by `thread_id == thread.forge_id`; a PENDING review's
--- review-comments that belong to NO thread become their own (pending) anchors so an interrupted review still
--- shows. Resolved threads are dropped unless `show_resolved`. Anchors with no resolvable line are dropped
--- (they cannot be placed). The result is sorted file → line → id (the `]t`/`[t` order).
---@param model { threads: table[], posts: table[], reviews: table[], show_resolved?: boolean }
---@return LvimForgeReviewAnchor[]
function M.build_anchors(model)
    local threads = model.threads or {}
    local posts = model.posts or {}
    local reviews = model.reviews or {}
    local show_resolved = model.show_resolved == true

    -- The key set a PENDING review-comment's `review_id` matches: a REMOTE native pending review keys by
    -- its forge_id; a LOCAL draft review (forge_id unset — created by `cc`/`cr`) keys by its local db id
    -- (a draft comment's `review_id` holds that id). Either way the comment shows with a `[pending]` tag.
    local pending_review = {}
    for _, rv in ipairs(reviews) do
        if rv.state == "pending" then
            if rv.forge_id ~= nil then
                pending_review[tostring(rv.forge_id)] = true
            end
            if rv.id ~= nil then
                pending_review[tostring(rv.id)] = true
            end
        end
    end

    ---@type LvimForgeReviewAnchor[]
    local anchors = {}
    local in_thread = {} ---@type table<any, boolean>  posts already shown under a thread (by forge_id)

    for _, th in ipairs(threads) do
        local resolved = truthy(th.resolved)
        if show_resolved or not resolved then
            local comments = {}
            local line = th.line
            for _, p in ipairs(posts) do
                if p.kind == "review-comment" and th.forge_id ~= nil and p.thread_id == th.forge_id then
                    comments[#comments + 1] = { author = p.author, created = p.created, body = p.body }
                    if p.forge_id ~= nil then
                        in_thread[p.forge_id] = true
                    end
                    line = line or p.line
                end
            end
            if line then
                anchors[#anchors + 1] = {
                    id = "th:" .. tostring(th.id),
                    thread_db_id = th.id,
                    thread_forge_id = th.forge_id,
                    node_id = th.node_id,
                    path = th.path or (comments[1] and "?") or "?",
                    line = line,
                    side = M.side_of(th.side),
                    resolved = resolved,
                    outdated = truthy(th.outdated),
                    pending = false,
                    comments = comments,
                    count = #comments,
                }
            end
        end
    end

    -- Pending review-comments not already grouped under a thread → their own read-only anchors.
    for _, p in ipairs(posts) do
        if
            p.kind == "review-comment"
            and p.line
            and p.path
            and p.review_id ~= nil
            and pending_review[tostring(p.review_id)]
            and not (p.forge_id ~= nil and in_thread[p.forge_id])
        then
            anchors[#anchors + 1] = {
                id = "pend:" .. tostring(p.id),
                path = p.path,
                line = p.line,
                side = M.side_of(p.side),
                resolved = false,
                outdated = truthy(p.outdated),
                pending = true,
                comments = { { author = p.author, created = p.created, body = p.body } },
                count = 1,
            }
        end
    end

    table.sort(anchors, function(a, b)
        if a.path ~= b.path then
            return a.path < b.path
        end
        if a.line ~= b.line then
            return a.line < b.line
        end
        return a.id < b.id
    end)
    return anchors
end

--- The collapsed one-liner as a `virt_lines` block (a single virt line of `{text, hl}` chunks).
---@param a LvimForgeReviewAnchor
---@return table[][]
function M.collapsed_virt(a)
    local marker = a.pending and "LvimForgeReviewPending" or "LvimForgeReviewMarker"
    local first = a.comments[1] or {}
    local chunks = {
        { "  ", "LvimForgeReviewBody" },
        { GLYPH.pointer .. " ", marker },
        { first.author or "?", "LvimForgeReviewAuthor" },
        { "  ", "LvimForgeReviewBody" },
        { trunc(first_line(first.body), 60), "LvimForgeReviewBody" },
    }
    if a.pending then
        chunks[#chunks + 1] = { "  [pending]", "LvimForgeReviewPending" }
    end
    if a.resolved then
        chunks[#chunks + 1] = { "  [resolved]", "LvimForgeReviewResolved" }
    end
    if a.outdated then
        chunks[#chunks + 1] = { "  [outdated]", "LvimForgeReviewOutdated" }
    end
    chunks[#chunks + 1] = { ("  %s (%d)"):format(GLYPH.collapsed, a.count), "LvimForgeReviewCaret" }
    return { chunks }
end

--- The full thread as a `virt_lines` block: a header line (`▾ thread (N)` + tags) then, per comment, an
--- author · rel-date line and its indented body lines.
---@param a LvimForgeReviewAnchor
---@return table[][]
function M.expanded_virt(a)
    local marker = a.pending and "LvimForgeReviewPending" or "LvimForgeReviewMarker"
    ---@type table[][]
    local lines = {}
    local head = {
        { "  ", "LvimForgeReviewBody" },
        { ("%s thread (%d)"):format(GLYPH.expanded, a.count), "LvimForgeReviewCaret" },
    }
    if a.pending then
        head[#head + 1] = { "  [pending]", "LvimForgeReviewPending" }
    end
    if a.resolved then
        head[#head + 1] = { "  [resolved]", "LvimForgeReviewResolved" }
    end
    if a.outdated then
        head[#head + 1] = { "  [outdated]", "LvimForgeReviewOutdated" }
    end
    lines[#lines + 1] = head
    for _, cmt in ipairs(a.comments) do
        lines[#lines + 1] = {
            { "  " .. GLYPH.pointer .. " ", marker },
            { cmt.author or "?", "LvimForgeReviewAuthor" },
            { "  ·  " .. rel_date(cmt.created), "LvimForgeReviewDate" },
        }
        for _, bl in ipairs(body_lines(cmt.body)) do
            lines[#lines + 1] = { { "      ", "LvimForgeReviewBody" }, { bl, "LvimForgeReviewBody" } }
        end
    end
    return lines
end

--- The `virt_lines` block for an anchor in its current (collapsed/expanded) state.
---@param a LvimForgeReviewAnchor
---@param expanded boolean
---@return table[][]
function M.virt_for(a, expanded)
    if expanded then
        return M.expanded_virt(a)
    end
    return M.collapsed_virt(a)
end

--- Parse a unified diff body into rows carrying new/old-side line numbers (the fallback anchoring math).
---@param text string
---@return { text: string, kind: string, new_ln?: integer, old_ln?: integer }[]
function M.parse_unified(text)
    ---@type { text: string, kind: string, new_ln?: integer, old_ln?: integer }[]
    local out = {}
    local new_ln, old_ln
    for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
        local oh, nh = line:match("^@@%s*%-(%d+)[,%d]*%s+%+(%d+)")
        if line:match("^@@") then
            old_ln = tonumber(oh) or old_ln
            new_ln = tonumber(nh) or new_ln
            out[#out + 1] = { text = line, kind = "hunk" }
        elseif line:match("^%+%+%+") or line:match("^%-%-%-") or line:match("^diff ") or line:match("^index ") then
            out[#out + 1] = { text = line, kind = "header" }
        elseif new_ln then
            local c = line:sub(1, 1)
            if c == "+" then
                out[#out + 1] = { text = line, kind = "add", new_ln = new_ln }
                new_ln = new_ln + 1
            elseif c == "-" then
                out[#out + 1] = { text = line, kind = "del", old_ln = old_ln }
                old_ln = old_ln + 1
            else
                out[#out + 1] = { text = line, kind = "context", new_ln = new_ln, old_ln = old_ln }
                new_ln = new_ln + 1
                old_ln = old_ln + 1
            end
        end
    end
    return out
end

--- Build the flat descriptor list the fallback renders: file headers, unified-diff rows (when a per-file
--- diff is available), and thread rows anchored at the matching side line (leftovers appended under the
--- file). Pure — the headless test asserts its shape.
---@param files table[]                          the pr_files rows (file order + status)
---@param anchors LvimForgeReviewAnchor[]         from build_anchors
---@param diff_by_path? table<string, string>    path → unified diff text (nil = no diff lines)
---@return { kind: "file"|"diff"|"thread", path: string, [string]: any }[]
function M.build_unified_model(files, anchors, diff_by_path)
    files = files or {}
    anchors = anchors or {}
    local by_path = {} ---@type table<string, LvimForgeReviewAnchor[]>
    for _, a in ipairs(anchors) do
        by_path[a.path] = by_path[a.path] or {}
        table.insert(by_path[a.path], a)
    end
    -- file order: the pr_files order, then any anchor-only paths (a thread on a file not in the set).
    local order, seen = {}, {}
    for _, f in ipairs(files) do
        if f.path and not seen[f.path] then
            seen[f.path] = true
            order[#order + 1] = f.path
        end
    end
    for _, a in ipairs(anchors) do
        if not seen[a.path] then
            seen[a.path] = true
            order[#order + 1] = a.path
        end
    end

    local rows = {}
    for _, path in ipairs(order) do
        local f
        for _, x in ipairs(files) do
            if x.path == path then
                f = x
                break
            end
        end
        rows[#rows + 1] = {
            kind = "file",
            path = path,
            status = f and f.status,
            additions = f and f.additions,
            deletions = f and f.deletions,
        }
        local file_anchors = by_path[path] or {}
        local placed = {}
        local text = diff_by_path and diff_by_path[path]
        if text and text ~= "" then
            for _, l in ipairs(M.parse_unified(text)) do
                rows[#rows + 1] = { kind = "diff", path = path, text = l.text, dkind = l.kind }
                for _, a in ipairs(file_anchors) do
                    if not placed[a.id] then
                        local match = (a.side == "new" and l.new_ln == a.line)
                            or (a.side == "old" and l.old_ln == a.line)
                        if match then
                            rows[#rows + 1] = { kind = "thread", path = path, anchor = a }
                            placed[a.id] = true
                        end
                    end
                end
            end
        end
        for _, a in ipairs(file_anchors) do
            if not placed[a.id] then
                rows[#rows + 1] = { kind = "thread", path = path, anchor = a }
                placed[a.id] = true
            end
        end
    end
    return rows
end

-- ── the live review SESSION (one at a time; the augroup callbacks reach it here) ──
---@class LvimForgeReviewSession
---@field active   boolean
---@field mode     "diff"|"fallback"
---@field root     string
---@field remote   string
---@field repo_id  integer
---@field repo_row table
---@field number   integer
---@field range?   string
---@field anchors  LvimForgeReviewAnchor[]
---@field ns       integer
---@field augroup? integer
---@field cur?     table   the last LvimGitDiffFileLoaded payload (path + per-mode buffers)
---@field await_detail? boolean  waiting for the PR detail pull to fill base_ref before opening the diff
---@field handle?  table   the fallback surface handle
---@field diff?    table   the lvim-git diff module (diff path)
---@type LvimForgeReviewSession?
local S = nil

--- Reload the PR model from the cache and rebuild `S.anchors`. Returns the topic row (nil = not cached yet).
---@return table?
local function reload_anchors()
    if not S then
        return nil
    end
    local topic = db.get_topic(S.repo_id, S.number, "pullreq")
    if not topic then
        S.anchors = {}
        return nil
    end
    S.anchors = M.build_anchors({
        threads = db.threads(topic.id),
        posts = db.posts(topic.id),
        reviews = db.reviews(topic.id),
        show_resolved = config.review and config.review.show_resolved == true,
    })
    return topic
end

-- ── overlay placement on the lvim-git diff buffers ─────────────────────────────

--- The diff buffer an anchor belongs in for a given file-load payload (inline → the single buffer; split →
--- the new-side or base-side buffer per the anchor's side).
---@param a { side: "new"|"old" }  an anchor (only its side is read)
---@param ev table  the LvimGitDiffFileLoaded payload
---@return integer?
local function anchor_buffer(a, ev)
    if ev.mode == "inline" then
        return ev.buf_inline
    end
    if a.side == "old" then
        return ev.buf_base
    end
    return ev.buf_work
end

--- (Re)place the review overlays for the just-loaded file: clear our namespace on its buffers, then set one
--- `virt_lines` extmark per matching anchor at its side line (or an eol `virt_text` summary when
--- `config.review.virt_lines` is off).
---@param ev table  the LvimGitDiffFileLoaded payload
local function place_overlays(ev)
    if not S then
        return
    end
    local as_virt = not (config.review and config.review.virt_lines == false)
    for _, buf in ipairs({ ev.buf_base, ev.buf_work, ev.buf_inline }) do
        if buf and api.nvim_buf_is_valid(buf) then
            api.nvim_buf_clear_namespace(buf, S.ns, 0, -1)
        end
    end
    for _, a in ipairs(S.anchors) do
        if a.path == ev.path then
            local buf = anchor_buffer(a, ev)
            if buf and api.nvim_buf_is_valid(buf) then
                local lc = api.nvim_buf_line_count(buf)
                local row = math.max(0, math.min(a.line - 1, math.max(0, lc - 1)))
                local expanded = state.review.expanded[a.id] == true
                if as_virt then
                    pcall(api.nvim_buf_set_extmark, buf, S.ns, row, 0, {
                        virt_lines = M.virt_for(a, expanded),
                        virt_lines_above = false,
                    })
                else
                    local marker = a.pending and "LvimForgeReviewPending" or "LvimForgeReviewMarker"
                    pcall(api.nvim_buf_set_extmark, buf, S.ns, row, 0, {
                        virt_text = { { ("  %s (%d)"):format(GLYPH.pointer, a.count), marker } },
                        virt_text_pos = "eol",
                    })
                end
            end
        end
    end
end

-- ── the WRITE verbs (cc new comment · cr reply · cx resolve · cs submit) ───────────────────────────────
-- All go through `actions.lua` (never a request built here). `cc`/`cr` append to the DB-backed pending
-- review (LOCAL draft — instant, offline); the overlay re-anchors the new `[pending]` comment on the
-- `LvimForgeTopicChanged` the action fires. `cx` resolves via GraphQL (caps-gated by the action). `cs`
-- opens the SUBMIT transient (verdict + a summary via the composer) and submits the whole batch.

--- The current diff line as a review-comment anchor (`cc`). `sline` marks the START of a visual range (a
--- multi-line comment); nil = a single line. Side is GitHub's LEFT (base) / RIGHT (head). nil outside a
--- diff file buffer.
---@param sline? integer  the visual-range start line (for a range comment)
---@param eline? integer  the range end line (defaults to the cursor line)
---@return { path: string, line: integer, side: "LEFT"|"RIGHT", start_line?: integer }?
local function cursor_target(sline, eline)
    if not (S and S.cur) then
        return nil
    end
    local buf = api.nvim_get_current_buf()
    if buf ~= S.cur.buf_base and buf ~= S.cur.buf_work and buf ~= S.cur.buf_inline then
        return nil
    end
    local side = (buf == S.cur.buf_base) and "LEFT" or "RIGHT"
    local line = eline or api.nvim_win_get_cursor(0)[1]
    local start_line = (sline and sline < line) and sline or nil
    return { path = S.cur.path, line = line, side = side, start_line = start_line }
end

--- The review thread the verbs act on: the anchor exactly on the cursor line (diff), else the current
--- `]t`/`[t` index anchor (and always the index anchor in the fallback panel). nil = no threads.
---@return LvimForgeReviewAnchor?
local function current_thread_anchor()
    if not S then
        return nil
    end
    if S.mode == "diff" and S.cur then
        local buf = api.nvim_get_current_buf()
        local row = api.nvim_win_get_cursor(0)[1]
        local side = (buf == S.cur.buf_base) and "old" or "new"
        for _, a in ipairs(S.anchors) do
            if a.path == S.cur.path and a.side == side and a.line == row then
                return a
            end
        end
    end
    return S.anchors[state.review.index]
end

--- The trailing verb opts every write action shares (target THIS repo without a filesystem detect).
---@return table
local function verb_opts()
    return { repo_row = S and S.repo_row }
end

--- `cc` — a NEW line/range review comment at the cursor (a visual range → a multi-line comment). Opens the
--- composer; on submit it appends a draft to the pending review.
---@param sline? integer  a visual-range start line
---@param eline? integer  a visual-range end line
local function do_cc(sline, eline)
    if not S then
        return
    end
    local tgt = cursor_target(sline, eline)
    if not tgt then
        notify("place the cursor on a changed line in the diff to add a comment", vim.log.levels.WARN)
        return
    end
    local where = tgt.start_line and ("%s:%d-%d"):format(tgt.path, tgt.start_line, tgt.line)
        or ("%s:%d"):format(tgt.path, tgt.line)
    composer.open({
        mode = "review",
        root = S.root,
        repo_id = S.repo_id,
        heading = "New review comment",
        subtext = where,
        on_submit = function(body, done)
            if vim.trim(body) == "" then
                notify("nothing to add (the comment is empty)", vim.log.levels.WARN)
                done(false)
                return
            end
            actions.add_review_comment(S.root, S.number, {
                path = tgt.path,
                line = tgt.line,
                side = tgt.side,
                start_line = tgt.start_line,
                body = body,
            }, function(ok, res)
                if not ok then
                    notify("comment failed: " .. ((res and (res.message or res.kind)) or "?"), vim.log.levels.WARN)
                    done(false)
                    return
                end
                notify(("draft comment added (%d pending)"):format((res and res.pending) or 1))
                done(true)
            end, verb_opts())
        end,
    })
end

--- `cr` — reply to the thread the cursor is on (or the current `]t` index). Opens the composer; on submit
--- it appends a draft REPLY to the pending review.
local function do_cr()
    if not S then
        return
    end
    local a = current_thread_anchor()
    if not a then
        notify("no review thread to reply to (use ]t / [t to reach one)", vim.log.levels.WARN)
        return
    end
    if a.pending then
        notify("that is your own pending comment — press cs to submit the review")
        return
    end
    if a.thread_forge_id == nil then
        notify("this thread has no root comment cached — `:LvimForge pull` first", vim.log.levels.WARN)
        return
    end
    composer.open({
        mode = "review",
        root = S.root,
        repo_id = S.repo_id,
        heading = "Reply to thread",
        subtext = ("%s:%d"):format(a.path, a.line),
        on_submit = function(body, done)
            if vim.trim(body) == "" then
                notify("nothing to add (the reply is empty)", vim.log.levels.WARN)
                done(false)
                return
            end
            actions.reply_thread(S.root, S.number, {
                root_comment_id = a.thread_forge_id,
                path = a.path,
                line = a.line,
                side = a.side == "old" and "LEFT" or "RIGHT",
                body = body,
            }, function(ok, res)
                if not ok then
                    notify("reply failed: " .. ((res and (res.message or res.kind)) or "?"), vim.log.levels.WARN)
                    done(false)
                    return
                end
                notify(("draft reply added (%d pending)"):format((res and res.pending) or 1))
                done(true)
            end, verb_opts())
        end,
    })
end

--- `cx` — resolve / unresolve the thread the cursor is on (or the current `]t` index). GraphQL, caps-gated
--- by the action (a non-supporting forge notifies cleanly). No confirm.
local function do_cx()
    if not S then
        return
    end
    local a = current_thread_anchor()
    if not a then
        notify("no review thread on this line (use ]t / [t to reach one)", vim.log.levels.WARN)
        return
    end
    if a.pending then
        notify("a pending comment has no thread to resolve yet — submit the review first")
        return
    end
    if a.thread_db_id == nil then
        notify("this thread cannot be resolved", vim.log.levels.WARN)
        return
    end
    local want = not a.resolved
    notify(("%s %s:%d …"):format(want and "resolving" or "unresolving", a.path, a.line))
    actions.resolve_thread(
        S.root,
        S.number,
        {
            id = a.thread_db_id,
            forge_id = a.thread_forge_id,
            node_id = a.node_id,
        },
        want,
        function(ok, res)
            if not ok then
                notify("resolve failed: " .. ((res and (res.message or res.kind)) or "?"), vim.log.levels.WARN)
                return
            end
            notify(res and res.resolved and "thread resolved" or "thread unresolved")
        end,
        verb_opts()
    )
end

-- ── the SUBMIT transient (shared engine) — verdict switch + a summary via the composer + pending count ──

--- The submit transient's Submit action: read the verdict, open the composer for the summary, then submit
--- the batch (gating APPROVE / REQUEST_CHANGES behind `ui.confirm` when `confirm_destructive`).
---@param _ string[]
---@param ctx table  `{ selection = { root, number, repo_row, repo_id, pending } }`
local function submit_action(_, ctx)
    local sel = ctx.selection or {}
    local number = sel.number
    if not number then
        return
    end
    local rows = ctx.rows or {}
    local verdict = (rows["-v"] and rows["-v"].value) or (config.review and config.review.default_verdict) or "comment"
    local EVENT = { comment = "COMMENT", approve = "APPROVE", ["request-changes"] = "REQUEST_CHANGES" }
    local event = EVENT[verdict] or "COMMENT"

    ---@param body string
    local function fire(body)
        actions.submit_review(sel.root, number, { event = event, body = body }, function(ok, res)
            if not ok then
                notify("submit failed: " .. ((res and (res.message or res.kind)) or "?"), vim.log.levels.WARN)
                return
            end
            notify(("review submitted (%s)"):format(verdict))
        end, { repo_row = sel.repo_row })
    end

    composer.open({
        mode = "review",
        root = sel.root,
        repo_id = sel.repo_id,
        heading = ("Submit review (%s)"):format(verdict),
        subtext = ("#%d · %d pending comment%s"):format(number, sel.pending or 0, (sel.pending == 1) and "" or "s"),
        on_submit = function(body, done)
            local destructive = event == "APPROVE" or event == "REQUEST_CHANGES"
            if destructive and config.confirm_destructive then
                ui.confirm({
                    prompt = ("Submit a %s review on #%d?"):format(verdict, number),
                    default_no = true,
                    callback = function(yes)
                        if not yes then
                            done(false)
                            return
                        end
                        done(true)
                        fire(body)
                    end,
                })
            else
                done(true)
                fire(body)
            end
        end,
    })
end

--- The submit transient's Discard action: drop the pending review (confirm when `confirm_destructive`).
---@param _ string[]
---@param ctx table
local function discard_action(_, ctx)
    local sel = ctx.selection or {}
    local number = sel.number
    if not number then
        return
    end
    local function run()
        actions.discard_review(sel.root, number, function(_, res)
            notify(res and res.discarded and "pending review discarded" or "no pending review to discard")
        end, { repo_row = sel.repo_row })
    end
    if config.confirm_destructive then
        ui.confirm({
            prompt = ("Discard the pending review on #%d?"):format(number),
            default_no = true,
            callback = function(yes)
                if yes then
                    run()
                end
            end,
        })
    else
        run()
    end
end

--- (Re)register the submit transient DEF with the live pending count in its title (`define` replaces, so a
--- re-open reflects the current draft count). Static groups; the PR rides in on `ctx.selection`.
---@param pending integer
local function register_submit_transient(pending)
    transient.define({
        id = "review-submit",
        title = ("Submit review · %d pending comment%s"):format(pending, pending == 1 and "" or "s"),
        groups = {
            {
                title = "Verdict",
                infix = {
                    {
                        kind = "option",
                        key = "-v",
                        arg = "--verdict",
                        label = "Verdict",
                        choices = { "comment", "approve", "request-changes" },
                        default = (config.review and config.review.default_verdict) or "comment",
                        level = 1,
                    },
                },
            },
            {
                title = "Actions",
                actions = {
                    { key = "s", label = "Submit review", run = submit_action },
                    { key = "d", label = "Discard pending review", run = discard_action, level = 1 },
                },
            },
        },
    })
end

--- `cs` — open the SUBMIT transient for this review (verdict switch + a summary via the composer + the live
--- pending-comment count).
local function do_cs()
    if not S then
        return
    end
    local pending = 0
    for _, a in ipairs(S.anchors) do
        if a.pending then
            pending = pending + 1
        end
    end
    register_submit_transient(pending)
    transient.open("review-submit", {
        root = S.root,
        selection = {
            root = S.root,
            number = S.number,
            repo_row = S.repo_row,
            repo_id = S.repo_id,
            pending = pending,
        },
    })
end

--- `?` — open the dispatch SCOPED to this review's PR, so it offers the topic verbs (merge / edit /
--- review) alongside the global views. A review is always over a pull request.
local function open_dispatch()
    if not S then
        require("lvim-forge.ui.dispatch").open()
        return
    end
    require("lvim-forge.ui.dispatch").open({
        root = S.root,
        topic = { root = S.root, number = S.number, kind = "pullreq", is_pr = true },
    })
end

-- ── cursor navigation across the diff windows ──────────────────────────────────

--- Move the cursor to `line` in the diff window showing the anchor's side buffer (focusing that window).
---@param a { side: "new"|"old", line: integer }  a full anchor or a lightweight `{ side, line }` jump target
local function move_to_anchor(a)
    if not (S and S.cur) then
        return
    end
    local buf = anchor_buffer(a, S.cur)
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
        if api.nvim_win_get_buf(w) == buf then
            local lc = api.nvim_buf_line_count(buf)
            pcall(api.nvim_win_set_cursor, w, { math.max(1, math.min(a.line, lc)), 0 })
            api.nvim_set_current_win(w)
            return
        end
    end
end

--- `]t` / `[t` — walk every thread across all files (file → line order). Jumps the diff to another file via
--- the lvim-git seam when the target thread is elsewhere (the cursor lands once the file finishes loading).
---@param dir integer  +1 next, -1 prev
local function jump_thread(dir)
    if not S then
        return
    end
    local order = S.anchors
    if #order == 0 then
        notify("no review threads on this pull request")
        return
    end
    local i = (state.review.index or 0) + dir
    if i < 1 then
        i = #order
    elseif i > #order then
        i = 1
    end
    state.review.index = i
    local a = order[i]
    notify(("thread %d/%d  %s:%d%s"):format(i, #order, a.path, a.line, a.resolved and "  [resolved]" or ""))
    if S.mode == "fallback" then
        if S.handle and S.handle.focus then
            S.handle.focus("thread:" .. a.id)
        end
        return
    end
    if S.cur and S.cur.path == a.path then
        move_to_anchor(a)
    else
        state.review.pending_jump = { path = a.path, line = a.line, side = a.side }
        if not (S.diff and S.diff.show_file and S.diff.show_file(a.path)) then
            notify("could not open " .. a.path .. " in the diff", vim.log.levels.WARN)
        end
    end
end

--- `<Tab>`/`za`/`<CR>` — toggle the FULL thread for the anchor on the cursor line (diff path).
local function toggle_at_cursor()
    if not (S and S.cur) then
        return
    end
    local buf = api.nvim_get_current_buf()
    local row = api.nvim_win_get_cursor(0)[1]
    local side = (buf == S.cur.buf_base) and "old" or "new"
    for _, a in ipairs(S.anchors) do
        if a.path == S.cur.path and a.side == side and a.line == row then
            state.review.expanded[a.id] = not (state.review.expanded[a.id] == true)
            place_overlays(S.cur)
            return
        end
    end
    notify("no review thread on this line (use ]t / [t to reach one)")
end

-- ── the help window (canonical cheatsheet — lists the Phase-10 write keys too) ──
local function show_help()
    ui.help({
        title = "Forge review keymaps",
        items = {
            { "]t / [t", "next / previous review thread (all files)" },
            { "<Tab> / za / <CR>", "expand / collapse the thread on this line" },
            { "]f / [f", "next / previous file (diff)" },
            { "]c / [c", "next / previous hunk (diff)" },
            { "cc", "new comment on this line (visual: a range comment)" },
            { "cr", "reply to the thread on this line" },
            { "cx", "resolve / unresolve the thread" },
            { "cs", "submit review (approve / request changes / comment)" },
            { "?", "dispatch (all commands)" },
            { "g?", "this help" },
            { "q / <Esc>", "close the review workspace" },
        },
        close_keys = { "q", "<Esc>" },
    })
end

-- ── diff-buffer key wiring (added on top of lvim-git's diff keys, per loaded file) ──
local wired = {} ---@type table<integer, boolean>  buffers we have already wired (per session)

---@param buf integer?
local function wire_review_keys(buf)
    if not (buf and api.nvim_buf_is_valid(buf)) or wired[buf] then
        return
    end
    wired[buf] = true
    local function map(lhs, fn)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "lvim-forge review" })
    end
    map("]t", function()
        jump_thread(1)
    end)
    map("[t", function()
        jump_thread(-1)
    end)
    map("<Tab>", toggle_at_cursor)
    map("za", toggle_at_cursor)
    map("<CR>", toggle_at_cursor)
    map("cc", function()
        do_cc()
    end)
    map("cr", do_cr)
    map("cx", do_cx)
    map("cs", do_cs)
    map("?", open_dispatch)
    map("g?", show_help)
    -- Visual `cc` → a multi-line (range) comment over the selected lines (leave visual → read the range).
    vim.keymap.set("x", "cc", function()
        local a, b = vim.fn.line("v"), vim.fn.line(".")
        api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
        do_cc(math.min(a, b), math.max(a, b))
    end, { buffer = buf, nowait = true, silent = true, desc = "lvim-forge review" })
end

-- ── teardown ───────────────────────────────────────────────────────────────────
local function teardown()
    if not S then
        return
    end
    if S.augroup then
        pcall(api.nvim_del_augroup_by_id, S.augroup)
    end
    wired = {}
    state.review.pending_jump = nil
    state.panels[VIEW] = nil
    S = nil
end

-- ── the diff-path autocmds (anchor hook + close + refresh) ─────────────────────
local function setup_diff_autocmds()
    if not S then
        return
    end
    if S.augroup then
        pcall(api.nvim_del_augroup_by_id, S.augroup)
    end
    S.augroup = api.nvim_create_augroup("lvim-forge.review", { clear = true })
    local mine = { [("%s/%s"):format(S.repo_row.owner, S.repo_row.name)] = true }
    if type(S.root) == "string" and S.root ~= "" then
        mine[S.root] = true
    end

    -- The anchor hook: a file finished rendering in the diff → (re)place our overlays + wire our keys.
    api.nvim_create_autocmd("User", {
        group = S.augroup,
        pattern = "LvimGitDiffFileLoaded",
        callback = function(ev)
            if not S then
                return
            end
            local d = ev.data
            S.cur = d
            place_overlays(d)
            wire_review_keys(d.buf_base)
            wire_review_keys(d.buf_work)
            wire_review_keys(d.buf_inline)
            -- a cross-file `]t`/`[t` jump completes now that the target file is loaded.
            local pj = state.review.pending_jump
            if pj and pj.path == d.path then
                move_to_anchor({ side = pj.side, line = pj.line, path = pj.path })
                state.review.pending_jump = nil
            end
        end,
    })

    -- lvim-git's diff closed (its `q`, or externally) → tear our session down.
    api.nvim_create_autocmd("User", {
        group = S.augroup,
        pattern = "LvimGitDiffClose",
        callback = function()
            teardown()
        end,
    })

    -- The PR's threads changed (a background detail pull landed) → rebuild anchors + re-place / open.
    api.nvim_create_autocmd("User", {
        group = S.augroup,
        pattern = { "LvimForgeTopicChanged", "LvimForgePullDone" },
        callback = function(ev)
            if not S then
                return
            end
            local dd = ev.data
            if dd and dd.root and not mine[dd.root] then
                return
            end
            local topic = reload_anchors()
            if S.await_detail and topic and topic.pullreq and topic.pullreq.base_ref then
                S.await_detail = false
                M._open_diff(topic)
            elseif S.cur then
                place_overlays(S.cur)
            end
        end,
    })
end

--- Fetch the PR head and hand the `base...head` range to lvim-git's diffview; overlays follow via the
--- `LvimGitDiffFileLoaded` hook. Internal (also the deferred-open target once a detail pull fills base_ref).
---@param topic table  the PR topic (with .pullreq extras)
function M._open_diff(topic)
    if not S then
        return
    end
    local pr = topic.pullreq
    local stable = ("refs/forge/pr/%d"):format(S.number)
    S.range = ("%s/%s...%s"):format(S.remote, pr.base_ref, stable)
    local diff = S.diff
    notify("fetching #" .. S.number .. " head for review …")
    git.fetch_ref(S.root, S.remote, ("pull/%d/head:%s"):format(S.number, stable), function(fok, ferr)
        if not fok then
            notify("fetch of the pull head failed: " .. (ferr or "?"), vim.log.levels.WARN)
            teardown()
            return
        end
        if not (S and diff and pcall(diff.open, { range = S.range })) then
            notify("could not open the review diff", vim.log.levels.WARN)
            teardown()
        end
    end)
end

-- ── the fallback surface (no lvim-git) ─────────────────────────────────────────

--- The status glyph + highlight for a file row.
---@param status? string
---@return string glyph, string hl
local function file_status(status)
    if status == "added" then
        return GLYPH.file_added, "LvimForgeMetaAdd"
    elseif status == "removed" then
        return GLYPH.file_removed, "LvimForgeMetaDel"
    elseif status == "renamed" then
        return GLYPH.file_renamed, "LvimForgeBranch"
    end
    return GLYPH.file_modified, "LvimForgeCheckPending"
end

--- Split a whole-range `git diff` body into a per-file map (path → its diff chunk).
---@param text? string
---@return table<string, string>
local function split_diff(text)
    local map, cur, path = {}, {}, nil
    for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
        local b = line:match("^diff %-%-git a/.- b/(.+)$")
        if b then
            if path then
                map[path] = table.concat(cur, "\n")
            end
            path, cur = b, { line }
        elseif path then
            cur[#cur + 1] = line
        end
    end
    if path then
        map[path] = table.concat(cur, "\n")
    end
    return map
end

--- Render the fallback panel from the descriptor model: per-file `ui.section` folds holding the unified-diff
--- leaf rows with thread accordions interleaved at their anchor line.
---@param diff_by_path table<string, string>
---@return table[]
local function fallback_rows(diff_by_path)
    if not S then
        return {}
    end
    local files = db.pr_files(db.get_topic(S.repo_id, S.number, "pullreq").id)
    local descriptors = M.build_unified_model(files, S.anchors, diff_by_path)

    ---@param name string
    ---@param text string
    ---@param group string
    local function leaf(name, text, group)
        return {
            type = "action",
            name = name,
            flat = true,
            tight = true,
            icon = "",
            label = text == "" and " " or text,
            text_hl = group,
            run = function() end,
        }
    end

    --- A thread accordion (collapsed one-liner header → per-comment leaves).
    ---@param a LvimForgeReviewAnchor
    ---@return table
    local function thread_row(a)
        local exp = state.review.expanded[a.id] == true
        local children = {}
        for _, cmt in ipairs(a.comments) do
            children[#children + 1] = leaf(
                "t" .. a.id .. ":h" .. tostring(#children),
                (cmt.author or "?") .. "  " .. GLYPH.pointer .. " " .. rel_date(cmt.created),
                "LvimForgeReviewAuthor"
            )
            for _, bl in ipairs(body_lines(cmt.body)) do
                children[#children + 1] =
                    leaf("t" .. a.id .. ":b" .. tostring(#children), "    " .. bl, "LvimForgeReviewBody")
            end
        end
        local tags = a.pending and "  [pending]" or ""
        tags = tags .. (a.resolved and "  [resolved]" or "") .. (a.outdated and "  [outdated]" or "")
        local trow = {
            type = "action",
            name = "thread:" .. a.id,
            flat = true,
            tight = true,
            icon = " " .. (exp and GLYPH.expanded or GLYPH.collapsed) .. " ",
            icon_hl = a.pending and "LvimForgeReviewPending" or "LvimForgeReviewMarker",
            label = ("%s:%d  %s  %s%s"):format(
                a.path,
                a.line,
                GLYPH.pointer,
                first_line((a.comments[1] or {}).body),
                tags
            ),
            text_hl = a.resolved and "LvimForgeReviewResolved" or "LvimForgeReviewBody",
            expanded = exp,
            children = children,
        }
        return trow
    end

    local rows = {}
    local cur_children, cur_section
    local function flush()
        if cur_section then
            cur_section.children = cur_children
            rows[#rows + 1] = cur_section
        end
    end
    for _, d in ipairs(descriptors) do
        if d.kind == "file" then
            flush()
            cur_children = {}
            local g, ghl = file_status(d.status)
            local label = ("%s   +%d -%d"):format(d.path, d.additions or 0, d.deletions or 0)
            cur_section = ui.section({
                name = "file:" .. d.path,
                icon = " " .. g .. " ",
                box_hl = ghl,
                label = label,
                accent = "magenta",
                expanded = true,
                children = {},
            })
        elseif d.kind == "diff" then
            local group = (d.dkind == "add" and "LvimForgeMetaAdd")
                or (d.dkind == "del" and "LvimForgeMetaDel")
                or (d.dkind == "hunk" and "LvimForgeBranch")
                or "LvimForgeReviewBody"
            cur_children[#cur_children + 1] = leaf("d" .. tostring(#cur_children) .. ":" .. d.path, d.text, group)
        elseif d.kind == "thread" then
            cur_children[#cur_children + 1] = thread_row(d.anchor)
        end
    end
    flush()
    if #rows == 0 then
        rows[1] = leaf("empty", "  no changed files or threads cached — `:LvimForge pull`", "LvimForgeReviewBody")
    end
    return rows
end

--- Open the fallback workspace surface (no lvim-git): fetch the range diff (best effort), render per-file
--- hunks + thread accordions in a `lvim-ui.tabs` menu hosted in the workspace tab.
---@param topic table
local function open_fallback(topic)
    if not S then
        return
    end
    S.mode = "fallback"
    local layout = commands.layout_for(VIEW, nil)
    local is_tab = layout == "tab"

    ---@type { handle?: table, tabs?: table[] }
    local st = { handle = nil, tabs = nil }

    local function build(diff_by_path)
        st.tabs = { { label = "Review", icon = GLYPH.review, menu = true, rows = fallback_rows(diff_by_path or {}) } }
        if is_tab then
            workspace.enter(VIEW)
        end
        st.handle = ui.tabs({
            title = { icon = GLYPH.review, text = ("Review #%d"):format(S.number) },
            title_pos = "center",
            tabs = st.tabs,
            layout = is_tab and "float" or layout,
            slot = is_tab and workspace.slot() or nil,
            pad = 0,
            cursorline_hl = "LvimUiCursorLine",
            keymaps = {
                {
                    key = "]t",
                    run = function()
                        jump_thread(1)
                    end,
                },
                {
                    key = "[t",
                    run = function()
                        jump_thread(-1)
                    end,
                },
                { key = "cc", run = do_cc },
                { key = "cr", run = do_cr },
                { key = "cx", run = do_cx },
                { key = "cs", run = do_cs },
                { key = "?", run = open_dispatch },
                { key = "g?", run = show_help },
            },
            callback = function()
                if is_tab then
                    workspace.exit(VIEW)
                end
                teardown()
            end,
        })
        if not st.handle then
            if is_tab then
                workspace.exit(VIEW)
            end
            teardown()
            return
        end
        S.handle = {
            focus = function(name)
                if st.handle and st.handle.focus then
                    st.handle.focus(name)
                end
            end,
            valid = function()
                return st.handle ~= nil and st.handle.valid and st.handle.valid()
            end,
            close = function()
                if st.handle and st.handle.valid and st.handle.valid() then
                    st.handle.close()
                end
            end,
        }
        state.panels[VIEW] = { handle = st.handle }
        -- Refresh on the sync events (re-pull threads → rebuild rows).
        local ag = api.nvim_create_augroup("lvim-forge.review.fallback", { clear = true })
        S.augroup = ag
        api.nvim_create_autocmd("User", {
            group = ag,
            pattern = { "LvimForgeTopicChanged", "LvimForgePullDone" },
            callback = function()
                if not (S and st.handle and st.handle.valid and st.handle.valid()) then
                    return
                end
                reload_anchors()
                st.tabs[1].rows = fallback_rows(diff_by_path or {})
                local idx = st.handle.cursor_index and st.handle.cursor_index() or 1
                st.handle.recalc()
                if st.handle.focus_index then
                    st.handle.focus_index(idx)
                end
            end,
        })
    end

    -- Fetch the whole-range diff once (split per file) so the panel shows real hunks; degrade to no-diff.
    local pr = topic.pullreq
    if S.root and pr and pr.base_ref then
        local stable = ("refs/forge/pr/%d"):format(S.number)
        local range = ("%s/%s...%s"):format(S.remote, pr.base_ref, stable)
        git.fetch_ref(S.root, S.remote, ("pull/%d/head:%s"):format(S.number, stable), function(fok)
            if not S then
                return
            end
            if fok then
                git.diff_range(S.root, range, function(text)
                    if S then
                        build(split_diff(text))
                    end
                end)
            else
                build({})
            end
        end)
    else
        build({})
    end
end

-- ── open / is_open / close ─────────────────────────────────────────────────────

--- Open the READ review workspace for PR `number` in the current tracked repo. Overlays the review threads
--- on lvim-git's diff (fetching the PR head first); without lvim-git it renders the fallback hunk panel.
---@param root? string|integer
---@param number integer|string
---@param opts? { layout?: string }
function M.open(root, number, opts)
    opts = opts or {}
    if not (config.review and config.review.enabled) then
        notify("the review component is disabled (config.review.enabled = false)")
        return
    end
    if not db.available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end
    local num = tonumber(number)
    if not num then
        notify("a pull request number is required (`:LvimForge review <n>`)", vim.log.levels.WARN)
        return
    end
    ---@type integer
    local pr_number = math.floor(num)

    local client = require("lvim-forge.client")
    local detected = client.detect(root or 0)
    if not detected then
        notify("not inside a recognized forge repository", vim.log.levels.WARN)
        return
    end
    local repo_row = db.repo_for_detect(detected)
    if not repo_row then
        notify(
            ("%s/%s is not tracked — `:LvimForge add` to track it"):format(
                detected.owner or "?",
                detected.name or "?"
            ),
            vim.log.levels.WARN
        )
        return
    end
    root = detected.root
    if type(root) ~= "string" or root == "" then
        notify("could not resolve the repository root", vim.log.levels.WARN)
        return
    end

    local topic = db.get_topic(repo_row.id, pr_number, "pullreq")
    if topic and topic.kind ~= "pullreq" then
        notify("the review workspace applies to pull requests only")
        return
    end

    -- Any existing review session closes first (one at a time).
    M.close()

    state.review = { expanded = {}, index = 0 }
    S = {
        active = true,
        mode = "diff",
        root = root,
        remote = (detected.remote or "origin"),
        repo_id = repo_row.id,
        repo_row = repo_row,
        number = pr_number,
        anchors = {},
        ns = api.nvim_create_namespace("lvim-forge.review"),
    }
    reload_anchors()

    -- Fill the cache in the background (threads / files / base_ref) — the refresh event re-anchors.
    local cached = topic ~= nil and topic.pullreq ~= nil
    sync.pull_topic(root, pr_number, { force = not cached })

    local ok_git, diff = pcall(require, "lvim-git.ui.diff")
    if ok_git and type(diff.open) == "function" then
        S.diff = diff
        setup_diff_autocmds()
        if topic and topic.pullreq and topic.pullreq.base_ref then
            M._open_diff(topic)
        else
            -- Not cached deeply enough yet — wait for the detail pull, then open (handled in the refresh cb).
            S.await_detail = true
            notify("fetching pull request detail for #" .. pr_number .. " …")
        end
    else
        if not (topic and topic.pullreq) then
            notify(
                "pull request #" .. pr_number .. " is not cached yet — `:LvimForge pull` first",
                vim.log.levels.WARN
            )
            teardown()
            return
        end
        open_fallback(topic)
    end
end

--- Whether a review workspace is open.
---@return boolean
function M.is_open()
    return S ~= nil and S.active == true
end

--- Open the SUBMIT transient for PR `number` standalone (`:LvimForge review submit`), without the review
--- workspace being open. Resolves the tracked repo, reads the pending-comment count from the cache, and
--- opens the shared submit transient (verdict + a summary via the composer).
---@param root? string|integer
---@param number integer|string
function M.submit(root, number)
    if not (config.review and config.review.enabled) then
        notify("the review component is disabled (config.review.enabled = false)")
        return
    end
    if not db.available() then
        notify("the local database needs sqlite.lua (install kkharji/sqlite.lua)", vim.log.levels.ERROR)
        return
    end
    local num = tonumber(number)
    if not num then
        notify("a pull request number is required (`:LvimForge review submit <n>`)", vim.log.levels.WARN)
        return
    end
    num = math.floor(num)
    local client = require("lvim-forge.client")
    local detected = client.detect(root or 0)
    if not detected then
        notify("not inside a recognized forge repository", vim.log.levels.WARN)
        return
    end
    local repo_row = db.repo_for_detect(detected)
    if not repo_row then
        notify(("%s/%s is not tracked — `:LvimForge add`"):format(detected.owner or "?", detected.name or "?"))
        return
    end
    local pending = db.pending_review_count(repo_row.id, num)
    register_submit_transient(pending)
    transient.open("review-submit", {
        root = detected.root,
        selection = {
            root = detected.root,
            number = num,
            repo_row = repo_row,
            repo_id = repo_row.id,
            pending = pending,
        },
    })
end

--- Close the review workspace (closes the diff / fallback surface, clears overlays + session).
function M.close()
    if not S then
        return
    end
    if S.mode == "fallback" then
        if S.handle and S.handle.close then
            pcall(S.handle.close)
        end
        -- teardown runs from the surface close callback; ensure it runs even if the handle was never built.
        if S then
            teardown()
        end
    else
        if S.diff and S.diff.is_open and S.diff.is_open() then
            pcall(S.diff.close) -- fires LvimGitDiffClose → teardown
        else
            teardown()
        end
    end
end

return M
