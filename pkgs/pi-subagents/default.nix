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
  version = "0.89.2";

  src = fetchFromGitHub {
    owner = "nicobailon";
    repo = "pi-subagents";
    rev = "v0.89.2";
    hash = "sha256-6XHZ/+KPcx2AcVB2TY9V49Ticw5NbHU4RML7lJ9OsdU=";
  };

  patches = [
    ./task-boundary-wake.patch
    ./host-verification-activity.patch
    ./workflow-reuse-launch-metadata.patch
    ./efficiency-polish.patch
  ];

  npmDepsHash = "sha256-Rx+IzIc1+iv5RoUfc23KmF884D7bd+522qr9I28gu6Q=";
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
    PI_TEST_HOST=${pi-coding-agent}/lib/node_modules/pi-monorepo \
      PI_TEST_PACKAGE=$out/lib/node_modules/pi-subagents \
      node ${./efficiency-polish.test.mjs}
    runHook postInstallCheck
  '';

  meta = {
    description = "Pi extension for single-agent delegation and scripted multi-agent workflows";
    homepage = "https://github.com/nicobailon/pi-subagents";
    license = lib.licenses.mit;
  };
}
