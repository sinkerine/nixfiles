{
  coreutils,
  git,
  lib,
  codex,
  writeShellApplication,
}:

writeShellApplication {
  name = "codex-trusted";
  runtimeInputs = [
    coreutils
    git
  ];

  text = ''
    if git rev-parse --show-toplevel >/dev/null 2>&1; then
      root="$(git rev-parse --show-toplevel)"
    else
      root="$PWD"
    fi

    # Orca's headless Sachi runtime uses Xvfb on :99. Keep normal desktop
    # Codex launches on their native clipboard, but let headless Orca sessions
    # fall back to OSC 52 instead of writing into Xvfb's private clipboard.
    if [[ -n "''${ORCA_CODEX_HOME:-}" && "''${DISPLAY:-}" == ":99" ]]; then
      unset DISPLAY WAYLAND_DISPLAY
    fi

    exec ${lib.getExe codex} \
      -C "$root" \
      --dangerously-bypass-hook-trust \
      -c "projects.$root.trust_level=\"trusted\"" \
      "$@"
  '';
}
