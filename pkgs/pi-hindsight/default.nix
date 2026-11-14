{ lib, fetchFromGitHub, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "pi-hindsight";
  version = "0.1.0-unstable-2026-11-13";

  src = fetchFromGitHub {
    owner = "sinkerine";
    repo = "pi-hindsight";
    rev = "cb26ab553dfa1536797ecc7901970e03ef16fa1d";
    hash = "sha256-M7jMQEGKX0AZ7yS5cqQGe0GqciBKCNpHjgI1D3/9DgQ=";
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
