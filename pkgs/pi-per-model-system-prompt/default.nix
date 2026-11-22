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
    rev = "14e997a740e96ec33f0620ac9957c46461c98300";
    hash = "sha256-XkKtFqX+QlBHzH70bCdrEZ3mN25exnz6K+Dd27thusg=";
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
