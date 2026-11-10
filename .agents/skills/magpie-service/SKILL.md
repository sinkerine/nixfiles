---
name: magpie-service
description: Inspect and configure the user's running Magpie service at https://magpie.sachi.m.mado.moe. Use for service settings, providers and accounts, usage and quotas, Codex auto-use reset switches, and weekly reset policy.
---

# Magpie service

The user's instance is `https://magpie.sachi.m.mado.moe` (the management UI and `/api` routes). Its OpenAI-compatible inference endpoint is `https://magpie-api.sachi.m.mado.moe/v1`. Send administration requests to the management host.

This skill is maintained in `/nixfiles/.agents/skills/magpie-service/SKILL.md`. It was moved from the Magpie checkout's local skills. It is a repository skill, available while working in nixfiles; it does not require a Nix or Home Manager change.

## Discover the running contract

Start with `GET /api/settings`, validate a JSON object, and read its `version`. The last verified running version was `ea728dcc9416d2f91af0922ed2eb6a152502ca75`, matching `/home/sinkerine/dev/magpie` at verification. Check the live version again for every task; a local checkout can differ from the deployed service. There is no `/api/version` route in the verified version.

Resolve unfamiliar API contracts against the matching Magpie source before writing:

- `internal/gui/api.go`: settings routes, `settingsJSON`, `settingsState`, and derived environment policy fields.
- `internal/settings/`: persisted setting names, optional fields, and defaults.
- `internal/gui/providers.go`: provider/account state and actions.
- `internal/gui/usage.go`: quota reads, refresh, and manual reset routes.
- `internal/provider/codex_autoreset.go`: reset triggers, renewal threshold, and spending semantics.
- `internal/provider/migrate*.go`: built-in subscription retirement and plugin migration.

If the checkout does not match the live version, inspect the source at the deployed revision (for example with `git show <version>:internal/gui/api.go`) rather than assuming HEAD's API. Prefer current handlers and runtime state over historical feature plans.

## Requests and verification

Use Python's standard-library `urllib.request` and `json`, or curl, over verified HTTPS. Give requests a finite timeout (normally 20 seconds; allow longer when the matching handler has a longer server timeout). Do not follow redirects on writes. The verified instance allowed the discovery reads without additional credentials; if authentication is required, use the user's supplied access. Never bypass authentication or store credentials in this skill or logs.

Use the narrow setting-specific endpoint where available. Do not POST a settings object copied from an earlier read: it can overwrite unrelated or concurrent edits. Perform writes sequentially, validate each HTTP status and JSON response, then GET current state again and verify the requested behavior. Do not blindly retry an operation that may already have spent a reset. Report partial progress accurately if a request fails. Show only fields needed for the task; full settings, provider records, and usage can contain private data.

The user's request to change service settings authorizes the matching API writes. Proceed with an already specified reversible setting change. Destructive operations or immediately spending a reset require explicit user authorization; a request to configure automatic resets authorizes those policy switches, not a manual reset spend.

Useful reads in the verified version:

| Route | Response and use |
| --- | --- |
| `GET /api/settings` | Object: version, settings, account identities, and derived environment policy. |
| `GET /api/state` | Object: agents, clients, catalog, profiles, served state, and settings. |
| `GET /api/providers` | Object: `providers`, `plugins`, `gateway`, `presets`, and migration metadata. |
| `GET /api/usage/quotas` | Array of quota cards; do not assume an object wrapper. |

Quota reads may initiate background vendor usage reads. `X-Magpie-Reading: 1` means a read is still in progress and the returned cards may be stale; reread with a bounded number of attempts when freshness matters. Avoid `?asked=...` and `&all=...` unless the task needs their additional Claude usage reads. A targeted refresh is `POST /api/usage/quotas/refresh?provider=<encoded-id>&user=<encoded-identity>`; `provider` is required, `user` is optional, and its handler allows 30 seconds. Allow a client timeout over 30 seconds for that request. Encode query values rather than concatenating raw identities.

For a retired built-in subscription, inspect its provider row's `move.state` and the returned plugin state before diagnosing it as built-in code. A plugin can own sign-in, refresh, models, requests, usage, and errors. Use the actual provider id returned by the service, including remote or plugin ids.

A minimal read that prints no account identities or private settings:

