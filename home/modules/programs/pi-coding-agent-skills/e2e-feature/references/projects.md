# Maintained-project verification recipes

Generate a run-local recipe from the current feature checkout. The generator refuses to overwrite an existing recipe, preserves complete check discovery, and does not modify either project's source or install dependencies. Review the resulting inventory against the approved plan and current AGENTS.md. A custom required check still needs to be added explicitly.

## Element Web

From the feature worktree, after entering its existing supported tool/browser environment:

```sh
e2e-feature-run recipe --feature <feature> --project element-web
```

For an approved automated journey against a pinned static build:

```sh
e2e-feature-run recipe --feature <feature> --project element-web \
  --e2e-spec playwright/e2e/<approved-spec>.spec.ts \
  --web-config <run-dir>/isolated-config.json
```

The config must use the approved isolated Matrix test environment. Keep credentials out of recipe commands and generated configs. `--smoke-test` can select an existing test; the default is `apps/web/src/utils/arrays.test.ts`.

The recipe includes:

- A bounded smoke check for the current pinned pnpm version, current root project-discovery pattern, Linux baselines, and a real browser connection. It requires `CI=1` for visual baseline selection (set by the command), `PW_TEST_CONNECT_WS_ENDPOINT`, and the actual `E2E_BROWSER_IMAGE_DIGEST=sha256:...`. Enter the pinned container environment once; the smoke check does not pull images, start unrelated servers, or modify baselines.
- Nx test prerequisites and desktop TypeScript output, with generated directories captured as artifacts. Consumers hash those generated inputs before and after execution.
- An unfiltered Vitest discovery listing and one complete coverage run, including all configured unit, browser and Storybook projects. It does not pass a project exclusion list. If the checkout contains legacy `apps/web/test/**/*-test.*` files, a separate Jest coverage check is added instead of silently dropping them.
- Full lint, i18n generation with a clean-diff check, production app build, nonempty LCOV validation and the repository's configured diff-coverage comparison. Test preparation and generators remain exclusive. Full checks start after the app build is pinned.
- An optional approved Chrome E2E spec served from the copied build on an ephemeral loopback port. The helper owns and tears down that server, and checks the pinned source/artifact identity before and after the journey. It never reuses an arbitrary app server on port 8080.

To allow coverage and the journey to overlap, provide a separate `E2E_PW_TEST_CONNECT_WS_ENDPOINT` and its `E2E_JOURNEY_BROWSER_IMAGE_DIGEST`. Both endpoints must belong to the approved test environment. If the endpoints are shared, the generated recipe assigns the same browser resource and serializes those checks. A host-wide two-slot `host-cpu` resource bounds expensive work across these recipes. Adjust resource assumptions only after measuring the host and proving independent output/state ownership.

Run the full graph with `e2e-verify` and the generated recipe. Omit `phase` to include all checks, including an explicitly selected automated journey; or run full verification and the journey separately with `phase: "full"` and `phase: "e2e"`. Dependencies are included automatically and matching independent receipts are reused. The final result must satisfy both inventories. If no automated journey was selected, the independent journey worker is still required by the feature workflow.

Smoke phase contains only the bounded environment check. The existing-test smoke check is in task phase because it depends on preparation that may take longer than the design-stage 60-second budget. Preparation failures remain setup blockers, never a test exemption.

## Element X Android and Matrix Rust SDK

Use the Android checkout's `nix develop` shell. Supply the exact producer revision and repository from its verified delivery:

```sh
e2e-feature-run recipe --feature <feature> --project element-x-android \
  --sdk-repo <producer-repository> --sdk-sha <full-sha> --abi x86_64
```

Use `arm64-v8a` for the corresponding approved APK/device. Add `--sdk-api <repo-relative-rust-path>:<function>` for any additional API required by the feature. The current preset checks retained Threads Inbox functions and the extra-content send/reply functions used by the maintained client.

The first check validates those functions against the exact Git snapshot, pins the installed AAR's SHA256, checks its native ABI, and uses JDK `javap` to verify retained and new methods in the generated Client/Timeline bindings. Missing APIs fail before an expensive app build. It also requires the current JDK 21 and Android SDK/NDK environment. A replacement AAR requires validating its provenance and regenerating the recipe; do not edit the pinned digest merely to clear a failure.

The full recipe runs existing unit tests and lint through `tools/gradle-local.sh`, then builds the matching Gplay debug APK and pins a copy. It deliberately uses one execution slot and the repository Gradle resource. Android's E2E skill prohibits overlapping Gradle work with emulator testing due to memory peaks; keep this ordering even though the generic runner supports concurrency.

After all build/verification work finishes, give the independent emulator journey worker the pinned APK and manifest. Continue following the project's emulator selection, ABI matching, in-place installation, fixture, evidence and cleanup rules. This recipe does not install an APK, select a device, create accounts, or replace the required user journey.
