{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  python3,
}:

buildNpmPackage {
  pname = "pi-subagents";
  version = "0.71.0";

  src = fetchFromGitHub {
    owner = "nicobailon";
    repo = "pi-subagents";
    rev = "v0.71.0";
    hash = "sha256-KUnrfinRPiEPPdj0pd06MWnYncQmjiQvGySmGqdvwEg=";
  };

  npmDepsHash = "sha256-IwQZju9R2n0XxcPVVHzQejQ/Gihijy30Pq7cZ4kqN8E=";
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

  meta = {
    description = "Pi extension for single-agent delegation and scripted multi-agent workflows";
    homepage = "https://github.com/nicobailon/pi-subagents";
    license = lib.licenses.mit;
  };
}
