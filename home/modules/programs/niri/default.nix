{ config, lib, pkgs, hostname, ... }:

with lib;
let
  cfg = config.my.programs.niri;
  # HM KDL generator emits attr names verbatim. Quote names containing spaces.
  monitorName = monitor: ''"${removePrefix "desc:" monitor.output}"'';
  outputSettings = mapAttrs'
    (name: monitor: nameValuePair "output ${monitorName monitor}" {
      scale = config.my.display.scale;
      "position x=${toString (if name == "one" then 0 else 1920)} y=0" = { };
    }) config.my.display.monitors;
  workspaceSettings =
    if hostname == "kazuki" && config.my.display.monitors ? two then
      (map
        (workspace: {
          workspace = {
            _args = [ (toString workspace) ];
            "open-on-output" = removePrefix "desc:" config.my.display.monitors.one.output;
          };
        })
        (range 1 5))
      ++ (map
        (workspace: {
          workspace = {
            _args = [ (toString workspace) ];
            "open-on-output" = removePrefix "desc:" config.my.display.monitors.two.output;
          };
        })
        (range 6 10))
    else
      map
        (workspace: {
          workspace = {
            _args = [ (toString workspace) ];
          };
        })
        (range 1 10);
  screenshotDir = "${config.home.homeDirectory}/Screenshots";
  noctalia = lib.getExe config.programs.noctalia.package;
  screenshot = command: "mkdir -p ${escapeShellArg screenshotDir}; ${command} ${screenshotDir}/$(date +%Y-%m-%d-%H%M%S.png)";
  delayedScreenshot = pkgs.writeShellScript "niri-delayed-screenshot" ''
    ${pkgs.systemd}/bin/systemd-run --user --collect --on-active=3s --no-block ${pkgs.runtimeShell} -c ${escapeShellArg "${noctalia} msg screenshot-region"}
  '';
  playerCommand = action: [ "playerctl" "-p" cfg.musicPlayer action ];
  focusOrLaunchOrca = pkgs.writeShellScript "focus-or-launch-orca" ''
    set -eu
    window_id="$(${pkgs.jq}/bin/jq -r '.[] | select((."app-id" // "") == "orca" or (."app-id" // "") == "orca-ide") | .id' < <(${pkgs.niri}/bin/niri msg --json windows) | head -n 1)"
    if [ -n "$window_id" ]; then
      exec ${pkgs.niri}/bin/niri msg action focus-window --id "$window_id"
    fi
    exec ${pkgs.orca-ide}/bin/orca-ide open
  '';
  nameDynamicWorkspace = pkgs.writeShellScript "niri-name-dynamic-workspace" ''
    set -eu
    niri=${lib.getExe pkgs.niri}
    jq=${lib.getExe pkgs.jq}

    if "$niri" msg --json workspaces | "$jq" -e 'any(.[]; .is_focused and ((.name // "") == ""))' >/dev/null; then
      "$niri" msg action set-workspace-name "+"
    fi
  '';
