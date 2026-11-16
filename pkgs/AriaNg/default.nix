{
  lib,
  fetchzip,
  stdenvNoCC,
}:

let
  pname = "AriaNg";
  version = "1.3.15";
in stdenvNoCC.mkDerivation {
  inherit pname version;
  src = fetchzip {
    url =
      "https://github.com/mayswind/AriaNg/releases/download/${version}/AriaNg-${version}-AllInOne.zip";
    stripRoot = false;
    hash = "sha256-K1w/8ALqQ9Z0L1Pj15XA/RxnbEnbol4rz8ANDKsORKM=";
  };
  phases = [ "installPhase" ];
  installPhase = ''
    outdir=$out/share/AriaNg
    mkdir -p $outdir
    cp -r $src/* $outdir/
  '';

  meta = with lib; {
    description = "Modern web frontend for aria2";
    homepage = "https://github.com/mayswind/AriaNg";
    license = licenses.mit;
    platforms = platforms.all;
  };
}
