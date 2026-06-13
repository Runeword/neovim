local vim = vim

return {
  'bluz71/vim-nightfly-colors',

  -- Highlight overrides live in after/plugin/colors.lua.

  config = function()
    vim.cmd.colorscheme('nightfly')
  end,

  lazy = false,

  priority = 1000,

  init = function()
    vim.g.nightflyTerminalColors = false
    vim.g.nightflyItalics = false
  end,
}
