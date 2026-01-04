local vim = vim

require('autocmd')
require('options')
require('filetype')
require('mappings')

local lazypath = vim.fn.stdpath('data') .. '/lazy/lazy.nvim'
if not vim.loop.fs_stat(lazypath) then
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

require('lazy').setup({
  { import = 'plugins.core' },
  { import = 'plugins.minimal.init' },
  { import = 'plugins.minimal.baleia' },
  { import = 'plugins.minimal.putter' },
  { import = 'plugins.minimal.spider' },
  { import = 'plugins.minimal.appender' },
  { import = 'plugins.minimal.asterisk' },
  { import = 'plugins.minimal.autosave' },
  { import = 'plugins.minimal.highlightundo' },
  { import = 'plugins.minimal.highlightedyank' },
  { import = 'plugins.completion.cmp' },
  { import = 'plugins.completion.neocodeium' },
  { import = 'plugins.textobjects.miniai' },
  { import = 'plugins.textobjects.comment' },
  { import = 'plugins.textobjects.surroundfunk' },
  { import = 'plugins.textobjects.vimtextobjuser' },
  { import = 'plugins.textobjects.varioustextobjs' },
  { import = 'plugins.search.numb' },
  { import = 'plugins.search.searchpulse' },
  { import = 'plugins.format.dial' },
  { import = 'plugins.format.abolish' },
  { import = 'plugins.format.surround' },
  { import = 'plugins.format.autopairs' },
  { import = 'plugins.format.splitjoin' },
  { import = 'plugins.format.stayinplace' },
  { import = 'plugins.move.flash' },
  { import = 'plugins.move.grasp' },
  { import = 'plugins.move.matchup' },
  { import = 'plugins.move.sideways' },
  { import = 'plugins.ui.notify' },
  { import = 'plugins.ui.checker' },
  { import = 'plugins.ui.lualine' },
  { import = 'plugins.ui.livecommand' },
  { import = 'plugins.ui.smearcursor' },
  { import = 'plugins.ui.localhighlight' },
  { import = 'plugins.ui.highlightcolors' },
}, {
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
})

local viewConfig = require('lazy.view.config')

viewConfig.keys.details = 'o'
viewConfig.keys.close = '<Esc>'
viewConfig.keys.hover = 'o'
viewConfig.keys.diff = 'd'
viewConfig.keys.profile_sort = '<C-s>'
viewConfig.keys.profile_filter = '<C-f>'
viewConfig.keys.abort = '<C-c>'

viewConfig.commands.build.key_plugin = 'r'
