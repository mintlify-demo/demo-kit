# mintlify-demo reset kit

Layout: all docs live in `mintlify-demo/docs` (single Mintlify source). Site pages are at its root (served at `/`, `/quickstart`, `/es/...`; old `/docs/...` URLs redirect), each API's docs are in `<repo>/` (served at `/<repo>/...`, login required). The four API repos hold only code, tests, and a README. The 12 demo PRs change only `main.py` and `tests/`; Mintlify's *Update from code changes* automation watches the API repos and opens the matching docs PR in `docs`.

Every demo PR is opened against `main` (`gh pr create --base main --head demo/<n>-...`). They are not stacked. Each `demo/*` branch already contains the commits below it, so the PRs merge cleanly in any order. Whichever one you merge lands on main and triggers *Update from code changes*. A higher PR's diff includes the lower PRs' changes until those merge.

- `manifest.json`: the 12 demo PRs (repo, order, branch, backup_branch, base, title, body, patch). `base` is always `main`.
- `patches/<repo>/000N.patch`: the same commits as a patch series on top of the `demo-baseline` tag (fallback).
- Backup branches on GitHub: `demo-src/<n>-<slug>` in each API repo hold the exact demo commits. The reset never deletes them.
- `reset.sh`: `./reset.sh --dry-run` to preview, `./reset.sh` for the full nightly reset, `./reset.sh --only-open` to just recreate missing demo branches and PRs. Needs gh, jq, git. Optionally creates `$KIT/.venv` from `requirements-dev.txt` (non-fatal; the reset itself doesn't use it). Skip that with `SKIP_VENV=1`.
- `verify.sh`: checks API mains (and acme-app) match `demo-baseline`, 12 open demo PRs all target `main`, no open PRs in `docs`, and https://mintlify-demo.mintlify.site/ returns 200. Exit 1 if anything is off. Used by the nightly workflow after `reset.sh`.
- `logs/`: one log per run (not committed).

## Nightly reset (GitHub Actions)

The scheduled reset runs in this repo at 11 PM Pacific Standard Time via `.github/workflows/reset.yml`:

```
cron: '0 7 * * *'   # 11:00 PM PST (UTC-8)
```

Pacific Daylight Time (mid-March to early November) is UTC-7, so the same cron is 12:00 AM PDT. The workflow is also runnable by hand (`workflow_dispatch`). It does not use a local `/workspace` checkout or the box venv.

The workflow needs the `DEMO_RESET_TOKEN` secret (see the token scopes in the workflow file comments). Do not put tokens in this repo.

To run the same reset locally: `./reset.sh --dry-run`, then `./reset.sh`, then `./verify.sh`.

## Docs repo (docs_safe_repos)
The reset never force-pushes docs main. It closes open PRs from the Mintlify app or Autopilot (`bot_author_regex`) and deletes their branches; PRs by humans or other agents are left alone. Then it reverts Mintlify PRs merged since the `demo-reset-last` tag (falling back to `demo-baseline`) in one commit, "Demo reset: revert Mintlify automation docs updates", pushed as a fast-forward. A revert that conflicts is skipped with a WARNING and the script exits 3. Finally it moves `demo-reset-last` to docs main.

## Acme Coffee Club (acme-app + the public Acme Help Center)
- `acme-app` is in `reset_repos`: open PRs are closed and main is reset to its `demo-baseline` tag (the app with plain-English `acme/settings.py`). It has no demo PRs in the manifest; demos open their own one-line settings PRs.
- The public `/acme` docs are reset by **Step 0b, docs restore** (`docs_restore` in `manifest.json`): `acme/`, `images/acme/` and the "Acme Help Center" nav tab in `docs.json` go back to the docs tag `acme-baseline` (docs #40) in one normal commit, "Demo reset: restore Acme Help Center baseline", pushed as a fast-forward. Pages added under `acme/` (for example a "change my email" page) are removed. The rest of `docs.json` (theme, styling, other tabs) is never touched.
- `verify.sh` checks that those paths and the tab match `acme-baseline` and that every `/acme` page returns 200 without a login redirect.
- To change the Acme baseline: merge the change to docs main, then move the annotated `acme-baseline` tag to the new commit (and `demo-baseline` in acme-app for code).
- `reset.sh` starts with a no-change write-access probe per repo and logs a WARNING if `DEMO_RESET_TOKEN` can't push to one.

To change the docs baseline: land the change on docs main with a normal push or a merged PR, then move both `demo-baseline` and `demo-reset-last` to the new main.

## Changing an API repo's main (rebuild the demo commits)
1. Commit the change on top of the repo's `demo-baseline` in a local clone (code/tests/README only; no `docs/`).
2. Rebuild each `demo-src/*` commit on top of the new main (code-only: `main.py` and `tests/`). Each later branch should still contain the commits below it. Run pytest on every commit.
3. Force-push the new main, `demo-src/*`, and move the annotated `demo-baseline` tag (`gh api` git/tags + `PATCH git/refs/tags/demo-baseline -F force=true`).
4. `git format-patch --zero-commit -o patches/<repo> <new-main>..<last demo-src>` and rename to `000N.patch`; update bodies in `manifest.json` if needed. Keep `"base": "main"`.
5. `./reset.sh --dry-run`, then `./reset.sh`, then `./verify.sh`.

TODO(hosting): the APIs aren't hosted; the OpenAPI `servers` are `http://localhost:8000` only. When a host exists, add it first in `servers=[...]` in each `main.py` (and `url` in text-utils-api's `code_samples`, `DEFAULT_BASE_URL` in todo-api `sdk/todo_client/client.py`), then update `servers` in the docs repo's `<repo>/openapi*.json` and `todo-api/asyncapi.yaml` (regenerate with `app.openapi()` from the code) and follow the steps above.

## Other files
- `linear-tickets.json`: six seed tickets (DEMO-1 to DEMO-6) for the *Update docs from tickets* automation. Each names the code repo and files (code there, docs in `mintlify-demo/docs` under `<repo>/`). Each API repo README has a matching "Ticket -> file map". Nothing is created in Linear.
- `auth0-post-login-action.js`: the Auth0 Action for personalization without a hosted Info API (Mintlify Info API URL = Auth0 `/userinfo`). See `mintlify-demo/demo-info-api` README.
- `auth0-jwt-handoff-action.js`: Auth0 Action for the JWT handoff path.
