{
  buildNpmPackage,
  fetchFromGitHub,
}:

buildNpmPackage {
  pname = "pi-web-access";
  version = "0.48.0";

  src = fetchFromGitHub {
    owner = "nicobailon";
    repo = "pi-web-access";
    rev = "v0.48.0";
    hash = "sha256-kvxwqQzvUEvBU8URxTCe4hGbWiUa41TbsdtdiM6+GqE=";
  };

  npmDepsHash = "sha256-kmyoh7lvHssAhSBU2qKqk9ElGgm6Z5BZUtBjy1+hri4=";
  npmFlags = [ "--omit=dev" ];
  dontNpmBuild = true;

  meta = {
    description = "Web access extension for Pi coding agent";
    homepage = "https://github.com/nicobailon/pi-web-access";
  };
}
