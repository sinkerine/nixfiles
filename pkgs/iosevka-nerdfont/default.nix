{ pkgs, fetchzip }:

let
  pname = "iosevka-nerdfont";
  version = "3.5.1";
in pkgs.stdenv.mkDerivation {
  inherit pname version;
  srcs = [
    (fetchzip {
      url =
        "https://github.com/ryanoasis/nerd-fonts/releases/download/v${version}/Iosevka.zip";
      stripRoot = false;
      hash = "sha256-o+gu/ILu+gOza2zCtDWL+TS4ayPGO18tMkm8kjfUNcI=";
    })
  ];
  sourceRoot = ".";

  phases = [ "installPhase" ];
  installPhase = ''
    find $srcs -name '*.ttf' | xargs install -m644 --target $out/share/fonts/truetype/iosevka-nerfont -D
  '';
}
