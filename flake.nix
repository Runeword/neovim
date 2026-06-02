{
  description = "My neovim flake";

  # Enable binary cache from nix-community to download pre-built packages,
  # such as neovim-nightly-overlay, instead of building them locally.
  nixConfig.extra-substituters = [
    "https://nix-community.cachix.org"
  ];
  nixConfig.extra-trusted-public-keys = [
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
  ];

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  # Required to creates outputs for all supported systems
  inputs.flake-utils.url = "github:numtide/flake-utils";

  inputs.neovim-nightly-overlay.url = "github:nix-community/neovim-nightly-overlay";
  inputs.neovim-nightly-overlay.inputs.nixpkgs.follows = "nixpkgs";

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }@inputs:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          # A handful of vim plugins (vim-textobj-line, vim-textobj-comment,
          # …) are mistakenly tagged unfree in nixpkgs even though they ship
          # under permissive licenses. allowUnfree avoids rebuilding them
          # from source just to bypass the gate.
          config.allowUnfree = true;
          overlays = [
            inputs.neovim-nightly-overlay.overlays.default
          ];
        };

        neovim-override = pkgs.neovim.override {
          # withPython3 = true;
          # withNodeJs = true;
          # package = pkgs.neovim-nightly;
        };

        # Textobject queries (`queries/<lang>/textobjects.scm`) come from
        # nvim-treesitter-textobjects. We can't load that plugin's Lua —
        # it still imports the removed `nvim-treesitter.configs` module —
        # so we expose only `queries/` and add it to runtimepath. mini.ai's
        # `gen_spec.treesitter()` picks up the queries automatically.
        ts-textobjects-queries = pkgs.runCommandLocal "nvim-ts-textobjects-queries" { } ''
          mkdir -p $out
          ln -s ${pkgs.vimPlugins.nvim-treesitter-textobjects}/queries $out/queries
        '';

        # Plugins not in nixpkgs — fetched directly from GitHub. We use
        # fetchFromGitHub instead of vimUtils.buildVimPlugin because the
        # latter runs a require()-check on every Lua module at build time,
        # which fails for plugins whose submodules expect runtime state
        # (a codeium binary, network, etc.). fetchFromGitHub gives us the
        # raw source dir which is exactly what lazy.nvim's `dev.path`
        # expects — same on-disk shape as `pkgs.vimPlugins.*` outputs.
        #
        # Commits taken from config/lazy-lock.json so versions stay aligned
        # with the previous lazy.nvim-managed install. Bump these (and
        # re-prefetch hashes) when you want to update.
        custom-plugins = {
          printer-nvim = pkgs.fetchFromGitHub {
            owner = "rareitems";
            repo = "printer.nvim";
            rev = "bdd5310075f9d4fe5d4270b7dc75188347fa9353";
            hash = "sha256-qMe4q7y91yXKTKt77cwsSzgSCPr85ZWC9u4hHTnyvuQ=";
          };
          yank-assassin = pkgs.fetchFromGitHub {
            owner = "svban";
            repo = "YankAssassin.vim";
            rev = "55ce478a08333c086bcccdf087453085f85854d4";
            hash = "sha256-xuQ60dTv+GjU904SB+Nt3tclbNsOycZurdtYZWciD3A=";
          };
          stay-in-place-nvim = pkgs.fetchFromGitHub {
            owner = "gbprod";
            repo = "stay-in-place.nvim";
            rev = "0628b6db8970fc731abf9608d6f80659b58932c9";
            hash = "sha256-Cq9/JQoxuUiAQPobiSizwmvdxJRjE7XjG47A38wdVwY=";
          };
          vim-surround-funk = pkgs.fetchFromGitHub {
            owner = "Matt-A-Bennett";
            repo = "vim-surround-funk";
            rev = "688b9c945b66641dab8e355f6ae8f894aa4d842a";
            hash = "sha256-UChiJUU1bSoagnla0+OK5HP0+DYDrO0KZkyNvxnpgtY=";
          };
          vim-textobj-chainmember = pkgs.fetchFromGitHub {
            owner = "D4KU";
            repo = "vim-textobj-chainmember";
            rev = "f14a151c42a14e18a298aec7d943a3c7f43161dc";
            hash = "sha256-AIKtzG9ZTx11wwD7w814lZ3lxacVWbj03byGbIcx0Q4=";
          };
          neocodeium = pkgs.fetchFromGitHub {
            owner = "monkoose";
            repo = "neocodeium";
            rev = "a1f73887af6cc4b09cb15cc96e0b72d7932552a5";
            hash = "sha256-4IejQ1dQVfmngyF7hUrQ3XXZsHWbuBm3tFDn4hUM/sA=";
          };
          # In nixpkgs but marked unfree (license-metadata quirk).
          vim-textobj-line = pkgs.fetchFromGitHub {
            owner = "kana";
            repo = "vim-textobj-line";
            rev = "1a6780d29adcf7e464e8ddbcd0be0a9df1a37339";
            hash = "sha256-h7c6PMg4rJMH1f+NibOuQW/ComTmtCMpkCqntezwKTY=";
          };
          ts-node-action = pkgs.fetchFromGitHub {
            owner = "ckolkey";
            repo = "ts-node-action";
            rev = "6d3b60754fd87963d70eadaa2f77873b447eac26";
            hash = "sha256-kOXH3r+V+DAxoATSnZepEAekrkO1TezKSkONuQ3Kzu4=";
          };
          local-highlight-nvim = pkgs.fetchFromGitHub {
            owner = "tzachar";
            repo = "local-highlight.nvim";
            rev = "dd8ae2ca26a5cfa17fb598864eacbe2df63938f3";
            hash = "sha256-ApsyPsCECN6V0dRL9BCQZBgktyGDxpHu2aACujJ3Wus=";
          };
          gitgraph-nvim = pkgs.fetchFromGitHub {
            owner = "isakbm";
            repo = "gitgraph.nvim";
            rev = "01e466b32c346a165135dd47d42f1244eca06572";
            hash = "sha256-d55IRrOhK5tSLo2boSuMhDbkerqij5AHgNDkwtGadyI=";
          };
        };

        # All active plugins installed via Nix. The wrapper points lazy.nvim's
        # `dev.path` at this directory; any spec whose `name` matches a subdir
        # here uses the Nix copy instead of cloning from GitHub.
        #
        # Subdir names MUST match lazy.nvim's derived spec name — the part
        # after `/` in the GitHub spec, exact case. Nix's `pname` often
        # differs (`gitsigns-nvim` vs `gitsigns.nvim`), so we link explicitly.
        # echasnovski/mini.* all share one source — same derivation linked thrice.
        nix-plugins = pkgs.runCommandLocal "nvim-nix-plugins" { } ''
          mkdir -p $out

          # ---- treesitter (grammars bundled via withAllGrammars) ----
          # nvim-treesitter-textobjects is NOT installed as a plugin here:
          # its `plugin/*.vim` still calls require('nvim-treesitter.configs'),
          # which the new nvim-treesitter rewrite removed. Its query files
          # are made available via $NVIM_TS_TEXTOBJECTS_QUERIES; mini.ai
          # consumes them via gen_spec.treesitter().
          ln -s ${pkgs.vimPlugins.nvim-treesitter.withAllGrammars} $out/nvim-treesitter

          # ---- LSP / completion ----
          ln -s ${pkgs.vimPlugins.nvim-lspconfig} $out/nvim-lspconfig
          ln -s ${pkgs.vimPlugins.nvim-cmp}       $out/nvim-cmp
          ln -s ${pkgs.vimPlugins.cmp-nvim-lsp}   $out/cmp-nvim-lsp
          ln -s ${pkgs.vimPlugins.cmp-buffer}     $out/cmp-buffer
          ln -s ${pkgs.vimPlugins.cmp-cmdline}    $out/cmp-cmdline
          ln -s ${pkgs.vimPlugins.cmp-path}       $out/cmp-path
          ln -s ${pkgs.vimPlugins.cmp_luasnip}    $out/cmp_luasnip
          ln -s ${pkgs.vimPlugins.luasnip}        $out/LuaSnip
          ln -s ${custom-plugins.neocodeium}      $out/neocodeium

          # ---- common dependencies ----
          ln -s ${pkgs.vimPlugins.plenary-nvim}      $out/plenary.nvim
          ln -s ${pkgs.vimPlugins.nvim-web-devicons} $out/nvim-web-devicons

          # ---- git / diff ----
          ln -s ${pkgs.vimPlugins.gitsigns-nvim} $out/gitsigns.nvim
          ln -s ${pkgs.vimPlugins.diffview-nvim} $out/diffview.nvim

          # ---- format / pairs / surround ----
          ln -s ${pkgs.vimPlugins.conform-nvim}      $out/conform.nvim
          ln -s ${pkgs.vimPlugins.nvim-autopairs}    $out/nvim-autopairs
          ln -s ${pkgs.vimPlugins.nvim-ts-autotag}   $out/nvim-ts-autotag
          ln -s ${pkgs.vimPlugins.nvim-surround}     $out/nvim-surround
          ln -s ${custom-plugins.vim-surround-funk}  $out/vim-surround-funk
          ln -s ${pkgs.vimPlugins.splitjoin-vim}     $out/splitjoin.vim
          ln -s ${pkgs.vimPlugins.dial-nvim}         $out/dial.nvim
          ln -s ${pkgs.vimPlugins.vim-abolish}       $out/vim-abolish
          ln -s ${pkgs.vimPlugins.sort-nvim}         $out/sort.nvim
          ln -s ${custom-plugins.stay-in-place-nvim} $out/stay-in-place.nvim

          # ---- text objects ----
          ln -s ${pkgs.vimPlugins.mini-nvim}                 $out/mini.ai
          ln -s ${pkgs.vimPlugins.mini-nvim}                 $out/mini.align
          ln -s ${pkgs.vimPlugins.mini-nvim}                 $out/mini.indentscope
          ln -s ${pkgs.vimPlugins.nvim-various-textobjs}     $out/nvim-various-textobjs
          ln -s ${pkgs.vimPlugins.comment-nvim}              $out/Comment.nvim
          ln -s ${pkgs.vimPlugins.vim-textobj-user}          $out/vim-textobj-user
          ln -s ${custom-plugins.vim-textobj-line}           $out/vim-textobj-line
          ln -s ${pkgs.vimPlugins.vim-textobj-comment}       $out/vim-textobj-comment
          ln -s ${custom-plugins.vim-textobj-chainmember}    $out/vim-textobj-chainmember

          # ---- move / search ----
          ln -s ${pkgs.vimPlugins.fzf-lua}          $out/fzf-lua
          ln -s ${pkgs.vimPlugins.flash-nvim}       $out/flash.nvim
          ln -s ${pkgs.vimPlugins.nvim-spider}      $out/nvim-spider
          ln -s ${pkgs.vimPlugins.vim-matchup}      $out/vim-matchup
          ln -s ${pkgs.vimPlugins.sideways-vim}     $out/sideways.vim
          ln -s ${pkgs.vimPlugins.numb-nvim}        $out/numb.nvim
          ln -s ${pkgs.vimPlugins.vim-asterisk}     $out/vim-asterisk
          ln -s ${pkgs.vimPlugins.vim-search-pulse} $out/vim-search-pulse

          # ---- UI ----
          ln -s ${pkgs.vimPlugins.bufferline-nvim}      $out/bufferline.nvim
          ln -s ${pkgs.vimPlugins.lualine-nvim}         $out/lualine.nvim
          ln -s ${pkgs.vimPlugins.nvim-notify}          $out/nvim-notify
          ln -s ${pkgs.vimPlugins.aerial-nvim}          $out/aerial.nvim
          ln -s ${pkgs.vimPlugins.nvim-highlight-colors} $out/nvim-highlight-colors
          ln -s ${pkgs.vimPlugins.highlight-undo-nvim}  $out/highlight-undo.nvim
          ln -s ${pkgs.vimPlugins.vim-highlightedyank} $out/vim-highlightedyank
          ln -s ${pkgs.vimPlugins.smear-cursor-nvim}    $out/smear-cursor.nvim
          ln -s ${pkgs.vimPlugins.live-command-nvim}    $out/live-command.nvim
          ln -s ${pkgs.vimPlugins.baleia-nvim}          $out/baleia.nvim
          ln -s ${pkgs.vimPlugins.nightfly}             $out/vim-nightfly-colors

          # ---- misc / quality of life ----
          ln -s ${pkgs.vimPlugins.flatten-nvim}      $out/flatten.nvim
          ln -s ${pkgs.vimPlugins.mkdir-nvim}        $out/mkdir.nvim
          ln -s ${pkgs.vimPlugins.project-nvim}      $out/project.nvim
          ln -s ${pkgs.vimPlugins.vim-auto-save}     $out/vim-auto-save
          ln -s ${pkgs.vimPlugins.vim-exchange}      $out/vim-exchange
          ln -s ${custom-plugins.printer-nvim}       $out/printer.nvim
          ln -s ${custom-plugins.yank-assassin}      $out/YankAssassin.vim

          # ---- currently disabled (enabled = false) but kept ready in Nix
          # so re-enabling is a one-line spec toggle. Excludes intentionally
          # dead alternatives: mason*, coq_nvim, codeium.{vim,nvim}, gp.nvim.
          # Excludes anuvyklack/hydra.nvim (archived; collides with nvimtools fork).
          ln -s ${pkgs.vimPlugins.ssr-nvim}                 $out/ssr.nvim
          ln -s ${pkgs.vimPlugins.grug-far-nvim}            $out/grug-far.nvim
          ln -s ${pkgs.vimPlugins.treesj}                   $out/treesj
          ln -s ${pkgs.vimPlugins.vim-table-mode}           $out/vim-table-mode
          ln -s ${custom-plugins.ts-node-action}            $out/ts-node-action
          ln -s ${pkgs.vimPlugins.nvim-dap}                 $out/nvim-dap
          ln -s ${pkgs.vimPlugins.nvim-dap-go}              $out/nvim-dap-go
          ln -s ${pkgs.vimPlugins.nvim-dap-virtual-text}    $out/nvim-dap-virtual-text
          ln -s ${pkgs.vimPlugins.one-small-step-for-vimkind} $out/one-small-step-for-vimkind
          ln -s ${pkgs.vimPlugins.sniprun}                  $out/sniprun
          ln -s ${
            pkgs.vimPlugins.neotest.overrideAttrs (_: {
              # Upstream nixpkgs build runs neotest's own test harness which
              # exits non-zero even when all tests pass. neotest is currently
              # disabled in this config; skip the check entirely.
              doCheck = false;
              doInstallCheck = false;
              checkPhase = "true";
              installCheckPhase = "true";
            })
          } $out/neotest
          ln -s ${pkgs.vimPlugins.neotest-go}               $out/neotest-go
          ln -s ${pkgs.vimPlugins.nvim-nio}                 $out/nvim-nio
          ln -s ${pkgs.vimPlugins.hydra-nvim}               $out/hydra.nvim
          ln -s ${pkgs.vimPlugins.nvim-ufo}                 $out/nvim-ufo
          ln -s ${pkgs.vimPlugins.promise-async}            $out/promise-async
          ln -s ${pkgs.vimPlugins.yazi-nvim}                $out/yazi.nvim
          ln -s ${pkgs.vimPlugins.markview-nvim}            $out/markview.nvim
          ln -s ${pkgs.vimPlugins.nvim-lightbulb}           $out/nvim-lightbulb
          ln -s ${custom-plugins.local-highlight-nvim}      $out/local-highlight.nvim
          ln -s ${pkgs.vimPlugins.virt-column-nvim}         $out/virt-column.nvim
          ln -s ${custom-plugins.gitgraph-nvim}             $out/gitgraph.nvim
        '';

        wrapper = with pkgs; ''
          rm $out/bin/nvim
          makeWrapper ${neovim-override}/bin/nvim $out/bin/nvim --prefix PATH : ${
            lib.makeBinPath [
              fzf
              sox
              typescript-language-server
              bash-language-server
              eslint
              eslint_d
              biome
              vue-language-server
              pyright
              vscode-langservers-extracted
              yaml-language-server
              lua-language-server
              selene
              marksman
              ccls
              nil
              alejandra
              nixfmt-rfc-style
              shfmt
              shellcheck
              shellharden
              terraform-ls
              gopls
              delve
              rust-analyzer
              taplo
              black
              isort
              stylua
              harper
              jsonnet-language-server
              # typos-lsp
            ]
          } \
          --set NVIM_NIX_PLUGINS_DIR ${nix-plugins} \
          --set NVIM_LAZY_NVIM_PATH ${pkgs.vimPlugins.lazy-nvim} \
          --set NVIM_TS_TEXTOBJECTS_QUERIES ${ts-textobjects-queries} \
          --set XDG_CONFIG_HOME "$out/.config"
        '';

        neovim-dev =
          {
            configPath ? builtins.getEnv "NVIM_CONFIG_DIR",
          }:
          pkgs.symlinkJoin {
            name = "nvim";
            paths = [ neovim-override ];
            buildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              mkdir -p $out/.config
              ln -sf ${configPath} $out/.config/nvim
              ${wrapper}
            '';
          };

        neovim = pkgs.symlinkJoin {
          name = "nvim";
          paths = [ neovim-override ];
          buildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            mkdir -p $out/.config
            cp -r ${./config} $out/.config/nvim
            ${wrapper}
          '';
        };
      in
      {
        # Bundled mode
        apps.default.type = "app";
        apps.default.program = "${neovim}/bin/nvim";
        packages.default = neovim;

        # Dev mode
        apps.dev.type = "app";
        apps.dev.program = "${neovim-dev { }}/bin/nvim";
        packages.dev.default = neovim-dev { };
        packages.dev.options = neovim-dev;

        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.stylua
            pkgs.nixfmt-rfc-style
            (pkgs.writeShellScriptBin "dev" ''
              NVIM_CONFIG_DIR="$PWD/config" nix run .#dev --impure "$@"
            '')
            (pkgs.writeShellScriptBin "h" ''
              echo "type 'dev' to run neovim in development mode"
              echo "type 'bdl' to run neovim in bundled mode"
              echo "type 'h' for help"
            '')
            (pkgs.writeShellScriptBin "bdl" ''
              nix run . "$@"
            '')
          ];
          shellHook = ''
            h
          '';
        };
      }
    );
}
