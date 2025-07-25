local vim = vim

return {
  'mikavilpas/yazi.nvim',
  event = 'VeryLazy',
  enabled = false,
  keys = {
    {
      '<leader>y',
      '<cmd>Yazi<cr>',
      desc = 'Open yazi at the current file',
    },
  },
  opts = {
    keymaps = {
    },
  },
}
