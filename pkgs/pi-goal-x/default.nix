{ lib, fetchFromGitHub, stdenvNoCC }:

# sinkerine/pi-goal-x carries local changes on main over tmonk/pi-goal-x:
# waiting for the soonest magpie quota reset after a usage limit, keeping
# agents pursuing the goal (pausing stays a user control), and holding goal
# checkpoints while pi-subagents runs are active. See /nixfiles/forked-projects.md.
stdenvNoCC.mkDerivation {
  pname = "pi-goal-x";
  version = "0.34.1-unstable-2026-11-06";

  src = fetchFromGitHub {
    owner = "sinkerine";
    repo = "pi-goal-x";
    rev = "07f41230a46604c78f5b8c0d1d43ee7d37524e76";
    hash = "sha256-66URe+FBfFoAj2316mmlyP10V2waCgziPjHzZPWGxTo=";
  };

  dontConfigure = true;
  dontBuild = true;

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
