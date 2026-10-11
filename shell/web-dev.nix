{ pkgs }:

let
  webPkgs = with pkgs; [
    nodejs
    typescript
    chromium
  ];
in

pkgs.mkShell {
  packages = webPkgs;
}
