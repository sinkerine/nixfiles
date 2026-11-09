-- Hyprland native Lua configuration.
-- Generated wrapper adds this file as extraConfig.

local mainMod = "SUPER"
local musicPlayer = @musicPlayer@
local musicPlayerDesktopFileName = @musicPlayerDesktopFileName@
local monitorOne = @monitorOne@
local monitorTwo = @monitorTwo@
local scale = @scale@

-- Startup
hl.on("hyprland.start", function()
  hl.exec_cmd("xprop -root -f _XWAYLAND_GLOBAL_OUTPUT_SCALE 32c -set _XWAYLAND_GLOBAL_OUTPUT_SCALE " .. scale)
  hl.exec_cmd("xrdb -merge ~/.Xresources")
  hl.exec_cmd("hyprctl setcursor breeze_cursors " .. @cursorSize@)
end)

-- Monitors
hl.monitor({
  output = monitorOne,
  mode = "highres",
  position = "0x0",
  scale = scale,
})

if monitorTwo ~= nil then
  hl.monitor({
    output = monitorTwo,
    mode = "highres",
    position = "1920x0",
    scale = scale,
  })
end

local primaryWorkspaces = { 1, 2, 3, 4, 5 }
for _, workspace in ipairs(primaryWorkspaces) do
  hl.workspace_rule({
    workspace = tostring(workspace),
    monitor = monitorOne,
    default = workspace == 1,
  })
end

if monitorTwo ~= nil then
  local secondaryWorkspaces = { 6, 7, 8, 9, 10 }
  for _, workspace in ipairs(secondaryWorkspaces) do
    hl.workspace_rule({
      workspace = tostring(workspace),
      monitor = monitorTwo,
      default = workspace == 6,
    })
  end
end

-- Look and feel
hl.config({
  xwayland = {
    force_zero_scaling = true,
  },

  animations = {
    enabled = true,
  },

  input = {
    sensitivity = 0.5,
    follow_mouse = 2,
    repeat_rate = 20,
    repeat_delay = 200,
    touchpad = {
      natural_scroll = true,
      tap_and_drag = true,
    },
  },

  general = {
    gaps_in = 5,
    gaps_out = 5,
    border_size = 5,
    col = {
      active_border = {
        colors = { "rgba(33ccffee)", "rgba(00ff99ee)" },
        angle = 45,
      },
      inactive_border = "rgba(595959aa)",
    },
    layout = "master",
  },

  cursor = {
    inactive_timeout = 20,
  },

  binds = {
    allow_workspace_cycles = true,
  },

  master = {
    new_status = "slave",
    new_on_top = false,
  },
})

hl.curve("myBezier", {
  type = "bezier",
  points = {
    { 0.05, 0.9 },
    { 0.1, 1.05 },
  },
})

local animations = {
  { leaf = "windows", enabled = true, speed = 1, bezier = "myBezier" },
  { leaf = "windowsOut", enabled = true, speed = 1, bezier = "default", style = "popin 80%" },
  { leaf = "border", enabled = true, speed = 1, bezier = "default" },
  { leaf = "borderangle", enabled = true, speed = 1, bezier = "default" },
  { leaf = "fade", enabled = true, speed = 1, bezier = "default" },
  { leaf = "workspaces", enabled = true, speed = 1, bezier = "default" },
  { leaf = "specialWorkspace", enabled = false },
}

for _, animation in ipairs(animations) do
  hl.animation(animation)
end

-- Frequently used shortcuts
hl.bind(mainMod .. " + Q", hl.dsp.window.close())
hl.bind(mainMod .. " + RETURN", hl.dsp.exec_cmd("foot"))
hl.bind(mainMod .. " + D", hl.dsp.exec_cmd(@appLauncherCommand@))
hl.bind(mainMod .. " + W", hl.dsp.exec_cmd(@windowSwitcherCommand@))
hl.bind(mainMod .. " + I", hl.dsp.exec_cmd("keepassxc"))
hl.bind(mainMod .. " + I", hl.dsp.focus({ window = "^(org.keepassxc.KeePassXC)$" }))
hl.bind(mainMod .. " + C", hl.dsp.exec_cmd(@clipboardCommand@))

-- App launcher
hl.bind(mainMod .. " + O", hl.dsp.submap("open"))
hl.define_submap("open", "reset", function()
  hl.bind("F", hl.dsp.exec_cmd("firefox"))
  hl.bind("C", hl.dsp.exec_cmd('dex "$HOME/.nix-profile/share/applications/google-chrome.desktop"'))
  hl.bind("D", hl.dsp.exec_cmd("nemo"))
  hl.bind("S", hl.dsp.exec_cmd(@screenshotCommand@))
  hl.bind("SHIFT + S", hl.dsp.exec_cmd("screenshot-annotate"))
  hl.bind("M", hl.dsp.exec_cmd('dex "$HOME/.nix-profile/share/applications/' .. musicPlayerDesktopFileName .. '"'))
  hl.bind("N", hl.dsp.exec_cmd(@dismissNotificationsCommand@))
  hl.bind("SHIFT + N", hl.dsp.exec_cmd(@restoreNotificationCommand@))
  hl.bind("W", hl.dsp.exec_cmd(@networkCommand@))
  hl.bind("g", hl.dsp.exec_cmd('dex "$HOME/.nix-profile/share/applications/io.github.xiaoyifang.goldendict_ng.desktop"'))
  hl.bind("g", hl.dsp.focus({ window = "^(GoldenDict)$" }))
  hl.bind("escape", hl.dsp.submap("reset"))
end)

