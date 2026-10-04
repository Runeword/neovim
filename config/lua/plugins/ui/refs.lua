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

  -- Loaded at start, as the panel opens then. (A require() wouldn't load it: lazy.nvim
  -- takes a module's plugin from its path up to the first /lua/, here the config's own.)
  lazy = false,

  config = function()
    require('refs').setup()
    -- The panel opens at start, beside the file (not beside a man page, help or a diff,
    -- nor in a run without a UI, as headless)
    vim.api.nvim_create_autocmd('UIEnter', {
      group = vim.api.nvim_create_augroup('refs_start', { clear = true }),
      once = true,
      callback = function()
        if vim.bo.buftype == '' and not vim.wo.diff then
          require('refs').open()
        end
      end,
    })
  end,
}
