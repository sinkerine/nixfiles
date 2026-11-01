{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.my.services.vinput;
in
{
  options.my.services.vinput = {
    enable = mkEnableOption "Vinput voice input";

    enableStreaming = mkEnableOption "streaming ASR through the OpenAI Realtime API";
  };

  config = mkIf cfg.enable (
    let
      asrProvider = if cfg.enableStreaming then "streaming" else "batch";
      asrProviderId =
        if cfg.enableStreaming then
          "provider.openai-compatible.streaming"
        else
          "provider.openai-compatible";
      asrProviderUrl =
        if cfg.enableStreaming then
          "https://raw.githubusercontent.com/xifan2333/vinput-registry/main/resources/providers/openai-compatible/streaming/entry.py"
        else
          "https://raw.githubusercontent.com/xifan2333/vinput-registry/main/resources/providers/openai-compatible/batch/entry.py";
      asrProviderHash =
        if cfg.enableStreaming then
          "sha256-RQPa3xvz/G/+Jsi1/VJ6fE2Of8e5p0n2IOH3wSJbK3g="
        else
          "sha256-u7XqXkuRb4xL5m8gdS7omOY9zTuexCK1p3YLZToWVaM=";
      asrProviderPath = "${config.home.homeDirectory}/.local/share/vinput/providers/openai-compatible/${asrProvider}";
      pangu = pkgs.python3Packages.buildPythonPackage {
        pname = "pangu";
        version = "5.0.0";
        format = "wheel";
        src = pkgs.fetchPypi {
          pname = "pangu";
          version = "5.0.0";
          format = "wheel";
          dist = "py3";
          python = "py3";
          hash = "sha256-Z5ozHnEw/X1VF3c/6eRRDrJ6AT/1lJQbxAU/+bQjOLg=";
        };
        pythonImportsCheck = [ "pangu" ];
      };
      asrPostprocessorPython = pkgs.python3.withPackages (_: [
        pangu
        pkgs.python3Packages.opencc
      ]);
      asrPostprocessor = pkgs.writeText "vinput-asr-postprocessor.py" ''
        import json
        import subprocess
        import sys

        import pangu
        from opencc import OpenCC

        opencc = OpenCC("t2s")


        def format_text(text):
            return pangu.spacing_text(opencc.convert(text))


        def terminate_provider(provider):
            if provider.poll() is not None:
                return

            provider.terminate()
            try:
                provider.wait(timeout=5)
            except subprocess.TimeoutExpired:
                provider.kill()
                provider.wait()


        provider_path, mode = sys.argv[1:3]
        if mode not in ("batch", "streaming"):
            raise SystemExit(f"unsupported ASR provider mode: {mode}")

        provider = subprocess.Popen(
            [sys.executable, provider_path],
            stdin=sys.stdin.buffer,
            stdout=subprocess.PIPE,
            stderr=sys.stderr,
        )

        try:
            if mode == "streaming":
                for line in provider.stdout:
                    event = json.loads(line)
                    if isinstance(event, dict) and isinstance(event.get("text"), str):
                        event["text"] = format_text(event["text"])
                    sys.stdout.write(json.dumps(event, ensure_ascii=False) + "\n")
                    sys.stdout.flush()
            else:
                transcript = provider.stdout.read().decode("utf-8")
                sys.stdout.write(format_text(transcript))
                sys.stdout.flush()
        except BaseException:
            terminate_provider(provider)
            raise

        raise SystemExit(provider.wait())
      '';
      asrEnv = {
        VINPUT_ASR_API_KEY = config.sops.placeholder.vinputOpenAIAPIKey;
        VINPUT_ASR_MODEL = if cfg.enableStreaming then "gpt-realtime-whisper" else "gpt-transcribe";
        VINPUT_ASR_URL =
          if cfg.enableStreaming then
            "wss://api.openai.com/v1/realtime"
          else
            "https://api.openai.com/v1/audio/transcriptions";
      }
      // optionalAttrs cfg.enableStreaming {
        VINPUT_ASR_FINISH_GRACE_SECS = "2";
      };
    in
    {
      my.services.fcitx5.addons = [ pkgs.fcitx5-vinput ];

      home.packages = [ pkgs.fcitx5-vinput ];

      home.file.".local/share/vinput/providers/openai-compatible/${asrProvider}" = {
        source = pkgs.fetchurl {
          url = asrProviderUrl;
          hash = asrProviderHash;
        };
        executable = true;
      };

      sops.secrets.vinputOpenAIAPIKey = { };
      sops.secrets.vinputDeepSeekAPIKey = { };
      sops.templates."vinput-config.json" = {
        path = "${config.xdg.configHome}/vinput/config.json";
        content = ''
          {
            "version": 1,
            "registry": {
              "base_urls": [
                "https://raw.githubusercontent.com/xifan2333/vinput-registry/main",
                "https://gh-proxy.com/https://raw.githubusercontent.com/xifan2333/vinput-registry/main",
                "https://ghfast.top/https://raw.githubusercontent.com/xifan2333/vinput-registry/main"
              ]
            },
            "global": {
              "default_language": "zh",
              "capture_device": ""
            },
            "asr": {
              "active_provider": "${asrProviderId}",
              "normalize_audio": true,
              "input_gain": 1.0,
              "vad": {
                "enabled": true
              },
              "providers": [
                {
                  "id": "sherpa-onnx",
                  "type": "local",
                  "model": "model.sherpa-onnx.qwen3-asr-0.6b-int8",
                  "timeout_ms": 15000
                },
                {
                  "id": "${asrProviderId}",
                  "type": "command",
                  "command": "${asrPostprocessorPython}/bin/python3",
                  "args": ${
                    builtins.toJSON [
                      asrPostprocessor
                      asrProviderPath
                      asrProvider
                    ]
                  },
                  "env": ${
                    builtins.toJSON (
                      asrEnv
                      // {
                        VINPUT_ASR_PROMPT = "Transcribe speech in English, Simplified Chinese, or any mix of them. Always render Chinese content using Simplified Chinese characters; never use Traditional Chinese characters. Always separate adjacent Chinese and English text with a single space.";
                      }
                    )
                  },
                  "timeout_ms": 60000
                }
              ]
            },
            "llm": {
              "providers": [
                {
                  "id": "Magpie",
                  "base_url": "https://magpie-api.sachi.m.mado.moe/v1",
                  "api_key": "dummykey"
                },
                {
                  "id": "OpenAI",
                  "base_url": "https://cpa.sachi.m.mado.moe/v1",
                  "api_key": "sk-dummy"
                },
                {
                  "id": "DeepSeek",
                  "base_url": "https://api.deepseek.com/v1",
                  "api_key": "${config.sops.placeholder.vinputDeepSeekAPIKey}"
                }
              ],
              "adapters": []
            },
            "scenes": {
              "active_scene": "__raw__",
              "definitions": [
                {
                  "id": "__raw__",
                  "candidate_count": 0
                },
                {
                  "id": "default",
                  "label": "Magpie correction",
                  "prompt": "You are a transcription corrector, not a translator. Correct only obvious speech-recognition errors and remove accidental filler words. Preserve the original meaning, tone, and language of every span. Never translate between languages. English speech must remain English; Chinese speech must remain Chinese. Preserve code-switching, names, product names, and technical terms. Never replace English words or phrases with Chinese equivalents, even when surrounded by Chinese. Render only Chinese spans using Simplified Chinese characters. Add a single space between adjacent Chinese and English text. Return only the corrected transcript; never explain or answer its content.",
                  "provider_id": "Magpie",
                  "model": "group/gpt",
                  "context_lines": 3,
                  "candidate_count": 1,
                  "timeout_ms": 60000
                },
                {
                  "id": "__command__",
                  "prompt": "# Command Mode Prompt\n\n## Role\n\nYou are an assistant that applies a spoken command to the user-provided text.\n\n## Output Language\n\n- Always render Chinese output using Simplified Chinese characters.\n- Never output Traditional Chinese characters; convert any Traditional Chinese source text to Simplified Chinese.\n- Preserve non-Chinese languages unless the spoken command requests translation.\n\n## Context\n\n- The user message is the source text to operate on.\n- The spoken command may contain ASR errors.\n- The spoken command is appended at runtime in the `## Task` section.\n\n## Task\n",
                  "provider_id": "Magpie",
                  "model": "group/gpt",
                  "timeout_ms": 30000
                }
              ]
            }
          }
        '';
      };

      systemd.user.services.vinput-daemon = {
        Unit = {
          Description = "Vinput voice input daemon";
          After = [ "pipewire.service" ];
          X-Restart-Triggers = [ config.sops.templates."vinput-config.json".file ];
        };
        Service = {
          Type = "dbus";
          BusName = "org.fcitx.Vinput";
          ExecStart = "${pkgs.fcitx5-vinput}/bin/vinput-daemon";
        };
        Install.WantedBy = [ "default.target" ];
      };
    }
  );
}
