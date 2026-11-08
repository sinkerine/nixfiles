{ buildNpmPackage, fetchFromGitHub, lib, jq }:

buildNpmPackage {
  pname = "better-paseo";
  version = "1.5.1";

  src = fetchFromGitHub {
    owner = "roundreddot";
    repo = "better-paseo";
    rev = "36a6bb52a17802a6576d9b61b79fb1819c50e020";
    hash = "sha256-yc0c+ZwWWHdCMj+1zZhBC4T8+lO+bZW/7pIvPjrDXDw=";
  };

  npmDepsHash = "sha256-JhfDpwIAEBDnaVlJieM7zOY4BfzOnu/kxK5M1hHA8dc=";
  npmFlags = [ "--ignore-scripts" ];
  npmBuildScript = "build:client";
  npmBuildFlags = [ "--" "--install" "--force" ];
  nativeBuildInputs = [ jq ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r index.client.ts index.server.ts client server shared assets node_modules package.json OVERVIEW.md "$out/"
    # Nix supplies dependencies and the client bundle; no runtime preparation is needed.
    jq 'del(.build)' paseo-plugin.json > "$out/paseo-plugin.json"
    runHook postInstall
  '';

  meta = {
    description = "Task board and enhanced chat timeline for Paseo";
    homepage = "https://github.com/roundreddot/better-paseo";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
