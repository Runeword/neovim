local vim = vim

return {
  'monkoose/neocodeium',
  event = 'VeryLazy',
  enabled = true,

  config = function()
    local neocodeium = require('neocodeium')
    neocodeium.setup({
      silent = true,
    })

    vim.keymap.set('i', '<C-CR>', neocodeium.accept)
    vim.keymap.set('i', '<C-w>', neocodeium.accept_word)
    -- Accept the suggestion's line, or with none showing go to end of line (readline <C-e>,
    -- see mappings.lua): accept_line alone does nothing then.
    vim.keymap.set('i', '<C-e>', function()
      if neocodeium.visible() then
        neocodeium.accept_line()
      else
        vim.api.nvim_feedkeys(vim.keycode('<End>'), 'in', false)
      end
    end)
  end,
}
