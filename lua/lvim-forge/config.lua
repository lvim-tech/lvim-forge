-- lvim-forge.config: the LIVE configuration table for the forge (PR / issue / code-review / notifications)
-- sibling of lvim-git. Holds the defaults; `setup()` merges user overrides into it IN PLACE (via
-- lvim-utils.utils.merge), so every `require("lvim-forge.config")` reader sees the effective values.
-- Nothing is captured at setup time — a control-center toggle takes effect on the next open, no restart.
--
-- Each COMPONENT carries its own `enabled` flag: a disabled component loads nothing (no require, no
-- autocmd, no keymap). Components depend only on the shared core (client/db/sync/model/config/state/
-- highlights), never on each other — the decoupling contract mirrored from lvim-git.
--
-- The client seam reads `transport`/`auth`/`hosts`/`limits`/`pull` here; the UI reads `layouts`/
-- `keymaps`/`icons`/the per-component blocks. Tokens are NEVER stored — `auth.<forge>.token` is a live
-- value (string | function) resolved per request, never persisted to the DB.
--
---@module "lvim-forge.config"

---@class LvimForgeAuthForge
---@field token? string|fun():string?  a PAT string, or a function returning one (shell out to a secret manager)
---@field env?   string                the env var checked for the token (per-forge overridable, e.g. GH_ENTERPRISE_TOKEN)

---@class LvimForgeAuthGitea : LvimForgeAuthForge
---@field tea? boolean  read the `tea` CLI's own logins (~/.config/tea/config.yml) — opt-in, read-only

---@class LvimForgeAuthConfig
---@field netrc    boolean            allow a ~/.netrc lookup (`machine <host> … password <token>`)
---@field github   LvimForgeAuthForge
---@field gitlab   LvimForgeAuthForge
---@field gitea    LvimForgeAuthGitea
---@field codeberg LvimForgeAuthForge

---@class LvimForgeLimitsConfig
---@field floor integer  pause sync below this many remaining API calls (fires LvimForgeRateLimit)

---@class LvimForgePullConfig
---@field on_open      boolean  background pull when a forge UI opens and the cache is stale
---@field stale_after  integer  seconds before the cache is considered stale (drives on_open)
---@field closed_since string   initial-pull window for closed topics: "6m"|"1y"|"all"
---@field max_pages    integer  pagination cap per collection per pull

---@class LvimForgeDatabaseConfig
---@field prune_closed_after? string  nil = keep everything; "1y" prunes closed topics + posts older than this
---@field path?              string   override the DB file path; nil = stdpath("data")/lvim-forge/lvim-forge.db

---@class LvimForgeTopicsConfig
---@field enabled boolean
---@field limit   integer  max topic rows the list renders

---@class LvimForgeToggleComponent
---@field enabled boolean

---@class LvimForgeReviewConfig
---@field enabled         boolean  the review workspace component (threads overlaid on the PR diff)
---@field show_resolved   boolean  overlay resolved threads too (default false — resolved are hidden/collapsed)
---@field virt_lines      boolean  render thread overlays as inline `virt_lines` on the diff (false = anchor list only)
---@field default_verdict "comment"|"approve"|"request-changes"  the verdict the submit transient starts on

---@class LvimForgeNotifReason
---@field icon  string  the reason's badge glyph (a single-width Nerd codepoint)
---@field label string  the short reason label shown in the badge box

---@class LvimForgeNotificationsConfig
---@field enabled  boolean
---@field poll     boolean  optional timer polling of the notifications endpoint
---@field interval integer  poll interval (seconds) when poll = true
---@field reasons  table<string, LvimForgeNotifReason>  reason (review_requested/mention/…) → badge glyph + short label

---@class LvimForgeStatusSectionConfig
---@field enabled  boolean  the lvim-git status Forge section (soft; self-registers when both installed)
---@field max_rows integer  max rows per bucket (open PRs / assigned / review-requested)

---@class LvimForgeCompletionConfig
---@field enabled   boolean  #topic / @user completion in composer buffers
---@field gitcommit boolean  also offer it in `gitcommit` buffers

---@class LvimForgeCheckoutConfig
---@field branch        "head"|"pr/<n>"  local branch name for a checked-out PR ("head" = the PR head-ref name)
---@field track         boolean          set the local branch's upstream to the PR head
---@field branch_prefix string           prefix for the `pr/<n>` naming style + the collision fallback (default "pr/")
---@field worktree_dir  string           worktree dir-name template (tokens {repo} {branch} {n}); created beside the repo root

---@class LvimForgeCreateConfig
---@field push_head "ask"|"always"|"never"  push the PR head branch when it has no upstream (ask via confirm | auto | skip)

