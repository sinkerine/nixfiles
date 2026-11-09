{ lib, fetchFromGitHub, stdenvNoCC, nodejs, jq, bash, pi-coding-agent }:

# sinkerine/pi-goal-x carries local changes on main over tmonk/pi-goal-x:
# waiting for the soonest magpie quota reset after a usage limit, keeping
# agents pursuing the goal (pausing stays a user control), and holding goal
# checkpoints while pi-subagents runs are active. See /nixfiles/forked-projects.md.
stdenvNoCC.mkDerivation {
  pname = "pi-goal-x";
  version = "0.34.1-unstable-2026-11-09";

  src = fetchFromGitHub {
    owner = "sinkerine";
    repo = "pi-goal-x";
    rev = "07f41230a46604c78f5b8c0d1d43ee7d37524e76";
    hash = "sha256-66URe+FBfFoAj2316mmlyP10V2waCgziPjHzZPWGxTo=";
  };

  # Compact tool receipts and durable source-specific Paseo handoff waits.
  patches = [ ./workflow-efficiency.patch ];

  dontConfigure = true;
  dontBuild = true;

  doCheck = true;
  nativeCheckInputs = [ nodejs jq bash ];
  checkPhase = ''
    runHook preCheck
    # The shell harness generates curl fixtures whose interpreter must exist
    # inside the Nix sandbox as well as in an interactive development shell.
    substituteInPlace tests/shell/harness.test.sh \
      --replace-fail '#!/usr/bin/env bash' '#!${bash}/bin/bash'
    mkdir -p node_modules/@earendil-works
    ln -s ${pi-coding-agent}/lib/node_modules/pi-monorepo/node_modules/typebox node_modules/typebox
    ln -s ${pi-coding-agent}/lib/node_modules/pi-monorepo node_modules/@earendil-works/pi-coding-agent
    for peer in pi-ai pi-tui; do
      ln -s ${pi-coding-agent}/lib/node_modules/pi-monorepo/node_modules/@earendil-works/$peer node_modules/@earendil-works/$peer
    done
    node scripts/run-unit-tests.mjs
    runHook postCheck
  '';

  installPhase = ''
    mkdir -p $out/lib/node_modules/pi-goal-x
    cp -r -- extensions scripts package.json README.md LICENSE $out/lib/node_modules/pi-goal-x/
  '';

  meta = {
    description = "Goal planning and progress tracking extension for Pi";
    homepage = "https://github.com/sinkerine/pi-goal-x";
    license = lib.licenses.mit;
  };
}
