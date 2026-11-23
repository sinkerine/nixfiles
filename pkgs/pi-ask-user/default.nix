{ lib, fetchFromGitHub, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "pi-ask-user";
  version = "0.17.2-unstable-2026-11-23";

  src = fetchFromGitHub {
    owner = "sinkerine";
    repo = "pi-ask-user";
    rev = "14055c0e02dcc1fb2f2d059e4d2c790169b622b2";
    hash = "sha256-J72gBMTwZAENL/94tus7V7Y1Utm//3oQ41wQrKbuCtM=";
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/lib/node_modules/pi-ask-user
    cp -r -- *.ts skills package.json README.md LICENSE $out/lib/node_modules/pi-ask-user/
  '';

  meta = {
    description = "Pi extension that adds an interactive ask_user tool";
    homepage = "https://github.com/sinkerine/pi-ask-user";
    license = lib.licenses.mit;
  };
}
