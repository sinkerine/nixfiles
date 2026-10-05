{
  description = "Nix Flakes of Sinkerine";
  nixConfig = {
    extra-substituters = [ "https://cache.numtide.com" ];
    extra-trusted-public-keys = [ "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=" ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nur = {
      url = "github:nix-community/NUR";
    };
    flake-utils.url = "github:numtide/flake-utils";
    # nixgl is needed for alacritty outside of nixOS
    # refer to https://github.com/NixOS/nixpkgs/issues/122671
    # https://github.com/guibou/nixGL/#use-an-overlay
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    nixgl = {
      inputs.flake-utils.follows = "flake-utils";
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:guibou/nixGL";
    };
    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    kmonad = {
      url = "github:kmonad/kmonad?dir=nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware/master";
    };
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-compat.follows = "flake-compat";
    };
    hyprland = {
      url = "git+https://github.com/hyprwm/Hyprland?submodules=1";
    };
    noctalia = {
      url = "github:noctalia-dev/noctalia";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixvim = {
      url = "github:nix-community/nixvim";
    };
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
    };
    jailed-agents = {
      url = "github:andersonjoseph/jailed-agents";
    };
    cua = {
      url = "github:trycua/cua";
    };
    fcitx5-vinput = {
      url = "github:xifan2333/fcitx5-vinput";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Do not add inputs.nixpkgs.follows — proxmox-nixos pins nixpkgs-stable intentionally.
    proxmox-nixos.url = "github:SaumonNet/proxmox-nixos";
    proxmox-nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-stable,
      home-manager,
      nur,
      nixgl,
      sops-nix,
      kmonad,
      nixos-hardware,
      deploy-rs,
      hyprland,
      noctalia,
      nixvim,
      llm-agents,
      jailed-agents,
      cua,
      fcitx5-vinput,
      proxmox-nixos,
      ...
    }:
    let
      supportedSystems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      state = import (
        if builtins.pathExists ./home/state/default.nix then
          ./home/state
        else
          ./home/state/default.example.nix
      );
    in
    rec {
      overlays = import ./overlays {
        inherit
          nixpkgs
          llm-agents
          fcitx5-vinput
          cua
          ;
      };
      packages = forAllSystems (
        system:
        import nixpkgs {
          inherit system;
          overlays = with overlays; [
            additions
            modifications
            nixgl.overlays.default
            kmonad.overlays.default
          ];
          config.allowUnfree = true;
          config.nvidia.acceptLicense = true;
          config.permittedInsecurePackages = [
            "electron-36.9.5"
            "ventoy-1.1.17"
            "qtwebengine-5.15.19"
            "mbedtls-2.28.10"
          ];
        }
      );

      noctaliaHomeModules = [
        ./home/modules/programs/noctalia
        noctalia.homeModules.default
      ];

      homeConfigurationArgs = {
        "sinkerine@kazuki" = {
          pkgs = packages."x86_64-linux";
          modules = [ ./home/users/sinkerine/kazuki ] ++ noctaliaHomeModules;
          extraSpecialArgs = {
            hostname = "kazuki";
          };
        };
        "sinkerine@asako" = {
          pkgs = packages."x86_64-linux";
          modules = [ ./home/users/sinkerine/asako ] ++ noctaliaHomeModules;
          extraSpecialArgs = {
            hostname = "asako";
          };
        };
        "sinkerine@sachi" = {
          pkgs = packages."x86_64-linux";
          modules = [ ./home/users/sinkerine/sachi ];
          extraSpecialArgs = {
            hostname = "sachi";
          };
        };
        "sinkerine@yumiko" = {
          pkgs = packages."x86_64-linux";
          modules = [ ./home/users/sinkerine/yumiko ];
          extraSpecialArgs = {
            hostname = "yumiko";
          };
        };
        "sinkerine@amane" = {
          pkgs = packages."x86_64-linux";
          modules = [ ./home/users/sinkerine/amane ];
          extraSpecialArgs = {
            hostname = "amane";
          };
        };
        "work@desktop" = {
          pkgs = packages."x86_64-linux";
          modules = [ ./home/users/work/desktop/default.nix ];
          extraSpecialArgs = {
            hostname = "desktop";
          };
        };
      };
      homeConfigurations = nixpkgs.lib.pipe homeConfigurationArgs [
        (builtins.mapAttrs (
          configName: v:
          v
          // {
            modules = v.modules ++ [
              ./modules/home-manager
              ./home/modules
              {
                imports = [
                  nur.modules.homeManager.default
                  nixvim.homeModules.nixvim
                  sops-nix.homeManagerModules.sops
                ];
              }
            ];
            extraSpecialArgs = (v.extraSpecialArgs or { }) // rec {
              inherit state;
              nixvimLib = nixvim.lib.nixvim;
              nixinfo = {
                inherit configName;
                projectRoot = "/nixfiles";
              };
              pkgsStable = import nixpkgs-stable {
                system = v.pkgs.stdenv.hostPlatform.system;
                config = {
                  allowUnfree = true;
                  nvidia.acceptLicense = true;
                  permittedInsecurePackages = [
                    "electron-36.9.5"
                    "ventoy-1.1.17"
                    "qtwebengine-5.15.19"
                    "mbedtls-2.28.10"
                  ];
                };
              };
              mylib = (
                import ./lib {
                  inherit (v) pkgs;
                  inherit (v.pkgs) lib;
                }
              );
            };
          }
        ))
        (builtins.mapAttrs (_: v: home-manager.lib.homeManagerConfiguration v))
      ];

      nixosConfigurationArgs = {
        # TODO: migrate to unencrypted pool + encrypted dataset.
        "kazuki" = rec {
          system = "x86_64-linux";
          pkgs = (builtins.getAttr system packages) // {
            config.cudaSupport = true;
          };
          modules = [
            ./hosts/kazuki
            hyprland.nixosModules.default
          ]
          ++ (with nixos-hardware.nixosModules; [
            common-gpu-nvidia-nonprime
            common-cpu-amd
          ]);
          specialArgs = {
            hostname = "kazuki";
          };
        };
        # TODO: migrate to unencrypted pool + encrypted dataset.
        "asako" = rec {
          system = "x86_64-linux";
          pkgs = builtins.getAttr system packages;
          modules = [
            ./hosts/asako
            hyprland.nixosModules.default
            kmonad.nixosModules.default
          ]
          ++ (with nixos-hardware.nixosModules; [
            lenovo-thinkpad-z13-gen2
            common-cpu-amd-pstate
          ]);
          specialArgs = {
            hostname = "asako";
          };
        };
        # TODO: migrate to unencrypted pool + encrypted dataset.
        "sachi" = rec {
          system = "x86_64-linux";
          pkgs = builtins.getAttr system packages;
          modules = [
            ./hosts/sachi
            hyprland.nixosModules.default
          ]
          ++ (with nixos-hardware.nixosModules; [ common-cpu-intel-cpu-only ]);
          specialArgs = {
            hostname = "sachi";
          };
        };
        "yumiko" = rec {
          system = "x86_64-linux";
          pkgs = builtins.getAttr system packages;
          modules = [ ./hosts/yumiko ];
          specialArgs = {
            hostname = "yumiko";
          };
        };
        "amane" = rec {
          system = "x86_64-linux";
          pkgs = builtins.getAttr system packages;
          modules = [ ./hosts/amane ];
          specialArgs = {
            hostname = "amane";
          };
        };
      };
      nixosConfigurations = builtins.mapAttrs (
        _: v:
        nixpkgs.lib.nixosSystem (
          v
          // {
            modules = v.modules ++ [
              ./modules/nixos
              ./hosts/modules
              sops-nix.nixosModules.sops
            ];
            specialArgs = v.specialArgs // {
              inherit (self) inputs;
              mylib = (
                import ./lib {
                  inherit (v) pkgs;
                  inherit (v.pkgs) lib;
                }
              );
            };
          }
        )
      ) nixosConfigurationArgs;

      deploy = {
        nodes = nixpkgs.lib.genAttrs [ "sachi" "amane" "yumiko" "asako" ] (hostname: {
          inherit hostname;
          profilesOrder = [
            "system"
            "home"
          ];
          profiles = {
            system = {
              sshUser = "root";
              path = deploy-rs.lib.x86_64-linux.activate.nixos (
                builtins.getAttr hostname self.nixosConfigurations
              );
              confirmTimeout = 60;
              autoRollback = false;
              magicRollback = false;
            };
            home = {
              sshUser = "sinkerine";
              path = deploy-rs.lib.x86_64-linux.activate.home-manager (
                builtins.getAttr "sinkerine@${hostname}" self.homeConfigurations
              );
              confirmTimeout = 60;
              autoRollback = false;
              magicRollback = false;
            };
          };
        });
      };
      checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
      devShells = forAllSystems (system: {
        default = import ./shell/default.nix {
          pkgs = builtins.getAttr system packages;
          inherit jailed-agents system;
        };
        tmux = import ./shell/tmux-dev.nix {
          pkgs = builtins.getAttr system packages;
          inherit jailed-agents system;
        };
        python = import ./shell/python-dev.nix {
          pkgs = builtins.getAttr system packages;
        };
        web = import ./shell/web-dev.nix {
          pkgs = builtins.getAttr system packages;
          inherit jailed-agents system;
        };
      });
    };
}
