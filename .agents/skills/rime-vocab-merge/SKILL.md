---
name: rime-vocab-merge
description: Manually merge learned Wanxiang Rime vocabulary between kazuki's Fcitx5 and the connected Android Fcitx5 Rime plugin over ADB, preserving native learning history and separate device identities. Use when explicitly asked to merge or sync Rime vocabulary between desktop and phone.
disable-model-invocation: true
---

# Merge Rime vocabulary between kazuki and Android

Perform a one-time, bidirectional vocabulary merge. Invocation authorizes the backups, temporary input-method stops, native database merges, installation on both devices, verification, and restart described below. Proceed without a second confirmation once the targets are unambiguous. Do not configure scheduled synchronization, upgrade schemas, or migrate between input schemes as part of this skill.

## Known setup

| Item | Desktop | Android |
| --- | --- | --- |
| Host/device | kazuki | Connected phone; discover with `adb devices -l` |
| Fcitx application | `fcitx5-daemon.service`, user service | `org.fcitx.fcitx5.android` |
| Rime plugin | fcitx5-rime | `org.fcitx.fcitx5.android.plugin.rime` |
| Rime user directory | `~/.local/share/fcitx5/rime` | `/sdcard/Android/data/org.fcitx.fcitx5.android/files/data/rime` |
| Expected installation ID | `kazuki` | `makina` |
| User dictionary | `wanxiang` | `wanxiang` |
| Input scheme | Wanxiang Base / Xiaohe | Wanxiang Base / Xiaohe |
| Android IME | — | `org.fcitx.fcitx5.android/.input.FcitxInputMethodService` |

Treat these as defaults to verify, not permission to overwrite a different installation. Both devices were already migrated to compatible Wanxiang codes. No Ice-to-Wanxiang conversion is needed for ordinary merges.

## Non-negotiable data rules

- Never read, copy, replace, or run standalone database tools against an open LevelDB database. Stop its owning Fcitx process first, and check that it stopped. A stale `LOCK` file can remain; process exit matters. Never delete a lock to bypass a running owner.
- Keep installation IDs distinct. Never copy desktop `installation.yaml` to Android or rename one device to match the other.
- **Do not change a copied database's identity by running `rime_dict_manager --backup` under a different `installation_id`.** librime may recreate metadata and reset the global `/tick` while leaving entry timestamps unchanged. Instead, restore a native snapshot into a fresh empty database under the destination's own `installation.yaml`.
- Merge with native Rime tools. Do not concatenate snapshots, add usage counts, rename a database, or replace native learning metadata with hand-built values.
- Keep vocabulary, raw databases, exports, logs containing words, and device screenshots outside the repository and Nix store. Use a private run directory, mode `0700`, under `~/.local/state/rime-migration/`.
- Preserve all unrelated settings, schema files, custom phrases, other dictionaries, and repository changes. Handle `wanxiang` only unless additional dictionaries are explicitly requested.

## 1. Preflight and tools

1. Check `hostname`, `git status --short`, and the desktop service state. Run this workflow on kazuki. If elsewhere, use an already authorized connection to kazuki or report the blocker.
2. Resolve tools through Nix. Use installed commands when available. Otherwise obtain `android-tools` and `librime`, preferably from this repository's pinned nixpkgs input. Discover their store paths with `nix build --no-link --print-out-paths`; do not reuse store paths from a past run or install through another package manager. `librime` provides `bin/rime_dict_manager`.
3. Run `adb devices -l`. Choose the sole authorized phone; when several devices match and the user supplied no target, ask which one. Use `adb -s <serial>` for every subsequent command. If offline/unauthorized, report that the user must connect/unlock/authorize the phone; do not weaken ADB security.
4. Verify the Fcitx and Rime plugin packages are installed, and the Android Rime directory is accessible. ADB external-storage access worked without root on this phone. If access is denied, report the actual restriction rather than assuming root or `run-as` is available.
5. Read both `installation.yaml` files, active schemas, and translator dictionary names. Confirm both still use compatible Wanxiang Base pronunciation codes and the intended `wanxiang` database. Stop on changed identity, missing database, or incompatible encoding; do not silently convert an Ice or Pro database.
6. Record the desktop service's original active/inactive state and Android's current default IME (`adb shell settings get secure default_input_method`). Resolve Fcitx's launch activity using `cmd package resolve-activity --brief org.fcitx.fcitx5.android`; do not hardcode a version-specific activity.
7. Create a unique private run directory. Persist a short phase/status file, target identity, tool paths, original service/IME state, and backup locations there. After interruption, inspect it and actual device state before repeating any writes.

## 2. Stop and snapshot

Explain briefly that Fcitx will pause while the databases are merged.

1. Stop the desktop user service with `systemctl --user stop fcitx5-daemon` if it was running. Verify it is inactive.
2. Stop Android Fcitx with `adb shell am force-stop org.fcitx.fcitx5.android`. Verify its process exited before pulling data. Android may switch to a fallback keyboard automatically. If the IME keeps restarting the app, select an existing fallback IME temporarily and record it; do not disable or uninstall keyboards.
3. Copy the desktop Rime directory to this run's backup, preserving symlinks. Pull the Android Rime directory and Fcitx external `files/config` directory into separate backups. Verify each operation succeeded. Do not overwrite backups from this or earlier runs.
4. Keep Fcitx stopped on both devices through installation. If it restarts or the user resumes typing with it, take new consistent snapshots before deriving a new merge. Do not install a stale merge over newer learning.
5. On each **backup copy**, run native Backup from that directory's working directory, with its own unchanged `installation.yaml`:

