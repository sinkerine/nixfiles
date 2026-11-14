# Fork maintenance registry

This is the reviewed maintenance set for the `fork-maintenance` skill. It was refreshed on 2026-11-08 from the calling Paseo daemon's projects and open workspaces, local Git remotes/status, live GitHub metadata, recent local Pi conversations (2026-11-02–08), and read-only Docker inspection on sachi. Hermes runtime details below come from the November 5 conversation, not a fresh VM inspection. Re-discover live project IDs, repository identities, default branches, and runtime paths before each run; these values are a starting point.

## Current discovery and testing policy

The calling daemon currently registers `nixfiles`, `paseo`, `magpie`, `hermes-agent`, `element-web`, `element-x-android`, `tiny-llm`, and `book-distill`. Open foreground workspaces currently belong to `nixfiles`, `paseo`, `magpie`, `tiny-llm`, and `book-distill`. A registered project and an open workspace are different discovery signals; neither alone approves new maintenance scope.

`matrix-rust-sdk` and `keepass2android` are no longer registered on this daemon; their checkouts still exist and they remain maintained. Their IDs below are historical: resolve or restore placement explicitly before creating maintenance workspaces, without silently registering duplicate projects. `pi-goal-x` remains unregistered.

The user's November 7 amendment supersedes the original blanket E2E gate: run existing unit tests and required build/lint checks for maintenance, pushes and deployments. Run sandbox E2E when first adding a feature, or when explicitly requested; do not rerun it merely for a later sync, push or deployment. Reuse feature evidence honestly and report its original revision. Read-only runtime health checks remain required. No production conversations, books, databases or accounts become test fixtures.

Repo-level `.agents/skills` were deliberately untracked/ignored in the November 7 conversation. The local fork-maintenance skill and its platform recipes still apply; editing this registry must not re-track them or reverse their staged deletions.

## Software managed by Nix

