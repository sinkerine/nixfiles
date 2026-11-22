{
  lib,
  fetchFromGitHub,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "pi-per-model-system-prompt";
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "sinkerine";
    repo = "pi-per-model-system-prompt";
    rev = "5387f11609fcd9f820cb49d6ffddb8880d8380c5";
    hash = "sha256-bZqXZwpBu9lZAp9+9jM5f6hQMxRNnLq8I+s8RRzqM3Q=";
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/node_modules/@sinkerine/pi-per-model-system-prompt"
    cp -r -- extensions src package.json README.md LICENSE \
      "$out/lib/node_modules/@sinkerine/pi-per-model-system-prompt/"
    runHook postInstall
  '';

  meta = {
    description = "Per-model system prompt injection for Pi coding agent";
    homepage = "https://github.com/sinkerine/pi-per-model-system-prompt";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
