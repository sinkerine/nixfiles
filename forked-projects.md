# Fork maintenance registry

This is the reviewed maintenance set for the `fork-maintenance` skill. It was collected from the current local Paseo project registry, Git remotes, GitHub repository metadata, and read-only runtime inspection on sachi and agent-sachi on 2026-11-02. Re-discover live project IDs, repository identities, default branches, and runtime paths before each run; these values are a starting point.

## Software managed by Nix

| Project | Fork → upstream | Fork default / upstream branch | Local checkout | Paseo project ID |
| --- | --- | --- | --- | --- |
| paseo | [sinkerine/paseo](https://github.com/sinkerine/paseo) → [getpaseo/paseo](https://github.com/getpaseo/paseo) | `main` / `main` | `/home/sinkerine/dev/paseo` | `prj_fd25e9856e774463` |

Paseo is consumed by the `/nixfiles` flake input `paseo`, then installed as the daemon and desktop app by standalone Home Manager. Update the fork first, then the input, activate Home Manager, and verify both running revisions. A NixOS switch alone does not install the updated user packages. Android builds of Paseo are outside the default scope; offer them only when requested.

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

SSH alias `agent-sachi` currently reports hostname `sinkerine-agent`. The runtime source is `/home/sinkerine/hermes-agent`, owned by the existing source installation. The active user unit is `hermes-gateway.service`, working directory `/home/sinkerine/hermes-agent`, with launcher `/home/sinkerine/hermes-agent/.hermes/bin/hermes gateway run`. Its `origin` is `https://github.com/15cm/hermes-agent.git`; GitHub resolves this to the same repository ID as `sinkerine/hermes-agent`. Nix was not found in the noninteractive VM PATH during inspection. Respect the target machine's installation policy and the existing runtime owner; see the platform recipe before updating dependencies.

## Android apps and their SDK library

| Project | Fork → upstream | Fork default / upstream branch | Local checkout | Paseo project ID |
| --- | --- | --- | --- | --- |
| element-x-android | [sinkerine/element-x-android](https://github.com/sinkerine/element-x-android) → [element-hq/element-x-android](https://github.com/element-hq/element-x-android) | `develop` / `develop` | `/home/sinkerine/dev/element-x-android` | `prj_19503f905c297417` |
| matrix-rust-sdk | [sinkerine/matrix-rust-sdk](https://github.com/sinkerine/matrix-rust-sdk) → [matrix-org/matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-sdk) | `main` / `main` | `/home/sinkerine/dev/matrix-rust-sdk` | `prj_9fb83d91a45a8abc` |
| keepass2android | [sinkerine/keepass2android](https://github.com/sinkerine/keepass2android) → [PhilippC/keepass2android](https://github.com/PhilippC/keepass2android) | `main` / `main` | `/home/sinkerine/dev/keepass2android` | `prj_734234b52e95cd93` |

Treat the Rust SDK and Element X as a dependency chain: SDK regression tests → immutable Android AAR/Maven artifact → Element X dependency pin → app unit/E2E tests → signed APKs → installation. The SDK is not an independently installed phone app. Element X currently consumes `org.matrix.rustcomponents:sdk-android:26.09.9-custom.1` from the fork's GitHub Packages repository.

Known conditions that require inspection before a run:

- Element X's fork default and local checkout are both `develop`, matching upstream's default. Recheck live metadata before each sync.
- The SDK's local `main` was four commits ahead of `origin/main` with three modified source files. Leave that work untouched; do not switch, merge, stash, or publish it as part of maintenance. A clean checkout of the fork default can be used for remote-only maintenance if it does not silently omit an expected local fix; report the distinction.
- The SDK's `android-sdk-package.yml` currently publishes only from `custom`, despite the fork default being `main`, and contains historical `15cm` package URLs. Compare the publishing branch with the tested default commit. Never dispatch a stale branch or claim the new SDK was installed from an old artifact.
- Preserve the canonical signing keys documented in each app's `AGENTS.md`. Element X has primary and second package variants. KeePass2Android uses its own local release signing identity. Never regenerate keys or uninstall an installed app to bypass a signature mismatch.

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

Prompt again for a changed upstream identity, ambiguous default/installation branch, category or deployment target, newly required permissions/credentials, or a change that would remove a fork customization or user data. An equivalent renamed GitHub URL is metadata refresh, not a new project. Missing Paseo registrations do not authorize deleting checkouts or removing maintained entries: mark them unavailable and report them. Update observed branch/path metadata when unambiguous; do not silently broaden the maintenance scope.

Routine clean merges, understood conflict fixes, declared test runs, installation to the recorded target, and archiving workspaces created by the current invocation do not need repeated confirmation when the user has requested the full sync-and-install workflow. A sync-only or report-only request limits that authorization. Creating this registry and skill does not itself run updates, publish artifacts, or deploy software.
