{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  python3,
}:

buildNpmPackage {
  pname = "pi-ast-grep";
  version = "0.1.1-unstable-20260924";

  src = fetchFromGitHub {
    owner = "code-yeongyu";
    repo = "pi-ast-grep";
    rev = "ddd87a7ab524dc16af5da9abc44011be82493ed6";
    hash = "sha256-N/5nGduQc65x50JcUjbjrgBEx+/lOOkMnQFcVFvaTlA=";
  };

  npmDepsHash = "sha256-joDeeKVvYjJBh0LgoA6XFzYQTZSJqgUUHt3ahaWkHbg=";
  npmFlags = [ "--omit=dev" ];
  dontNpmBuild = true;

  postPatch = ''
    ${lib.getExe python3} -c 'import json; from pathlib import Path; p=Path("package-lock.json"); l=json.loads(p.read_text()); l["packages"]={k:v for k,v in l["packages"].items() if not k or "integrity" in v}; p.write_text(json.dumps(l, indent=2)+chr(10))'
  '';

  meta = {
    description = "AST-aware code search and rewrite extension for pi";
    homepage = "https://github.com/code-yeongyu/pi-ast-grep";
    license = lib.licenses.mit;
  };
}
