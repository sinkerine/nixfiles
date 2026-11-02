# Platform test and installation recipes

Use `/nixfiles/forked-projects.md` for the reviewed targets. These are inspected entry points, not frozen commands: read the selected revision's instructions and script definitions before execution. Provision workstation software through Nix, preferring existing development shells. Preserve the target's installation owner; do not introduce a second updater or migrate deployment systems as part of a routine sync.

## Paseo through Nix and standalone Home Manager

Read `/nixfiles/.agents/skills/paseo-update/SKILL.md`, plus `nix-switch` for local activation or `nix-deploy-rs` when a remote Nix target was requested. In the fork, read `AGENTS.md`, `docs/testing.md`, `docs/qa.md`, `docs/development.md` and relevant fork feature plans.

Run targeted Vitest files (`npx vitest run <file> --bail=1`), the required npm typecheck/lint/format checks, and relevant daemon and app Playwright E2E tests. Rebuild owning workspace packages before diagnosing stale declaration failures. Use disposable daemon homes/ports and avoid the main daemon on 6767 during testing. Follow the repository's ban on full local test suites; use CI for broad coverage. Test protocol and local custom agent/workspace behavior when affected. Include a real Electron journey when desktop integration changes; a Chromium renderer test does not prove native Electron behavior.

After the tested fork default is pushed, refresh only the `paseo` input in `/nixfiles`. Require its locked revision to equal the tested candidate; if the fork advanced, pin the tested revision or test the newer one rather than installing an untested HEAD. Fix npm dependency hashes in the fork when necessary and repeat the relevant checks.

Apply standalone Home Manager and restart daemon/desktop using the durable systemd procedures in `paseo-update`. Record the current profile/store paths before activation. Verify active daemon and desktop executable store paths contain the new revision, the daemon is reachable, and providers/workspaces remain accessible. A NixOS switch alone is insufficient. Restart Paseo last, retaining a durable run record and continuation instructions for any interruption.

Follow `/nixfiles/AGENTS.md` for Nix validation: only on `kazuki`, use `nixos-rebuild build --flake .#<affected-host>` for affected hosts or `nix build` for package changes, and fix failures. Do not run this validation on other machines. Do not automatically activate other Nix hosts just because they also consume the input.

## Magpie and Element Web in sachi Docker

Read the project's root/subdirectory instructions and inspect the current Compose file and Dockerfile on sachi. Connect with `ssh -o BatchMode=yes sachi`; authentication failure is a blocker, not a reason to request or print a secret. Read selected fields and mount paths; avoid expanded Compose/environment dumps that expose credentials.

Testing:

- **Magpie:** read `docs/code-standards.md`, `LESSONS.md`, relevant subsystem docs, `Makefile`, and `internal/gui/tests/README.md`. Use the declared Go build tags for targeted `go test`/vet; `make test` and `make test-ui` are broad entry points whose scope must be budgeted. Browser regressions use Node's test runner, for example `node --test --test-concurrency=1 internal/gui/tests/<selected>.test.cjs`, with Chromium/WebKit supplied through the Nix environment. Fixtures must not read live provider configuration. For gateway/runtime changes, also run an isolated real Magpie backend with synthetic state and the relevant UI/API journey. Verify fork-specific provider/routing/usage behavior affected by upstream changes.
- **Element Web:** read `AGENTS.md` and `docs/playwright.md`. Legacy `apps/web/test/**/*-test.*` uses Jest; colocated `*.test.ts(x)` uses Vitest; shared-components tests run in that package. Use the file's actual runner. Playwright entry point: from `apps/web`, `pnpm test:playwright -- playwright/e2e/<spec>.spec.ts --project=Chrome`. Supply disposable homeserver containers and test accounts. Check for a stale server on port 8080 so the test exercises the candidate. Preserve custom Matrix behavior and do not regenerate unexplained screenshot baselines.

Installation sequence:

