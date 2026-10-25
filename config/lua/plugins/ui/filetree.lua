local vim = vim

return {
  enabled = true,

  dir = vim.fn.stdpath('config') .. '/lua/myplugins/filetree.nvim',

  keys = {
    {
      '<leader>e',
      function()
        require('filetree').toggle()
      end,
      desc = 'File tree',
    },
  },

  -- Loaded at start, as the tree can open then
  lazy = false,

  config = function()
    require('filetree').setup()
    -- At start, the tree never opens by itself (only from <leader>e), but on a directory
    -- (nvim .) it takes the place of its listing; not in a run without a UI, as headless
    vim.api.nvim_create_autocmd('UIEnter', {
      group = vim.api.nvim_create_augroup('filetree_start', { clear = true }),
      once = true,
      callback = function()
        require('filetree').start()
      end,
    })
  end,
}
