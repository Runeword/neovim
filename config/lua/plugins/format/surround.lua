return {
  'kylechui/nvim-surround',
  enabled = true,

  init = function()
    vim.g.nvim_surround_no_mappings = true
  end,

  config = function()
    require('nvim-surround').setup({})
    vim.keymap.set('n', 's', '<Plug>(nvim-surround-normal)')
    vim.keymap.set('n', 'ds', '<Plug>(nvim-surround-delete)')
    vim.keymap.set('n', 'cs', '<Plug>(nvim-surround-change)')
    vim.keymap.set('n', 'cS', '<Plug>(nvim-surround-change-line)')
    vim.keymap.set('x', 's', '<Plug>(nvim-surround-visual)')
  end,
}
