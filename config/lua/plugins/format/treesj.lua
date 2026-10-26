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

    -- While the file tree is open, <C-j> goes to its next file instead, from the tree or the
    -- code, as <C-Down> does (myplugins/filetree.nvim; <C-k> is in mappings.lua)
    vim.keymap.set('n', '<C-j>', function()
      if not (package.loaded.filetree and require('filetree').step_file(vim.v.count1)) then
        treesj.toggle()
      end
    end, { desc = 'Next file in the tree while it is open, else treesj toggle' })
  end,
}
