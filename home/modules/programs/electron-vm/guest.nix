# Ephemeral microvm for driving Electron apps through CDP and cua-driver.
# The electron-vm CLI fills the job share and boots this guest; nothing
# persists in the guest between runs.
# Each slot gets its own job share and host ports; the guest system itself is
# identical across slots, so they share one store image.
{
  jobDir,
  sshPort,
  vncPort,
}:
{ lib, pkgs, ... }:
let
  display = ":0";
  # Native modules and npm-downloaded Electron binaries are dynamically linked
  # against FHS paths, so expose their libraries through nix-ld.
  electronLibs = with pkgs; [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    libdrm
    libgbm
    libGL
    libnotify
    libsecret
    libuuid
    libxkbcommon
    mesa
    nspr
    nss
    pango
    stdenv.cc.cc.lib
    systemd
    vulkan-loader
    libx11
    libxscrnsaver
    libxcomposite
    libxcursor
    libxdamage
    libxext
    libxfixes
    libxi
    libxrandr
    libxrender
    libxtst
    libxcb
    libxshmfence
    zlib
  ];
  runtimeDir = "/run/user/1000";
  # Environment shared by everything in the tester's desktop session.
  sessionEnv = {
    DISPLAY = display;
    HOME = "/home/tester";
    XDG_RUNTIME_DIR = runtimeDir;
    DBUS_SESSION_BUS_ADDRESS = "unix:path=${runtimeDir}/bus";
    # Services do not read /etc/profile, where nix.nixPath ends up.
    NIX_PATH = "nixpkgs=${pkgs.path}";
    # GTK aborts native file dialogs when no GSettings schemas are found.
    XDG_DATA_DIRS = lib.concatStringsSep ":" [
      "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}"
      "${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}"
      "/run/current-system/sw/share"
    ];
  };
  sessionUnits = [
    "xvnc.service"
    "user@1000.service"
  ];
  # ELECTRON_OVERRIDE_DIST_PATH points here, so every launcher that resolves
  # Electron through the npm package starts it with CDP and the accessibility
  # tree enabled.
  electronDist = pkgs.writeTextFile {
    name = "electron-vm-dist";
    destination = "/electron";
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      resolve() {
        (cd "$1" 2>/dev/null && env -u ELECTRON_OVERRIDE_DIST_PATH \
          ${pkgs.nodejs}/bin/node -p "require('electron')" 2>/dev/null)
      }
      real=$(resolve "$PWD" || resolve "$HOME/app")
      if [ -z "$real" ]; then
        real=$(${pkgs.findutils}/bin/find "$HOME/app" -path '*/node_modules/electron/dist/electron' -type f -print -quit)
      fi
      if [ -z "$real" ]; then
        echo "electron-vm: cannot find the npm Electron binary" >&2
        exit 1
      fi
      exec "$real" --remote-debugging-port=9222 --force-renderer-accessibility "$@"
    '';
  };
  cdpHelper = pkgs.writeShellScriptBin "electron-vm-cdp" ''
    exec ${pkgs.nodejs}/bin/node ${./cdp.mjs} "$@"
  '';
