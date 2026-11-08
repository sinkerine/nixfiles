{ lib, fetchFromGitHub, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "pi-hindsight";
  version = "0.1.0-unstable-2026-11-08";

  src = fetchFromGitHub {
    owner = "sinkerine";
    repo = "pi-hindsight";
    rev = "1162ba148506a7ebb6161b94d9edcc7ef9726ee8";
    hash = "sha256-UmMkd3Qwhhk9ONyclLlrTJG3+SQS5tVneBbGHURqYsg=";
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