```bash
python3 - <<'PY'
import json
import urllib.request

url = 'https://magpie.sachi.m.mado.moe/api/settings'
with urllib.request.urlopen(url, timeout=20) as response:
    state = json.load(response)
if not isinstance(state, dict):
    raise SystemExit('Expected a settings object')
print(json.dumps({key: state.get(key) for key in (
    'version', 'codexWeekResetMinHours', 'codexWeekResetMinHoursBad'
)}, indent=2))
PY
```

## Codex auto-use resets

`GET /api/settings` returns:

- `codexUsers`: full account identities, including any ` · Team` suffix. Preserve these suffixes; account identities are not just email addresses.
- `codexAutoReset`: lowercased identities with at least one auto-use trigger enabled. Treat an omitted or null list as empty.
- `codexAutoResetOnly`: optional identity-to-trigger map. `week` means weekly only; `expiring` means expiry only; a missing entry for an enabled identity means both. An identity absent from `codexAutoReset` has both off, regardless of a map entry. Treat an omitted or null map as empty; the live response omitted this field at verification.

Change one trigger with `POST /api/settings/codex-auto-reset`, content type `application/json`:

```json
{"User":"<full account identity>","When":"week","On":false}
```

`When: "week"` controls **when its week runs out**. `When: "expiring"` controls **before one expires**. Always include `When` for a single-trigger change: omitting it changes both triggers. Preserve the other trigger unless the user asks to change it. The response is the settings object; verify it and perform a final settings read.

For all accounts, take the union of `codexUsers` and `codexAutoReset`, deduplicating case-insensitively. Compute both triggers before writing. Skip accounts already in the desired state, write each remaining account sequentially, and reread settings. Verify the target trigger and that each account's other trigger equals its original value. If unrelated state changes during the operation, report it rather than overwriting it from a snapshot.

To disable weekly auto-use for all accounts, send the payload above for every identity with its weekly trigger enabled. An account still enabled for expiry must have `codexAutoResetOnly[identity] == "expiring"`; an account with both triggers off must be absent from `codexAutoReset`.

### Weekly renewal threshold

Enabling the weekly switch does not guarantee a reset will be spent. The weekly path requires an exhausted weekly window, an available reset, and no automatic weekly reset already spent for that account's current week. It is used when routing needs a reset, including before falling through to paid credits; it is not a scheduled reset merely because the switch is on.

The serving gateway's `MAGPIE_CODEX_WEEK_RESET_MIN_HOURS` controls how far away natural weekly renewal must be:

- Unset or empty: **24 hours**.
- Whole hours `0` through `168`, with surrounding whitespace accepted: renewal must be at least that many hours away, inclusive.
- `0`: no minimum renewal distance.
- Invalid value: weekly auto-use pauses before the vendor usage read. The independent expiry trigger is unaffected.

The API exposes derived, read-only `codexWeekResetMinHours` and optional `codexWeekResetMinHoursBad`. Check the `Bad` field first: invalid input reports hours as `0`, which must not be mistaken for a valid zero threshold. These fields also appear under `GET /api/state` → `settings`.

Change this threshold in the **serving gateway process's environment**, then restart that process through its actual service configuration. Exporting it in the agent's shell or POSTing it to settings does not change the running policy. If the service is Nix-managed, update its declarative configuration in nixfiles; use the relevant deployment skill if asked to activate it remotely. Do not deploy or restart merely to inspect policy.

### Expiry lead and manual spending

`POST /api/settings/codex-reset-lead` accepts `{"Minutes": <integer>}` and changes the shared lead time for accounts with the expiry trigger enabled. Zero selects the implementation's default. Check `SetCodexResetLead` and current settings for accepted limits and the effective default before changing this value.

`POST /api/usage/codex-reset` **spends** a reset; it is not a policy toggle or a verification read. Its payload has `Provider`, `User`, and `Credit` strings. Only use it when the user explicitly requests spending a reset, resolving the exact credit and account from current quota state and the matching implementation. A nonempty provider other than `codex` delegates to a remote Magpie and can require a longer timeout.

## Maintenance

Keep this skill tracked in nixfiles. The user's global Git ignore excludes `/.agents/skills/`, so a newly moved skill needs `git add -f .agents/skills/magpie-service/SKILL.md`. Do not retain a second editable copy in the Magpie checkout. Reload the agent's skills or start a new session to discover updates. Keep credentials and private service snapshots out of tracked files.
