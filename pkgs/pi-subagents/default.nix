{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  python3,
  nodejs,
  pi-coding-agent,
}:

buildNpmPackage {
  pname = "pi-subagents";
  version = "0.84.0";

  src = fetchFromGitHub {
    owner = "nicobailon";
    repo = "pi-subagents";
    rev = "0398b9e8d6f03dc6054dbf13dfe851c7a20bff3a";
    hash = "sha256-yJHclk8TqJX0OGDteZYAbcW9qGDY9a8BSVy0kxcRpEU=";
  };

  patches = [
    ./task-boundary-wake.patch
    ./host-verification-activity.patch
    ./workflow-reuse-launch-metadata.patch
  ];

  npmDepsHash = "sha256-4iHfVe/7y5xTT3tu8hhbrjOMr8OpkvgpCiDdWqMGVoQ=";
  npmFlags = [ "--omit=dev" ];
  dontNpmBuild = true;
  dontStrip = true;

  # Pi supplies typebox at runtime. Keep it as a peer dependency so the
  # package does not ship a second copy that can conflict with Pi's version.
  postInstall = ''
    ${lib.getExe python3} - "$out/lib/node_modules/pi-subagents/package.json" <<'PY'
    import json
    import pathlib
    import sys

    path = pathlib.Path(sys.argv[1])
    package = json.loads(path.read_text())
    package.setdefault("peerDependencies", {})["typebox"] = "*"
    package.get("dependencies", {}).pop("typebox", None)
    path.write_text(json.dumps(package, indent=2) + "\n")
    PY
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ nodejs ];
  installCheckPhase = ''
    runHook preInstallCheck
    PI_TEST_HOST=${pi-coding-agent}/lib/node_modules/pi-monorepo \
      node --input-type=module <<'JS'
    import assert from 'node:assert/strict';
    import { createJiti } from './node_modules/jiti/lib/jiti.mjs';
    const jiti = createJiti(import.meta.url);
    const { resolveHostPeerAliases } = await jiti.import(
      process.env.out + '/lib/node_modules/pi-subagents/src/runs/background/runner-aliases.ts'
    );
    const { aliases, missing } = resolveHostPeerAliases(process.env.PI_TEST_HOST);
    assert.deepEqual(missing, [], 'Background runner must resolve every required host peer');
    for (const target of new Set(Object.values(aliases))) await import(target);
    JS
    PI_TEST_HOST=${pi-coding-agent}/lib/node_modules/pi-monorepo \
      PI_TEST_PACKAGE=$out/lib/node_modules/pi-subagents \
      node ${./task-boundary-wake.test.mjs}
    PI_TEST_HOST=${pi-coding-agent}/lib/node_modules/pi-monorepo \
      PI_TEST_PACKAGE=$out/lib/node_modules/pi-subagents \
      node ${./host-verification-activity.test.mjs}
    runHook postInstallCheck
  '';

  meta = {
    description = "Pi extension for single-agent delegation and scripted multi-agent workflows";
    homepage = "https://github.com/nicobailon/pi-subagents";
    license = lib.licenses.mit;
  };
}
