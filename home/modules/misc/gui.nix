{
  config,
  pkgs,
  lib,
  mylib,
  hostname,
  ...
}:

let
  cfg = config.my.essentials.gui;
  inherit (mylib) applyChromeFlagsToDesktopExec;
in
{
  options.my.essentials.gui = {
    enable = lib.mkEnableOption "linux gui";
    enablePolkitAgent = lib.mkEnableOption "polkit-gnome authentication agent" // {
      default = true;
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        my.programs.hyprland = {
          enable = true;
          inherit (config.my.display) monitors scale;
        };
        my.programs.niri = {
          enable = true;
          musicPlayer = config.my.programs.hyprland.musicPlayer;
        };
      }
      {
        home.sessionVariables = {
          PATH = "${config.home.homeDirectory}/.nix-profile/bin:$PATH";
          QT_AUTO_SCREEN_SCALE_FACTOR = "1";
        };
        xresources.properties = {
          "Xft.rgba" = "rgb";
          "Xft.antialias" = true;
          "Xft.hinting" = true;
          "Xft.lcdfilter" = "lcddefault";
        }
        // (
          if hostname == "asako" then
            {
              "Xft.dpi" = 120;
            }
          else
            {
              "Xft.dpi" = 192;
            }
        );
        my.programs.fontconfig.enableGui = true;
      }

      {
        home.packages = with pkgs; [
          # For tweaking XWayland config.
          xprop
          xrdb

          # Wayland env
          qt6.qtwayland
          # qt5.qtwayland
          # libsForQt5.qt5ct

          # Development
          gnumake
          postgresql
          ccls
          ruby
          rust-analyzer
          keepassxc
          google-chrome
          jellyfin-media-player
          clementine
          nemo
          kdePackages.ark
          unrar
          insomnia
          picard
          kdePackages.kate
          kdePackages.gwenview
          nodejs
          pandoc
          kdePackages.okular
          calibre
          libreoffice
          oxipng
          dex
          krita
          unflac
          wl-clipboard
          libnotify
          grim
          slurp
          xdg-utils
          khinsider
          imagemagick
          cloc
          antimicrox
          unzip
          sqlite
          goldendict-ng
          yt-dlp
          feishin
          ffmpeg
          telegram-desktop
          kdePackages.kdenlive
          darktable
          webos-dev-manager
          wechat
          discord
          prusa-slicer
          repomix
        ];

        my.programs.hyprland.enableGammastep = true;

        qt = {
          enable = true;
          platformTheme = {
            package = with pkgs; [
              kdePackages.plasma-integration
              kdePackages.systemsettings
            ];
          };
          style = {
            package = with pkgs; [ kdePackages.breeze ];
          };
        };
        xdg.configFile."kdeglobals".text = ''
          [DirSelect Dialog]
          DirSelectDialog Size=860,586

          [KFileDialog Settings]
          Allow Expansion=false
          Automatically select filename extension=true
          Breadcrumb Navigation=true
          Decoration position=2
          LocationCombo Completionmode=5
          PathCombo Completionmode=5
          Show Bookmarks=false
          Show Full Path=false
          Show Inline Previews=true
          Show Preview=false
          Show Speedbar=true
          Show hidden files=false
          Sort by=Name
          Sort directories first=true
          Sort hidden files last=false
          Sort reversed=false
          Speedbar Width=144
          View Style=DetailTree

          [KDE]
          SingleClick=false
        '';
        gtk = {
          enable = true;
          theme = {
            package = pkgs.kdePackages.breeze-gtk;
            name = "Breeze";
          };
          iconTheme = {
            package = pkgs.kdePackages.breeze-icons;
            name = "breeze";
          };
          gtk4.theme = config.gtk.theme;
        };
        xdg.userDirs = {
          enable = true;
          createDirectories = true;
          setSessionVariables = true;
        };
        my.services.gpg.enable = true;

        programs.zsh.shellAliases = {
          # Nix Home Manager
          snh = "switch-nix-home.sh";
          snho = "switch-nix-home.sh --option substitute false";
          bnh = "build-nix-home.sh";
          # NixOS
          sno = "switch-nix-os.sh";
          snoo = "switch-nix-os.sh --option substitute false";
          bno = "build-nix-os.sh";
          webos-dev-manager = "NIXPKGS_ALLOW_UNFREE=1 nix run --impure github:nix-community/nixGL -- webos-dev-manager";
        };
        programs.direnv = {
          enable = true;
          nix-direnv.enable = true;
          config.whitelist.prefix = [
            "${config.home.homeDirectory}/tech/repo/"
            "${config.home.homeDirectory}/orca/"
          ];
        };
        my.services.syncthing.enable = true;
        my.programs.networkmanager-dmenu = {
          enable = true;
          settings = {
            dmenu.dmenu_command = "${config.programs.wofi.package}/bin/wofi -dmenu";
          };
        };
        my.services.network-manager-applet.enable = true;
        my.programs.firefox = {
          enable = true;
          searchEngines = [
            {
              name = "GitHub";
              value = {
                urls = [
                  {
                    template = "https://github.com/search?q={searchTerms}&type=repositories";
                  }
                ];
                icon = "https://github.githubassets.com/favicons/favicon.svg";
                updateInterval = 24 * 60 * 60 * 1000; # every day
                definedAliases = [ "@gh" ];
              };
            }
            {
              name = "GitHub Code Search";
              value = {
                urls = [
                  {
                    template = "https://github.com/search?q={searchTerms}&type=code";
                  }
                ];
                icon = "https://github.githubassets.com/favicons/favicon.svg";
                updateInterval = 24 * 60 * 60 * 1000; # every day
                definedAliases = [ "@ghc" ];
              };
            }
            {
              name = "NixOS Packages";
              value = {
                urls = [
                  {
                    template = "https://search.nixos.org/packages?channel=unstable&query={searchTerms}";
                  }
                ];
                icon = "https://search.nixos.org/favicon.png";
                updateInterval = 24 * 60 * 60 * 1000; # every day
                definedAliases = [ "@nixp" ];
              };
            }
            {
              name = "NixOS Options";
              value = {
                urls = [
                  {
                    template = "https://search.nixos.org/options?channel=unstable&query={searchTerms}";
                  }
                ];
                icon = "https://search.nixos.org/favicon.png";
                updateInterval = 24 * 60 * 60 * 1000; # every day
                definedAliases = [ "@nixo" ];
              };
            }
            {
              name = "Nix Home Manager Options";
              value = {
                urls = [
                  {
                    template = "https://home-manager-options.extranix.com/?query={searchTerms}";
                  }
                ];
                icon = "https://home-manager-options.extranix.com/images/favicon.png";
                updateInterval = 24 * 60 * 60 * 1000; # every day
                definedAliases = [ "@nixhm" ];
              };
            }
            {
              name = "DockerHub";
              value = {
                urls = [ { template = "https://hub.docker.com/search?q={searchTerms}"; } ];
                icon = "https://hub.docker.com/favicon.ico";
                updateInterval = 24 * 60 * 60 * 1000; # every day
                definedAliases = [ "@dh" ];
              };
            }
          ];
          searchEnginesOrderPrepend = [ "google" ];
        };

        # Name the entry same as the entry that comes with the package to overwrite it.
        xdg.desktopEntries = {
          google-chrome = {
            name = "Google Chrome";
            exec = applyChromeFlagsToDesktopExec "google-chrome-stable";
          };
          "com.github.iwalton3.jellyfin-media-player" = {
            name = "Jellyfin Media Player";
            exec = "jellyfinmediaplayer --platform=xcb";
          };
          insomnia = {
            icon = "insomnia";
            name = "Insomnia";
            exec = "insomnia --disable-gpu-sandbox";
          };
          feishin = {
            icon = "feishin";
            name = "Feishin";
            exec = "feishin --disable-gpu-sandbox --ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime";
          };
          webos-dev-manager = {
            name = "Dev Manager Desktop";
            exec = "env NIXPKGS_ALLOW_UNFREE=1 nix run --impure github:nix-community/nixGL -- webos-dev-manager";
            terminal = false;
          };
          "io.github.xiaoyifang.goldendict_ng" = {
            name = "GoldenDict-ng";
            exec = "env GOLDENDICT_FORCE_WAYLAND=1 goldendict";
          };
          # Using fcitx instead of wayland for QT_IM_MODULE fixes https://www.github.com/fcitx/fcitx5/issues/1152.
          "org.telegram.desktop" = {
            name = "Telegram Desktop";
            exec = "env QT_IM_MODULE=fcitx QT_IM_MODULES=fcitx Telegram -- %U";
            icon = "telegram";
            terminal = false;
            settings = {
              DBusActivatable = "false";
              StartupWMClass = "TelegramDesktop";
              MimeType = "x-scheme-handler/tg;x-scheme-handler/tonsite";
              SingleMainWindow = "true";
            };
          };
        };

        home.pointerCursor = {
          enable = true;
          name = "breeze_cursors";
          package = pkgs.kdePackages.breeze;
          size = config.my.display.cursorSize;
          x11.enable = true;
          gtk.enable = true;
        };

        my.services.fcitx5 = {
          enable = true;
          enableWaylandEnv = true;
        };
        my.services.vinput.enable = true;
        my.services.playerctld.enable = true;
        my.programs.ergodox.enable = true;
        my.programs.foot.enable = true;
        my.programs.pythonDevTools.enable = true;

        systemd.user.services.polkit-gnome-authentication-agent-1 = lib.mkIf cfg.enablePolkitAgent {
          Unit = {
            Description = "polkit-gnome-authentication-agent-1";
            PartOf = [ "graphical-session.target" ];
          };
          Service = {
            Type = "simple";
            ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
            Restart = "on-failure";
            RestartSec = 1;
            TimeoutStopSec = 10;
          };
          Install = {
            WantedBy = [ "graphical-session.target" ];
          };
        };

        programs.obs-studio = {
          enable = true;
          plugins = with pkgs.obs-studio-plugins; [ wlrobs ];
        };
      }
    ]
  );
}
