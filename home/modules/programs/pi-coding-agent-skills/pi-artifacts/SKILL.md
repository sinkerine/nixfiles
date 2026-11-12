---
name: pi-artifacts
description: Create and publish interactive HTML, React/TSX, and Markdown artifacts with browser previews from Pi. Use for interactive explanations, visualizations, prototypes, dashboards, shareable documents, or updating and restoring existing artifacts.
---

# Pi artifacts

Use the `artifact_publish`, `artifact_list`, and `artifact_get` tools supplied by the Pi artifacts extension. Discover them through tool search when they are not in the current tool list. The service and extension are installed through Nix Home Manager on kazuki. The gallery is https://artifacts.kazuki.m.mado.moe and is reachable through the LAN/Tailscale gateway.

## Create and publish

1. Use the absolute session work directory provided by the extension's artifact guidance, with a subdirectory for each artifact. Keep working files outside the current project unless the user explicitly asks to use project files. If guidance is unavailable, inspect `PI_ARTIFACTS_CONFIG` or the default `~/.config/pi-artifacts/config.json` to identify workDir; use a fresh subdirectory there. Never read or print tokenFile contents.
2. Write complete source files using normal file tools. Choose `html` for plain HTML/CSS/JS, `react` for JSX/TSX, or `markdown` for documents.
3. Call `artifact_publish` with `title`, `kind`, an absolute `entrypoint`, and an explicit `files` array containing the entrypoint and every local import, stylesheet, script and image. All files must be ordinary files under the entrypoint's parent directory. Globs, directory recursion, symlinks and path escapes are rejected.
4. Return the resulting `previewUrl` as a clickable link. Include `revisionUrl` when a fixed, reproducible snapshot is useful. Preview follows the global Latest publication; the revision URL pins saved bytes. In Paseo desktop the user can open the URL in a workspace browser beside the conversation.

Example tool arguments (replace the work path with the current session directory):

```json
{"title":"Interactive chart","kind":"react","entrypoint":"/absolute/session/work/chart/main.tsx","files":["/absolute/session/work/chart/main.tsx"]}
```

React entrypoints must default-export a component. Available packaged imports are `react`, `react-dom`, `lucide-react`, `recharts`, and their public subpaths. Tailwind utilities are available locally. Include local CSS and asset imports in `files`. Use relative asset URLs. Do not install dependencies or depend on a public CDN for these libraries. HTML and Markdown may also include explicitly listed relative assets.

Prefer readable typography, responsive layouts and accessible controls. Use an interactive artifact when interaction helps the explanation; use ordinary text for simple answers. For scientific/publication figures, create a standalone export with appropriate plotting tools.

## Update, browse and restore

Call `artifact_list({})` to find artifacts referenced on the active conversation branch. To publish an update, pass that artifact's `id` to `artifact_publish`, retain its `kind`, and include the complete updated file set. Edits to working files become visible only after successful publication. A failed build preserves the previous preview: fix the reported problem and retry.

Call `artifact_get({"id":"<uuid>"})` to read saved sources for the branch's revision. Add `revision` to inspect another committed revision. Add `restoreTo` to restore exact saved bytes into a new, nonexistent directory; existing directories are rejected. Restore does not publish or advance branch references. Text responses have a total 64 KiB limit; binary originals and full sources are available through the viewer/download links.

`/artifacts` displays the gallery link; `/artifacts <id>` displays a branch-referenced pinned link without another agent turn. New unrelated sessions start with no artifact references. Forks inherit references; global Latest may differ from the revision referenced on this branch.

## Availability and trust

The extension publishes to the configured internal service URL and reads its token privately; viewer URLs never contain tokens. If tools are missing after activation, reload or restart Pi. If publication cannot reach the service, inspect `systemctl --user status pi-artifacts` and `journalctl --user -u pi-artifacts`; do not launch a second writer or change the configured bind address. The default config path is discovered even when an existing Pi/Paseo process has not inherited `PI_ARTIFACTS_CONFIG`.

Published browser content executes without sandboxing. Read endpoints expose saved sources to clients allowed by the gateway. Publish trusted content, exclude credentials and private unrelated files, and keep the service bound to loopback. Do not alter Nix configuration, activate services or expose the backend merely to produce an artifact.
