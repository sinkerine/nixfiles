{ pkgs, config, lib, nixinfo, ... }:

with lib;
let cfg = config.my.programs.fontconfig;
in {
  options.my.programs.fontconfig = {
    enable = mkEnableOption "fontconfig";
    enableGui = mkEnableOption "gui";
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf cfg.enableGui {
      home.packages = with pkgs; [
        font-manager
        sarasa-gothic-nerdfont
        fontconfig
        noto-fonts
        noto-fonts-cjk-sans
        noto-fonts-cjk-serif
        noto-fonts-color-emoji
        emacs-all-the-icons-fonts
        sarasa-gothic
        iosevka
        iosevka-nerdfont
        material-design-icons
        wqy_zenhei
        # Not sure why Font Manager doesn't work well with FontAwesome v6
        font-awesome_5
        nerd-fonts.symbols-only
      ];
      # So that font manager can see the user installed fonts.
      home.file.".local/share/fonts".source = "${config.home.path}/share/fonts";
      fonts.fontconfig.enable = true;
    })
    (mkIf cfg.enableGui {
      xdg.configFile."fontconfig/conf.d/90-my-fonts.conf".source = ./fonts.conf;
    })
  ]);
}
