{ appimageTools, fetchurl }:
let
  pname = "webos-dev-manager";
  version = "1.99.21";

  src = fetchurl {
    url =
      "https://github.com/webosbrew/dev-manager-desktop/releases/download/v${version}/${pname}_${version}_amd64.AppImage";
    hash = "sha256-KSQKwBiVnJ7fp0gziA8byg5VpMgfo4ShOX1/e/QQGjU=";
  };
in appimageTools.wrapType2 { inherit pname version src; }
