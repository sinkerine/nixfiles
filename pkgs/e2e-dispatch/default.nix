{ lib, stdenvNoCC, makeWrapper, python3, git, openssh, rsync }:

# Moves all active Paseo agent tabs and workspace files between hosts.
# The legacy e2e-dispatch name remains available for registered e2e workflows.
stdenvNoCC.mkDerivation {
  pname = "workspace-dispatch";
  version = "0.2.0";
  src = lib.cleanSource ./.;

  dontConfigure = true;
  dontBuild = true;
  nativeBuildInputs = [ makeWrapper python3 git rsync ];
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    python3 -m unittest discover -v
    runHook postCheck
  '';

  # Both hosts execute this same source, streamed over SSH with remote python3.
  installPhase = ''
    runHook preInstall
    install -Dm755 e2e-dispatch.py $out/libexec/workspace-dispatch.py
    makeWrapper ${python3}/bin/python3 $out/bin/workspace-dispatch \
      --add-flags $out/libexec/workspace-dispatch.py \
      --prefix PATH : ${lib.makeBinPath [ git openssh rsync ]}
    ln -s workspace-dispatch $out/bin/e2e-dispatch
    runHook postInstall
  '';

  meta = {
    description = "Move active Paseo workspace agent tabs between hosts";
    mainProgram = "workspace-dispatch";
  };
}
