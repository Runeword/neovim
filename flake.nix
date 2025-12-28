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
          overlays = [
            inputs.neovim-nightly-overlay.overlays.default
          ];
        };

        neovim-override = pkgs.neovim.override {
          # withPython3 = true;
          # withNodeJs = true;
          # package = pkgs.neovim-nightly;
        };

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
