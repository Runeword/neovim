# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A reproducible Neovim setup packaged as a Nix flake. Two layers work together:

1. **Nix layer** (`flake.nix`) — provides the Neovim binary, every LSP/formatter/linter on `PATH`, and *pre-installs every plugin into the Nix store*. It then wraps `nvim` with env vars that point the Lua layer at those store paths.
2. **Lua layer** (`config/`) — the actual Neovim config, managed by lazy.nvim with ordinary Lua specs. This is what you edit day-to-day.

## Commands

Entering the directory auto-loads the dev shell via direnv (`.envrc` = `use flake`); otherwise run `nix develop`. Inside the shell:

- `dev` — run Neovim in **dev mode** (config symlinked into the store; edits to `config/` apply on next launch with no rebuild). Wraps `NVIM_CONFIG_DIR="$PWD/config" nix run .#dev --impure`.
- `bdl` — run Neovim in **bundled mode** (config copied into the store; fully isolated, requires a rebuild to pick up config changes). Wraps `nix run .`.
- `h` — print the dev/bdl/help reminder.
- `nix build .` — build the bundled package. This is also the entire CI check (see `.github/workflows/neovim.yml`); there is no Lua unit-test suite (neotest is disabled).

Use **dev mode** while iterating on Lua config. Use **bundled mode** (or `nix build`) to validate that a `flake.nix` change actually builds.

### Formatting

- Lua: `stylua` (config at `config/.stylua.toml` + `config/editorconfig` — 2-space indent, single quotes, max line 120, trailing table separator always).
- Nix: `nixfmt` (nixfmt-rfc-style).

`stylua` and `nixfmt-rfc-style` are in the dev shell. Commits run remote lefthook hooks (`lefthook.yml` → `Runeword/lefthook`) that auto-format Lua and Nix and auto-generate the commit message.

## How the Nix ↔ lazy.nvim bridge works

This is the core mechanism and touches multiple files:

- `flake.nix` builds `nix-plugins`, a directory of symlinks to each plugin in the Nix store, and exposes it as `$NVIM_NIX_PLUGINS_DIR`.
- `config/init.lua` reads that env var and configures lazy.nvim's `dev` feature: any plugin spec whose name matches a subdir in `$NVIM_NIX_PLUGINS_DIR` loads from the store instead of cloning from GitHub. `fallback = true` lets anything not in the store clone normally.
- **The store subdir name must exactly match lazy.nvim's derived spec name** — the part after `/` in the GitHub spec, case-sensitive (e.g. spec `'lewis6991/gitsigns.nvim'` → subdir `gitsigns.nvim`). Nix's own `pname` often differs (`gitsigns-nvim`), so the symlinks in `flake.nix` are named explicitly. Get this wrong and the plugin silently falls back to cloning.

### Adding or updating a plugin

1. Add/edit the lazy.nvim spec under `config/lua/plugins/<category>/`.
2. Add a matching `ln -s ${pkgs.vimPlugins.<name>} $out/<spec-name>` line in the `nix-plugins` derivation in `flake.nix`.
3. If the plugin is **not in nixpkgs** (or is mis-tagged unfree), add it to `custom-plugins` in `flake.nix` via `fetchFromGitHub` first (needs `rev` + `hash`; reference commits live in `config/lazy-lock.json`), then symlink that.
4. Rebuild: relaunch `dev`, or `nix build` to verify.

`custom-plugins` deliberately uses `fetchFromGitHub` rather than `vimUtils.buildVimPlugin` — the latter runs a `require()`-check at build time that fails for plugins needing runtime state. The flake.nix comments document several such gotchas (the treesitter-textobjects queries-only workaround, the shared `mini.nvim` source linked under multiple names, the neotest `doCheck` override); read them before touching that file.

### Adding an LSP / formatter / linter

LSP servers and CLI tools are **not** installed by Lua/Mason — they come from the `lib.makeBinPath [...]` list in `flake.nix`'s wrapper. To add one:

1. Add the package to that list in `flake.nix`.
2. Register it in `config/lua/plugins/core/lspconfig.lua` with `vim.lsp.config(<name>, set_config(...))` + `vim.lsp.enable(<name>)`.

LSP setup uses the Neovim 0.11+ `vim.lsp.config`/`vim.lsp.enable` API (not the old `lspconfig` framework). `set_config()` merges per-server overrides over shared defaults (cmp capabilities + an `on_attach` that sets the `gh`/`gd`/`gr`/… keymaps). Pass `on_attach_server(false)` to disable a server's formatting (formatting is delegated to conform.nvim).

## Config layout

- `config/init.lua` — entry point. Loads core modules (`autocmd`, `options`, `filetype`, `mappings`), bootstraps lazy.nvim, wires up the `$NVIM_*` dev paths, then imports plugin groups. (`config/init-scrollback.lua` is a separate slimmed-down entry point with a plugin subset; not used by the flake.)
- `config/lua/{options,mappings,autocmd,filetype}.lua` — core editor config. Leader is `<Space>`.
- `config/lua/functions.lua` — a module table `M` of custom editor helpers, consumed as `require('functions').<fn>` (mostly from `mappings.lua`).
- `config/lua/plugins/<category>/*.lua` — plugin specs, grouped into `core`, `minimal`, `completion`, `textobjects`, `search`, `format`, `debug`, `move`, `ui`. `init.lua` imports each group with `{ import = 'plugins.<category>' }`, so **every file in a category dir is auto-loaded** — no central registry to update.
- `config/lua/myplugins/<name>.nvim/` — first-party plugins (appender, buffer-history, checker, grasp, putter, undotree). Their specs load locally via `dir = vim.fn.stdpath('config') .. '/lua/myplugins/<name>'`, which is why `init.lua` builds the dev `patterns` list from real store subdirs instead of a blanket `.` (a blanket pattern would clobber these `dir=` specs).
- `config/after/plugin/colors.lua` — highlight overrides applied after plugins load.

### Plugin spec conventions

- Each spec file begins with `local vim = vim` and `return`s a lazy.nvim spec table (or a list of them).
- A spec is disabled with `enabled = false` (kept in-tree and still symlinked in `flake.nix` so re-enabling is a one-line toggle; ~20 specs are currently parked this way).
- `config/lazy-lock.json` is a *reference* for pinned commits — actual versions are pinned by Nix, not by lazy.nvim's lockfile.
