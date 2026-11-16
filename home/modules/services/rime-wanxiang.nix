{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my.services.fcitx5.wanxiang;
  source = pkgs.fetchFromGitHub {
    owner = "amzxyz";
    repo = "rime-wanxiang";
    rev = "6ab77371f1ba72154e74645965e53a287ce3cb39";
    hash = "sha256-9IviNV0PxGxtM59AINU0cQv55WBBGlLAvyVMHVU3mg8=";
  };
  model = pkgs.fetchurl {
    url = "https://github.com/amzxyz/rime-wanxiang-data/releases/download/LTS/wanxiang-lts-zh-hans.gram";
    hash = "sha256-dphUyD9skUoFoeGrtnwxwA8a5iKkGHjgWVe83uPb2po=";
  };
  defaults = pkgs.writeText "default.custom.yaml" ''
    patch:
      schema_list:
        - schema: wanxiang
      switcher/hotkeys:
        - Control+grave
      menu/page_size: 6
  '';
  customization = pkgs.writeText "wanxiang.custom.yaml" ''
    patch:
      speller/algebra:
        __patch:
          - wanxiang_algebra:/base/小鹤双拼
      # Handle the existing paging shortcuts before Wanxiang consumes apostrophe
      # as its interactive syllable separator.
      engine/processors/@before 0: key_binder
      key_binder/bindings/+:
        - { when: has_menu, accept: semicolon, send: Page_Up }
        - { when: has_menu, accept: apostrophe, send: Page_Down }
  '';
  data = pkgs.runCommand "rime-wanxiang-xiaohe-6ab7737" { } ''
    mkdir -p "$out"
    cp ${source}/wanxiang*.yaml ${source}/default.yaml "$out/"
    cp -r ${source}/dicts ${source}/lua ${source}/opencc "$out/"
    # Personal phrases and live user databases stay writable and outside Nix.
    cp ${source}/custom_phrase.dict.yaml "$out/"
    cp ${defaults} "$out/default.custom.yaml"
    cp ${customization} "$out/wanxiang.custom.yaml"
    ln -s ${model} "$out/wanxiang-lts-zh-hans.gram"
  '';
in
{
  options.my.services.fcitx5.wanxiang.enable =
    lib.mkEnableOption "Wanxiang Base with Xiaohe Shuangpin";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.my.services.fcitx5.enable;
        message = "Wanxiang requires my.services.fcitx5.enable.";
      }
    ];
    home.file.".local/share/fcitx5/rime" = {
      source = data;
      recursive = true;
    };
  };
}
