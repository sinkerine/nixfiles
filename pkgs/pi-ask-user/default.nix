{ lib, fetchFromGitHub, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "pi-ask-user";
  version = "0.17.1-unstable-20261030";

  src = fetchFromGitHub {
    owner = "edlsh";
    repo = "pi-ask-user";
    rev = "df1df70acf1f7521d24f9518a702064930340df2";
    hash = "sha256-iAnr33DpE0mTjPlzxDZM2zzi6ncbrCHt0O3ahtlkW5o=";
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
