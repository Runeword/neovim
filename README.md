### Neovim

#### Standalone run

* Development mode :
  ```shell
  git clone git@github.com:Runeword/neovim.git && \
  cd neovim && NVIM_CONFIG_DIR="$PWD/config" nix run .#dev --impure
  ```

* Bundled mode :

  ```shell
  nix run "github:Runeword/neovim" \
  --option substituters "https://runeword-neovim.cachix.org" \
  --option trusted-public-keys "runeword-neovim.cachix.org-1:Vvtv02wnOz9tp/qKztc9JJaBc9gXDpURCAvHiAlBKZ4="
  ```

#### Home Manager

* Development mode :

  `flake.nix`
  ```nix
  inputs.runeword-neovim.url = "github:Runeword/neovim";
  ```

  `home.nix`
  ```nix
  home.packages = [
    (inputs.runeword-neovim.packages.${pkgs.system}.dev.options { configPath = "${config.home.homeDirectory}/neovim/config"; })
  ];
  ```

* Bundled mode :

  `flake.nix`
  ```nix
  nixConfig.extra-substituters = [ "https://runeword-neovim.cachix.org" ];
  nixConfig.extra-trusted-public-keys = [ "runeword-neovim.cachix.org-1:Vvtv02wnOz9tp/qKztc9JJaBc9gXDpURCAvHiAlBKZ4=" ];
  inputs.runeword-neovim.url = "github:Runeword/neovim";
  ```

  `home.nix`
  ```nix
  home.packages = [
    inputs.runeword-neovim.packages.${pkgs.system}.default
  ];
  ```
