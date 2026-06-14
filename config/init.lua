local vim = vim

require('autocmd')
require('options')
require('filetype')
require('mappings')

-- When wrapped by Nix, lazy.nvim itself is installed in the store
-- (flake.nix sets NVIM_LAZY_NVIM_PATH). Fall back to a git clone into
-- stdpath('data') for non-Nix entry points.
local lazypath = vim.env.NVIM_LAZY_NVIM_PATH or (vim.fn.stdpath('data') .. '/lazy/lazy.nvim')
if not vim.env.NVIM_LAZY_NVIM_PATH and not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    'git',
    'clone',
    '--filter=blob:none',
    '--single-branch',
    'https://github.com/folke/lazy.nvim.git',
    lazypath,
  })
end

vim.opt.runtimepath:prepend(lazypath)

local lazy_opts = {
  defaults = { lazy = false },
  -- install = { colorscheme = { 'tokyonight', 'habamax' } },
  -- checker = { enabled = true },

  performance = {
    rtp = {
      disabled_plugins = {
        'gzip',
        'matchit',
        'matchparen',
        'netrwPlugin',
        'tarPlugin',
        'tohtml',
        'tutor',
        'zipPlugin',
      },
    },
  },

  change_detection = {
    enabled = true,
    notify = false,
  },
}

-- When wrapped by Nix, NVIM_NIX_PLUGINS_DIR points at a directory of
-- pre-installed plugins (flake.nix: nix-plugins). lazy.nvim's `dev`
-- mechanism uses these in place of cloning from GitHub when a spec's
-- name matches a subdir there. `fallback = true` lets plugins not in
-- that dir continue to clone normally.
if vim.env.NVIM_NIX_PLUGINS_DIR then
  -- Build the pattern list from what's actually present in NVIM_NIX_PLUGINS_DIR.
  -- A blanket pattern like { '.' } also matches myplugins/* specs that use
  -- `dir = stdpath('config') .. '/lua/myplugins/<name>'`, and lazy.nvim's dev
  -- resolution would then overwrite their `dir` with NVIM_NIX_PLUGINS_DIR/<name>
  -- (which doesn't exist), silently disabling them.
  local patterns = {}
  for name in vim.fs.dir(vim.env.NVIM_NIX_PLUGINS_DIR) do
    table.insert(patterns, '^' .. vim.pesc(name) .. '$')
  end
  lazy_opts.dev = {
    path = vim.env.NVIM_NIX_PLUGINS_DIR,
    patterns = patterns,
    fallback = true,
  }
end

require('lazy').setup({
  { import = 'plugins' },
  { import = 'plugins.core' },
  { import = 'plugins.minimal' },
  { import = 'plugins.completion' },
  { import = 'plugins.textobjects' },
  { import = 'plugins.search' },
  { import = 'plugins.format' },
  { import = 'plugins.debug' },
  { import = 'plugins.move' },
  { import = 'plugins.ui' },
}, lazy_opts)

local viewConfig = require('lazy.view.config')

viewConfig.keys.details = 'o'
viewConfig.keys.close = '<Esc>'
viewConfig.keys.hover = 'o'
viewConfig.keys.diff = 'd'
viewConfig.keys.profile_sort = '<C-s>'
viewConfig.keys.profile_filter = '<C-f>'
viewConfig.keys.abort = '<C-c>'

viewConfig.commands.build.key_plugin = 'r'
