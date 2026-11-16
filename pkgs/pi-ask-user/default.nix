{ lib, fetchFromGitHub, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "pi-ask-user";
  version = "0.17.2";

  src = fetchFromGitHub {
    owner = "edlsh";
    repo = "pi-ask-user";
    rev = "v0.17.2";
    hash = "sha256-0I7CyxRgadLPLZYPnTbe1jzE3ElwpBj0Cs54gAH0K7w=";
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/lib/node_modules/pi-ask-user
    cp -r -- *.ts skills package.json README.md LICENSE $out/lib/node_modules/pi-ask-user/
  '';

  meta = {
    description = "Pi extension that adds an interactive ask_user tool";
    homepage = "https://github.com/edlsh/pi-ask-user";
    license = lib.licenses.mit;
  };
}
