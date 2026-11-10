{ lib, fetchFromGitHub, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "pi-hindsight";
  version = "0.1.0-unstable-2026-11-10";

  src = fetchFromGitHub {
    owner = "sinkerine";
    repo = "pi-hindsight";
    rev = "18b8162e7fc6d7f7d768fd7d64248a1c4e5db684";
    hash = "sha256-VvwOxb+YRU8XBFwKlxH1vtKxHaqh5FqoELsWbf1+Pz4=";
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
