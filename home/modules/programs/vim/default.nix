{ config, lib, mylib, pkgs, ... }:

with lib;
let
  cfg = config.my.programs.vim;
  inherit (mylib) templateFile;
  templateData = {
    inherit (config.my.services.clipper) copyCommand;
  };
in {

  options.my.programs.vim = {
    enable = mkEnableOption "Vim";
    viAlias = mkEnableOption "Vi alias";
  };

  config = mkIf cfg.enable (mkMerge [
    {
      programs.vim = {
        enable = true;
        extraConfig = pipe ./vimrc.jinja [
          (templateFile "vimrc" templateData)
          builtins.readFile
        ];
      };

      home.file.".vim/colors/solarized.vim".source = pkgs.fetchurl {
        url =
          "https://raw.githubusercontent.com/altercation/vim-colors-solarized/master/colors/solarized.vim";
        hash = "sha256-i2NgdR9IIGv0sKRN0v65xIr2VvJmLlv2K0fruHwncAQ=";
      };
      home.file.".vim/colors/Tomorrow-Night.vim".source = pkgs.fetchurl {
        url =
          "https://github.com/chriskempson/tomorrow-theme/raw/master/vim/colors/Tomorrow-Night.vim";
        hash = "sha256-Nrn/IoBWCpsoI/bVBVbJeY82VxchrEqV8hYn3c7LIgY=";
      };
    }
    (mkIf cfg.viAlias { programs.zsh.shellAliases = { vi = "vim"; }; })
  ]);
}
