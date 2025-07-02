local vim = vim

return {
  enabled = true,

  dir = vim.fn.stdpath('config') .. '/lua/myplugins/buffer-history.nvim',

  config = function()
    require('buffer_history').setup()

    -- Set up keymaps
    vim.keymap.set('n', '<C-t>', require('buffer_history').reopen_most_recent, {
      desc = 'Reopen most recently closed buffer',
      silent = true,
    })
  end,
} 