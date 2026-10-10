{
  buildNpmPackage,
  fetchFromGitHub,
}:

buildNpmPackage {
  pname = "pi-web-access";
  version = "0.38.0";

  src = fetchFromGitHub {
    owner = "nicobailon";
    repo = "pi-web-access";
    rev = "7e6e2386dc9a31d5e2a448172060dd1339c604f7";
    hash = "sha256-FLRsw9G1lmr0fkAvJ/lM+gxNbjSF2C3WBaKJx0S65sE=";
  };

  npmDepsHash = "sha256-YxfzwPOjYv+NEwtRtLk8xsKZ2t1bqYRwXPqG94Ld/Ps=";
  npmFlags = [ "--omit=dev" ];
  dontNpmBuild = true;

  meta = {
    description = "Web access extension for Pi coding agent";
    homepage = "https://github.com/nicobailon/pi-web-access";
  };
}
