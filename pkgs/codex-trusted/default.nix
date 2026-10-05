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

    # Orca launches Codex with an isolated CODEX_HOME. Keep profile names and
    # settings aligned with the canonical profiles managed under ~/.codex.
    orca_profile_runtime_home="''${ORCA_CODEX_HOME:-}"
    orca_profile_source_home="$HOME/.codex"
    if [[ -n "$orca_profile_runtime_home" && -d "$orca_profile_runtime_home" && -w "$orca_profile_runtime_home" && "$orca_profile_runtime_home" != "$orca_profile_source_home" ]]; then
      for orca_profile_source in "$orca_profile_source_home"/*.config.toml; do
        [[ -f "$orca_profile_source" ]] || continue
        cp --remove-destination -- "$orca_profile_source" "$orca_profile_runtime_home/$(basename -- "$orca_profile_source")"
      done
    fi

    exec ${lib.getExe codex} \
      -C "$root" \
      --dangerously-bypass-hook-trust \
      -c "projects.$root.trust_level=\"trusted\"" \
      "$@"
  '';
}
