{
  lib,
  rustPlatform,
  fetchFromGitHub,
  curl,
  bash,
  bashInteractive,
  coreutils,
  procps,
  util-linux,
}:

rustPlatform.buildRustPackage {
  pname = "qex";
  version = "0-unstable-2026-09-20";

  src = fetchFromGitHub {
    owner = "stephenc";
    repo = "qex";
    rev = "afd869eef8ab9085dcaa4376a9f8f8b77397ba16";
    hash = "sha256-WEVj3UGc5SeASsFDrYB6myi+I2wtt1/7bslRRXd/Wvo=";
  };
  cargoHash = "sha256-Xu5WD+JfxAsrqi6fZIGgAvoZiNforwdy4jAX613rT2I=";

  nativeCheckInputs = [
    curl
    bashInteractive
    procps
    util-linux
  ];
  patches = [ ./test-paths.patch ];
  # Upstream's E2E fixtures assume an FHS PATH and absolute /bin programs.
  # Adapt only the fixtures; qex itself still executes the submitted argv.
  postPatch = ''
    substituteInPlace tests/e2e.rs \
      --replace-fail '/bin/bash' '${bash}/bin/bash' \
      --replace-fail '/bin/echo' '${coreutils}/bin/echo' \
      --replace-fail '/usr/bin:/bin' '${
        lib.makeBinPath [
          bashInteractive
          coreutils
          procps
          util-linux
        ]
      }' \
      --replace-fail '#!/usr/bin/env bash' '#!${bash}/bin/bash' \
      --replace-fail '@coreutils@' '${coreutils}'
  '';
  # PID 1 inside Nix's PID namespace belongs to the builder, not another user.
  checkFlags = [ "--skip=sys::tests::a_process_of_another_user_is_never_the_supervisor" ];

  # Nix can provide a PTY, whereas upstream's text assertions expect no colour.
  preCheck = ''
    export NO_COLOR=1
    # Nix starts builders at best-effort I/O priority; the inheritance fixture
    # expects a parent in class none, and qex correctly leaves `io=none` alone.
    ionice -c 0 -p "$$"
    # Temporary-ID warnings test /tmp, while Nix normally puts fixtures in /build.
    export TMPDIR="$(mktemp -d /tmp/qex-check-XXXXXX)"
    export XDG_CONFIG_HOME="$TMPDIR/qex-config"
    export XDG_STATE_HOME="$TMPDIR/qex-state"
    mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
  '';

  meta = {
    description = "Shared local job scheduler with CPU and memory admission control";
    homepage = "https://github.com/stephenc/qex";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
    mainProgram = "qex";
  };
}
