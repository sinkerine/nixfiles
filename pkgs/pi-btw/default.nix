{ lib, fetchFromGitHub, stdenvNoCC, pi-coding-agent, python3 }:

stdenvNoCC.mkDerivation {
  pname = "pi-btw";
  version = "0.1.0-unstable-2026-11-12";

  src = fetchFromGitHub {
    owner = "sinkerine";
    repo = "pi-btw";
    rev = "7ea4f106f9b9414a0fdc550efc8165fa33d5ab8f";
    hash = "sha256-H+s5LAGMhexCCIe4Z8L70ST3XqKTKtfSTJ8lqFT0jJg=";
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/node_modules/@sinkerine/pi-btw
    cp -r -- extensions src package.json README.md docs LICENSE CHANGELOG.md \
      $out/lib/node_modules/@sinkerine/pi-btw/
    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ python3 ];
  installCheckPhase = ''
    runHook preInstallCheck
    PI_TEST_BINARY=${pi-coding-agent}/bin/pi \
      PI_TEST_PACKAGE=$out/lib/node_modules/@sinkerine/pi-btw \
      python3 <<'PY'
    import json
    import os
    import pathlib
    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory() as root:
        agent_dir = pathlib.Path(root) / "agent"
        agent_dir.mkdir()
        (agent_dir / "settings.json").write_text(json.dumps({
            "packages": [os.environ["PI_TEST_PACKAGE"]],
        }))
        environment = dict(os.environ, PI_CODING_AGENT_DIR=str(agent_dir))
        result = subprocess.run(
            [os.environ["PI_TEST_BINARY"], "--mode", "rpc", "--no-session"],
            input=json.dumps({"id": "commands", "type": "get_commands"}) + "\n",
            text=True,
            capture_output=True,
            cwd=root,
            env=environment,
            timeout=30,
            check=True,
        )
        responses = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        response = next(item for item in responses if item.get("id") == "commands")
        assert response["success"], response
        names = {command["name"] for command in response["data"]["commands"]}
        expected = {
            "btw", "side", "btw:new", "btw:tangent", "btw:abort", "btw:inject",
            "btw:summarize", "btw:clear", "btw:model", "btw:thinking", "btw:status",
        }
        assert expected <= names, (expected - names, result.stderr)
        print("Pi loaded the packaged BTW extension and registered all 11 commands")
    PY
    runHook postInstallCheck
  '';

  meta = {
    description = "Read-only Pi side conversations with exact finished parent context";
    homepage = "https://github.com/sinkerine/pi-btw";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
