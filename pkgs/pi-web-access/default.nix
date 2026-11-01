{
  buildNpmPackage,
  fetchFromGitHub,
}:

buildNpmPackage {
  pname = "pi-web-access";
  version = "0.46.0";

  src = fetchFromGitHub {
    owner = "nicobailon";
    repo = "pi-web-access";
    rev = "4af1a7f7757d450ba0afefe2d98737384dc9a9b4";
    hash = "sha256-i/C22ovZYwUu3a7gzBeFVaMqvhIB+N/Z63wOCPdhwLs=";
  };

  npmDepsHash = "sha256-g+/xF1ciVUYveV8Czz4eOcKZtu52pWhOYS8+qpgcmJQ=";
  npmFlags = [ "--omit=dev" ];
  dontNpmBuild = true;

  meta = {
    description = "Web access extension for Pi coding agent";
    homepage = "https://github.com/nicobailon/pi-web-access";
  };
}