in
{
  options.my.programs.niri = {
    enable = mkEnableOption "Niri";
    musicPlayer = mkOption {
      type = types.str;
      default = "Feishin";
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ pkgs.wlr-which-key ];
    home.sessionVariables = {
      XDG_SESSION_TYPE = "wayland";
      QT_QPA_PLATFORM = "wayland;xcb";
    };
    my.env = {
      QT_SCREEN_SCALE_FACTORS = toString config.my.display.scale;
      GDK_SCALE = toString config.my.display.scale;
      GDK_DPI_SCALE = toString (1.0 / config.my.display.scale);
    };

    wayland.windowManager.niri = {
      enable = true;
      package = pkgs.niri;
      systemd.enable = false;
      portalPackage = null;
      settings = {
        prefer-no-csd = true;
        hotkey-overlay.skip-at-startup = true;
        input = {
          keyboard = { repeat-rate = 20; repeat-delay = 200; };
          mouse.accel-profile = "adaptive";
          mouse.accel-speed = 0.6;
          touchpad = {
            accel-profile = "adaptive";
            accel-speed = 0.6;
            tap = { };
            click-method = "clickfinger";
            natural-scroll = { };
          };
        };
        gestures."hot-corners".off = { };
        cursor = {
          xcursor-theme = "breeze_cursors";
          xcursor-size = config.my.display.cursorSize;
          hide-when-typing = true;
          hide-after-inactive-ms = 20000;
        };
        layout = {
          gaps = 5;
          struts = { left = 0; right = 0; top = 0; bottom = 0; };
          border = { width = 5; active-color = "#33ccffee"; inactive-color = "#595959aa"; };
          default-column-width = { proportion = 0.5; };
        };
        _children = workspaceSettings ++ [
          {
            window-rule._children = [
              { match._props = { app-id = "^foot$"; }; }
              { opacity = 0.9; }
            ];
          }
          {
            window-rule._children = [
              { match._props = { app-id = "^orca(-ide)?$"; }; }
              { draw-border-with-background = false; }
              { opacity = 0.9; }
            ];
          }
        ];
        binds = {
          "Mod+O" = { spawn = [ "wlr-which-key" "apps" ]; };
          "Mod+Return" = { spawn = [ "foot" ]; };
          "Mod+D" = { spawn = [ noctalia "msg" "panel-toggle" "launcher" ]; };
          "Mod+C" = { spawn = [ noctalia "msg" "panel-toggle" "clipboard" ]; };
          "Super+Alt+L" = { spawn = [ noctalia "msg" "session" "lock" ]; };
          "Mod+W" = { spawn = [ (toString focusOrLaunchOrca) ]; };
          "Mod+S" = { toggle-overview = {}; };
          "Mod+X" = { toggle-column-tabbed-display = {}; };
          "Mod+R" = { switch-preset-column-width = {}; };
          "Mod+Minus" = { set-column-width = "-10%"; };
          "Mod+Equal" = { set-column-width = "+10%"; };
          "Mod+A" = { center-column = {}; };
          "Mod+Shift+A" = { center-visible-columns = {}; };
          "Mod+Shift+Z" = { spawn = [ "wlr-which-key" "power" ]; };
          "Mod+F" = { maximize-column = {}; };
          "Mod+Shift+F" = { fullscreen-window = {}; };
          "Mod+N" = { focus-monitor-left = {}; };
          "Mod+M" = { focus-monitor-right = {}; };
          "Mod+Shift+N" = { move-window-to-monitor-left = {}; };
          "Mod+Shift+M" = { move-window-to-monitor-right = {}; };
          "Mod+V" = { toggle-window-floating = {}; };
          "Mod+Shift+B" = { switch-focus-between-floating-and-tiling = {}; };
          "Mod+Q" = { close-window = {}; };
          "Mod+H" = { focus-column-left = {}; };
          "Mod+J" = { focus-window-down = {}; };
          "Mod+K" = { focus-window-up = {}; };
          "Mod+L" = { focus-column-right = {}; };
          "Mod+Shift+H" = { move-column-left = {}; };
          "Mod+Shift+J" = { move-window-down = {}; };
          "Mod+Shift+K" = { move-window-up = {}; };
          "Mod+Shift+L" = { move-column-right = {}; };
          "Mod+Left" = { focus-column-left = {}; };
          "Mod+Right" = { focus-column-right = {}; };
          "Mod+Up" = { focus-window-up = {}; };
          "Mod+Down" = { focus-window-down = {}; };
          "Mod+U" = { focus-workspace-down = {}; };
          "Mod+I" = { focus-workspace-up = {}; };
          "Mod+Shift+U" = { move-window-to-workspace-down = {}; };
          "Mod+Shift+I" = { move-window-to-workspace-up = {}; };
          "Mod+Comma" = { consume-window-into-column = {}; };
          "Mod+Period" = { expel-window-from-column = {}; };
          "Mod+Shift+W" = { spawn = [ (toString nameDynamicWorkspace) ]; };
          "Mod+1" = { focus-workspace = "1"; };
          "Mod+2" = { focus-workspace = "2"; };
          "Mod+3" = { focus-workspace = "3"; };
          "Mod+4" = { focus-workspace = "4"; };
          "Mod+5" = { focus-workspace = "5"; };
          "Mod+6" = { focus-workspace = "6"; };
          "Mod+7" = { focus-workspace = "7"; };
          "Mod+8" = { focus-workspace = "8"; };
          "Mod+9" = { focus-workspace = "9"; };
          "Mod+0" = { focus-workspace = "10"; };
          "Mod+Shift+1" = { move-column-to-workspace = "1"; };
          "Mod+Shift+2" = { move-column-to-workspace = "2"; };
          "Mod+Shift+3" = { move-column-to-workspace = "3"; };
          "Mod+Shift+4" = { move-column-to-workspace = "4"; };
          "Mod+Shift+5" = { move-column-to-workspace = "5"; };
          "Mod+Shift+6" = { move-column-to-workspace = "6"; };
          "Mod+Shift+7" = { move-column-to-workspace = "7"; };
          "Mod+Shift+8" = { move-column-to-workspace = "8"; };
          "Mod+Shift+9" = { move-column-to-workspace = "9"; };
          "Mod+Shift+0" = { move-column-to-workspace = "10"; };
          "Mod+Shift+Slash" = { show-hotkey-overlay = {}; };
          "Mod+Escape" = { toggle-keyboard-shortcuts-inhibit = {}; };
          "Mod+Shift+E" = { quit = {}; };
          "Ctrl+Alt+Delete" = { quit = {}; };
          "Print" = { spawn = [ "sh" "-c" (screenshot "grim") ]; };
          "Ctrl+Print" = { spawn = [ "sh" "-c" (screenshot "grim -g \"$(slurp)\"") ]; };
          # Sony headphones send XF86AudioPause and XF86AudioPlay in turn.
          "XF86AudioPause" = { spawn = playerCommand "play-pause"; };
          "XF86AudioPlay" = { spawn = playerCommand "play-pause"; };
          "XF86AudioNext" = { spawn = playerCommand "next"; };
          "XF86AudioPrev" = { spawn = playerCommand "previous"; };
          "XF86Favorites" = { spawn = playerCommand "play-pause"; };
          "XF86MonBrightnessUp" = { spawn = [ "brightnessctl" "set" "5%+" ]; };
          "XF86MonBrightnessDown" = { spawn = [ "brightnessctl" "set" "5%-" ]; };
          "XF86AudioMute" = { spawn = [ "pactl" "set-sink-mute" "0" "toggle" ]; };
          "XF86AudioRaiseVolume" = { spawn = [ "sh" "-c" "pactl set-sink-mute 0 false && pactl set-sink-volume 0 +5%" ]; };
          "XF86AudioLowerVolume" = { spawn = [ "pactl" "set-sink-volume" "0" "-5%" ]; };
        };
      } // outputSettings;
    };

    xdg.configFile."wlr-which-key/apps.yaml".text = ''
      font: sans 16
      background: "#202020ee"
      color: "#eeeeee"
      border: "#33ccffee"
      border_width: 2
      anchor: center
      menu:
        - { key: i, desc: KeePassXC, cmd: keepassxc }
        - { key: f, desc: Firefox, cmd: firefox }
        - { key: c, desc: Chrome, cmd: google-chrome-stable }
        - { key: d, desc: Nemo, cmd: nemo }
        - { key: s, desc: Screenshot, cmd: ${noctalia} msg screenshot-region }
        - { key: S, desc: Screenshot in 3 seconds, cmd: ${toString delayedScreenshot} }
        - { key: m, desc: Music, cmd: dex "$HOME/.nix-profile/share/applications/feishin.desktop" }
        - { key: n, desc: Dismiss notifications, cmd: ${noctalia} msg notification-clear-active }
        - { key: h, desc: Notification history, cmd: ${noctalia} msg panel-toggle control-center notifications }
        - { key: g, desc: GoldenDict, cmd: goldendict }
    '';

    xdg.configFile."wlr-which-key/power.yaml".text = ''
      font: sans 16
      background: "#202020ee"
      color: "#eeeeee"
      border: "#33ccffee"
      border_width: 2
      anchor: center
      menu:
        - { key: l, desc: Lock, cmd: ${noctalia} msg session lock }
        - { key: s, desc: Suspend, cmd: systemctl suspend }
        - { key: q, desc: Quit Niri, cmd: niri msg action quit }
        - { key: r, desc: Reload Niri config, cmd: niri msg action load-config-file }
        - { key: p, desc: Shutdown, cmd: systemctl poweroff }
        - { key: P, desc: Reboot, cmd: systemctl reboot }
    '';
  };
}
