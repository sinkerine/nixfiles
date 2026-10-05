{ pkgs, ... }:

{
  # Xray 26.9.8+ rejects the ClientHello sent by current sing-box Reality clients.
  # Keep Xray 26.9.9, but use the Reality revision before that new check.
  services.xray.package = pkgs.xray.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace go.mod \
        --replace-fail 'github.com/xtls/reality v0.0.0-20260908062103-8cdf7bf9c7f0' \
                       'github.com/xtls/reality v0.0.0-20260908045812-e1986a4d31ca'
      cat >> go.sum <<'EOF'
github.com/xtls/reality v0.0.0-20260908045812-e1986a4d31ca h1:eugDuiZ7KGED+IFIBQIUsPJXThy+Wgp3MnroI8S11RE=
github.com/xtls/reality v0.0.0-20260908045812-e1986a4d31ca/go.mod h1:DsJblcWDGt76+FVqBVwbwRhxyyNJsGV48gJLch0OOWI=
EOF
    '';
    vendorHash = "sha256-zc0dJtPK+KOvNZffc9lC2aYa9qptuhKkoXixoBTOUIs=";
  });
}