-- System power management
hl.bind(mainMod .. " + SHIFT + Z", hl.dsp.submap("power-management"))
hl.define_submap("power-management", "reset", function()
  hl.bind("L", hl.dsp.exec_cmd(@lockCommand@))
  hl.bind("S", hl.dsp.exec_cmd("systemctl suspend"))
  hl.bind("SHIFT + R", hl.dsp.exec_cmd("reboot"))
  hl.bind("SHIFT + S", hl.dsp.exec_cmd("shutdown -h now"))
  hl.bind("escape", hl.dsp.submap("reset"))
end)

-- Workspaces and layouts
for workspace = 1, 10 do
  local key = tostring(workspace % 10)
  hl.bind(mainMod .. " + " .. key, hl.dsp.focus({ workspace = tostring(workspace) }))
  hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = tostring(workspace) }))
end

hl.bind(mainMod .. " + J", hl.dsp.layout("cyclenext"))
hl.bind(mainMod .. " + K", hl.dsp.layout("cycleprev"))
hl.bind(mainMod .. " + SHIFT + J", hl.dsp.layout("swapnext"))
hl.bind(mainMod .. " + SHIFT + K", hl.dsp.layout("swapprev"))
hl.bind(mainMod .. " + U", hl.dsp.layout("focusmaster"))
hl.bind(mainMod .. " + SHIFT + U", hl.dsp.layout("swapwithmaster master"))
hl.bind(mainMod .. " + N", hl.dsp.focus({ monitor = monitorOne }))
if monitorTwo ~= nil then
  hl.bind(mainMod .. " + M", hl.dsp.focus({ monitor = monitorTwo }))
end
hl.bind(mainMod .. " + SHIFT + Y", hl.dsp.window.move({ workspace = "special:default" }))
hl.bind(mainMod .. " + Y", hl.dsp.workspace.toggle_special("default"))
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special:search" }))
hl.bind(mainMod .. " + S", hl.dsp.workspace.toggle_special("search"))
hl.bind(mainMod .. " + SHIFT + E", hl.dsp.window.move({ workspace = "special:emacs" }))
hl.bind(mainMod .. " + E", hl.dsp.workspace.toggle_special("emacs"))

-- Window dispatchers
hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }))
hl.bind(mainMod .. " + SHIFT + F", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))
hl.bind(mainMod .. " + X", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + P", hl.dsp.window.pin({ action = "toggle" }))

hl.bind(mainMod .. " + SHIFT + mouse_up", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + SHIFT + mouse_down", hl.dsp.focus({ workspace = "e-1" }))
hl.bind(mainMod .. " + H", hl.dsp.focus({ workspace = "r-1" }))
hl.bind(mainMod .. " + L", hl.dsp.focus({ workspace = "r+1" }))
hl.bind(mainMod .. " + SHIFT + H", hl.dsp.window.move({ workspace = "r-1" }))
hl.bind(mainMod .. " + SHIFT + L", hl.dsp.window.move({ workspace = "r+1" }))
hl.bind(mainMod .. " + COMMA", hl.dsp.window.move({ workspace = "empty" }))
hl.bind(mainMod .. " + PERIOD", hl.dsp.window.move({ workspace = "previous" }))

-- Resize submap
hl.bind(mainMod .. " + R", hl.dsp.submap("resize"))
hl.define_submap("resize", "reset", function()
  hl.bind("L", hl.dsp.window.resize({ x = 10, y = 0, relative = true }), { repeating = true })
  hl.bind("SHIFT + L", hl.dsp.window.resize({ x = 20, y = 0, relative = true }), { repeating = true })
  hl.bind("H", hl.dsp.window.resize({ x = -10, y = 0, relative = true }), { repeating = true })
  hl.bind("SHIFT + H", hl.dsp.window.resize({ x = -20, y = 0, relative = true }), { repeating = true })
  hl.bind("K", hl.dsp.window.resize({ x = 0, y = -10, relative = true }), { repeating = true })
  hl.bind("SHIFT + K", hl.dsp.window.resize({ x = 0, y = -20, relative = true }), { repeating = true })
  hl.bind("J", hl.dsp.window.resize({ x = 0, y = 10, relative = true }), { repeating = true })
  hl.bind("SHIFT + J", hl.dsp.window.resize({ x = 0, y = 20, relative = true }), { repeating = true })
  hl.bind("escape", hl.dsp.submap("reset"))
end)

hl.bind(mainMod .. " + ALT + E", hl.dsp.exit())

-- Media
local function playerCommand(action)
  return "playerctl -p " .. musicPlayer .. " " .. action
end

hl.bind("XF86AudioPause", hl.dsp.exec_cmd(playerCommand("play-pause")))
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd(playerCommand("play-pause")))
hl.bind("XF86AudioNext", hl.dsp.exec_cmd(playerCommand("next")))
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd(playerCommand("previous")))
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd(@brightnessUpCommand@), { repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd(@brightnessDownCommand@), { repeating = true })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd(@muteCommand@))
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd(@volumeUpCommand@), { repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd(@volumeDownCommand@), { repeating = true })
hl.bind("XF86Favorites", hl.dsp.exec_cmd(playerCommand("play-pause")))

-- Mouse movement
hl.bind(mainMod .. " + SHIFT + mouse:273", hl.dsp.window.drag(), { mouse = true })
hl.bind(mainMod .. " + SHIFT + mouse:272", hl.dsp.window.resize(), { mouse = true })

-- Window rules
hl.window_rule({
  name = "emacs-opacity",
  match = { class = "emacs" },
  opacity = "0.9 override 0.9 override",
})
hl.window_rule({
  name = "alacritty-opacity",
  match = { class = "Alacritty" },
  opacity = "0.7 override 0.7 override",
})
hl.window_rule({
  name = "foot-opacity",
  match = { class = "foot" },
  opacity = "0.7 override 0.7 override",
})
