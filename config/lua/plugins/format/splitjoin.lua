local vim = vim

return {
  'AndrewRadev/splitjoin.vim',

  enabled = true,

  event = 'VeryLazy',

  config = function()
    vim.g.splitjoin_split_mapping = ''
    vim.g.splitjoin_join_mapping = ''

    vim.keymap.set('n', '<C-j>', '<cmd>silent SplitjoinJoin<CR>')
    vim.keymap.set('n', '<C-k>', '<cmd>silent SplitjoinSplit<CR>')
  end,
}
