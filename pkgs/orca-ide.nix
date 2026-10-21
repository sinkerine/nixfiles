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
  gobject-introspection,
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
  computerUsePython = python3.withPackages (ps: [ ps.pygobject3 ]);
in
stdenv.mkDerivation (finalAttrs: {
  pname = "orca-ide";
  # Keep the upstream version with the update date and time through seconds.
  version = "1.4.214-20261120.000000";

  # Always update from the upstream main branch commit.
  src = fetchFromGitHub {
    owner = "sinkerine";
    repo = "orca";
    rev = "245736431255bf0809c572e8d69aad92d2ea44e3";
    hash = "sha256-stOrwmHK1AGnuuv00sEV5Ja3rollTIyN/WH2r+7m/t8=";
  };

  pnpmDeps = (fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    fetcherVersion = 4;
    hash = "sha256-NKJY6o1w2j+iaUhuiM2x2SprQ+5eKgHEalEV57jrJh0=";
    pnpmInstallFlags = [ "--config.package-import-method=copy" ];
  }).overrideAttrs (old: {
    fixupPhase = lib.replaceStrings
      [ "find $storePath -name \"*.json\"" ]
      [ "find $storePath -path \"$storePath/v11/links\" -prune -o -name \"*.json\" -print
              find \"$storePath/v11/links\" -type f -name esbuild -exec chmod 555 {} +" ]
      old.fixupPhase;
  });

  passthru.mobileDeps = (fetchPnpmDeps {
    pname = "orca-mobile";
    inherit (finalAttrs) version src;
    inherit pnpm;
    sourceRoot = "source/mobile";
    fetcherVersion = 4;
    hash = "sha256-ghOPbJgOg2HvS/wb1s4uBiy8iuZajESljaeq8yh9pfc=";
    pnpmInstallFlags = [ "--config.package-import-method=copy" ];
  }).overrideAttrs (old: {
    fixupPhase = lib.replaceStrings
      [ "find $storePath -name \"*.json\"" ]
      [ "find $storePath -path \"$storePath/v11/links\" -prune -o -name \"*.json\" -print" ]
      old.fixupPhase;
  });

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
    computerUsePython
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
    # GitHub source archives have no .git directory; retain the pinned identity.
    substituteInPlace config/scripts/build-source-commit.mjs \
      --replace-fail \
        "execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()" \
        "'${finalAttrs.src.rev}'"
    # Use the installed TypeScript compiler for the CLI's typecheck as well.
    substituteInPlace config/scripts/build-cli.mjs \
      --replace-fail "selectTypecheckCompiler('bun'," "selectTypecheckCompiler('native',"
    # Nix builds the helper and supplies Node; avoid Docker and runtime downloads.
    # Native binaries target nixpkgs glibc rather than the Ubuntu release floor.
    substituteInPlace config/electron-builder.config.cjs \
      --replace-fail "ensureWaylandClipboard(context.arch)" "void context.arch" \
      --replace-fail \
        "placeAppImageNodeRuntime(resourcesDir, targetArch)" \
        "placeAppImageNodeRuntime(resourcesDir, targetArch, async () => '${nodejs_24}/bin/node')" \
      --replace-fail "verifyLinuxGlibcFloor(context.appOutDir, { targetArch })" "void context.appOutDir" \
      --replace-fail \
        "prunePackagedRuntimeNodeModules(resourcesDir, context.electronPlatformName, context.arch)" \
        "prunePackagedRuntimeNodeModules(resourcesDir, context.electronPlatformName, context.arch); for (const base of ['node_modules', 'app.asar.unpacked/node_modules']) { const dest = join(resourcesDir, base, 'node-pty/build/Release'); require('node:fs').mkdirSync(dest, { recursive: true }); require('node:fs').cpSync(join(__dirname, '../node_modules/node-pty/build/Release'), dest, { recursive: true }); }"
  '';

  buildPhase = ''
    runHook preBuild

    desktopStore="$STORE_PATH"
    desktopDeps="$pnpmDeps"
    pnpmRoot=mobile
    pnpmDeps=${finalAttrs.passthru.mobileDeps}
    pnpmConfigHook
    pnpmRoot=
    pnpmDeps="$desktopDeps"
    export STORE_PATH="$desktopStore"

    # pnpm 11's restored links store can lose executable bits during import.
    # Restore native tools (including esbuild, TypeScript, and Bun) by ELF magic.
    python3 - <<'PY'
    import os
    from pathlib import Path

    for path in Path(os.environ["STORE_PATH"], "v11/links").rglob("*"):
        if path.is_file():
            with path.open("rb") as executable:
                if executable.read(4) == b"\x7fELF":
                    path.chmod(path.stat().st_mode | 0o111)
    PY

    export npm_config_nodedir=${nodejs_24}
    (cd node_modules/node-pty && node-gyp rebuild --nodedir=${nodejs_24})

    pnpm --dir mobile run postinstall
    pnpm run typecheck --compiler=native
    pnpm run build:desktop:assets

    mkdir -p native/wayland-clipboard/.build/x64
    $CC -O2 -Wall -Wextra -Werror -fstack-protector-strong \
      -D_FORTIFY_SOURCE=2 -fPIE -pie -Wl,-z,relro,-z,now \
      native/wayland-clipboard/wayland-clipboard.c \
      native/wayland-clipboard/x11-clipboard-publisher.c \
      -ldl -o native/wayland-clipboard/.build/x64/orca-wayland-clipboard

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
    # Keep Nix's Node runtime and its existing library paths intact.
    ln -sf ${nodejs_24}/bin/node $out/opt/orca-ide/resources/node-runtime/bin/node
    # The glibc host uses the matching watcher; musl variants cannot load here.
    rm -rf $out/opt/orca-ide/resources/app.asar.unpacked/node_modules/@parcel/watcher-linux-*-musl
    mkdir -p $out/bin
    install -Dm444 resources/build/icon.png \
      $out/share/icons/hicolor/1024x1024/apps/orca-ide.png

    runHook postInstall
  '';

  postFixup = ''
    # Run the unpacked CLI with the same Electron/Node ABI as the app.
    # Expose an executable on PATH instead of a symlink to a JavaScript file.
    makeWrapper ${lib.getExe electron} $out/bin/orca-ide-cli \
      --set ELECTRON_RUN_AS_NODE 1 \
      --set ORCA_CLI_COMMAND orca-ide-cli \
      --prefix PATH : ${computerUsePython}/bin \
      --prefix GI_TYPELIB_PATH : ${gobject-introspection}/lib/girepository-1.0:${at-spi2-core}/lib/girepository-1.0 \
      --run 'export ORCA_NODE_OPTIONS="''${NODE_OPTIONS-}"' \
      --run 'export ORCA_NODE_REPL_EXTERNAL_MODULE="''${NODE_REPL_EXTERNAL_MODULE-}"' \
      --unset NODE_OPTIONS \
      --unset NODE_REPL_EXTERNAL_MODULE \
      --add-flags $out/opt/orca-ide/resources/app.asar.unpacked/out/cli/index.js

    makeWrapper ${lib.getExe electron} $out/bin/orca-ide \
      --inherit-argv0 \
      --set ELECTRON_FORCE_IS_PACKAGED 1 \
      --set ORCA_CLI_COMMAND orca-ide-cli \
      --prefix PATH : ${computerUsePython}/bin \
      --prefix GI_TYPELIB_PATH : ${gobject-introspection}/lib/girepository-1.0:${at-spi2-core}/lib/girepository-1.0 \
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
