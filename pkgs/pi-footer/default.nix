{ lib, fetchFromGitHub, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "pi-footer";
  version = "0.1.5-unstable-20261012";

  src = fetchFromGitHub {
    owner = "smoosex";
    repo = "pi-footer";
    rev = "4462237e7b61fbafd14015990a5d2d7e5f82edae";
    hash = "sha256-8XW2oAaaXxZkZVVE00N2JT7EoeVf+ay/WHkD9zi/urY=";
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/lib/node_modules/@smoose/pi-footer
    cp -r -- *.ts package.json README.md $out/lib/node_modules/@smoose/pi-footer/
  '';

  meta = {
    description = "Customizable footer and status bar extension for Pi coding agent";
    homepage = "https://github.com/smoosex/pi-footer";
    license = lib.licenses.mit;
  };
}
