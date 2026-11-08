{ lib, fetchFromGitHub, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "pi-hindsight";
  version = "0.1.0-unstable-2026-11-08";

  src = fetchFromGitHub {
    owner = "sinkerine";
    repo = "pi-hindsight";
    rev = "2389de76faf26c6441cfd4d7569c54b7aa2d0c5d";
    hash = "sha256-UE6mVqXrEzLppr2P8DPjCJoGxE/PGBsIkKQF6XdxNMs=";
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/node_modules/pi-hindsight-memory
    cp -r -- src package.json README.md $out/lib/node_modules/pi-hindsight-memory/
    runHook postInstall
  '';

  meta = {
    description = "Long-term Hindsight memory extension for Pi";
    homepage = "https://github.com/sinkerine/pi-hindsight";
    platforms = lib.platforms.all;
  };
}
