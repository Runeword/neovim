local vim = vim

return {
  enabled = true,

  dir = vim.fn.stdpath('config') .. '/lua/myplugins/gl.nvim',

  keys = {
    {
      '<leader>gl',
      function()
        require('gl').open()
      end,
      desc = "git log: the shell's gl picker (~/terminal)",
    },
    {
      '<leader>gdc',
      function()
        require('gl').open('staged')
      end,
      desc = "git diff --cached: the shell's gdc picker (~/terminal)",
    },
  },
}
