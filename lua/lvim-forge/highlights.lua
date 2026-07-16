-- lvim-forge.highlights: the self-theming highlight factory.
-- Every group lvim-forge paints is DERIVED from the live lvim-utils palette here and registered through
-- `lvim-utils.highlight.bind`, so it re-applies on ColorScheme / palette sync and stays overridable
-- off-lvim. UI code never inlines a colour — it references one of these NAMED groups. Tints follow the
-- canon: `mtint(accent, t)` = blend the accent toward the panel bg (higher t = more accent).
--
-- Topic-state / review-verdict / check-status / label-chip groups all come from the palette's ROLE
-- colours (open = green, closed = red, merged = magenta, …). Data-driven LABEL colours (the API supplies
-- each label's hex) are NOT built here — highlights.lua keeps a per-hex on-demand cache (added in the DB
-- phase) that blends the live hex toward the live bg, the lvim-lsp outline source-colours precedent.
--
---@module "lvim-forge.highlights"

local hl = require("lvim-utils.highlight")

local M = {}

--- Seen label hex colours (a normalized 6-hex key, no leading '#') → true. Each drives a data-driven
--- `LvimForgeLabel_<hex>` chip group (bg = the hex tinted toward the panel bg, fg = the raw hex). The set
--- is re-derived on every ColorScheme via one shared bound factory (below) so the chips track the theme —
--- the lvim-lsp outline source-colours precedent (colours from live DATA, blended toward the live bg).
---@type table<string, boolean>
local label_hexes = {}

--- Whether the shared label-chip factory is bound yet (bound once, on the first `label_hl` call).
---@type boolean
local label_bound = false

