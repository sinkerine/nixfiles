{
  config,
  lib,
  pkgs,
  hostname,
  ...
}:

let
  cfg = config.my.programs.qex;
  toml = pkgs.formats.toml { };
  profilesFile = ./profiles.json;
  sharedQex =
    (pkgs.writeShellApplication {
      name = "qex";
      text = ''
        # Pin scheduler state, while preserving project XDG roots inside the job.
        qex_job_config="''${XDG_CONFIG_HOME:-${config.xdg.configHome}}"
        qex_job_state="''${XDG_STATE_HOME:-${config.xdg.stateHome}}"
        export XDG_CONFIG_HOME=${lib.escapeShellArg config.xdg.configHome}
        export XDG_STATE_HOME=${lib.escapeShellArg config.xdg.stateHome}
        case "''${1:-}" in
          submit|run)
            qex_action="$1"
            shift
            exec ${pkgs.qex}/bin/qex "$qex_action" \
              --env "XDG_CONFIG_HOME=$qex_job_config" \
              --env "XDG_STATE_HOME=$qex_job_state" "$@"
            ;;
          *) exec ${pkgs.qex}/bin/qex "$@" ;;
        esac
      '';
    }).overrideAttrs
      (_: {
        name = "qex-shared";
      });
  agentJob = pkgs.writeShellApplication {
    name = "agent-job";
    runtimeInputs = [
      pkgs.python3
      pkgs.git
    ];
    text = ''
      export AGENT_JOB_QEX=${sharedQex}/bin/qex
      export AGENT_JOB_PROFILES=${profilesFile}
      exec python3 -B ${./agent-job.py} "$@"
    '';
  };
in
{
  options.my.programs.qex = {
    enable = lib.mkEnableOption "shared resource admission for Gradle builds and E2E tests";
    settings = lib.mkOption {
      type = toml.type;
      default = { };
      description = "Additional declarative qex.toml settings, recursively overriding the managed defaults. The budget supports CPU and RAM only. Change configuration here rather than with qex config set.";
    };
    cpuBudget = lib.mkOption {
      type = lib.types.either lib.types.ints.positive lib.types.str;
      default = if hostname == "kazuki" then 8 else "25%";
      description = "Shared CPU claims; hosts other than kazuki use a provisional conservative fraction.";
    };
    memoryBudget = lib.mkOption {
      type = lib.types.str;
      default = if hostname == "kazuki" then "24GiB" else "25%";
      description = "Shared memory claims, separate from the live available-memory reserve.";
    };
    reserveMemory = lib.mkOption {
      type = lib.types.str;
      default = if hostname == "kazuki" then "8GiB" else "4GiB";
      description = "Memory left available when admitting a job; calibrate separately on each host.";
    };
    maxMemoryPressure = lib.mkOption {
      type = lib.types.ints.between 0 100;
      default = 5;
      description = "Maximum Linux PSI memory some avg10 percentage before new jobs wait.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          let
            budget = cfg.settings.budget or { };
          in
          lib.isAttrs budget && lib.all (name: lib.elem name [ "cpu" "mem" ]) (lib.attrNames budget);
        message = "my.programs.qex.settings.budget supports only cpu and mem.";
      }
      {
        assertion = (cfg.settings.pool or [ ]) == [ ];
        message = "my.programs.qex.settings.pool must be empty. Use named locks for exclusive access to shared resources.";
      }
    ];
    home.packages = [
      sharedQex
      agentJob
    ];
    xdg.configFile."qex.toml".source = toml.generate "qex.toml" (lib.recursiveUpdate {
      budget = {
        cpu = cfg.cpuBudget;
        mem = cfg.memoryBudget;
      };
      system = {
        reserve_mem = cfg.reserveMemory;
        max_pressure = cfg.maxMemoryPressure;
      };
      enforce.mode = "cooperative";
      queue = {
        oversized = "reject";
        max_bypass = 2;
      };
      defaults = {
        cpu = 4;
        mem = "8GiB";
        timeout = "0";
        max_queue_time = "0";
      };
      politeness = {
        nice = 10;
        io = "idle";
        oom_score_adj = 0;
      };
      learn.enabled = false;
      # Package updates belong to Nix, not runtime release checks.
      update.check = "never";
      logs.max_bytes = "32MiB";
      gc.keep = "7d";
    } cfg.settings);
    xdg.configFile."qex/profiles.json".source = profilesFile;
    xdg.configFile."qex/AGENT.md".source = ../pi-coding-agent-skills/qex/SKILL.md;
    xdg.configFile."qex/e2e-resources.md".source =
      ../pi-coding-agent-skills/e2e-feature/references/qex-resources.md;
  };
}
