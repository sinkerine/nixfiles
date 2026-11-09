{
  nixvimLib,
  config,
  lib,
  pkgs,
  mylib,
  ...
}:

with lib;
let
  cfg = config.my.programs.nvim;
in
{
  imports = [
    ./nix.nix
    ./clipper.nix
    ./text-edit.nix
    ./completion.nix
    ./ide.nix
  ];

  options.my.programs.nvim = {
    enable = mkEnableOption "Neo Vim";
    viAlias = mylib.mkDefaultTrueEnableOption "Vi Alias";
    colorscheme = mkOption { type = types.str; };
  };
  config = mkIf cfg.enable (mkMerge [
    {
      my.programs.nvim.colorscheme = "kanagawa";
      programs.nixvim = {
        enable = true;
        nixpkgs.pkgs = pkgs;
        opts = {
          number = true; # Show line numbers
          relativenumber = true; # Show relative line numbers
          shiftwidth = 2; # Tab width should be 2
          hlsearch = true;
          ignorecase = true;
          smartcase = true;
        };
        colorscheme = cfg.colorscheme;
        colorschemes.kanagawa = {
          enable = true;
        };
        globals.mapleader = " ";
        keymaps = [
          {
            mode = "n";
            options.silent = true;
            key = "<Esc>";
            action = "<cmd>noh<CR>";
          }
          {
            key = "<leader><leader>c";
            action = "<cmd>Telescope colorscheme<CR>";
          }
          {
            key = "<leader>;";
            action = "<cmd>Telescope commands<CR>";
          }
          {
            key = "<leader>:";
            action = "<cmd>Telescope command_history<CR>";
          }
          {
            key = "<leader>'";
            action = "<cmd>Yazi<CR>";
          }
          {
            key = ''<leader>"'';
            action = "<cmd>Yazi cwd<CR>";
          }
          {
            key = "<leader>ft";
            action = "<cmd>Neotree toggle<CR>";
          }
          {
            key = "<leader>ff";
            action = nixvimLib.mkRaw ''
              function()
                local fb = require("telescope").extensions.file_browser.file_browser
                local utils = require("telescope.utils")
                fb { cwd = utils.buffer_dir() }
              end
            '';
          }
          {
            key = "<leader>fr";
            action = "<cmd>Telescope oldfiles<CR>";
          }
          {
            key = "<leader>yn";
            action = ''<cmd>let @" = expand('%')<CR>'';
            options.desc = "Yank file name";
          }
          {
            key = "<leader>yf";
            action = ''<cmd>let @" = expand('%:p')<CR>'';
            options.desc = "Yank file path";
          }
          {
            key = "<leader>yd";
            action = ''<cmd>let @" = expand('%:h')<CR>'';
            options.desc = "Yank directory path";
          }
          {
            key = "<leader>ss";
            action = "<cmd>Telescope current_buffer_fuzzy_find<CR>";
          }
          {
            key = "<leader>sS";
            action = nixvimLib.mkRaw ''
              function()
                require("telescope.builtin").current_buffer_fuzzy_find {
                  default_text = table.concat(get_selection())
                }
              end
            '';
          }
          {
            key = "<leader>sd";
            action = nixvimLib.mkRaw ''
              function()
                local lg = require("telescope.builtin").live_grep
                local utils = require("telescope.utils")
                lg { cwd = utils.buffer_dir() }
              end
            '';
          }
          {
            key = "<leader>sD";
            action = nixvimLib.mkRaw ''
              function()
                local lg = require("telescope.builtin").live_grep
                local utils = require("telescope.utils")
                lg {
                  cw= utils.buffer_dir(),
                  default_text = table.concat(get_selection())
                }
              end
            '';
          }
          {
            key = "<leader>,";
            action = "<cmd>Telescope buffers<CR>";
          }
          {
            key = "<leader>.";
            action = "<cmd>Telescope find_files<CR>";
          }
          {
            key = "<leader>/";
            action = "<cmd>Telescope live_grep<CR>";
          }
          {
            key = "<leader>*";
            action = nixvimLib.mkRaw ''
              function()
                require("telescope.builtin").live_grep {
                  default_text = table.concat(get_selection())
                }
              end
            '';
            options.desc = "Telescope live_grep selection";
          }
          # Correct the keymaps of <Home> and <End>
          {
            mode = [
              ""
              "!"
            ];
            key = "<Find>";
            action = "<Home>";
          }
          {
            mode = [
              ""
              "!"
            ];
            key = "<Select>";
            action = "<End>";
          }
          {
            mode = [
              ""
              "!"
            ];
            key = "<A-x>";
            action = "<cmd>Telescope commands<CR>";
          }
          {
            mode = [
              ""
              "!"
            ];
            key = "<C-s>";
            action = "<cmd>up<CR>";
          }
          {
            key = "<leader>bb";
            action = "<cmd>Telescope buffers<CR>";
          }
          {
            key = "<leader>bn";
            action = "<cmd>enew<CR>";
          }
          {
            key = "<leader>bd";
            action = "<cmd>bp <BAR> bd #<CR>";
          }
          {
            key = "<leader>gg";
            action = "<cmd>Neogit<CR>";
          }
          {
            key = "<leader>pp";
            action = "<cmd>Telescope projects<CR>";
          }
          {
            key = "<leader>pa";
            action = "<cmd>ProjectAdd<CR>";
          }
          {
            key = "<leader>pd";
            action = "<cmd>ProjectDelete<CR>";
          }
        ];

        plugins = {
          lz-n.enable = true;
          noice.enable = true;
          orgmode = {
            enable = true;
            settings = {
              org_agenda_files = "~/org/**/*";
              org_default_notes_file = "~/org/inbox.org";
              org_startup_indented = true;
            };
          };
          neo-tree = {
            enable = true;
          };
          web-devicons.enable = true;
          telescope = {
            enable = true;
            extensions = {
              file-browser.enable = true;
              fzf-native = {
                enable = true;
                settings = {
                  case_mode = "smart_case";
                  fuzzy = true;
                };
              };
            };
            settings = {
              defaults = {
                mappings = {
                  i = {
                    "<ESC>" = nixvimLib.mkRaw "require('telescope.actions').close";
                    "<C-h>" = "which_key";
                  };
                };
              };
            };
          };
          treesitter = {
            enable = true;
          };
          fzf-lua.enable = true;
          project-nvim = {
            enable = true;
          };
          neogit = {
            enable = true;
            lazyLoad = {
              settings = {
                cmd = "Neogit";
              };
            };
          };
          gitblame = {
            enable = true;
            lazyLoad = {
              settings = {
                cmd = "GitBlameToggle";
              };
            };
          };
          airline = {
            enable = true;
            settings.theme = "tomorrow";
          };
          auto-session = {
            enable = true;
          };
          yazi = {
            enable = true;
            settings = {
              open_for_directories = true;
              keymaps = false;
              clipboard_register = "";
            };
            lazyLoad = {
              settings = {
                cmd = "Yazi";
              };
            };
            luaConfig.pre = ''
              vim.g.loaded_netrw       = 1
              vim.g.loaded_netrwPlugin = 1
            '';
          };
          which-key = {
            enable = true;
            settings = {
              spec = [
                {
                  __unkeyed-b = "<leader>b";
                  group = "Buffers";
                }
                {
                  __unkeyed-c = "<leader>c";
                  group = "Buffers";
                }
                {
                  __unkeyed-f = "<leader>f";
                  group = "Files";
                }
                {
                  __unkeyed-p = "<leader>p";
                  group = "Projects";
                }
                {
                  __unkeyed-y = "<leader>y";
                  group = "Yank";
                }
                {
                  __unkeyed-leader = "<leader><leader>";
                  group = "Misc";
                }
                {
                  __unkeyed-bang = "<leader>!";
                  group = "Spell Check";
                }
                {
                  __unkeyed-x = "<leader>x";
                  group = "Debug";
                }
              ];
            };
          };
          rainbow = {
            enable = true;
          };
          conform-nvim = {
            enable = true;
            settings = {
              formatters_by_ft.python = [ "ruff_format" ];
              formatters.ruff_format.command = "${pkgs.ruff}/bin/ruff";
              format_on_save = {
                timeout_ms = 500;
                lsp_format = "fallback";
              };
            };
          };
          highlight-colors.enable = true;
        };
        extraPlugins = with pkgs.vimPlugins; [
          vim-rsi
          vim-airline-themes
          (pkgs.vimUtils.buildVimPlugin rec {
            pname = "nvim-solarized";
            version = "3.6.0";
            src = pkgs.fetchFromGitHub rec {
              owner = "maxmx03";
              repo = "solarized.nvim";
              rev = "v${version}";
              sha256 = "sha256-fNytlDlYHqX1W1pqt8xLoud+AtMQDlmtUkbwZArj4bs=";
            };
          })
        ];
        extraPackages = with pkgs; [
          difftastic
        ];
        extraConfigLuaPre = ''
          get_selection = function()
            return vim.fn.getregion(
              vim.fn.getpos ".", vim.fn.getpos "v", { mode = vim.fn.mode() }
            )
          end
          vim.o.termguicolors = true
        '';
        extraConfigLua = ''
          require("telescope").load_extension("projects")
          local theme_file = vim.fn.stdpath("state"):gsub("/nvim$", "") .. "/theme-mode"
          local function sync_noctalia_theme()
            local file = io.open(theme_file, "r")
            local mode = file and file:read("*l") or "dark"
            if file then file:close() end
            if mode ~= "light" and mode ~= "dark" then return end
            if vim.g.noctalia_theme_mode == mode then return end
            vim.g.noctalia_theme_mode = mode
            vim.o.background = mode
            vim.cmd.colorscheme(mode == "light" and "solarized" or "${cfg.colorscheme}")
          end
          sync_noctalia_theme()
          local timer = vim.uv.new_timer()
          timer:start(2000, 2000, vim.schedule_wrap(sync_noctalia_theme))
          vim.api.nvim_create_autocmd("VimLeavePre", { callback = function() timer:close() end })
        '';
        dependencies = {
          git.enable = true;
          fzf.enable = true;
          ripgrep.enable = true;
          gcc.enable = true;
        };
      };
    }
    (mkIf cfg.viAlias {
      programs.zsh.shellAliases = {
        vi = "nvim";
      };
    })
  ]);
}
