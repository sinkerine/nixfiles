{ lib, stdenvNoCC, nodejs, pi-coding-agent }:
stdenvNoCC.mkDerivation {
  pname = "pi-goal";
  version = "1.0.0";
  src = ./.;
  dontConfigure = true;
  dontBuild = true;
  doCheck = true;
  nativeCheckInputs = [ nodejs ];
  checkPhase = ''
    runHook preCheck
    mkdir -p node_modules/@earendil-works
    ln -s ${pi-coding-agent}/lib/node_modules/pi-monorepo/node_modules/typebox node_modules/typebox
    ln -s ${pi-coding-agent}/lib/node_modules/pi-monorepo node_modules/@earendil-works/pi-coding-agent
    for peer in pi-ai pi-tui; do
      ln -s ${pi-coding-agent}/lib/node_modules/pi-monorepo/node_modules/@earendil-works/$peer node_modules/@earendil-works/$peer
    done
    node --experimental-strip-types --test tests/*.test.ts
    runHook postCheck
  '';
  installPhase = ''
    mkdir -p $out/lib/node_modules/pi-goal
    cp -r extensions prompts package.json NOTICE LICENSE.* README.md $out/lib/node_modules/pi-goal/
  '';
  meta = {
    description = "Session-bound goals and automatic continuation for Pi";
    license = with lib.licenses; [ mit asl20 ];
  };
}