| Project | Fork → upstream | Fork default / upstream branch | Local checkout | Paseo project ID |
| --- | --- | --- | --- | --- |
| paseo | [sinkerine/paseo](https://github.com/sinkerine/paseo) → [getpaseo/paseo](https://github.com/getpaseo/paseo) | `main` / `main` | `/home/sinkerine/dev/paseo` | `prj_fd25e9856e774463` |

Paseo is consumed by the `/nixfiles` flake input `paseo`, then installed as the daemon and desktop app by standalone Home Manager. Update the fork first, then the input, activate Home Manager, and verify both running revisions. A NixOS switch alone does not install the updated user packages. Android builds of Paseo are outside the default scope; offer them only when requested.

| Project | Fork → upstream | Fork default / upstream branch | Local checkout | Paseo project ID |
| --- | --- | --- | --- | --- |
| pi-goal-x | [sinkerine/pi-goal-x](https://github.com/sinkerine/pi-goal-x) → [tmonk/pi-goal-x](https://github.com/tmonk/pi-goal-x) | `main` / `main` | `/home/sinkerine/dev/pi-goal-x` | not registered |

pi-goal-x is superseded by the in-tree `pkgs/pi-goal` package. The old package and fork remain for reference, and legacy `.pi/goals` data is left intact. Pi now loads `pi-goal`: goals belong to a session, live outside the worktree in `$XDG_STATE_HOME/pi-goal/goals`, restore automatically, copy on fork with deferred continuation, and transfer between tabs through `adopt_goal`. The quota-reset wrapper `PI_GOAL_QUOTA_URL` and active-subagent continuation hold remain. Pause/resume/clear are available to agents in user-triggered turns. There is no task tree or focus concept. Package checks run `node --experimental-strip-types --test tests/*.test.ts` with Pi peer dependencies linked by `pkgs/pi-goal/default.nix`. Paseo's separate `pi-goal` adapter is merged into the fork's `main` and consumed by the `paseo` flake input; its upstream `pi-goal-x` adapter stays untouched. After updating the input, activate standalone Home Manager and restart Paseo following the relevant deployment skills when deployment is requested.

## Services in sachi Docker

| Project | Fork → upstream | Fork default / upstream branch | Local checkout | Paseo project ID |
| --- | --- | --- | --- | --- |
| magpie | [sinkerine/magpie](https://github.com/sinkerine/magpie) → [yetone/magpie](https://github.com/yetone/magpie) | `main` / `main` | `/home/sinkerine/dev/magpie` | `prj_3c02ce6e187599fe` |
| element-web | [sinkerine/element-web](https://github.com/sinkerine/element-web) → [element-hq/element-web](https://github.com/element-hq/element-web) | `develop` / `develop` | `/home/sinkerine/dev/element-web` | `prj_3a6dc38d905a8c9f` |

Verified deployment locations:

| Project | Compose directory / file | Build context | Service / observed container | Observed image tag |
| --- | --- | --- | --- | --- |
| magpie | `/pool/main/docker/available/magpie/docker-compose.yaml` | `./magpie` | `magpie` / `magpie-magpie-1` | `magpie:15cm` |
| element-web | `/pool/main/docker/available/element-web/docker-compose.yaml` | `./source`, Dockerfile `apps/web/Dockerfile` | `app` / `element-web-app-1` | `element-web:local` |

The remote Magpie checkout has both `origin` and `upstream` pointing to `15cm/magpie`, the historical fork name. Do not treat that `upstream` remote as the original project. Resolve old GitHub URLs to canonical repository identity before deciding there is a mismatch. Keep Compose secrets and persistent directories out of sync artifacts and logs.

## Hermes on agent-sachi VM

| Project | Fork → upstream | Fork default / upstream branch | Local checkout | Paseo project ID |
| --- | --- | --- | --- | --- |
| hermes-agent | [sinkerine/hermes-agent](https://github.com/sinkerine/hermes-agent) → [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | `main` / `main` | `/home/sinkerine/dev/hermes-agent` | `prj_0a8d7488348f3f8c` |

SSH alias `agent-sachi` currently reports hostname `sinkerine-agent`. The runtime source is `/home/sinkerine/hermes-agent`, owned by the existing source installation. The active user unit is `hermes-gateway.service`, working directory `/home/sinkerine/hermes-agent`, with launcher `/home/sinkerine/hermes-agent/.hermes/bin/hermes gateway run`. Its `origin` is `https://github.com/15cm/hermes-agent.git`; GitHub resolves this to the same repository ID as `sinkerine/hermes-agent`. Nix was not found in the noninteractive VM PATH during the original inspection. The November 5 conversation established the deployment path: push local `main`, then run the existing installation's `hermes update --branch main --yes` on `agent-sachi`; it deployed `422eced44d` and left the gateway active and the checkout clean. Verify the updater selects the exact tested `origin/main` commit and stop on branch advancement or runtime divergence. Preserve the managed environment and source-install owner; do not replace it with raw pip/uv or migrate it to Nix as routine maintenance. See the platform recipe.

## Android apps and their SDK library

| Project | Fork → upstream | Fork default / upstream branch | Local checkout | Paseo project ID |
| --- | --- | --- | --- | --- |
| element-x-android | [sinkerine/element-x-android](https://github.com/sinkerine/element-x-android) → [element-hq/element-x-android](https://github.com/element-hq/element-x-android) | `develop` / `develop` | `/home/sinkerine/dev/element-x-android` | `prj_19503f905c297417` |
| matrix-rust-sdk | [sinkerine/matrix-rust-sdk](https://github.com/sinkerine/matrix-rust-sdk) → [matrix-org/matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-sdk) | `main` / `main` | `/home/sinkerine/dev/matrix-rust-sdk` | `prj_9fb83d91a45a8abc` |
| keepass2android | [sinkerine/keepass2android](https://github.com/sinkerine/keepass2android) → [PhilippC/keepass2android](https://github.com/PhilippC/keepass2android) | `main` / `main` | `/home/sinkerine/dev/keepass2android` | `prj_734234b52e95cd93` |

Treat the Rust SDK and Element X as a dependency chain: SDK regression tests → immutable Android AAR/Maven artifact → Element X dependency pin → app unit/E2E tests → signed APKs → installation. The SDK is not an independently installed phone app. Element X currently consumes `org.matrix.rustcomponents:sdk-android:26.09.9-custom.1` from the fork's GitHub Packages repository.

Known conditions that require inspection before a run:

- Element X's fork default and local checkout are both `develop`, matching upstream's default. Recheck live metadata before each sync.
- The SDK's local `main` had four unpublished commits at the November 2 inspection. On November 8 it still has a dirty tree, now including FFI/thread-inbox, event-cache and timeline changes plus new edit-ordering tests. Leave that work untouched; do not switch, merge, stash, or publish it as part of maintenance. A clean checkout of the fork default can be used for remote-only maintenance if it does not silently omit an expected local fix; report the distinction.
- The SDK's `android-sdk-package.yml` currently publishes only from `custom`, despite the fork default being `main`, and contains historical `15cm` package URLs. Compare the publishing branch with the tested default commit. Never dispatch a stale branch or claim the new SDK was installed from an old artifact.
- Element X's newer [APK release skill](/home/sinkerine/dev/element-x-android/.agents/skills/element-x-android-apk-release/SKILL.md), established November 5, owns routine phone updates: re-read HEAD, build a fresh `:app:assembleGplayRelease`, select the device ABI, re-sign with the canonical local key, and install in place with `adb -s <serial> install -r --no-incremental`. Verify the certificate and preserved first-install timestamp; do not reuse an old APK based on its mtime/version. The older F-Droid two-app distribution recipe applies when that distribution is requested; it is not the default for a primary phone update.
- Preserve the canonical signing keys documented in each app's `AGENTS.md`. Element X has primary and second package variants. KeePass2Android uses its own local release signing identity. Never regenerate keys or uninstall an installed app to bypass a signature mismatch.

## Additional reviewed sachi Docker projects

The user approved all four additions during the November 8 registry review. Miniflux and Miniflux AI join the maintained fork set. Book-distill and Calibre MCP are managed deployment entries with no upstream merge: include them when requested by name or as part of all managed deployments, not implicitly in “all forks.” All local paths below are under `/home/sinkerine/dev/`; none except book-distill is currently registered in Paseo. Resolve workspace placement before maintenance without creating duplicate registrations implicitly.

| Project | Identity and defaults | Proposed category / deployment | Maintenance status |
| --- | --- | --- | --- |
| book-distill | [sinkerine/book-distill](https://github.com/sinkerine/book-distill), user-owned, `main`; checkout `book-distill`; Paseo `prj_3ac436eee2979858` | sachi Docker; deployment only, no upstream sync | Managed deployment |
| calibre-mcp | [sinkerine/calibre-mcp](https://github.com/sinkerine/calibre-mcp), user-owned, `main`; checkout `calibre-mcp` | sachi Docker; deployment only, no upstream sync | Managed deployment |
| miniflux | [sinkerine/miniflux](https://github.com/sinkerine/miniflux) → [miniflux/v2](https://github.com/miniflux/v2); fork default `custom`, upstream `main`; local checkout `miniflux` currently on `main` | sachi Docker; service `app` in the shared Miniflux stack | Maintained fork; resolve branch alignment before execution |
| miniflux-ai | [sinkerine/miniflux-ai](https://github.com/sinkerine/miniflux-ai) → [Qetesh/miniflux-ai](https://github.com/Qetesh/miniflux-ai); `main` / `main`; checkout `miniflux-ai` | sachi Docker; service `ai` in the shared Miniflux stack | Maintained fork; verify test entry points before execution |

Observed sachi Compose locations on November 8:

| Project | Compose file | Service / container | Image |
| --- | --- | --- | --- |
| book-distill | `/pool/main/docker/available/book-distill/docker-compose.yaml` | `book-distill` / `book-distill-book-distill-1` | `book-distill:local` |
| calibre-mcp | `/pool/main/docker/available/calibre-mcp/docker-compose.yaml` | `calibre-mcp` / `calibre-mcp-calibre-mcp-1` | `calibre-mcp:local` |
| miniflux | `/pool/main/docker/available/miniflux/docker-compose.yaml` | `app` / `miniflux-app-1` | `miniflux-app` |
| miniflux-ai | same shared Miniflux Compose file | `ai` / `miniflux-ai-1` | `miniflux-ai` |

Book-distill's authoritative procedure is [AGENTS.md](/home/sinkerine/dev/book-distill/AGENTS.md) and its [deploy-sachi skill](/home/sinkerine/dev/book-distill/.agents/skills/deploy-sachi/SKILL.md). Run local Python/frontend unit tests, Nix builds, selftests, lint and Docker checks. Push the verified committed revision first, then back up production and have sachi pull that exact revision into `/pool/main/docker/available/book-distill/src` with `git pull --ff-only`; rebuild/restart through its existing Compose stack. Do not rsync local working-tree source. Removing production source edits needs explicit authorization; the one-time November 7 cleanup is not standing permission. Back up SQLite through the backup API (including reading position and durable jobs), protected config, source and Compose with checksums; preserve the old image. Keep data outside `src`. Preserve OCR data at `/home/sinkerine/.local/share/book-distill/tessdata`. Verify only read-only health, `/` and `/sw.js` at `https://learn.sachi.m.mado.moe`; do not run production test jobs or imports. The latest conversation reports deployment of `28eba99e9338ea8228578cc00cc0ce0a5edb1ae4` on November 8, with backup `persist/backup-20261108T021753Z`; rediscover the live source/image before updating. Chat was removed, so do not restore historical chat config/tests.

Book-distill depends on Calibre MCP and the separate `hindsight-books` stack. The latter exposes LAN-only UI `https://hindsight-book.sachi.m.mado.moe` and API/MCP `https://hindsight-book-api.sachi.m.mado.moe`, uses production BGE-M3 embeddings and bge-reranker-v2-m3, and is distinct from the existing `hindsight` stack. Preserve both stacks, banks and model dimensions; deployment does not authorize reindexing or provisioning. The lightweight synthetic E2E configuration does not validate production models.

Calibre MCP tests use `nix develop -c python -m unittest discover -s tests`; `nix build` also runs its synthetic suite. Its [README](/home/sinkerine/dev/calibre-mcp/README.md) owns the Docker recipe. Confirm live build context/source identity, update to the verified committed revision, retain the previous image, and rebuild/recreate only `calibre-mcp`. Preserve read-only library mounts, conversion cache and existing LAN-only access; check `/health` without downloading or converting real books. Roll back to the retained image/config without touching libraries.

Miniflux's [Makefile](/home/sinkerine/dev/miniflux/Makefile) declares `make test` (Go race/coverage), lint and integration tests; integration setup drops a test database, so use an isolated test database only. Reconcile fork `custom` versus local `main` and the remote build-context branch before any sync/install. Miniflux AI's [AGENTS.md](/home/sinkerine/dev/miniflux-ai/AGENTS.md) and README own its workflow; inspect current test entry points before execution (no test command established in this review). For either service, verify live build context and source, back up the shared PostgreSQL data/config consistently, retain old images, and build/recreate only the selected `app` or `ai` service with `--no-deps`. Preserve `db` and its volume; review schema migrations before relying on image rollback. Missing AI test evidence blocks a claim of completed regression testing.

## Other irrelevant projects

| Project | Classification | Local checkout | Paseo project ID |
| --- | --- | --- | --- |
| tiny-llm | Excluded tutorial fork of [skyzh/tiny-llm](https://github.com/skyzh/tiny-llm); local branch `week1` had user edits. | `/home/sinkerine/dev/tiny-llm` | `prj_15ebb5c01d32a1de` |
| nixfiles | Excluded from upstream sync: user-owned configuration and this maintenance registry. It remains the deployment source for Nix packages. | `/nixfiles` | `prj_1590dc3766194223` |

The previous Orca inventory included [sinkerine/TREK](https://github.com/sinkerine/TREK). TREK is running on sachi but is absent from the current Paseo project registry. It is outside this maintenance set until the user chooses to add it. Other sachi containers are not automatically maintenance projects.

## Managing this registry

This file is the source of truth; the live Paseo registry is discovery input. Run the [fork-maintenance skill](.agents/skills/fork-maintenance/SKILL.md) for an explicit project selection or all maintained forks. Maintain the SDK before Element X and install Paseo last, because its restart can interrupt orchestration.

At the start of every maintenance invocation, compare live Paseo projects with all entries above, including exclusions. New projects become pending candidates, never automatically managed. Gather the canonical fork and parent, default branches, checkout path, proposed category and target, dependency relationships, test entry points, and installation/rollback recipe before asking the user to review them. Present candidates together and offer **manage**, **exclude**, or **defer** for each. Explain the proposed target and any missing evidence. Continue unrelated approved projects while a candidate is pending.

Record accepted additions with all required metadata and links to their authoritative project instructions. Record exclusions with a reason so the same project does not trigger a question every run. Keep deferred candidates pending and re-present them on the next explicit registry review or when relevant evidence changes; do not repeatedly interrupt one run. If the user explicitly names a new project to maintain and provides its target, that is approval to add it once identity and the recipe are verified; ask only for missing decisions.

Prompt again for a changed upstream identity, ambiguous default/installation branch, category or deployment target, newly required permissions/credentials, or a change that would remove a fork customization or user data. An equivalent renamed GitHub URL is metadata refresh, not a new project. A registry-review request authorizes metadata/recipe edits, not executing syncs, pushes or deployments. Record user-owned projects as deployment entries without an invented upstream; “all forks” includes only admitted forks, while “all managed deployments” includes admitted deployment-only entries too.

Missing Paseo registrations do not authorize deleting checkouts or removing maintained entries: mark them unavailable and report them. Update observed branch/path metadata when unambiguous; do not silently broaden the maintenance scope.

Routine clean merges, understood conflict fixes, declared test runs, installation to the recorded target, and archiving workspaces created by the current invocation do not need repeated confirmation when the user has requested the full sync-and-install workflow. A sync-only or report-only request limits that authorization. Creating this registry and skill does not itself run updates, publish artifacts, or deploy software.
