local vim = vim

return {
  enabled = true,

  dir = vim.fn.stdpath('config') .. '/lua/myplugins/refs.nvim',

  keys = {
    {
      '<leader>r',
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

  -- Loaded at start, though the panel never opens by itself (only from the keys above and
  -- gf): it asks ahead where the cursor settles, so a first hop lands at once, and sees the
  -- servers attach. (A require(), as gf's and aerial's <Up>/<Down>, wouldn't load it:
  -- lazy.nvim takes a module's plugin from its path up to the first /lua/, here the
  -- config's own.)
  lazy = false,

  config = function()
    require('refs').setup()
  end,
}
