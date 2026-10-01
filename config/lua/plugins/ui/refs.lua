local vim = vim

return {
  enabled = true,

  dir = vim.fn.stdpath('config') .. '/lua/myplugins/refs.nvim',

  keys = {
    {
      'gF',
      function()
        require('refs').toggle()
      end,
      desc = 'References panel (follows cursor)',
    },
    {
      '<Left>',
      function()
        require('refs').hop(-1)
      end,
      desc = 'Previous symbol with references',
    },
    {
      '<Right>',
      function()
        require('refs').hop(1)
      end,
      desc = 'Next symbol with references',
    },
  },

  config = function()
    require('refs').setup()
  end,
}
