{ lib, python3Packages, fetchurl, makeWrapper, nodejs_24 }:

python3Packages.buildPythonApplication {
  pname = "loopx";
  version = "1.4.2";
  format = "wheel";
  src = fetchurl {
    url = "https://files.pythonhosted.org/packages/61/32/152fd3a39be60ad9bad970908f7cbbb8db9eccb9531b11289ccc832f6899/loopx-1.4.2-py3-none-any.whl";
    sha256 = "fc57c57227283de968f6222e0294b4b87ddf61a5f4fe530f014d99c60b6906b3";
  };
  nativeBuildInputs = [ makeWrapper ];
  # Upstream permits only loopback origins. Permit one explicit HTTPS origin
  # for the LAN reverse proxy, preserving Host/Origin matching and CSRF checks.
  postInstall = ''
    ${python3Packages.python.interpreter} ${./public-origin.py} "$out/${python3Packages.python.sitePackages}/loopx/chat_server.py"
    wrapProgram "$out/bin/loopx" --prefix PATH : ${lib.makeBinPath [ nodejs_24 ]}
  '';
  pythonImportsCheck = [ "loopx.chat_server" ];
  meta = {
    description = "Local agent control plane and WebUI with native Codex execution";
    homepage = "https://github.com/loopx-project/loopx";
    license = lib.licenses.asl20;
    mainProgram = "loopx";
    platforms = lib.platforms.linux;
  };
}
