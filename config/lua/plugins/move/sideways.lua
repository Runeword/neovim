local vim = vim

return {
  'AndrewRadev/sideways.vim',
  enabled = true,

  event = 'VeryLazy',

  config = function()
    -- <Left>/<Right> hop between symbols with references (plugins/ui/trouble.lua)
    -- vim.keymap.set('n', '<Left>', '<cmd>SidewaysJumpLeft<CR>')
    -- vim.keymap.set('n', '<Right>', '<cmd>SidewaysJumpRight<CR>')
    vim.keymap.set('n', '<S-Left>', '<cmd>SidewaysLeft<CR>')
    vim.keymap.set('n', '<S-Right>', '<cmd>SidewaysRight<CR>')
  end,
}
