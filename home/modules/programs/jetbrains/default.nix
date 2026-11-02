{ config, lib, mylib, pkgs, ... }:

with lib;
let cfg = config.my.programs.jetbrains;
in {
  options.my.programs.jetbrains = {
    enable = mkEnableOption "JetBrains";
    enableAndroidStudio = mkEnableOption "Android Studio";
  };

  config = mkIf cfg.enable (mkMerge [
    { home.file.".ideavimrc".source = ./ideavimrc; }
    (mkIf cfg.enableAndroidStudio {
      home.packages = with pkgs; [ android-studio ];
    })
  ]);
}