---@class LvimForgeMergeConfig
---@field default_method "merge"|"squash"|"rebase"  the merge method a fresh merge transient starts on
---@field delete_branch  boolean                    delete the head branch after a merge (default in the transient's delete-branch toggle)
---@field methods?       string[]                    the offered merge methods; nil = the forge caps (GitHub = merge/squash/rebase)

---@class LvimForgeTransientConfig
---@field level         integer  Magit levels 1-7: hide advanced infixes/actions above this
---@field save_defaults boolean  persist per-prefix `save`d args (the shared engine's store use)

---@class LvimForgeLayouts
---@field topics        "area"|"float"|"bottom"|"tab"
---@field topic         "area"|"float"|"bottom"|"tab"
---@field review        "area"|"float"|"bottom"|"tab"
---@field notifications "area"|"float"|"bottom"|"tab"
---@field composer      "area"|"float"|"bottom"|"tab"
---@field dispatch      "area"|"float"|"bottom"|"tab"

---@class LvimForgeIcons
---@field issue         string
---@field pull          string
---@field merged        string
---@field closed        string
---@field draft         string
---@field check_pass    string
---@field check_fail    string
---@field check_pending string
---@field comment       string
---@field review        string
---@field notification  string

---@class LvimForgeConfig
---@field remote?             string                     git remote naming the forge repo; nil = "upstream" when present else "origin"
---@field hosts               table<string, "github"|"gitlab"|"gitea"|"codeberg">  self-hosted host → forge family
---@field transport           "auto"|"cli"|"rest"        "auto" = gh/glab CLI when installed+authed, else REST/curl
---@field auth                LvimForgeAuthConfig
---@field limits              LvimForgeLimitsConfig
---@field pull                LvimForgePullConfig
---@field database            LvimForgeDatabaseConfig
---@field topics              LvimForgeTopicsConfig
---@field topic               LvimForgeToggleComponent
---@field review              LvimForgeReviewConfig
---@field notifications       LvimForgeNotificationsConfig
---@field status_section      LvimForgeStatusSectionConfig
---@field completion          LvimForgeCompletionConfig
---@field checkout            LvimForgeCheckoutConfig
---@field create              LvimForgeCreateConfig
---@field merge               LvimForgeMergeConfig
---@field transient           LvimForgeTransientConfig
---@field layouts             LvimForgeLayouts
---@field keymaps             table<string, string>      in-panel key overrides (defaults per the UI section)
---@field icons               LvimForgeIcons
---@field confirm_destructive boolean                     confirm merge / close / delete-branch / mark-all-read / remove repo
---@field hl                  table<string, table>        highlight-group overrides

---@type LvimForgeConfig
return {
    -- The git remote that names the forge repository. nil resolves at detect time to "upstream" when a
    -- fork's upstream remote exists, else "origin" (the contributor-fork convention).
    remote = nil,
    -- Self-hosted host → forge family, e.g. { ["git.company.com"] = "gitlab" }. Codeberg is hosted
    -- Forgejo → the `gitea` impl; codeberg.org classifies to "gitea" automatically (a named forge in
    -- config/docs, one impl in code).
    hosts = {},
    -- Transport pick behind the client seam. "auto" chooses the CLI (gh/glab api) when it is installed
    -- AND authenticated (probed once, cached), else curl + a resolved PAT. "cli" forces the CLI (falls
    -- back to REST for gitea/codeberg, which have no raw-API passthrough). "rest" forces curl everywhere.
    transport = "auto",
    -- Token resolution order (first hit wins, probed once, reported by health, NEVER persisted): the
    -- per-forge `token` (string | function) → its `env` var → ~/.netrc (when `netrc`) → for gitea the
    -- `tea` CLI logins (when `gitea.tea`). When the CLI transport runs, the CLI owns its own auth and
    -- no token is resolved here at all.
    auth = {
        netrc = true, -- allow ~/.netrc (machine <host> … password <token>)
        github = { token = nil, env = "GITHUB_TOKEN" }, -- token: string | fun():string?
        gitlab = { token = nil, env = "GITLAB_TOKEN" },
        gitea = { token = nil, env = "GITEA_TOKEN", tea = false }, -- tea: read ~/.config/tea logins
        codeberg = { token = nil, env = "CODEBERG_TOKEN" },
    },
    limits = { floor = 50 }, -- pause sync below this many remaining API calls
    pull = {
        on_open = true, -- background pull when a forge UI opens and the cache is stale
        stale_after = 300, -- seconds
        closed_since = "1y", -- initial-pull window for closed topics: "6m"|"1y"|"all"
        max_pages = 10, -- pagination cap per collection per pull
    },
    database = {
        prune_closed_after = nil, -- nil = keep everything; "1y" prunes closed topics + posts
        path = nil, -- override the DB file path; nil = stdpath("data")/lvim-forge/lvim-forge.db
    },
    -- Components — a disabled one loads nothing. `sync` is not listed: it IS the plugin (always on).
    topics = { enabled = true, limit = 500 },
    topic = { enabled = true },
    review = {
        enabled = true,
        show_resolved = false, -- overlay resolved threads too (default: hidden / collapsed)
        virt_lines = true, -- thread overlays as inline virt_lines on the diff buffers
        default_verdict = "comment", -- the verdict the submit transient opens on: "comment"|"approve"|"request-changes"
    },
    notifications = {
        enabled = true,
        poll = false, -- optional timer polling of the notifications endpoint (OFF by default)
        interval = 300, -- poll interval (seconds) when poll = true
        -- The inbox reason BADGE per notification reason: a single-width Nerd glyph + a short label.
        -- Unknown reasons fall back to the generic notification bell (icons.notification). All BMP
        -- (3-byte) Nerd codepoints, verified single-width via char2nr/strdisplaywidth.
        reasons = {
            review_requested = { icon = "\u{f06e}", label = "review" }, -- nf-fa-eye
            mention = { icon = "\u{f0e0}", label = "mention" }, -- nf-fa-envelope
            team_mention = { icon = "\u{f0c0}", label = "team" }, -- nf-fa-users
            assign = { icon = "\u{f007}", label = "assign" }, -- nf-fa-user
            author = { icon = "\u{f040}", label = "author" }, -- nf-fa-pencil
            comment = { icon = "\u{f075}", label = "comment" }, -- nf-fa-comment
            state_change = { icon = "\u{f021}", label = "state" }, -- nf-fa-refresh
            ci_activity = { icon = "\u{f085}", label = "ci" }, -- nf-fa-cogs
            push = { icon = "\u{f1e0}", label = "push" }, -- nf-fa-share
            subscribed = { icon = "\u{f0f3}", label = "subscribed" }, -- nf-fa-bell
            security_alert = { icon = "\u{f132}", label = "security" }, -- nf-fa-shield
            invitation = { icon = "\u{f0e0}", label = "invite" }, -- nf-fa-envelope
            manual = { icon = "\u{f0f3}", label = "manual" }, -- nf-fa-bell
            your_activity = { icon = "\u{f040}", label = "you" }, -- nf-fa-pencil
        },
    },
    status_section = { enabled = true, max_rows = 5 }, -- the lvim-git status Forge section (soft)
    completion = { enabled = true, gitcommit = true }, -- #topic/@user in composer + gitcommit buffers
    checkout = {
        branch = "head", -- "head" = the PR's head-ref name (pr/<n> on collision) | "pr/<n>"
        track = true, -- set the local branch upstream to the PR head
        branch_prefix = "pr/", -- prefix for the pr/<n> naming style + the head-ref collision fallback
        worktree_dir = "{repo}-{branch}", -- worktree dir-name template ({repo} {branch} {n}); created beside the repo root
    },
    create = {
        push_head = "ask", -- push the PR head branch when it has no upstream: "ask" (ui.confirm) | "always" | "never"
    },
    merge = {
        default_method = "merge", -- the merge method a fresh merge transient starts on: "merge"|"squash"|"rebase"
        delete_branch = false, -- default state of the transient's "delete branch after merge" toggle
        methods = nil, -- offered merge methods; nil = the forge caps (GitHub = merge/squash/rebase)
    },
    transient = {
        level = 4, -- Magit levels 1-7: hide advanced infixes/actions above this
        save_defaults = true, -- persist per-prefix `save`d args (the shared engine's store use)
    },
    -- Per-view default layout; a per-command token (area|float|bottom|tab) overrides it and is sticky
    -- for the session. ALL FOUR layouts are available for EVERY view. Heavy multi-section views default
    -- to the fullscreen `tab` workspace, the inbox to `area`, composer/dispatch to a modal `float`.
    layouts = {
        topics = "tab",
        topic = "tab",
        review = "tab",
        notifications = "area",
        composer = "float",
        dispatch = "float",
    },
    keymaps = {}, -- in-panel key overrides (the full defaults are set per component)
    -- Nerd-Font single-width glyphs (verified via char2nr/strdisplaywidth); state chips + section markers.
    icons = {
        issue = "", -- nf-oct-issue_opened
        pull = "", -- nf-oct-git_pull_request
        merged = "", -- nf-oct-git_merge
        closed = "", -- nf-oct-issue_closed
        draft = "", -- nf-fa-circle_o
        check_pass = "", -- nf-fa-check
        check_fail = "", -- nf-fa-times
        check_pending = "", -- nf-fa-hourglass_half
        comment = "", -- nf-fa-comment
        review = "", -- nf-oct-eye
        notification = "", -- nf-fa-bell
    },
    confirm_destructive = true, -- merge / close / delete-branch / mark-all-read / remove repo
    hl = {},
}
