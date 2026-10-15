{ lib, fetchFromGitHub, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "pi-ask-user";
  version = "0.16.0-unstable-20261004";

  src = fetchFromGitHub {
    owner = "edlsh";
    repo = "pi-ask-user";
    rev = "e8b59a5114bb1cf4fca239b75976483703c9783f";
    hash = "sha256-pZbjq4U0I+t0M2ToRQJLD1KP309DwIH+BzBjGnD52rU=";
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/lib/node_modules/pi-ask-user
    cp -r -- index.ts single-select-layout.ts skills package.json README.md LICENSE $out/lib/node_modules/pi-ask-user/
  '';

  meta = {
    description = "Pi extension that adds an interactive ask_user tool";
    homepage = "https://github.com/edlsh/pi-ask-user";
    license = lib.licenses.mit;
  };
}
