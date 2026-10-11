{ lib, fetchFromGitHub, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "pi-collapse-tools";
  version = "0.1.11-unstable-20260924";

  src = fetchFromGitHub {
    owner = "xRyul";
    repo = "pi-collapse-tools";
    rev = "b44dfc600e93a1d1883e3e648257385af2f93ec0";
    hash = "sha256-EUE9pLz/9NOBb+IKUfAwJ6vyQOAB2mrbEMXj4QTrUys=";
  };

  dontConfigure = true;
  dontBuild = true;

  postPatch = ''
    substituteInPlace index.ts \
      --replace-fail 'return tools ?? DEFAULT_TOOL_NAMES;' 'return tools ?? VALID_TOOL_NAMES;'
  '';

  installPhase = ''
    mkdir -p $out/lib/node_modules/pi-collapse-tools
    cp -r -- index.ts package.json README.md LICENSE $out/lib/node_modules/pi-collapse-tools/
  '';

  meta = {
    description = "Pi extension that hides tool output by default";
    homepage = "https://github.com/xRyul/pi-collapse-tools";
    license = lib.licenses.mit;
  };
}
