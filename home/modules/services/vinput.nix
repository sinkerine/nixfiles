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

    enableStreaming = mkEnableOption "streaming ASR through the OpenAI Realtime API" // {
      default = true;
    };
  };

  config = mkIf cfg.enable (
    let
      asrProvider = if cfg.enableStreaming then "streaming" else "batch";
      asrProviderId =
        if cfg.enableStreaming then
          "provider.openai-compatible.streaming"
        else
          "provider.openai-compatible";
      asrProviderUrl = "https://raw.githubusercontent.com/sinkerine/vinput-registry/main/resources/providers/openai-compatible/${asrProvider}/entry.py";
      asrProviderHash =
        if cfg.enableStreaming then
          "sha256-kg8P8Xl/4/Rxhj7UapQx2nFbi8ygo3PM+DowRN0lMrs="
        else
          "sha256-u7XqXkuRb4xL5m8gdS7omOY9zTuexCK1p3YLZToWVaM=";
      asrProviderSource = pkgs.fetchurl {
        url = asrProviderUrl;
        hash = asrProviderHash;
      };
      asrProviderPath = "${config.home.homeDirectory}/.local/share/vinput/providers/openai-compatible/${asrProvider}";
      postprocessingPrompt = ''
        You are a multilingual transcription post-processor supporting English, Simplified Chinese, Traditional Chinese, Japanese, and mixed-language speech.

        Your task is to clean up raw speech-to-text transcripts while preserving their original meaning and spoken languages.

        Rules:
        1. Support English, Chinese, Japanese, and code-switching between all three languages.
        2. **Always convert ALL Traditional Chinese characters and vocabulary to Simplified Chinese** in Chinese-language segments. Never output Traditional Chinese in Chinese text.
        3. Preserve standard Japanese writing, including kanji, hiragana, katakana, and Japanese punctuation. Do not mistakenly convert Japanese kanji into Simplified Chinese characters.
        4. Preserve the original spoken language. Do not translate between English, Chinese, and Japanese unless explicitly requested.
        5. Correct obvious transcription errors, punctuation, capitalization, spacing, and grammatical mistakes without changing the intended meaning.
        6. Remove unnecessary filler words, repetitions, and speech disfluencies while preserving meaningful content and natural conversational tone.
        7. Preserve technical terminology, product names, proper nouns, numbers, and acronyms. Normalize any Chinese-script portions to Simplified Chinese.
        8. Use natural, language-appropriate punctuation and spacing for English, Simplified Chinese, and Japanese.
        9. For Japanese, correctly handle particles, conjugations, kanji conversions, and sentence boundaries based on context. Preserve natural Japanese expressions and politeness levels.
        10. For mixed-language sentences, maintain the original language boundaries and avoid unnecessary translation or rewriting.
        11. Preserve the speaker's intent, tone, and sentence structure as much as possible.
        12. Do not add explanations, commentary, or information not present in the transcript.
        13. Output ONLY the cleaned transcript, without quotes, labels, or Markdown formatting.

        Critical requirements:
        - All Chinese text MUST use Simplified Chinese, never Traditional Chinese.
        - Japanese text MUST retain correct Japanese orthography, including Japanese-specific kanji forms, even when those characters overlap with Traditional Chinese.
        - English text MUST remain English.
        - Never translate or change the original language of a segment.
        - Prioritize transcription accuracy, minimal edits, and low processing latency.
      '';
      asrEnv = {
        VINPUT_ASR_API_KEY = config.sops.placeholder.vinputOpenAIAPIKey;
        VINPUT_ASR_MODEL = if cfg.enableStreaming then "gpt-live-transcribe" else "gpt-transcribe";
        VINPUT_ASR_URL =
          if cfg.enableStreaming then
            "wss://api.openai.com/v1/realtime"
          else
            "https://api.openai.com/v1/audio/transcriptions";
      }
      // optionalAttrs cfg.enableStreaming {
        VINPUT_ASR_DELAY = "medium";
        VINPUT_ASR_LANGUAGES = builtins.toJSON [ "en" "zh" "ja" ];
      };
    in
    {
      my.services.fcitx5.addons = [ pkgs.fcitx5-vinput ];

      home.packages = [ pkgs.fcitx5-vinput ];

      home.file.".local/share/vinput/providers/openai-compatible/${asrProvider}" = {
        source = asrProviderSource;
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
                  "command": "${pkgs.python3}/bin/python3",
                  "args": ${
                    builtins.toJSON [
                      asrProviderPath
                    ]
                  },
                  "env": ${
                    builtins.toJSON (
                      asrEnv
                      // {
                        VINPUT_ASR_PROMPT = "Transcribe speech in English, Chinese, Japanese, or any mix of them. Preserve each segment's spoken language and standard orthography. Use Simplified Chinese for Chinese segments and preserve Japanese kanji, hiragana, and katakana for Japanese segments.";
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
              "active_scene": "default",
              "definitions": [
                {
                  "id": "__raw__",
                  "candidate_count": 0
                },
                {
                  "id": "default",
                  "label": "Magpie correction",
                  "prompt": ${builtins.toJSON postprocessingPrompt},
                  "provider_id": "Magpie",
                  "model": "group/luna-ultrafast",
                  "context_lines": 3,
                  "raw_cand": false,
                  "raw_prev": false,
                  "candidate_count": 1,
                  "timeout_ms": 60000
                },
                {
                  "id": "__command__",
                  "prompt": "# Command Mode Prompt\n\n## Role\n\nYou are an assistant that applies a spoken command to the user-provided text.\n\n## Output Language\n\n- Always render Chinese output using Simplified Chinese characters.\n- Never output Traditional Chinese characters; convert any Traditional Chinese source text to Simplified Chinese.\n- Preserve non-Chinese languages unless the spoken command requests translation.\n\n## Context\n\n- The user message is the source text to operate on.\n- The spoken command may contain ASR errors.\n- The spoken command is appended at runtime in the `## Task` section.\n\n## Task\n",
                  "provider_id": "Magpie",
                  "model": "group/luna-ultrafast",
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
