{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.my.programs.pi-coding-agent;
  # Orca's orchestration discovery stub is longer than the Agent Skills
  # specification's limit. Keep Pi able to load the complete stub.
  piCodingAgent = pkgs.pi-coding-agent.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      cd $out/lib/node_modules/pi-monorepo
      sed -i 's/MAX_DESCRIPTION_LENGTH = 1024/MAX_DESCRIPTION_LENGTH = 2048/g; s/MAX_DESCRIPTION_LENGTH=1024/MAX_DESCRIPTION_LENGTH=2048/g; s/MAX_DESCRIPTION_LENGTH2=1024/MAX_DESCRIPTION_LENGTH2=2048/g' \
        dist/core/skills.js dist/bundle/chunks/chunk-*.js
    '';
    postWrapper = (old.postWrapper or "") + ''
      export PI_CODING_AGENT_PACKAGE_ROOT="${placeholder "out"}/lib/node_modules/pi-monorepo"
    '';
  });
  piAstGrep = pkgs.pi-ast-grep;
  piVim = pkgs.pi-vim;
  piWebAccess = pkgs.pi-web-access;
  piWebAccessConfig = builtins.toJSON {
    provider = "openai";
    openaiSearchProviders = [ "magpie" ];
    openaiUseProviderBaseUrl = true;
    openaiSearchModel = "gpt-6-luna";
    openaiUseAlphaSearch = false;
  };
  piLuna = pkgs.writeShellApplication {
    name = "pi-luna";
    runtimeInputs = [ piCodingAgent ];
    text = ''
      exec pi --provider magpie --model gpt-6-luna "$@"
    '';
  };
  piSol = pkgs.writeShellApplication {
    name = "pi-sol";
    runtimeInputs = [ piCodingAgent ];
    text = ''
      exec pi --provider magpie --model gpt-6.1-sol "$@"
    '';
  };
  piAstra = pkgs.writeShellApplication {
    name = "pi-astra";
    runtimeInputs = [ piCodingAgent ];
    text = ''
      exec pi --provider magpie --model gpt-6-astra "$@"
    '';
  };
  piSubagents = pkgs.buildNpmPackage rec {
    pname = "pi-subagents";
    version = "0.76.1";

    src = pkgs.fetchFromGitHub {
      owner = "nicobailon";
      repo = "pi-subagents";
      rev = "v${version}";
      hash = "sha256-D+JOBUu/RsYMcG+Cj5my9LYXmzzq9bEP0fCbZEEKGLI=";
    };

    npmDepsHash = "sha256-zPo0Z3IjaSEA74YptOUComiwvQxSMhPw7N6SwtGkveE=";
    npmFlags = [ "--omit=dev" ];
    dontNpmBuild = true;
    postInstall = ''
      # Pi provides typebox; declaring it as a peer avoids a second runtime copy.
      ${pkgs.python3}/bin/python - "$out/lib/node_modules/pi-subagents/package.json" <<'PY'
      import json, pathlib, sys
      path = pathlib.Path(sys.argv[1])
      package = json.loads(path.read_text())
      package.setdefault("peerDependencies", {})["typebox"] = "*"
      package.get("dependencies", {}).pop("typebox", None)
      path.write_text(json.dumps(package, indent=2) + "\n")
      PY
    '';
  };
in
{
  options.my.programs.pi-coding-agent = {
    enable = mkEnableOption "Pi coding agent";
  };

  config = mkIf cfg.enable {
    programs.pi-coding-agent = {
      enable = true;
      package = piCodingAgent;
      settings = {
        defaultProvider = "magpie";
        defaultModel = "gpt-pi";
        defaultProjectTrust = "always";
        packages = [
          "${piAstGrep}/lib/node_modules/pi-ast-grep"
          "${piSubagents}/lib/node_modules/pi-subagents"
          "${piWebAccess}/lib/node_modules/pi-web-access"
        ];
      };

      models.providers.magpie = {
        baseUrl = "https://magpie-api.sachi.m.mado.moe/v1";
        api = "openai-completions";
        apiKey = "magpie";
        models = [
          {
            id = "gpt-pi";
            name = "GPT-Pi";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1050000;
            maxTokens = 128000;
          }
          {
            id = "gpt-6-luna";
            name = "GPT-6 Luna";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1050000;
            maxTokens = 128000;
          }
          {
            id = "gpt-6.1-sol";
            name = "GPT-6.1 Sol";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1050000;
            maxTokens = 128000;
          }
          {
            id = "gpt-6-astra";
            name = "GPT-6 Astra";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1050000;
            maxTokens = 128000;
          }
        ];
      };
    };

    home.sessionVariables.PI_CODING_AGENT_PACKAGE_ROOT = "${piCodingAgent}/lib/node_modules/pi-monorepo";

    home.file.".pi/agent/extensions/pi-vim" = {
      source = "${piVim}/lib/node_modules/pi-vim";
      force = true;
    };
    xdg.configFile."pi/web-search.json".text = piWebAccessConfig;
    home.file.".pi/agent/keybindings.json".text = builtins.toJSON {
      "app.interrupt" = "ctrl+g";
      "app.editor.external" = [ ];
      "app.clear" = [ ];
    };

    home.packages = [
      piLuna
      piSol
      piAstra
    ];
  };
}