--- Build every LvimForge* group from the live palette. Passed to `hl.bind`, so it re-runs on every
--- palette change; read the palette INSIDE the factory so the groups track the theme.
---@param c table  the live lvim-utils palette
---@return table<string, table>
function M.build(c)
    local bg = c.bg_dark
    local mtint = function(accent, t)
        return hl.blend(accent, bg, t)
    end
    local groups = {
        -- ── topic state (icon/chip fg + a 0.2 band tint) ──
        LvimForgeOpen = { fg = c.green, bold = true },
        LvimForgeClosed = { fg = c.red },
        LvimForgeMerged = { fg = c.magenta, bold = true },
        LvimForgeDraft = { fg = c.fg_dark },
        LvimForgeOpenBand = { bg = mtint(c.green, 0.2) },
        LvimForgeClosedBand = { bg = mtint(c.red, 0.2) },
        LvimForgeMergedBand = { bg = mtint(c.magenta, 0.2) },
        LvimForgeDraftBand = { bg = mtint(c.fg_dark, 0.2) },

        -- ── topic-buffer header CHIPS (state chip = fg + a soft accent block; meta chips) ──
        LvimForgeChipOpen = { fg = c.green, bg = mtint(c.green, 0.18), bold = true },
        LvimForgeChipClosed = { fg = c.red, bg = mtint(c.red, 0.18), bold = true },
        LvimForgeChipMerged = { fg = c.magenta, bg = mtint(c.magenta, 0.18), bold = true },
        LvimForgeChipDraft = { fg = c.fg_dark, bg = mtint(c.fg_dark, 0.18) },
        LvimForgeMeta = { fg = c.fg_dark }, -- dim meta / separator chip text
        LvimForgeMetaAdd = { fg = c.green }, -- +additions
        LvimForgeMetaDel = { fg = c.red }, -- -deletions
        LvimForgeBranch = { fg = c.cyan }, -- base ← head refs

        -- ── topic-row metadata ──
        LvimForgeNumber = { fg = c.yellow, bold = true },
        LvimForgeAuthor = { fg = c.blue },
        LvimForgeDate = { fg = c.fg_dark, italic = true },
        LvimForgeUnread = { fg = c.orange, bold = true }, -- the unread accent dot
        LvimForgeMention = { fg = c.cyan }, -- @-mention token
        LvimForgeTitle = { fg = c.fg },

        -- ── review verdicts ──
        LvimForgeApproved = { fg = c.green, bold = true },
        LvimForgeChanges = { fg = c.red, bold = true },
        LvimForgeCommented = { fg = c.blue },
        LvimForgePending = { fg = c.yellow },
        -- Review threads: a subtle wash + resolved/outdated dims.
        LvimForgeThread = { bg = mtint(c.blue, 0.15) },
        LvimForgeThreadResolved = { fg = c.fg_dark },
        LvimForgeThreadOutdated = { fg = c.fg_dark, italic = true },

        -- ── review workspace overlay (the virt_lines thread layer on the diff) ──
        LvimForgeReviewMarker = { fg = c.blue, bold = true }, -- the ➤ thread pointer
        LvimForgeReviewAuthor = { fg = c.blue, bold = true }, -- comment author in the overlay
        LvimForgeReviewBody = { fg = c.fg }, -- comment body text
        LvimForgeReviewDate = { fg = c.fg_dark, italic = true }, -- rel-date in the overlay
        LvimForgeReviewCaret = { fg = c.yellow }, -- the ▸/▾ expand caret + count
        LvimForgeReviewResolved = { fg = c.fg_dark, italic = true }, -- the dim [resolved] tag
        LvimForgeReviewOutdated = { fg = c.fg_dark, italic = true }, -- the dim [outdated] tag
        LvimForgeReviewPending = { fg = c.yellow, bold = true }, -- a PENDING (unsubmitted) review comment

        -- ── checks / CI ──
        LvimForgeCheckPass = { fg = c.green },
        LvimForgeCheckFail = { fg = c.red },
        LvimForgeCheckPending = { fg = c.yellow },

        -- ── notifications inbox ──
        LvimForgeNotifReason = { fg = c.cyan, bg = mtint(c.cyan, 0.18), bold = true }, -- the reason badge box
        LvimForgeNotifRepo = { fg = c.blue, bold = true }, -- the owner/name group header
        LvimForgeNotifTitle = { fg = c.fg }, -- an unread notification's title
        LvimForgeNotifRead = { fg = c.fg_dark }, -- a read notification's title (dimmed)
        LvimForgeNotifDate = { fg = c.fg_dark, italic = true }, -- the dim rel-date

        -- ── section accents (through ui.section; accents only) ──
        LvimForgeSectionDesc = { fg = c.blue, bold = true },
        LvimForgeSectionComments = { fg = c.yellow, bold = true },
        LvimForgeSectionChecks = { fg = c.cyan, bold = true },
        LvimForgeSectionFiles = { fg = c.magenta, bold = true },

        -- ── transient (verb popup arg states — inherits the shared engine's shape) ──
        LvimForgeTransientOn = { fg = c.green, bold = true },
        LvimForgeTransientOff = { fg = c.fg_dark },
        LvimForgeTransientValue = { fg = c.yellow },
        LvimForgeTransientSaved = { fg = c.cyan, bold = true },
    }
    return groups
end

--- Normalize a label colour into a 6-hex key (no leading '#', lower-case). nil / malformed → nil.
---@param color? string  the API-supplied hex ("f29513" or "#f29513")
---@return string?
local function hex_key(color)
    if type(color) ~= "string" then
        return nil
    end
    local h = color:gsub("^#", ""):lower()
    if h:match("^%x%x%x%x%x%x$") then
        return h
    end
    return nil
end

--- The chip group opts for one label hex from the live palette: bg = the hex blended 0.25 toward the
--- panel bg (a soft coloured block), fg = the raw hex (bold). Re-derived on ColorScheme.
---@param h string  a 6-hex key (no '#')
---@param c table   the live palette
---@return string name, table opts
local function label_opts(h, c)
    local raw = "#" .. h
    return "LvimForgeLabel_" .. h, { bg = hl.blend(raw, c.bg_dark, 0.25), fg = raw, bold = true }
end

--- Register (idempotently) the data-driven chip group for a label colour and return its group NAME
--- (a valid highlight identifier `LvimForgeLabel_<hex>`). On first use it binds one shared factory that
--- re-derives EVERY seen chip on ColorScheme; a later colour applied after the bind is set immediately
--- (force) — the `section_accent` mechanism, mirrored for label chips. A nil / malformed colour degrades
--- to the neutral `LvimForgeTitle` (so a chip always has a valid group).
---@param color? string  the API-supplied label hex
---@return string
function M.label_hl(color)
    local h = hex_key(color)
    if not h then
        return "LvimForgeTitle"
    end
    local name = "LvimForgeLabel_" .. h
    if not label_hexes[h] then
        label_hexes[h] = true
        if label_bound then
            local ok, c = pcall(require, "lvim-utils.colors")
            if ok then
                local n, opts = label_opts(h, c)
                vim.api.nvim_set_hl(0, n, opts)
            end
        end
    end
    if not label_bound then
        label_bound = true
        hl.bind(function(c)
            c = c or require("lvim-utils.colors")
            local groups = {}
            for hex in pairs(label_hexes) do
                local n, opts = label_opts(hex, c)
                groups[n] = opts
            end
            return groups
        end)
    end
    return name
end

return M