1. Confirm live container labels still identify the registry's Compose directory, file and service. Read the build context, bind mounts, networks, healthcheck and build arguments. Inspect the remote source checkout's identity, branch and cleanliness. Preserve persistent state and any intentional deployment-only config.
2. Record running container image ID, prior source SHA, Compose/config identity, and health. Retain the old image under a unique rollback tag before building over a mutable tag. Check whether the candidate changes persistent schemas or requires a backup.
3. Bring the clean build-context checkout to the exact tested, pushed fork SHA using a fetch and fast-forward where possible. For an unexpected branch, dirty tree or divergence, preserve it and resolve the placement explicitly; do not hard-reset it. Verify remote `HEAD` equals the tested SHA. Audit historical `15cm` URLs by canonical repository ID, and never fetch original upstream based solely on a remote's name.
4. Build only the target service with the existing Compose recipe. In the confirmed directory, the normal command shapes are `docker compose -f docker-compose.yaml build <service>` followed by `docker compose -f docker-compose.yaml up -d --no-deps <service>`. Discover and include existing overrides/project options. `magpie` is Magpie's service and `app` is Element Web's service. Do not run a stack-wide `down`, change unrelated services, or delete volumes.
5. Confirm the running container's image ID equals the newly built image and the build used the recorded source SHA. Check health, startup logs and the existing route. For Magpie verify web/API availability without logging keys or spending model quota; for Element Web verify version/static assets and page startup through the existing route. Test user behavior with synthetic accounts in the isolated environment, not production conversations.
6. On activation failure, recreate only the target service with the retained image and existing config when data compatibility permits. Verify restoration. If a schema migration makes rollback unsafe, pause and report the concrete recovery decision rather than claiming rollback protection.

Do not replace these existing Docker deployments with NixOS services as a side effect of fork maintenance. Nix manages workstation tools and the host's existing Docker infrastructure; the reviewed service artifact remains its Docker image.

## Hermes on agent-sachi VM

Read the selected fork's `AGENTS.md`, `tests/AGENTS.md`, relevant area instructions, `CONTRIBUTING.md`, and `website/docs/reference/package-management.md`. Audit prompt changes on every upstream merge, including clean merges. Preserve the fork's profile, session, prompt-caching and runtime-owner behavior.

Use `scripts/run_tests.sh <selected paths/options>` as documented, never bare pytest. Run `python scripts/check` with the repository's pinned development tools. Select real-import E2E coverage using temporary `HERMES_HOME` and `HERMES_RUNTIME_DIR`; tests must not write to live `~/.hermes`. Test gateway/profile isolation, session persistence and relevant tool/provider behavior with synthetic fixtures. Validate host-specific behavior on the matching host without invoking live messaging side effects.

The inspected runtime is a source install at `/home/sinkerine/hermes-agent`, launched by user `hermes-gateway.service` through `.hermes/bin/hermes`. The VM reports `sinkerine-agent` through SSH alias `agent-sachi`. Verify all of this live, along with applicable remote instructions and installation provenance. Do not confuse local workstation Nix packaging with the VM's existing source installation.

1. Record runtime SHA, launcher, installation owner, selected Python/dependency generation, unit state and a rollback handle. Inspect source cleanliness and pending updater transactions. Preserve all profile state, secrets, sessions and tools.
2. Fetch the reviewed fork and fast-forward the clean runtime default to the exact tested SHA. Preserve divergence or user edits rather than resetting them. GitHub identifies the observed historical `15cm/hermes-agent` URL as `sinkerine/hermes-agent`.
3. Reconcile dependencies only through the verified installation owner's documented path. The current Hermes PM docs describe source launchers detecting source/lock changes and synchronizing the managed environment; inspect the candidate's actual launcher, install stamp, updater and supported PM commands before relying on this. Never use raw pip/uv to mutate its environment, rerun a network installer blindly, or run a floating `hermes update` that could select a different SHA. If an applicable machine policy requires Nix, use a Nix package/Home Manager deployment; if doing so would migrate this existing installation, prepare the migration and ask the user before changing ownership. Missing policy/ownership information or unsupported exact-revision reconciliation blocks installation.
4. After reconciliation succeeds, restart only the verified user unit, normally `systemctl --user restart hermes-gateway.service` on the VM. Check its state, runtime source SHA, launcher/dependency provenance and recent logs. Use read-only status/health commands documented by that revision; do not send a message to a real contact as a smoke test.
5. If it fails, restore the prior source revision and compatible dependency generation through the installation owner's supported recovery mechanism. Keep evidence and profile data intact. Do not mask failure with repeated gateway restarts.

## Android: matrix-rust-sdk → Element X

Read the SDK's `CONTRIBUTING.md`, relevant crate/binding docs and `.github/workflows/android-sdk-package.yml`. Read Element X's `AGENTS.md`, `.maestro/README.md`, `docs/integration_tests.md`, `docs/two-element-x-apps.md` and current release instructions. Use Nix-provided Rust/JDK/Android SDK/NDK and emulator tools on the workstation.

