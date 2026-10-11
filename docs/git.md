# Git Workflow For `/nixfiles`

This repo uses Git directly for local history, branching, and GitHub pushes.

## Clone

```bash
git clone git@github.com:sinkerine/nixfiles.git /nixfiles
cd /nixfiles
```

For fresh machines that do not have Git yet, install Nix first and then run:

```bash
nix shell nixpkgs#git -c git clone git@github.com:sinkerine/nixfiles.git /nixfiles
```

## Standard Daily Flow

Start from the current trunk:

```bash
git switch main
git pull --rebase origin main
```

Check what changed:

```bash
git status
git log --oneline --graph --decorate -20
git diff
```

Record work on a topic branch:

```bash
git switch -c my-topic
git add -A
git commit -m "module: short summary"
```

Update an existing branch after more changes:

```bash
git add -A
git commit -m "module: follow-up"
git push origin my-topic
```

## Updating From Remote

Rebase current work onto trunk:

```bash
git fetch origin
git rebase origin/main
```

Inspect someone else's published work:

```bash
git fetch origin their-branch
git switch --track origin/their-branch
```

## Remote Conventions

- GitHub remains the canonical remote.
- `origin` remains the default remote.
- `main` remains the trunk branch.
- Use topic branches for review and pull requests.
