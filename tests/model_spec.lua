-- The seam between a forge's API JSON and the database's row shape.
--
-- This layer exists so the sync engine and the schema never have to know which forge they are
-- talking to: `normalize(forge, entity, api, ctx)` dispatches to a per-forge table, and everything
-- downstream always calls `model.normalize_* -> db.upsert_*`. That makes it pure -- JSON in, a
-- column-to-value row out -- and therefore exactly checkable, with no network and no database.
--
-- Three coercions carry it, and each is the kind of thing that works until the day an API answers
-- differently: a timestamp may arrive as an ISO string OR as an epoch number and has to leave as
-- ISO; a boolean has to become 0 or 1 because SQLite has no boolean; and a compound response has
-- to split into the rows its tables expect.
--
-- One more property is a promise in the module's header rather than a coercion: "Tokens NEVER
-- appear here -- this layer only ever touches public content fields." That is checkable too.

local model = require("lvim-forge.model")

--- Normalise with GitHub's normalizers.
---@param entity string
---@param api table
---@param ctx? table
---@return table
local function github(entity, api, ctx)
    return model.normalize("github", entity, api, ctx or { repo_id = 1, topic_id = 5 })
end

describe("lvim-forge: dispatching to a forge")

it("every entity the schema writes has a normalizer", function()
    local fns = model.forges.github
    truthy(type(fns) == "table", "GitHub is the forge v1 ships")
    for _, entity in ipairs({
        "topic",
        "pullreq",
        "post",
        "review",
        "thread",
        "label",
        "milestone",
        "user",
        "notification",
        "pr_file",
        "repository",
    }) do
        truthy(type(fns[entity]) == "function", "no normalizer for " .. entity)
    end
end)

it("an unknown forge or entity is an error, not a silent empty row", function()
    eq(false, (pcall(model.normalize, "bitbucket", "topic", {}, {})), "a wrong row is worse than a refusal")
    eq(false, (pcall(model.normalize, "github", "not-an-entity", {}, {})))
end)

describe("lvim-forge: coercing what an API sends")

it("an ISO timestamp passes through and an epoch number becomes ISO", function()
    local row = github("topic", {
        number = 1,
        title = "t",
        created_at = "2024-01-02T03:04:05Z",
        updated_at = 1700000000,
    })
    eq("2024-01-02T03:04:05Z", row.created, "already ISO-8601")
    eq("2023-11-14T22:13:20Z", row.updated, "an epoch is rendered as UTC ISO-8601")
end)

it("a missing or empty timestamp stays absent", function()
    local row = github("topic", { number = 1, title = "t", created_at = "", updated_at = nil })
    eq(nil, row.created, "an empty string is not a date")
    eq(nil, row.updated)
end)

it("a boolean becomes 0 or 1, because SQLite has no boolean", function()
    local locked = github("topic", { number = 1, title = "t", locked = true })
    eq(1, locked.locked)
    local open = github("topic", { number = 1, title = "t", locked = false })
    truthy(open.locked == 0 or open.locked == nil, "false is 0 or absent, never the Lua boolean")

    local pr = github("pullreq", { number = 1, draft = true, base = { ref = "main" }, head = { ref = "f" } })
    eq(1, pr.draft)
end)

it("a state is normalised to one spelling", function()
    local review = github("review", { id = 42, state = "APPROVED", user = { login = "r" } })
    eq("approved", review.state, "the API shouts; the column does not")
end)

it("an id becomes a string, so forges that use non-numeric ids fit the same column", function()
    local review = github("review", { id = 42, state = "COMMENTED", user = { login = "r" } })
    eq("42", review.forge_id)
end)

describe("lvim-forge: an issue and a pull request are one object with two kinds")

it("an issue is a topic of kind issue", function()
    local row = github("topic", { number = 7, title = "A bug", state = "open" })
    eq("issue", row.kind)
    eq(7, row.number)
    eq("open", row.state)
end)

it("the same endpoint's object with a pull_request field is a pull request", function()
    -- This is GitHub's shape: the issues endpoint returns PRs too, marked only by that field.
    local row = github("topic", { number = 9, title = "A PR", state = "open", pull_request = {} })
    eq("pullreq", row.kind, "a PR read from the issues endpoint must not be stored as an issue")
end)

it("a pull request's own fields go to its extras row", function()
    local row = github("pullreq", {
        number = 9,
        base = { ref = "main" },
        head = { ref = "feature", sha = "abc123" },
        additions = 3,
        deletions = 1,
        changed_files = 2,
    })
    eq(5, row.topic_id, "the extras row belongs to its topic")
    eq("main", row.base_ref)
    eq("feature", row.head_ref)
    eq("abc123", row.head_sha)
    eq(3, row.additions)
    eq(1, row.deletions)
    eq(2, row.changed_files)
end)

