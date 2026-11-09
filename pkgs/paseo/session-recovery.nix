{ buildNpmPackage, fetchFromGitHub, lib, jq }:

buildNpmPackage {
  pname = "paseo-session-recovery";
  version = "0.6.15-unstable-2026-11-09";

  src = fetchFromGitHub {
    owner = "sinkerine";
    repo = "paseo-session-recovery";
    rev = "8e7a824a9b827c2eb5cea300fb1f6cc98141783b";
    hash = "sha256-JHaskYTyGUKeaLw7EqEqPsiXRyegktJrnK9hz7nlpfY=";
  };

  npmDepsHash = "sha256-4AojbgieetypBOf3RfwBbiOOOz7sPnrUkR71iP+oB/U=";
  npmFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;
  nativeBuildInputs = [ jq ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r index.client.tsx index.server.ts client server shared assets node_modules package.json paseo-plugin.json OVERVIEW.md "$out/"
    # Dependencies are supplied by Nix, so Paseo must not run npm on install.
    jq 'del(.build)' paseo-plugin.json > "$out/paseo-plugin.json"
    runHook postInstall
  '';

  meta = {
    description = "Recover interrupted Paseo sessions after daemon restarts";
    homepage = "https://github.com/sinkerine/paseo-session-recovery";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
