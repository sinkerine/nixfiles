{
  lib,
  fetchFromGitHub,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "pi-vim";
  version = "0.14.2";

  src = fetchFromGitHub {
    owner = "lajarre";
    repo = "pi-vim";
    rev = "e55b07c05b648f3bbccf656c2b0c6ec63f1a91d1";
    hash = "sha256-y8qsUKdzAM2yQyNDKWqGBHA139tDDYJlefvT+nVhGKQ=";
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/lib/node_modules/pi-vim
    cp -r -- *.ts package.json README.md LICENSE $out/lib/node_modules/pi-vim/
  '';

  meta = {
    description = "Vim-style modal editing for Pi's TUI editor";
    homepage = "https://github.com/lajarre/pi-vim";
    license = lib.licenses.mit;
  };
}
