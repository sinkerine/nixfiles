---
name: nix-deploy-rs
description: Deploy NixOS and Home Manager configurations to remote machines with deploy-rs. Use when asked to deploy, activate, switch, or roll out a Nix flake node or profile to hosts such as sachi, amane, yumiko, or asako, including dirty local worktrees, SSH authentication preflight, profile ordering, and remote activation failures.
---

# Deploy Nix with deploy-rs

Deploy the requested flake node through its declared deploy-rs profiles. Preserve local changes and use the working tree as the deployment source.

## Resolve deployment

1. Find the flake root and inspect its `deploy.nodes` definition.
2. Resolve the requested node exactly. Ask only when no safe target can be inferred.
3. Use an absolute `path:` flake reference so uncommitted files participate:

```text
path:<absolute-flake-root>#<node>
```

Use a profile selector such as `#sachi.system` only when the user requests one profile. Otherwise deploy the full node so its declared `profilesOrder` applies.

## Preflight

1. Run `git status --short`; preserve all existing changes.
2. Confirm the node exists in `deploy.nodes`.
3. Check SSH agent state with `ssh-add -l` and test each declared `sshUser` non-interactively with `ssh -o BatchMode=yes <user>@<host> true` when practical.
4. Stop before deployment if authentication needs a passphrase or password. Never request, read, echo, pipe, or store a secret. Tell the user to unlock/add the key in their own terminal.

## Deploy

Use this command shape:

```bash
deploy -s --auto-rollback false path:/nixfiles#sachi
```

Substitute only flake root and node/profile. Keep these semantics unless the user explicitly overrides them:

- `-s`: skip deploy-rs flake checks; local flakes may expose non-derivation package attributes unrelated to deployment.
- `--auto-rollback false`: do not trigger deploy-rs automatic rollback.
- Full node selector: deploy all declared profiles in configured order.

Run command with enough time to build, copy, and activate every profile. Follow interactive output until success or a concrete error. Do not claim success after build alone.

## Handle failures

- SSH passphrase/password prompt: cancel cleanly and report authentication blocker.
- Unknown node/profile: inspect `deploy.nodes`; do not guess another target.
- Build failure: fix only when request includes fixing configuration; otherwise report failing derivation/error.
- Copy or activation failure: retain exact host, profile, and error. Do not retry with weaker SSH or signature settings without authorization.
- Partial deployment: state which profiles activated and which failed.

After success, report node and activated profiles. Avoid dumping build logs unless needed to explain a failure.
