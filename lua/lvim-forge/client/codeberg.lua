-- lvim-forge.client.codeberg: Codeberg IS hosted Forgejo, so its backend IS the Gitea/Forgejo backend —
-- this module is a one-line re-export of `client/gitea`. The `client.backend(forge)` seam resolves a forge
-- by `require("lvim-forge.client." .. forge)`, so a repo detected as the first-class named forge "codeberg"
-- (via `client/detect` classifying `codeberg.org`, or `config.hosts`) runs the exact same code as a Gitea
-- host; only the API base URL differs (`https://codeberg.org/api/v1`, resolved host-driven by
-- `detect.api_base`), and the `ctx.forge` string ("codeberg") flows through unchanged. The normalizers
-- likewise share one table (`model.forges.codeberg = model.forges.gitea`), and `client.caps("codeberg")`
-- reads this module's `caps` (= gitea's). One impl in code, a first-class named forge in config/docs.
--
---@module "lvim-forge.client.codeberg"

return require("lvim-forge.client.gitea")
