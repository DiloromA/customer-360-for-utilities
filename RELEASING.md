# Releasing

This project is developed in one canonical repo and mirrored to two release repos.

| Repo | Remote | gh account | Purpose |
| --- | --- | --- | --- |
| `timstan-db/customer-360-for-utilities` | `origin` | timstan-db | **Development.** Full commit history, all branches, day-to-day work. |
| `tim-stanton_data/customer-360-for-utilities` | `release` | tim-stanton_data | **Internal mirror.** One clean squashed commit per release, tagged `vX.Y.Z`. |
| `databricks-industry-solutions/customer-360-for-utilities` | `release-industry` | timstan-db | **Solution Accelerator mirror.** Same snapshot model; org-standard governance lives on `main`. |

Normal development is unchanged — work on `main` and feature branches against `origin`. The mirrors only receive **major releases**, and only when you run the publish script. The two mirrors are **independent**: publish to whichever you want, whenever you want.

## How it works

Each mirror has its own persistent orphan branch in this clone (`release`, `release-industry`) that accumulates one commit per release. Each commit is the entire tree of `main` at publish time, chained to that mirror's previous release, so the mirror's history reads as a clean list of releases and `git diff` between release tags works. Dev history in `origin` is never pushed to a mirror.

Local tags are namespaced per mirror (`internal/vX.Y.Z`, `industry/vX.Y.Z`) so they never collide; each pushes to a plain `vX.Y.Z` tag in its own mirror repo.

## Publishing a release

From a clean `main`:

```
# internal mirror (tim-stanton_data)
scripts/publish-release.sh --mirror internal  v1.1.0 "Short changelog"

# solution-accelerator mirror (databricks-industry-solutions)
scripts/publish-release.sh --mirror industry  v1.0.0 "Short changelog"
```

The script snapshots `main`, commits onto the mirror's orphan branch, tags it, switches the active `gh` account to that mirror's publish account for the push, then restores your previous account.

`--force` overwrites the mirror's `main` — needed only the first time a mirror repo already contains unrelated history (e.g. the industry-solutions template scaffold). Steady-state releases do not need it.

Governance note: `LICENSE.md` (Databricks DB License), `NOTICE.md`, `SECURITY.md`, `CONTRIBUTING.md`, and the README SA badges live on `main`, so every mirror inherits them automatically. Improve them on `main`; do not hand-edit mirrors.

## One-time setup (already done)

- Remotes: `release` → tim-stanton_data, `release-industry` → databricks-industry-solutions.
- Orphan branches `release` and `release-industry`, each seeded with an empty root commit.
- `gh` logged into `timstan-db` and `tim-stanton_data`; `gh auth setup-git` is the credential helper.
- `databricks-industry-solutions` is SSO-enforced — the `timstan-db` gh token must be authorized for that org (`gh auth login --web`, complete the org SSO grant).
