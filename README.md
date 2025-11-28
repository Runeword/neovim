# Neovim reproducible setup
- LSPs are installed through nixpkgs.   
- Neovim plugins are managed with lazy.nvim.   
- Neovim configuration use lua for mainstream development experience.

## Development mode
- When running in development mode, the Neovim configuration is symlinked to the Nix store.   
This approach streamlines development, allowing you to apply configuration changes immediately without having to rebuild the flake.

### Standalone run
Run the `dev` app :

  ```shell
  git clone git@github.com:Runeword/neovim.git && \
  cd neovim && nix develop && dev
  ```

### Home-manager install
Install the `dev` package with home-manager :

  `flake.nix`
  ```nix
  inputs.runeword-neovim.url = "github:Runeword/neovim";
  ```

  `home.nix`
  ```nix
  home.packages = [
    (inputs.runeword-neovim.packages.${pkgs.stdenv.hostPlatform.system}.dev.options { configPath = "${config.home.homeDirectory}/neovim/config"; })
  ];
  ```

## Bundled mode
- In bundled mode, the Neovim configuration is copied into the Nix store.   
This ensures that both the flake and its Neovim configuration are fully isolated from your local environment.   
However, any changes to the Neovim configuration require rebuilding the flake before they take effect.   
- We use Cachix to provide ready-to-use Neovim binaries, so you can start using Neovim instantly without building it from source.

### Standalone run
Run the `default` app :

  ```shell
  nix run "github:Runeword/neovim" \
  --option substituters "https://runeword-neovim.cachix.org" \
  --option trusted-public-keys "runeword-neovim.cachix.org-1:Vvtv02wnOz9tp/qKztc9JJaBc9gXDpURCAvHiAlBKZ4="
  ```

### Home-manager install
Install the `default` package with home-manager :

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

> **Cachix**   
> - This repository contains 1 github actions workflow that automatically builds the neovim flake on Linux and MacOS environments.   
> - A new build is triggered whenever flake.nix or flake.lock changes.   
> - Build artifacts are uploaded to Cachix (a binary cache service) so subsequent builds can fetch pre-built binaries instead of rebuilding them from source.   