SDK tests use targeted affected crate tests and binding builds with the required features. Verify generated Kotlin/UniFFI bindings and all distributed Android ABIs. The SDK includes `cargo xtask kotlin build-android-library`; inspect its current `--help` and packaging workflow for the exact build inputs rather than inventing Gradle publication tasks.

The inspected SDK publishing workflow runs only on `custom`, although the fork default is `main`. Resolve which tested commit the publish branch contains before publishing. If moving/updating that branch changes its intended patch stack, present the concrete branch decision to the user. Never dispatch it against a stale commit. Its historical `15cm` Maven URLs and GitHub package ownership must be verified, not mechanically rewritten. Reusing `26.09.9-custom.1` would violate its immutable-version check: select a new version, publish only under the workflow's existing reviewed package ownership, and record the AAR checksum, source SHA, workflow run and Maven coordinate. Use supported workflow-dispatch inputs/branch selection after inspecting the live workflow. Do not trigger a public GitHub Release merely to update a Maven dependency.

Update Element X's `gradle/libs.versions.toml` (or current owner of the SDK pin) to that verified immutable artifact. Verify Gradle resolves the intended fork repository and version, then run affected module unit tests, lint/build checks and Maestro/instrumented E2E on a disposable emulator and dedicated synthetic Matrix account/room. The upstream Maestro guide sends messages, so use a test account and room. Include the fork's threads/inbox journeys when affected, plus login, sync and navigation. Record candidate APK hash and the embedded SDK version. Missing test-account credentials or emulator support is a blocker; never substitute the user's active account.

Build and preserve both primary and second Element X APKs when maintaining its recorded two-app distribution. `docs/two-element-x-apps.md` owns variant build/signing commands. The inspected release tasks are `:app:assembleFdroidRelease` and the same with `-PelementSecondInstance=true`. Gradle output currently uses a staging certificate; re-sign using the existing canonical local key described in `AGENTS.md`, without printing passwords. Compare both signer SHA-256 digests and package/version codes. Keep keys outside Git and logs. Run the required E2E workflow as part of maintenance; do not claim the SDK was installed until the consumer app uses it.

If the user specified a physical-device target or a registry review established one, verify its stable connection, serial, installed package ID, certificate and version first. Install with `adb -s <serial> install -r --no-incremental <signed-apk>`; never uninstall to bypass a certificate error or loop retries on an unstable connection. Confirm version/certificate and an in-place update (`firstInstallTime` precedes `lastUpdateTime` for an existing install). If no physical device was selected, complete install/E2E on the disposable emulator, retain the signed APKs and report that phone installation is pending. Prompt for the missing device choice only after preparing the concrete artifacts. Release uploads or publishing new distribution channels need their own authorization when not already requested.

## Android: KeePass2Android

Read `AGENTS.md`, `docs/development.md`, `.agents/skills/android-e2e/SKILL.md`, and `.agents/skills/android-release/SKILL.md`. Existing entry points:

```sh
nix develop --command kp2a test
nix develop --command kp2a build
nix develop --command kp2a e2e
nix develop --command kp2a release
```

Read current task definitions first. `kp2a test` covers the existing Autofill parser suite; select/add behavior tests for fork changes outside that coverage. The E2E runner starts a fresh disposable emulator with private ADB server/AVD data. Use it for first-run, synthetic database, Autofill and other affected user journeys. Never test against an existing emulator or physical device: this repository expressly requires an isolated test session. Preserve artifacts outside the clone before cleanup.

The repository normally skips emulator checks for a release-only build; this complete maintenance workflow explicitly requests E2E. Test the exact release candidate with `nix develop --command kp2a e2e --apk <signed-release-apk>` when verifying the distributable. Do not launch an extra emulator for a narrower release-only request. Debug and Release builds share outputs and must run sequentially.

Use the existing local release key, alias `kp2a`, through `kp2a release`. Verify signature, package/version and SHA-256. The inspected output is `src/keepass2android-app/bin/Release/net9.0-android/publish/keepass2android.keepass2android-Signed.apk`; recheck current output before use. Never generate a replacement key. Installing on a personal phone is separate from isolated test execution: follow the current release skill and explicit device choice. Without an established physical-device target, deliver the signed artifact and report phone installation pending. Do not use real vaults or secrets in tests, uninstall an existing package, or claim an emulator install updated the user's phone.
