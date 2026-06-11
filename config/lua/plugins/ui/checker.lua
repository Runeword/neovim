local vim = vim

return {
  enabled = true,

  -- 'Runeword/checker.nvim',

  dir = vim.fn.stdpath('config') .. '/lua/myplugins/checker.nvim',

  config = function()
    require('checker').setup()
    vim.keymap.set('n', '<PageUp>', require('checker').prevDiagnostic, { silent = true, desc = 'Previous diagnostic' })
    vim.keymap.set('n', '<PageDown>', require('checker').nextDiagnostic, { silent = true, desc = 'Next diagnostic' })
  end,
}
