{ lib, fetchFromGitHub, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "pi-goal-x";
  version = "0.34.1";

  src = fetchFromGitHub {
    owner = "tmonk";
    repo = "pi-goal-x";
    rev = "27d9facf49e66ee677770a74e26198a8bdcada8a";
    hash = "sha256-W/SY4jqZqy5CWSM7QRkqNne1YKFotJupT/x2roR3+U4=";
  };

  patches = [
    # Wait for the soonest magpie quota reset after a provider usage limit.
    ./quota-retry.patch
    # Keep agents pursuing the goal; pausing remains a user control.
    ./autonomous-progress.patch
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/lib/node_modules/pi-goal-x
    cp -r -- extensions scripts package.json README.md LICENSE $out/lib/node_modules/pi-goal-x/
  '';

  meta = {
    description = "Goal planning and progress tracking extension for Pi";
    homepage = "https://github.com/tmonk/pi-goal-x";
    license = lib.licenses.mit;
  };
}
