{
  buildNpmPackage,
  fetchFromGitHub,
  lib,
  jq,
}:

buildNpmPackage {
  pname = "better-paseo";
  version = "1.5.2";

  src = fetchFromGitHub {
    owner = "sinkerine";
    repo = "better-paseo";
    rev = "5d26670c2d15d2c4cd36b5424308c411f94e24e0";
    hash = "sha256-Zk/NfHN2ynesrVLEfZu3J1Ae1Rv/wxKBt8xy1/z7mnQ=";
  };

  npmDepsHash = "sha256-DHIyXm7ntgz/SfKYZ+wvp+DNsiq4YuMUwKS0lL5V5XA=";
  npmFlags = [ "--ignore-scripts" ];
  npmBuildScript = "build:client";
  npmBuildFlags = [
    "--"
    "--install"
    "--force"
  ];
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
    homepage = "https://github.com/sinkerine/better-paseo";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
