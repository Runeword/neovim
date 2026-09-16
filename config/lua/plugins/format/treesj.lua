local vim = vim

return {
  'Wansmer/treesj',

  enabled = true,

  dependencies = { 'nvim-treesitter/nvim-treesitter' },

  config = function()
    local treesj = require('treesj')

    treesj.setup({
      max_join_length = 120,
      use_default_keymaps = false,
    })

    vim.keymap.set('n', '<C-j>', treesj.toggle, { desc = 'treesj toggle' })
  end,
}
