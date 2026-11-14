# pi-goal implementation verification

The implementation follows `docs/pi-goal-design.md`: session goal package, consumer migration, and a separate Paseo adapter. The source was initially implemented in-tree and subsequently extracted at the user's request to `~/dev/pi-goal` and `sinkerine/pi-goal`; nixfiles retains the pinned package definition. The user subsequently authorized merging both branches into their repositories' `main` and updating nixfiles. The integration is recorded below; legacy `.pi/goals` and the old package remain untouched.

## Checks

From this nixfiles worktree:

```sh
npm --prefix /home/sinkerine/dev/pi-goal test
python3 -m unittest discover -s home/modules/programs/pi-coding-agent-skills/e2e-feature/tests -p 'test_verify.py'
python3 -m unittest discover -s pkgs/e2e-dispatch -p 'test*.py'
nix build --no-link .#pi-goal .#e2e-dispatch
nixos-rebuild build --flake .#kazuki
```

All pass: 20 extension tests (also run in the Nix checkPhase), 15 verification tests, and 21 dispatch tests. Strict TypeScript checking of the extension and its tests also passes:

```sh
/home/sinkerine/dev/paseo/node_modules/.bin/tsc \
  --noEmit --target es2022 --module nodenext --moduleResolution nodenext \
  --allowImportingTsExtensions --skipLibCheck --strict \
  /home/sinkerine/dev/pi-goal/extensions/index.ts /home/sinkerine/dev/pi-goal/tests/*.test.ts
```

Real Pi lifecycle smoke and producer/adapter compatibility:

```sh
python3 /home/sinkerine/dev/pi-goal/tests/smoke.py --adapter \
  /home/sinkerine/dev/paseo/packages/server/src/server/agent/providers/pi/extensions/pi-goal/index.ts
```

This passes using the installed Pi executable, a temporary Git repository, isolated configuration/session/state directories, and a deterministic local OpenAI-compatible endpoint. It executes `/goal`, observes two automatic goal turns, pauses out of band during streaming, restarts the session while paused, resumes, and pauses again. Actual emitted custom messages map through the real Paseo adapter to active/paused todos, suppress default prompt rendering, and replay the latest paused state. The same smoke also passes with `--extension /nix/store/bmacf78fqp3lvw6ryqlgsafmg8mjnv11-pi-goal-1.0.0/lib/node_modules/pi-goal/extensions/index.ts`, exercising the Nix-installed runtime without development peer symlinks. This is a real Pi RPC smoke, not a GUI screenshot or a remote-model quality evaluation.

In the Paseo adapter worktree (now integrated into `/home/sinkerine/dev/paseo`), the adapter worker ran these commands successfully:

```sh
cd packages/server
npx vitest run src/server/agent/providers/pi/extensions/pi-goal/index.test.ts --bail=1
npx vitest run src/server/agent/providers/pi/extensions/index.test.ts --bail=1
npx vitest run src/server/agent/providers/pi/history-mapper.test.ts --bail=1
npx vitest run src/server/agent/providers/pi/agent.test.ts --bail=1
cd ../..
npm run typecheck --workspace=@getpaseo/server
npm run lint
```

These cover 229 tests (27 adapter, 14 host, 21 history mapper, 167 agent). Formatting and the commit hook's full workspace `npm run typecheck` also pass. The upstream `pi-goal-x` adapter is unchanged.

## Failure and requirement coverage

