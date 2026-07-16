-- lvim-forge.state: RUNTIME-ONLY state (never configuration — config.lua is the live config).
-- Everything here is a projection of the current session or a live probe result: cached forge/repo
-- handles keyed by root, the resolved transport + CLI-auth probe cache, the per-session sticky layout
-- token per view, open-panel bookkeeping, per-panel state, and the transient session snapshots. None
-- of it is persisted — the sole persisted store is the sqlite DB (the topic cache) + the transient
-- saved-defaults section within it (both owned elsewhere; only the in-memory session lives here).
--
---@module "lvim-forge.state"

local M = {}

--- Cached forge/repo handles, keyed by absolute repo root. Each value is a resolved detect result
--- `{ forge, host, owner, name, base, remote_url, remote }` from `client/detect`. Never a config value.
---@type table<string, table>
M.repos = {}

--- Root lookup cache: an absolute path (dir or a file's dir) → its repo root (or false for "no repo").
--- Avoids re-walking the filesystem on every detect; mirrors lvim-git's `root_of` cache.
---@type table<string, string|false>
M.root_of = {}

--- The resolved transport per forge, keyed by forge name ("github"|"gitlab"|"gitea"|"codeberg") →
--- "cli"|"rest". Populated lazily by the client seam's transport resolver (probes the CLI once). A
--- config change to `transport` clears this via `M.reset()`.
---@type table<string, "cli"|"rest">
M.transport = {}

--- The CLI-auth probe cache, keyed by forge → boolean (the CLI is installed AND authenticated). Probed
--- once per session (a `gh auth status` / `glab auth status` exit code) then cached — never re-run on a
--- request hot path.
---@type table<string, boolean>
M.cli_auth = {}

--- The most recent rate-limit budget per host, keyed by host → `{ remaining, reset, limit }`. Updated
--- from the rate-limit response headers on every request; read by health + the sync pause logic.
---@type table<string, { remaining?: integer, reset?: integer, limit?: integer }>
M.rate = {}

--- Sticky per-session layout token per view name (set when a `:LvimForge <view> <layout>` token is
--- used). Overrides config.layouts for the rest of the session; nil falls back to config.
---@type table<string, "area"|"float"|"bottom"|"tab">
M.layout = {}

--- Open panel handles keyed by a logical view id, so a re-open toggles/focuses instead of stacking.
---@type table<string, table>
M.panels = {}

--- Per-panel runtime state (active filters, current selection, scroll) keyed by view id. Owned by each
--- UI component; kept here so a refresh from a DB-change event finds the panel's live filter set.
---@type table<string, table>
M.panel_state = {}

--- The SESSION defaults for each transient prefix, keyed by "<id>@<root>". Each value is a snapshot
--- `{ switches = { <key> = bool }, options = { <key> = value }, level? = integer }` — the shared
--- lvim-ui transient engine reads/writes this as its `state` table (the Phase-0 parameterization).
--- Runtime, never config.
---@type table<string, { switches: table<string, boolean>, options: table<string, any>, level?: integer }>
M.transient = {}

--- In-flight pull bookkeeping per repo root → `{ started = <ms>, notifications_only?: boolean }`, so a
--- second pull request coalesces onto the first instead of double-fetching. Owned by sync.lua.
---@type table<string, table>
M.pulling = {}

--- Per-topic detail-pull staleness cache: "<repo_id>#<number>" → the epoch (os.time) of the last
--- successful `sync.pull_topic`. The topic buffer opens on the cache and triggers a background detail
--- pull, skipping it when the same topic was pulled within the staleness window. Runtime, never config.
---@type table<string, integer>
M.topic_pulled = {}

--- The authenticated viewer's login per host (host → login), resolved lazily (once, cached) when a UI
--- needs "me" for an involvement filter. A live probe result — never config, never persisted.
---@type table<string, string>
M.viewer = {}

--- The dedicated-tabpage workspace host bookkeeping (ui/workspace.lua), keyed by view name → its origin
--- tab. ONLY the origin is remembered; the workspace tab itself is always found by its marker var.
---@type table<string, { origin_tab: integer }>
M.workspace = {}

--- The review-workspace session (ui/review.lua): the set of EXPANDED thread ids (keyed by the thread's
--- stable overlay id → true), the current thread index for `]t`/`[t`, and a pending cross-file jump the
--- diff's next `LvimGitDiffFileLoaded` completes. Rebuilt per open; runtime only, never config.
---@type { expanded: table<string, boolean>, index: integer, pending_jump?: { path: string, line: integer, side: "new"|"old" } }
M.review = { expanded = {}, index = 0 }

--- Reset ALL runtime state (used by tests and a hard config change that invalidates the probes).
function M.reset()
    M.repos = {}
    M.root_of = {}
    M.transport = {}
    M.cli_auth = {}
    M.rate = {}
    M.layout = {}
    M.panels = {}
    M.panel_state = {}
    M.transient = {}
    M.pulling = {}
    M.topic_pulled = {}
    M.viewer = {}
    M.workspace = {}
    M.review = { expanded = {}, index = 0 }
end

return M
