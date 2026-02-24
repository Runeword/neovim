local vim = vim

return {
  enabled = true,

  'chrisgrieser/nvim-spider',

  config = function()
    vim.keymap.set({ 'n', 'x' }, 'W', function()
      require('spider').motion('w', {
        customPatterns = {
          -- Match one or more characters that are neither word characters nor whitespace characters
          '[^%w\128-\255%s]+',
        },
      })
    end, {})

    vim.keymap.set({ 'n', 'x' }, 'w', function()
      require('spider').motion('w', {
        customPatterns = {
          -- subwordPatterns
          '[%w\128-\255]+',
          '%u%l+',
          -- skipPunctuationPatterns
          '%f[^%s]%p+%f[%s]',
          '^%p+%f[%s]',
          '%f[^%s]%p+$',
          '^%p+$',
        },
      })
    end, { desc = 'Spider-w' })

    vim.keymap.set({ 'n', 'x' }, 'b', function()
      require('spider').motion('b', {
        customPatterns = {
          -- subwordPatterns
          '[%w\128-\255]+',
          '%l%u+',
          -- skipPunctuationPatterns
          '%f[^%s]%p+%f[%s]',
          '^%p+%f[%s]',
          '%f[^%s]%p+$',
          '^%p+$',
        },
      })
    end, { desc = 'Spider-b' })

    local subwordPatterns = {
      '[%w\128-\255]+',
      '%f[^%s]%p+%f[%s]',
      '^%p+%f[%s]',
      '%f[^%s]%p+$',
      '^%p+$',
    }

    vim.keymap.set({ 'n', 'x', 'o' }, 'e', function()
      require('spider').motion('e', { customPatterns = subwordPatterns })
    end, { desc = 'Spider-e' })
    vim.keymap.set({ 'n', 'x', 'o' }, 'ge', function()
      require('spider').motion('ge', { customPatterns = subwordPatterns })
    end, { desc = 'Spider-ge' })

    vim.keymap.set({ 'o' }, 'w', 'iw')
    vim.keymap.set({ 'o' }, 'W', 'iW')
  end,
}
