{ lib, fetchFromGitHub, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "pi-goal-x";
  version = "0.32.3";

  src = fetchFromGitHub {
    owner = "tmonk";
    repo = "pi-goal-x";
    rev = "64c5ace87f3400c0b55ef87f2d2912167f53dbaa";
    hash = "sha256-d0IRFiK5JH/VDimVEdJFE/+5i4lDlPLXITvcbCpixt0=";
  };

  # Wait for the soonest magpie quota reset after a provider usage limit.
  patches = [ ./quota-retry.patch ];

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