```text
<rime_dict_manager> --backup wanxiang
```

The output is normally `sync/<installation_id>/wanxiang.userdb.txt`. Honor a configured `sync_dir`; in scratch copies, isolate it to a private run-local directory so tools cannot touch the live sync directory. Change only `sync_dir`, not identity. Reject unexpected or shared output locations.

## 3. Native merge and prepare destination databases

All standalone tool operations below run in scratch directories, never a running installation.

1. Parse both fresh snapshots. Retain headers and entry keys `(pronunciation code, text)`. Check the expected `db_name`, `db_type`, source `user_id`, global `/tick`, and entry `c`, `d`, and `t`. Reject malformed records, duplicate keys, non-finite decay values, missing metadata, or entry ticks exceeding the global tick. Save source counts and metadata privately; print counts rather than personal words.
2. Create an empty merge workspace containing kazuki's `installation.yaml`, with an isolated scratch sync directory. Restore the desktop snapshot, then the Android snapshot:

```text
<rime_dict_manager> --restore <absolute-desktop-snapshot>
<rime_dict_manager> --restore <absolute-android-snapshot>
<rime_dict_manager> --backup wanxiang
```

`--restore` performs a native merge. For shared keys, native Rime selects the commit count with the largest absolute magnitude, retains the existing sign on a magnitude tie, adjusts decay according to the source clocks, and advances the merged clock. Counts are not summed.

3. Assert the merged keys equal the exact union of source keys, and the magnitude of each commit count equals the maximum magnitude from its sources. Verify that the global tick is the maximum source tick. Native reconciliation may change per-entry `d` and `t`; do not demand that every original timestamp remain byte-identical.
4. Normalize the merged snapshot through native Restore into another **empty** workspace under kazuki's identity, then Backup. This reconciles entries to the merged clock using Rime's own logic. Use this exported snapshot as the canonical merge for both destinations, and repeat the key-union, commit-count, and global-tick checks.
5. Prepare two fresh destination workspaces. Each gets its own original `installation.yaml` and an isolated scratch sync directory. Restore the canonical snapshot into each empty workspace, then Backup. Do not seed either destination by copying a database belonging to the other identity.
6. Compare both prepared native exports against the canonical export: all entry keys and `c/d/t` metadata must match, the global ticks must match, and each export's `user_id` must match its destination. Abort installation on any discrepancy. Never repair a clock mismatch by editing the tick header.

## 4. Install while stopped

1. Recheck that both Fcitx owners are stopped. Confirm both original database backups are intact.
2. Upload only the prepared Android `wanxiang.userdb` into a temporary sibling directory. A closed, prepared database is being transported; this is not synchronization of a live database. Check that the upload is complete before any rename.
3. Rename Android's existing `wanxiang.userdb` to a unique rollback name **without a `.userdb` suffix**, then rename the uploaded directory to `wanxiang.userdb`. Use dependent commands with checked exit statuses; never continue past a failed rename. Preserve the phone's `installation.yaml`, `user.yaml`, schemas, model, and configuration.
4. Install the prepared desktop database using the same staged-directory and rename approach. Retain its original database under the private run directory. Do not delete either original before verification completes.
5. Place the two validated per-device native snapshots in both actual Rime sync directories, under `kazuki/` and `makina/` (or their verified IDs). Respect configured `sync_dir` values. Replace individual snapshot files atomically where supported; preserve other sync data.
6. Record which destinations were replaced. If only one installation succeeds, restore that installation's pre-run database before restarting, or explicitly report the partial state if rollback fails. Do not restart both and claim success after a partial install.

## 5. Restart and verify the actual installations

Use cleanup/finally handling: an error must not silently leave the desktop service stopped or Android on an unintended fallback keyboard.

1. Start the desktop service if it was originally active. Launch Android Fcitx with its resolved activity and restore the recorded default IME using `adb shell ime set <recorded-ime>`. If Fcitx was the default, explicitly reselect `org.fcitx.fcitx5.android/.input.FcitxInputMethodService`; launching the app alone does not undo Android's fallback.
2. Check both processes, the selected Android IME, and startup logs for database, Lua, or model errors. Vocabulary merging should not require deploying schemas or replacing the grammar model.
3. Perform a small Xiaohe smoke check if a safe local field is available: `vsgo` should offer 中国. Clear the composition without committing or submitting it. Avoid messaging apps, browser searches, and unrelated private screen contents. Do not print an entire device UI dump when a filtered check suffices.
4. After startup, briefly stop each owner again, snapshot its **installed** database and installation config, then restart/restore its IME immediately in a finally block. Run native Backup on these verification copies under their own identities. Compare their exports to the canonical merge, including the **global `/tick`**, not merely per-entry timestamps. Update shared native snapshots if needed.
5. If new real typing occurred, preserve it and derive a fresh native merge rather than overwriting it to satisfy an equality check. A count difference alone does not justify resetting data. Inspect timestamps and counts to distinguish new learning from corruption.
6. Write a private report with source/union counts, identity checks, global ticks, verification results, replaced paths, and exact rollback steps. Explain any partial failure. Do not put word lists in the final response or commit vocabulary artifacts.

## Completion

Report the merged entry count, whether both devices were verified, the backup/report path, and any unresolved limitation. State that this invocation performed a one-time merge; it did not enable automatic synchronization. Do not commit repository changes unless separately requested.

On failure, preserve every source and prepared artifact, restore the original databases where installation had begun, restore the prior service/IME states, and report the failed phase plus any rollback failure. Never treat an upload, staged merge, or app launch as proof of completed synchronization.
