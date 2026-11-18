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
    rev = "08f232906def94b85484104dabba19e1c38fe776";
    hash = "sha256-zyLB5JUeJIPO5tjqrNBLqihSvl48RlUjz1qMqCBQ+48=";
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
