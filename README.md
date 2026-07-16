# lvim-forge

The in-house **Magit Forge** (`forge.el`) replica for the lvim-tech ecosystem — pull requests,
issues, code review and notifications for **GitHub**, **GitLab**, **Gitea / Forgejo** and
**Codeberg**, sitting alongside its sibling [`lvim-git`](https://github.com/lvim-tech/lvim-git).

Like Forge, lvim-forge keeps a **local SQLite cache** of every topic (issue / PR), post, review,
thread and notification. Every view renders from that cache — instant and fully available
offline. An explicit **pull** reconciles the cache with the forge API; mutations go straight to
the API and upsert the response back into the cache (no optimistic writes — the API response is
the truth). On top of the cache: a filterable topic list, a rich topic buffer, PR checkout / diff
/ merge, a code-review workspace, a notifications inbox, and a **Forge section** inside
`lvim-git`'s status view.

Internally lvim-forge is a **suite of independently-usable components** over a shared core
(`client/*` transports + `db` + `sync` + `model` + `config` + `state` + `highlights`). Each UI
component (topics / topic / review / notifications / dispatch / composer / status-section /
completion) and `refs` has its own `enabled` flag, depends only on the shared core (never on
another component), and **degrades cleanly** when a dependency is missing — a disabled component
loads nothing (no `require`, no autocmd, no keymap).

[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](https://github.com/lvim-tech/lvim-forge/blob/main/LICENSE)

## Forge support

| Forge                | Detection                    | Transport               | Issues · PRs · Reviews | Notifications | Thread resolve | Draft toggle  |
| -------------------- | ---------------------------- | ----------------------- | ---------------------- | ------------- | -------------- | ------------- |
| **GitHub**           | `github.com` / Enterprise    | `gh` CLI or `curl` REST | yes                    | yes           | yes (GraphQL)  | yes (GraphQL) |
| **GitLab**           | `gitlab.com` / self-hosted   | `glab` CLI or `curl`    | yes                    | yes (todos)   | yes (REST)     | yes (`Draft:`)|
| **Gitea / Forgejo**  | self-hosted (`config.hosts`) | `curl` REST             | yes                    | yes           | no (no REST)   | yes (`WIP:`)  |
| **Codeberg**         | `codeberg.org`               | `curl` REST             | yes                    | yes           | no (no REST)   | yes (`WIP:`)  |

Capabilities are driven by a per-forge **caps matrix** — the UI only offers what a forge supports,
never a hard-coded `if forge == …`. Codeberg is hosted Forgejo, so it runs the Gitea backend
(host-driven; one implementation, a first-class named forge). **Bitbucket** is a v2 candidate: the
caps model already admits it, and a Bitbucket backend module is the only thing missing.

## Features

- **Topic list** (`:LvimForge topics` / `issues` / `pulls`) — one row per issue / PR (unread dot +
  state icon + `#number` + title + label chips + `author ➤ date`), a three-group filter band
  (kind ● state ● involvement) with live per-button counts, a `/` structured query
  (`label: author: milestone: mark: #n` + free text), and a session-sticky filter.
- **Topic buffer** (`:LvimForge topic <n>`) — two header chip bands + a scrollable panel of folds:
  Description, a chronological Timeline (comments + reviews with grouped review-comments +
  system rows), and for PRs Commits / Files changed / Checks / Review threads.
- **Compose** (`:LvimForge create [issue|pr]`, `:LvimForge comment <n>`) — one editable surface for
  new issues / PRs / comments / edits, with `@user` / `#topic` completion from the cache.
- **Mutations** — comment, edit (description / comment / title), close / reopen, labels, assignees,
  milestone, reviewers, lock / unlock — all through the cache-reconciling mutate seam.
- **PR checkout** (`:LvimForge checkout <n> [worktree]`) — fetch a PR head into a local branch or a
  sibling worktree; re-syncs `lvim-git` afterwards.
- **Merge** (`:LvimForge merge <n>`) — a merge transient (method · delete-branch · commit message),
  gated on mergeability + review decision; plus the draft toggle (`W`).
- **Code review** (`:LvimForge review [n]`) — the PR's review threads overlaid on `lvim-git`'s diff
  (`virt_lines`), with a plain hunk-panel fallback when `lvim-git` is absent; add / reply / resolve
  comments and submit a batched review (approve / request-changes / comment) via a transient.
- **Notifications inbox** (`:LvimForge notifications`) — every tracked repo, grouped per repo, with
  an `unread ● all` filter, reason badges, `<CR>` open + mark-read, and mark-all.
- **Dispatch** (`:LvimForge dispatch`, `?` in any panel) — the discoverable, caps-gated menu of
  every command (Magit-forge's `?`), context-aware over the topic under the cursor.
- **lvim-git integration** (soft) — a trailing **Forge** section in `:LvimGit status` (open PRs /
  assigned issues / review requests) and `#topic` / `@user` completion + open-at-point in
  `gitcommit` buffers.

## Architecture

The shared **core** is always loaded and standalone-usable:

- `client/` — `init.lua` (the one `request(spec, cb)` seam: transport resolution, auth, pagination,
  rate-limit, clean `{kind}` errors), the `github` / `gitlab` / `gitea` / `codeberg` backends behind
  a `backend(forge)` dispatch, plus `http` (curl) + `cli` (`gh`/`glab api`) transports, `detect`,
  `auth`, `runner`.
- `db.lua` — the SQLite cache (schema v3, 16 tables, FK-cascade, natural-key unique indexes,
  version-keyed migrations). Tokens are **never** stored.
- `sync.lua` — the offline-first pull-reconcile engine (cursor-advanced-last, crash-safe) + the
  no-optimistic-write mutate seam.
- `model.lua` — the API-JSON → db-row normalization layer (one entity vocabulary across forges).
- `config` / `state` / `highlights` — the live config, runtime state, and self-theming groups.

Every UI is a **decoupled component** over this core. `refs.lua` (completion + open-at-point) and
`ui/section.lua` (the `lvim-git` status section) self-wire at `setup()` — each gated + guarded, a
no-op when disabled or when the soft dependency is absent.

## Requirements

Hard dependencies:

- **Neovim >= 0.10** (`vim.system`, `vim.uv`, `vim.json`).
- **lvim-ui**, **lvim-utils**, **lvim-icons** — the panel chassis, palette / store / merge helpers,
  and file devicons.
- **sqlite.lua** (via `lvim-utils.store`) — the topic cache is the plugin; without it lvim-forge
  cannot run (`:checkhealth lvim-forge` reports this as an error).
- **`curl`** — the REST transport (and the only transport for Gitea / Forgejo / Codeberg).

Optional:

- **`gh`** / **`glab`** — the CLI transports for GitHub / GitLab (zero-config auth,
  enterprise-friendly); used automatically when installed and authenticated.
- **`tea`** — read only for a Gitea / Codeberg token when `auth.gitea.tea = true`.
- **lvim-git** — enables the diff hand-off (review workspace, PR diff), the status Forge section,
  and the `refresh` seam after a checkout / merge. lvim-forge degrades cleanly without it.

## Installation

Install with the lvim-tech **lvim-installer**, or with Neovim's native `vim.pack`:

```lua
vim.pack.add({
    { src = "https://github.com/kkharji/sqlite.lua" }, -- the topic cache backend (required)
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-icons" },
    { src = "https://github.com/lvim-tech/lvim-forge" },
})
require("lvim-forge").setup({})
```

`setup()` merges your options into the live configuration in place, registers the self-theming
highlights, wires the `:LvimForge` command + the `<Plug>` maps, and lazily bootstraps each enabled
component on first use.

## Quickstart

```
:LvimForge add        " track the current repository in the local cache
:LvimForge pull       " reconcile the cache with the forge (issues, PRs, reviews, notifications)
:LvimForge            " open the topic list (the default view)
:LvimForge dispatch   " the discoverable menu of every command  (also `?` in any panel)
```

`:LvimForge add [remote|owner/name] [full|selective]` registers a repo (no network); `:LvimForge
pull` fetches it. Thereafter every view renders instantly from the cache and refreshes on the next
pull. Authentication is resolved live per request (see below) — nothing is stored.

## Transport & authentication

lvim-forge reaches a forge through **one request seam** with two interchangeable transports:

- **CLI-first** (`transport = "auto"`, the default) — `gh` / `glab api` when the CLI is installed
  **and** authenticated (probed once, cached). The CLI owns its own auth.
- **REST** — `curl` with a resolved token; the fallback everywhere and the only transport for
  Gitea / Forgejo / Codeberg. `transport = "cli"` forces the CLI (still REST for Gitea/Codeberg);
  `transport = "rest"` forces curl everywhere.

For the REST transport a **token is resolved live per request** (first hit wins, probed once,
reported by `:checkhealth`, and **never persisted to the DB**):

1. the per-forge `auth.<forge>.token` — a string, or a function (shell out to a secret manager);
2. its `auth.<forge>.env` environment variable (e.g. `GITHUB_TOKEN`);
3. `~/.netrc` (`machine <host> … password <token>`) when `auth.netrc = true`;
4. for Gitea / Codeberg, the `tea` CLI logins when `auth.gitea.tea = true`.

Only the token **source** (never the token itself) is ever surfaced, and only in the health report.

## Commands

`:LvimForge <subcommand> [area|float|bottom|tab] [args]` — the layout token is recognised anywhere
in the arguments and is sticky for the session; all four layouts work for every view.

| Command                                      | Description                                                    |
| -------------------------------------------- | -------------------------------------------------------------- |
| `:LvimForge`                                 | open the topic list (the default view)                         |
| `:LvimForge topics` / `issues` / `pulls`     | the topic list, optionally pre-filtered to a kind              |
| `:LvimForge topic <n>`                       | the topic buffer for issue / PR `n`                            |
| `:LvimForge create [issue\|pr]`              | the composer to create an issue or a pull request              |
| `:LvimForge comment <n>`                     | the composer to comment on topic `n`                           |
| `:LvimForge review [n]`                      | the review workspace for PR `n` (or the current branch's PR)   |
| `:LvimForge review submit [n]`               | the submit-review transient for PR `n`                         |
| `:LvimForge checkout <n> [worktree]`         | check out PR `n` into a branch (or a worktree)                 |
| `:LvimForge merge <n> [merge\|squash\|rebase]` | merge PR `n` (a method merges directly; none opens the transient) |
| `:LvimForge pull [--notifications] [selective\|full]` | reconcile the cache with the forge                    |
| `:LvimForge notifications [pull]`            | the notifications inbox (`pull` fetches only notifications)    |
| `:LvimForge add [remote\|owner/name] [full\|selective]` | track the current repo in the cache                 |
| `:LvimForge remove`                          | untrack the current repo (cascade-deletes its cached rows)     |
| `:LvimForge repos`                           | list the tracked repositories                                  |
| `:LvimForge dispatch`                        | the dispatch menu of every command                             |

## Panels & keymaps

Every panel is a canonical lvim-ui surface; `g?` shows its keymap cheat-sheet and `?` opens the
dispatch. `q` / `<Esc>` closes.

**Topic list**

| Key             | Action                                                  |
| --------------- | ------------------------------------------------------- |
| `j` / `k`       | next / previous topic                                   |
| `<CR>`          | open the topic (or fire the focused filter button)      |
| `/`             | search (`label: author: milestone: mark: #n` + text)    |
| `P`             | pull (sync with the forge)                              |
| `n`             | create a topic                                          |
| `N`             | notifications inbox                                     |

**Topic buffer**

| Key                   | Action                                             |
| --------------------- | -------------------------------------------------- |
| `]]` / `[[`           | next / previous section                            |
| `<CR>`                | fold a section · diff the file under the cursor    |
| `l` / `h`             | expand / collapse the fold under the cursor        |
| `c` / `e` / `E`       | comment / edit post (author-gated) / edit title    |
| `L` / `A` / `M` / `R` | labels / assignees / milestone / reviewers         |
| `s`                   | close / reopen                                     |
| `m` / `W`             | merge (transient) / draft toggle                   |
| `o` / `O`             | checkout the PR / in a worktree                    |
| `d`                   | full PR diff `base…head`                            |
| `v`                   | review workspace (threads on the diff)             |
| `B` / `Y`             | browse the topic on the web / yank its URL         |

**Review workspace**

| Key                     | Action                                              |
| ----------------------- | --------------------------------------------------- |
| `]t` / `[t`             | next / previous review thread (all files)           |
| `<Tab>` / `za` / `<CR>` | expand / collapse the thread on this line           |
| `]f` / `[f`             | next / previous file (diff)                          |
| `]c` / `[c`             | next / previous hunk (diff)                          |
| `cc`                    | new comment on this line (visual: a range comment)  |
| `cr`                    | reply to the thread on this line                    |
| `cx`                    | resolve / unresolve the thread                      |
| `cs`                    | submit review (approve / request-changes / comment) |

**Notifications inbox**

| Key       | Action                            |
| --------- | --------------------------------- |
| `<CR>`    | open the topic (marks it read; or fire the focused filter button) |
| `r` / `R` | toggle read-state / mark all read |
| `P`       | pull notifications                |

**Composer** — `<C-c><C-c>` submit, `<C-c><C-k>` / `q` cancel (dirty buffers confirm),
`<C-x><C-o>` / `<C-Space>` `@user` / `#topic` completion, `gd` toggle draft (PR mode).

## Transients

lvim-forge's verb popups run on the shared `lvim-ui` transient engine (grouped switches / options /
actions, direct hotkeys, a visibility level 1–7, session `set` / persistent `save` / `reset`):

- **dispatch** — the caps-gated, context-aware top-level menu.
- **pull** — `--notifications-only` / `--full` / `--selective` + a `=c` closed-since window.
- **list-filter** — kind / state / involvement + `label:` / `author:` / `milestone:` / `mark:` /
  text passed to the topic-list query.
- **topic-edit** — close / reopen (all forges) + lock / unlock (caps-gated).
- **merge** — method (merge / squash / rebase) · delete-branch · commit title / message.
- **submit-review** — verdict (comment / approve / request-changes) · submit / discard.

## `<Plug>` maps

None are installed by default; map the ones you want:

```lua
vim.keymap.set("n", "<leader>ft", "<Plug>(LvimForgeTopics)")
vim.keymap.set("n", "<leader>fp", "<Plug>(LvimForgePull)")
vim.keymap.set("n", "<leader>fn", "<Plug>(LvimForgeNotifications)")
vim.keymap.set("n", "gf", "<Plug>(LvimForgeOpenAtPoint)") -- #123 / a branch / a commit → its topic
```

## Events

lvim-forge fires `User` autocommand events so consumers refresh instead of polling:

| Event                           | Fired when                                          |
| ------------------------------- | --------------------------------------------------- |
| `LvimForgePullStart`            | a repo pull begins (`{ root }`)                     |
| `LvimForgePullDone`             | a pull finishes (`{ root, topics_changed, ok, … }`) |
| `LvimForgeTopicChanged`         | a topic was mutated / re-pulled (`{ root, kind, number }`) |
| `LvimForgeNotificationsChanged` | the unread notification count changed (`{ unread }`) |
| `LvimForgeReviewSubmitted`      | a pending review was submitted                      |
| `LvimForgeRateLimit`            | the API remaining count dropped below `limits.floor` |

## Public API

```lua
local forge = require("lvim-forge")

forge.setup(opts) -- merge options into the live config + wire the enabled components
forge.topics(opts) -- open the topic list        (also `issues` / `pulls`)
forge.topic(number, opts) -- open a topic buffer
forge.review(number) -- open the review workspace
forge.notifications() -- open the notifications inbox
forge.dispatch() -- open the dispatch menu
forge.pull(opts, cb) -- reconcile the cache with the forge (async)
forge.request(spec, cb) -- the low-level client request seam

-- render-safe cache reads (the network never runs on these):
forge.repo(root_or_buf) -- the detected forge-repo record, or nil
forge.is_tracked(root_or_buf) -- whether the repo is in the local cache
forge.topics_list(filter) -- the topic list model for a filter
forge.get_topic(number, kind) -- a single topic
forge.pr_for_branch(branch) -- the PR whose head matches a branch
forge.unread_count(root_or_buf) -- the unread notification count (per-repo or global)
```

## Default configuration

The complete option tree with every default (kept in sync with `lua/lvim-forge/config.lua`):

```lua
require("lvim-forge").setup({
    -- The git remote that names the forge repository. nil = "upstream" when a fork's upstream
    -- remote exists, else "origin".
    remote = nil,
    -- Self-hosted host → forge family, e.g. { ["git.company.com"] = "gitlab" }.
    hosts = {},
    -- "auto" = gh/glab CLI when installed+authed, else curl+PAT. "cli" forces the CLI (REST for
    -- gitea/codeberg). "rest" forces curl everywhere.
    transport = "auto",
    -- Token resolution (first hit wins, probed once, reported by health, NEVER stored):
    -- per-forge token (string | fun) → env var → ~/.netrc → for gitea the tea CLI logins.
    auth = {
        netrc = true, -- allow a ~/.netrc lookup
        github = { token = nil, env = "GITHUB_TOKEN" }, -- token: string | fun():string?
        gitlab = { token = nil, env = "GITLAB_TOKEN" },
        gitea = { token = nil, env = "GITEA_TOKEN", tea = false }, -- tea: read ~/.config/tea logins
        codeberg = { token = nil, env = "CODEBERG_TOKEN" },
    },
    limits = { floor = 50 }, -- pause sync below this many remaining API calls
    pull = {
        on_open = true, -- background pull when a forge UI opens and the cache is stale
        stale_after = 300, -- seconds before the cache is considered stale
        closed_since = "1y", -- initial-pull window for closed topics: "6m"|"1y"|"all"
        max_pages = 10, -- pagination cap per collection per pull
    },
    database = {
        prune_closed_after = nil, -- nil = keep everything; "1y" prunes old closed topics + posts
        path = nil, -- override the DB file; nil = stdpath("data")/lvim-forge/lvim-forge.db
    },
    -- Components — a disabled one loads nothing. `sync` is not listed: it IS the plugin (always on).
    topics = { enabled = true, limit = 500 }, -- max topic rows the list renders
    topic = { enabled = true },
    review = {
        enabled = true,
        show_resolved = false, -- overlay resolved threads too (default: hidden / collapsed)
        virt_lines = true, -- thread overlays as inline virt_lines on the diff
        default_verdict = "comment", -- "comment"|"approve"|"request-changes"
    },
    notifications = {
        enabled = true,
        poll = false, -- optional timer polling of the notifications endpoint (OFF by default)
        interval = 300, -- poll interval (seconds) when poll = true
        -- The inbox reason BADGE per notification reason: a single-width Nerd glyph + a short label.
        reasons = {
            review_requested = { icon = "\u{f06e}", label = "review" },
            mention = { icon = "\u{f0e0}", label = "mention" },
            team_mention = { icon = "\u{f0c0}", label = "team" },
            assign = { icon = "\u{f007}", label = "assign" },
            author = { icon = "\u{f040}", label = "author" },
            comment = { icon = "\u{f075}", label = "comment" },
            state_change = { icon = "\u{f021}", label = "state" },
            ci_activity = { icon = "\u{f085}", label = "ci" },
            push = { icon = "\u{f1e0}", label = "push" },
            subscribed = { icon = "\u{f0f3}", label = "subscribed" },
            security_alert = { icon = "\u{f132}", label = "security" },
            invitation = { icon = "\u{f0e0}", label = "invite" },
            manual = { icon = "\u{f0f3}", label = "manual" },
            your_activity = { icon = "\u{f040}", label = "you" },
        },
    },
    status_section = { enabled = true, max_rows = 5 }, -- the lvim-git status Forge section (soft)
    completion = { enabled = true, gitcommit = true }, -- #topic/@user in composer + gitcommit buffers
    checkout = {
        branch = "head", -- "head" = the PR's head-ref name (pr/<n> on collision) | "pr/<n>"
        track = true, -- set the local branch upstream to the PR head
        branch_prefix = "pr/", -- prefix for the pr/<n> style + the head-ref collision fallback
        worktree_dir = "{repo}-{branch}", -- worktree dir template ({repo} {branch} {n})
    },
    create = {
        push_head = "ask", -- push the PR head when it has no upstream: "ask"|"always"|"never"
    },
    merge = {
        default_method = "merge", -- the merge method a fresh merge transient starts on
        delete_branch = false, -- default state of the "delete branch after merge" toggle
        methods = nil, -- offered merge methods; nil = the forge caps
    },
    transient = {
        level = 4, -- Magit levels 1-7: hide advanced infixes/actions above this
        save_defaults = true, -- persist per-prefix `save`d args
    },
    -- Per-view default layout; a per-command token (area|float|bottom|tab) overrides + sticks.
    layouts = {
        topics = "tab",
        topic = "tab",
        review = "tab",
        notifications = "area",
        composer = "float",
        dispatch = "float",
    },
    keymaps = {}, -- in-panel key overrides (the full defaults are set per component)
    -- Nerd-Font single-width glyphs; state chips + section markers.
    icons = {
        issue = "\u{f41b}", -- nf-oct-issue_opened
        pull = "\u{f407}", -- nf-oct-git_pull_request
        merged = "\u{f419}", -- nf-oct-git_merge
        closed = "\u{f41d}", -- nf-oct-issue_closed
        draft = "\u{f10c}", -- nf-fa-circle_o
        check_pass = "\u{f00c}", -- nf-fa-check
        check_fail = "\u{f00d}", -- nf-fa-times
        check_pending = "\u{f252}", -- nf-fa-hourglass_half
        comment = "\u{f075}", -- nf-fa-comment
        review = "\u{f4a5}", -- nf-oct-eye
        notification = "\u{f0f3}", -- nf-fa-bell
    },
    confirm_destructive = true, -- merge / close / delete-branch / mark-all-read / remove repo
    hl = {}, -- highlight-group overrides
})
```

## lvim-git integration

When both are installed, lvim-forge softly enriches `lvim-git` (no `lvim-git` edit is required —
it uses the public `register_section` / `refresh` / diff seams):

- a trailing **Forge** section in `:LvimGit status` listing open PRs / assigned issues / review
  requests (`status_section`), each row opening its topic buffer;
- `#topic` / `@user` completion and **open-at-point** in `gitcommit` buffers (`completion`) —
  `<Plug>(LvimForgeOpenAtPoint)` resolves `#123` to a topic and a branch / commit to its PR;
- the review workspace overlays threads on `lvim-git`'s diff, and a checkout / merge calls
  `lvim-git`'s `refresh` seam.

## Known limitations & roadmap

- **Bitbucket** is not yet a backend (v2) — the caps model already admits it; only the backend
  module + normalizers are missing.
- **Checks / commits / timeline events** are not cached yet — the Checks and Commits sections show
  a placeholder and the Timeline synthesizes only the events derivable from stored columns
  (opened / merged / closed). Fetching `check-runs`, `/pulls/{n}/commits` and the timeline endpoint
  into new tables is a schema-migration follow-up.
- **Gitea / Forgejo / Codeberg**: thread *resolve* has no stable REST endpoint (resolved state is
  read-only), review *replies* and review-comment *edits* are omitted (no clean endpoint), and the
  merge DB reconcile waits for the next pull (the endpoint returns no body).
- **GitLab**: review-comment edits need the owning discussion id threaded through; `pr_files`
  additions / deletions are not parsed from the diff; involves-me selective pull is not
  distinguished.
- **Enterprise / self-hosted GraphQL**: the draft toggle posts to the REST base's `/graphql`
  (correct on `github.com`; GitHub Enterprise puts GraphQL at `/api/graphql`).
- Enhancement ideas (post-v1): suggested-changes apply, an offline mutation queue, a reactions UI,
  auto-merge / merge-queue, cross-repo topic search, CI deep-dive, review templates, and an
  unread badge for a statusline / HUD.

## License

BSD-3-Clause. See [LICENSE](./LICENSE).
</content>
