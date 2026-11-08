{ buildNpmPackage, fetchFromGitHub, lib, jq }:

buildNpmPackage {
  pname = "paseo-session-recovery";
  version = "0.6.15-unstable-2026-11-08";

  src = fetchFromGitHub {
    owner = "sinkerine";
    repo = "paseo-session-recovery";
    rev = "06987c00b4a6d30477acefbbcaef3763a57cb6cd";
    hash = "sha256-vtHMWWp+zSWEpT2TC18QzI8C6D5+kkoVNcx1LWb0IQM=";
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
