{
  autoPatchelfHook,
  at-spi2-atk,
  at-spi2-core,
  cairo,
  copyDesktopItems,
  cups,
  dbus,
  electron_43,
  expat,
  fetchFromGitHub,
  fetchPnpmDeps,
  fontconfig,
  freetype,
  gnumake,
  gdk-pixbuf,
  glib,
  gtk3,
  lib,
  libdrm,
  libgbm,
  libnotify,
  libsecret,
  libx11,
  libxcb,
  libxcomposite,
  libxcursor,
  libxdamage,
  libxext,
  libxfixes,
  libxi,
  libxinerama,
  libxkbcommon,
  libxrandr,
  libxscrnsaver,
  libxshmfence,
  libxtst,
  makeDesktopItem,
  makeWrapper,
  node-gyp,
  nodejs_24,
  nspr,
  nss,
  pango,
  pipewire,
  pnpmConfigHook,
  pnpm_10,
  pnpm_11,
  pkg-config,
  python3,
  stdenv,
  systemd,
  wayland,
}:

let
  electron = electron_43;
  pnpm = pnpm_11;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "orca-ide";
  # Keep this update method: append the date and timestamp through seconds
  # to the upstream version, and pin the matching commit from custom.
  version = "1.4.197-20260927.203631";

  # Always update from the custom branch commit; keep this method honored.
  src = fetchFromGitHub {
    owner = "15cm";
    repo = "orca";
    rev = "bebaef88bb1054e0cce98855226a29b3631eee05";
    hash = "sha256-P42jdlrckLYg8bVGOjj1bid6pkHEgJylCz1Z8j4gLkM=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    fetcherVersion = 4;
    hash = "sha256-bJZ1dmrlfXe7j0Sw+/n7fVusz/dtjejWk2HaU4Cngsw=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    copyDesktopItems
    gnumake
    makeWrapper
    node-gyp
    nodejs_24
    pkg-config
    pnpm
    pnpmConfigHook
    python3
    stdenv.cc
  ];

  buildInputs = [
    at-spi2-atk
    at-spi2-core
    cairo
    cups
    dbus
    electron
    expat
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    libdrm
    libgbm
    libnotify
    libsecret
    libx11
    libxcb
    libxcomposite
    libxcursor
    libxdamage
    libxext
    libxfixes
    libxi
    libxinerama
    libxkbcommon
    libxrandr
    libxscrnsaver
    libxshmfence
    libxtst
    nspr
    nss
    pango
    pipewire
    systemd
    wayland
  ];

  strictDeps = true;

  env.ELECTRON_SKIP_BINARY_DOWNLOAD = "1";

  # Nix supplies Electron and its native runtime. Orca's release hook would
  # otherwise try to download Electron and rebuild native modules online.
  postPatch = ''
    # The Nix Electron runtime is supplied by nixpkgs; avoid the upstream
    # release hook's online Electron download and native rebuild.
    substituteInPlace config/electron-builder.config.cjs \
      --replace-fail \
        "  beforeBuild: electronBuilderNativeRebuild," \
        "beforeBuild: null,"
    # Static musl helper binaries have no dynamic symbol table. Keep the
    # upstream relocated-symbol check for binaries with DT_NEEDED entries.
    substituteInPlace config/scripts/verify-linux-glibc-floor.cjs \
      --replace-fail \
        "const providerViolations = Object.values(RELOCATED_SYMBOL_PROVIDERS).some(" \
        "const providerViolations = neededLibraries.size > 0 && Object.values(RELOCATED_SYMBOL_PROVIDERS).some("
    # Nix's current Electron and compiler target the host nixpkgs glibc, not
    # the upstream Ubuntu 20.04 compatibility floor.
    sed -i \
      '/^[[:space:]]*verifyLinuxGlibcFloor(context.appOutDir, {$/,+2c\\      void context.appOutDir' \
      config/electron-builder.config.cjs
  '';

  buildPhase = ''
    runHook preBuild

    export npm_config_nodedir=${nodejs_24}
    pnpm rebuild node-pty

    pnpm run build:desktop

    cp -r ${electron.dist} electron-dist
    chmod -R u+w electron-dist

    pnpm exec electron-builder \
      --dir \
      --config config/electron-builder.config.cjs \
      -c.electronDist=electron-dist \
      -c.electronVersion=${electron.version} \
      -c.npmRebuild=false

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/opt/orca-ide
    cp -r dist/*-unpacked/resources $out/opt/orca-ide/
    install -Dm444 resources/build/icon.png \
      $out/share/icons/hicolor/1024x1024/apps/orca-ide.png

    runHook postInstall
  '';

  postFixup = ''
    makeWrapper ${lib.getExe electron} $out/bin/orca-ide \
      --inherit-argv0 \
      --set ELECTRON_FORCE_IS_PACKAGED 1 \
      --add-flags --no-sandbox \
      --add-flags $out/opt/orca-ide/resources/app.asar
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "orca-ide";
      desktopName = "Orca";
      comment = "Worktree IDE for AI coding agents";
      exec = "orca-ide %U";
      icon = "orca-ide";
      startupWMClass = "orca";
      categories = [ "Development" ];
    })
  ];

  autoPatchelfIgnoreMissingDeps = [
    "libcuda.so.1"
    "libvulkan.so.1"
  ];

  meta = {
    description = "Worktree IDE for AI coding agents";
    homepage = "https://www.onorca.dev";
    license = lib.licenses.unfree;
    mainProgram = "orca-ide";
    platforms = [ "x86_64-linux" ];
  };
})
