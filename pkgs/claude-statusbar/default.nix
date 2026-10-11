{
  lib,
  python3Packages,
  fetchFromGitHub,
}:

python3Packages.buildPythonApplication {
  pname = "claude-statusbar";
  version = "3.46.1";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "leeguooooo";
    repo = "claude-code-usage-bar";
    rev = "038447bbf329d6dfc3ef8603f7e2e0e7d558f6de";
    hash = "sha256-38u35wzdIgkfsYPwdgsq5g3y9jtvkQNUMhKInDMNsPk=";
  };

  build-system = with python3Packages; [
    setuptools
    wheel
  ];

  # Updates are managed by Nix rather than the application's pip updater.
  makeWrapperArgs = [ "--set CLAUDE_STATUSBAR_NO_UPDATE 1" ];
  pythonImportsCheck = [ "claude_statusbar" ];

  meta = {
    description = "Inline Claude Code usage and rate-limit status bar";
    homepage = "https://github.com/leeguooooo/claude-code-usage-bar";
    license = lib.licenses.mit;
    mainProgram = "cs";
  };
}