in
{
  networking.hostName = "electron-vm";
  system.stateVersion = "26.05";

  microvm = {
    hypervisor = "qemu";
    vcpu = 4;
    # The root filesystem is a tmpfs holding the app and node_modules.
    mem = 8192;
    interfaces = [
      {
        type = "user";
        id = "electron-vm";
        mac = "02:00:00:e1:ec:01";
      }
    ];
    forwardPorts = [
      {
        host.address = "127.0.0.1";
        host.port = sshPort;
        guest.port = 22;
      }
      {
        host.address = "127.0.0.1";
        host.port = vncPort;
        guest.port = 5900;
      }
    ];
    shares = [
      {
        proto = "9p";
        tag = "job";
        source = jobDir;
        mountPoint = "/job";
      }
    ];
  };

  # A writable tmpfs overlay on the store lets the unprivileged tester add
  # dependencies with `nix shell nixpkgs#...`; it is discarded with the VM.
  microvm.writableStoreOverlay = "/nix/.rw-store";
  fileSystems."/nix/.rw-store" = {
    fsType = "tmpfs";
    options = [
      "mode=0755"
      "size=50%"
    ];
    neededForBoot = true;
  };
  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };
    # Same nixpkgs as the guest, so lookups need no download.
    registry.nixpkgs.to = {
      type = "path";
      path = pkgs.path;
    };
    nixPath = [ "nixpkgs=${pkgs.path}" ];
  };

  users.users.tester = {
    isNormalUser = true;
    # Matches the host user so files written to /job stay owned by them.
    uid = 1000;
    extraGroups = [ "video" ];
    # Starts user@1000 at boot for a session bus shared by the app and cua-driver.
    linger = true;
  };

  # Nothing in the VM runs as root on the tester's behalf.
  security.sudo.enable = false;

  services.openssh = {
    enable = true;
    # electron-vm writes a fresh key for each run into the job share.
    authorizedKeysFiles = [ "/job/authorized_keys" ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      StrictModes = false;
    };
  };

  # AT-SPI exposes the app's accessibility tree to cua-driver.
  services.gnome.at-spi2-core.enable = true;

  programs.nix-ld = {
    enable = true;
    libraries = electronLibs;
  };

  fonts = {
    enableDefaultPackages = true;
    packages = [ pkgs.noto-fonts-cjk-sans ];
  };

  environment.systemPackages = with pkgs; [
    # Icons for GTK file chooser dialogs.
    adwaita-icon-theme
    cdpHelper
    cua-driver
    hicolor-icon-theme
    imagemagick
    jq
    nodejs
    xdotool
  ];

  systemd.services.xvnc = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "tester";
      ExecStart = "${pkgs.tigervnc}/bin/Xvnc ${display} -geometry 1280x800 -depth 24 -SecurityTypes None -AlwaysShared";
    };
  };

  systemd.services.openbox = {
    wantedBy = [ "multi-user.target" ];
    after = sessionUnits;
    requires = sessionUnits;
    environment = sessionEnv;
    serviceConfig = {
      User = "tester";
      ExecStart = "${pkgs.openbox}/bin/openbox";
      Restart = "on-failure";
      RestartSec = 1;
    };
  };

  systemd.services.cua-driver = {
    wantedBy = [ "multi-user.target" ];
    after = sessionUnits ++ [ "openbox.service" ];
    requires = sessionUnits;
    environment = sessionEnv // {
      CUA_DRIVER_RS_TELEMETRY_ENABLED = "0";
    };
    serviceConfig = {
      User = "tester";
      ExecStartPre = "${pkgs.cua-driver}/bin/cua-driver telemetry disable";
      ExecStart = "${pkgs.cua-driver}/bin/cua-driver serve --socket=${runtimeDir}/cua-driver.sock --permission-mode standard --no-overlay";
      Restart = "always";
      RestartSec = 2;
    };
  };

  systemd.services.electron-app = {
    wantedBy = [ "multi-user.target" ];
    after = sessionUnits ++ [
      "openbox.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    requires = sessionUnits;
    path = with pkgs; [
      bash
      coreutils
      gcc
      git
      gnumake
      nodejs
      pkg-config
      pnpm
      python3
      yarn
    ];
    environment = sessionEnv;
    serviceConfig = {
      User = "tester";
      WorkingDirectory = "/home/tester";
    };
    script = ''
      out=/job/out
      # Service PATHs omit system packages such as nix and nix-shell.
      export PATH="$PATH:/run/current-system/sw/bin"
      cp -a /job/src ~/app
      cd ~/app
      rc=0
      bash /job/setup.sh > "$out/setup.log" 2>&1 || rc=$?
      echo "$rc" > "$out/setup-exit"
      if [ "$rc" -ne 0 ]; then
        exit "$rc"
      fi
      rc=0
      # Only the app run goes through the CDP-enabled launcher; setup keeps
      # Electron's own install script untouched.
      # Chromium loads its AT-SPI bridge only when accessibility is requested.
      ELECTRON_OVERRIDE_DIST_PATH=${electronDist} ELECTRON_ENABLE_LOGGING=1 \
        ACCESSIBILITY_ENABLED=1 GTK_MODULES=gail:atk-bridge \
        bash /job/start.sh > "$out/app.log" 2>&1 || rc=$?
      echo "$rc" > "$out/app-exit"
    '';
  };
}