| Design case | Evidence |
| --- | --- |
| F1: unfocused reminders | Runtime and production-hook tests inject no goal context without a binding; no project pool reads. |
| F2/F3: stop/continue via agent | User-triggered lifecycle tests accept pause/resume/clear, reject continuation-initiated lifecycle control, and pause by another session's goal id. |
| F4: revision conflicts | Two real Node processes perform 120 mutations of one goal; all increments and revisions survive. |
| F5: tab handoff | Adoption transfers ownership; the old owner unbinds, clears its todo/context, notices once, and can create a new goal. In-flight non-user writes to transferred/foreign goals are rejected under the lock. New owner continues; paused adoption stays paused. |
| F6: revived writer | Ownership is read again after the subagent probe, immediately before dispatch. Tests change ownership during that probe. Active runs hold continuation. Codex prompt adds authoritative-writer guidance. |
| F7: repetitive checkpoints | Create/settle tests and real Pi smoke continue without ready declarations. |
| F8: missing indicator | Adapter live/history/replay tests and actual producer snapshots map to the existing todo timeline. |
| Resume and fork | Same-session restore, paused restart, historical fork snapshots, first-user-turn deferral, original unchanged. |
| Waits | Source and complete first-token matching, unrelated messages, direct user steering, persisted state, one-time expiration block. |
| Retry, accounting, budgets | Quota reset plus grace, network backoff ladder, saved retry timers, owning-session usage, completion accounting, single budget steering. |
| Interrupt/no progress | Continuation-only abort pause; three empty continuations block; tools reset the guard. |
| Delegated children | Factory registers no goal tools/commands/hooks in child sessions. |
| Consumers | Initialization creates no goal settings and preserves existing legacy settings. New-store dispatch detection and archival leave legacy records intact. |

## Implementation notes

The package contains 817 lines of non-test TypeScript, including the copied helper modules; the Paseo adapter adds 75 lines.

Bindings include branch snapshots, and later session custom entries update those snapshots. This makes a historical fork use branch-time objective/usage rather than a later version of the original disk record. The semantic three-turn blocked audit follows the ported Codex prompt and tool contract; the tool requires a reason without demanding repeated blocker declarations. The automatic three-empty-continuation guard remains enforced in runtime state. This avoids turning an audited third-turn block into extra checkpoint turns.

The old host-dispatch helper name is retained for RPC compatibility; it now archives matching source goals atomically in the host-local store after source processes stop. It preserves status and does not transfer goal records. Legacy goal files are neither moved nor deleted.

Optional legacy import and child usage roll-up are omitted. Child completion usage is not required for this implementation; owning-session assistant usage is accounted. No required feature was deliberately removed.

The independent review found and rechecked the ownership-transfer fixes and reported no remaining issues. Final regressions also verify budget steering is not delayed by waits/retries and only the process that commits a budget/expiration transition emits its notice.

## Repository integration

The source is maintained in `sinkerine/pi-goal`, with extracted package history and standalone publication commit `a29f25cc42fe4868bb351d19b61da074d273ce10`. Nixfiles fetches that exact revision and hash instead of keeping a second source copy. The extracted checkout passes all 20 unit tests and the real Pi smoke; the fetched package runs the same tests in its Nix check phase.

Paseo `main` includes the adapter at `2e9d69649f39770d3ced777900d6be8bcfba269e`, published to `sinkerine/paseo`. The feature branch was integrated with the existing local main changes before main was advanced. The merged adapter/agent checks pass (194 tests), as do server typecheck, full workspace typecheck, lint and formatting. Both Nix daemon and desktop packages build successfully from the merged input.

The nixfiles feature branch was rebased onto main `bd83ab9fba` and merged into local main. Commit `2f26ae193e` updates only the `paseo` lock node to the published revision; daemon and desktop evaluate to `0.15.3-2e9d696`. The Pi package setting evaluates to `pi-goal`, with no `pi-goal-x` package loaded.

Existing `/nixfiles` changes were preserved as uncommitted work, including both intent-to-add skills and the untracked capability reference. Restoring them required resolving three skill-document overlaps: keep the newer capability, recovery and host-placement guidance, while using session-bound creation, automatic continuation, adoption and pause-preserving host handoffs. No unrelated edits were committed. The combined working tree passes 15 verification tests and 23 dispatch tests, including the existing project denylist regressions; the kazuki configuration build also passes.

Activation remains separate from this repository-integration request. Use the deployment/restart skills to activate standalone Home Manager and restart Paseo when requested, then reload/restart Pi sessions. Building the NixOS configuration alone does not activate standalone Home Manager or update already-running sessions.
