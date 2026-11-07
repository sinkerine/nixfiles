{ lib, stdenvNoCC, makeWrapper, python3, git, openssh, rsync }:

# Moves running /skill:e2e-feature runs between hosts: `e2e-dispatch out` before kazuki
# suspends, `e2e-dispatch back` after it wakes. See the docstring in e2e-dispatch.py.
#
# TODO: once it is stable, trigger it automatically instead of by hand: hold a logind sleep
# delay inhibitor (raising InhibitDelayMaxSec to about 90 s) that runs `e2e-dispatch out`
# when kazuki suspends, and run `e2e-dispatch back` when it resumes.
stdenvNoCC.mkDerivation {
  pname = "e2e-dispatch";
  version = "0.1.0";

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  nativeBuildInputs = [ makeWrapper ];

  # The away host runs libexec/e2e-dispatch.py streamed over SSH with its own python3.
  installPhase = ''
    install -Dm755 ${./e2e-dispatch.py} $out/libexec/e2e-dispatch.py
    makeWrapper ${python3}/bin/python3 $out/bin/e2e-dispatch \
      --add-flags $out/libexec/e2e-dispatch.py \
      --prefix PATH : ${lib.makeBinPath [ git openssh rsync ]}
  '';

  meta = {
    description = "Move running e2e-feature orchestrations between hosts";
    mainProgram = "e2e-dispatch";
  };
}
