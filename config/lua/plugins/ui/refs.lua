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
    -- (in the buffers aerial attaches to, its own <Up>/<Down> ask refs first too)
    {
      '<Up>',
      function()
        if not require('refs').go(-1) then
          vim.cmd('normal! ' .. vim.v.count1 .. 'k') -- no panel: a plain arrow
        end
      end,
      desc = 'Previous reference in the refs panel',
    },
    {
      '<Down>',
      function()
        if not require('refs').go(1) then
          vim.cmd('normal! ' .. vim.v.count1 .. 'j') -- no panel: a plain arrow
        end
      end,
      desc = 'Next reference in the refs panel',
    },
  },

  config = function()
    require('refs').setup()
  end,
}
