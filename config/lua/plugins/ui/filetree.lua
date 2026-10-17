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

  -- Loaded at start, as the tree opens then
  lazy = false,

  config = function()
    require('filetree').setup()
    -- At start, the tree opens beside the file if it's one of the working directory's (not
    -- a commit message, a temporary file), when Neovim starts without a file, or on a
    -- directory (nvim .); not beside a man page, help or a diff, nor in a run without a UI,
    -- as headless
    vim.api.nvim_create_autocmd('UIEnter', {
      group = vim.api.nvim_create_augroup('filetree_start', { clear = true }),
      once = true,
      callback = function()
        require('filetree').start()
      end,
    })
  end,
}