it("the author of anything is a login, not the whole user object", function()
    for _, entity in ipairs({ "topic", "post", "review" }) do
        local row = github(entity, { number = 1, id = 1, title = "t", body = "b", user = { login = "alice", id = 99 } })
        eq("alice", row.author, entity .. " should carry the login")
    end
end)

describe("lvim-forge: the people on a topic")

it("assignees and requested reviewers come back as logins", function()
    eq({ "bob", "eve" }, model.assignee_logins("github", { assignees = { { login = "bob" }, { login = "eve" } } }))
    eq({ "x" }, model.reviewer_logins("github", { requested_reviewers = { { login = "x" } } }))
end)

it("a topic with nobody on it is an empty list, not nil", function()
    eq({}, model.assignee_logins("github", {}))
    eq({}, model.reviewer_logins("github", {}))
end)

describe("lvim-forge: no token ever reaches a row")

it("a credential-looking field is never copied into a row", function()
    -- The module says this layer only touches public content fields. An API object that carries a
    -- token (a webhook payload, a misconfigured proxy, a future endpoint) must not leak it into
    -- the local database, which is a plain file on disk.
    local poisoned = {
        number = 1,
        title = "t",
        body = "b",
        id = 1,
        state = "open",
        user = { login = "a", token = "ghp_SECRET" },
        token = "ghp_SECRET",
        access_token = "ghp_SECRET",
        authorization = "Bearer ghp_SECRET",
        password = "hunter2",
    }
    for _, entity in ipairs({ "topic", "post", "review", "user", "notification" }) do
        local ok, row = pcall(github, entity, poisoned)
        if ok and type(row) == "table" then
            for column, value in pairs(row) do
                eq(
                    nil,
                    tostring(column):lower():match("token") or tostring(column):lower():match("password"),
                    ("%s row has a %s column"):format(entity, column)
                )
                if type(value) == "string" then
                    eq(nil, value:match("ghp_SECRET"), ("%s.%s carries a token: %q"):format(entity, column, value))
                    eq(nil, value:match("hunter2"), ("%s.%s carries a password"):format(entity, column))
                end
            end
        end
    end
end)

describe("lvim-forge: what a mutation's response refers to")

it("a pull request response is resolved as one, by any of the fields that mark it", function()
    -- A verb that passed no explicit `emit` leaves the sync layer to work it out from the body.
    eq({ kind = "pullreq", number = 7 }, model.response_ref("github", { number = 7, pull_request = {} }))
    eq({ kind = "pullreq", number = 7 }, model.response_ref("github", { number = 7, head = {} }))
    eq({ kind = "pullreq", number = 7 }, model.response_ref("github", { number = 7, base = {} }))
end)

it("a plain numbered response is an issue", function()
    eq({ kind = "issue", number = 7 }, model.response_ref("github", { number = 7 }))
end)

it("a body that announces nothing resolves to nothing", function()
    eq({}, model.response_ref("github", "not a table"))
    local empty = model.response_ref("github", {})
    eq(nil, empty.kind)
    eq(nil, empty.number)
end)

it("GitLab numbers a merge request by its iid, not its id", function()
    eq({ kind = "pullreq", number = 4 }, model.response_ref("gitlab", { iid = 4, source_branch = "feat" }))
    eq({ kind = "issue", number = 4 }, model.response_ref("gitlab", { iid = 4 }))
end)

it("a notification hands back its SUBJECT url, which is what the number is parsed off", function()
    -- Deliberately the API url: the sync layer reads the trailing topic number from it. It is not
    -- an address anybody opens, which is why it is not rewritten to the web page.
    local url = model.notification_url("github", {
        subject = { url = "https://api.github.com/repos/o/r/issues/7", type = "Issue" },
        repository = { full_name = "o/r" },
    })
    eq("https://api.github.com/repos/o/r/issues/7", url)
    eq("7", url:match("(%d+)$"), "the trailing number is the point of keeping it verbatim")
end)

it("a notification with no subject has no url", function()
    eq(nil, model.notification_url("github", {}))
    eq(nil, model.notification_url("github", { subject = "not a table" }))
    eq(nil, model.notification_url("github", "not a table"))
end)

it("a GitLab todo carries its target url instead", function()
    eq(
        "https://gitlab.com/o/r/-/issues/7",
        model.notification_url("gitlab", {
            target_url = "https://gitlab.com/o/r/-/issues/7",
        })
    )
end)
