{ pkgs, fetchzip }:

let
  pname = "sarasa-gothic-nerdfont";
  version = "1.0.43-0";
in pkgs.stdenv.mkDerivation {
  inherit pname version;
  srcs = [
    (fetchzip {
      url =
        "https://github.com/jonz94/Sarasa-Gothic-Nerd-Fonts/releases/download/v${version}/sarasa-mono-sc-nerd-font.zip";
      stripRoot = false;
      hash = "sha256-Ay9ay2bJ6DEFfDEJKB2wkUOntK++jiXQ+mwSRYx0Tko=";
    })
    (fetchzip {
      url =
        "https://github.com/jonz94/Sarasa-Gothic-Nerd-Fonts/releases/download/v${version}/sarasa-term-sc-nerd-font.zip";
      stripRoot = false;
      hash = "sha256-8a0vxk8PMcqZCTsEmo+33caZM5hiySBRPiw5sSy8olk=";
    })
  ];
  sourceRoot = ".";

  phases = [ "installPhase" ];
  installPhase = ''
    find $srcs -name '*.ttf' | xargs install -m644 --target $out/share/fonts/truetype/sarasa-gothic-nerfont -D
  '';
}
