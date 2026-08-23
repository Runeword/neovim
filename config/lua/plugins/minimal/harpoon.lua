local vim = vim

return {
  'ThePrimeagen/harpoon',
  branch = 'harpoon2',
  enabled = true,

  dependencies = { 'nvim-lua/plenary.nvim' },

  config = function()
    local harpoon = require('harpoon')
    harpoon:setup()

    vim.keymap.set('n', '<Leader>c', function()
      harpoon:list():add()
    end, { desc = 'Harpoon: pin current file' })

    vim.keymap.set('n', '<Leader>j', function()
      harpoon.ui:toggle_quick_menu(harpoon:list())
    end, { desc = 'Harpoon: menu' })

    for i = 1, 4 do
      vim.keymap.set('n', '<Leader>' .. i, function()
        harpoon:list():select(i)
      end, { desc = 'Harpoon: file ' .. i })
    end
  end,
}
