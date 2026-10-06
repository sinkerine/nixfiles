{ appimageTools, fetchurl }:
let
  pname = "webos-dev-manager";
  version = "1.99.20";

  src = fetchurl {
    url =
      "https://github.com/webosbrew/dev-manager-desktop/releases/download/v${version}/${pname}_${version}_amd64.AppImage";
    hash = "sha256-g6zrETK8g+2iUyUFPdOX5tAZfPWbxv/CuTPIvMjduPQ=";
  };
in appimageTools.wrapType2 { inherit pname version src; }
