local vim = vim

return {
  enabled = true,

  -- 'Runeword/appender.nvim',

  dir = vim.fn.stdpath('config') .. '/lua/myplugins/appender.nvim',

  config = function()
    require('appender').setup()
    vim.keymap.set(
      { 'x', 'n' },
      'ga',
      require('appender').appendCharEndLine,
      { expr = true, desc = 'Append char at end of line' }
    )
    vim.keymap.set(
      { 'x', 'n' },
      'gi',
      require('appender').appendCharStartLine,
      { expr = true, desc = 'Append char at start of line' }
    )
    vim.keymap.set(
      { 'n' },
      'go',
      require('appender').appendNewlineBelow,
      { expr = true, desc = 'Append newline below' }
    )
    vim.keymap.set(
      { 'n' },
      'gO',
      require('appender').appendNewlineAbove,
      { expr = true, desc = 'Append newline above' }
    )
  end,
}
