{ buildNpmPackage, fetchFromGitHub, lib, jq }:

buildNpmPackage {
  pname = "paseo-session-recovery";
  version = "0.6.13";

  src = fetchFromGitHub {
    owner = "sm1ee";
    repo = "paseo-session-recovery";
    rev = "50f83cd1045b41c516d7fb18f7517a277181be01";
    hash = "sha256-AI658eLECZUf7SxR0hxel78qSGQJzEeqVKVZjNKppx8=";
  };

  npmDepsHash = "sha256-lePI7JNyO+MXHfGuSS7p5+//m9MZGEDUge1cf9D9ZGo=";
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
    homepage = "https://github.com/sm1ee/paseo-session-recovery";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
