local vim = vim

return {
  'chrisgrieser/nvim-spider',
  enabled = true,

  config = function()
    local word = '[%w\128-\255]+'
    local nonword = '[^%w\128-\255%s]+'
    local camelForward = '%u%l+'
    local camelBackward = '%l%u+'

    local skipPunctuation = {
      '%f[^%s]%p+%f[%s]',
      '^%p+%f[%s]',
      '%f[^%s]%p+$',
      '^%p+$',
    }

    local function motion(key, patterns)
      return function()
        require('spider').motion(key, { customPatterns = patterns })
      end
    end

    vim.keymap.set({ 'n', 'x' }, 'w', motion('w', { word, camelForward, unpack(skipPunctuation) }))
    vim.keymap.set({ 'n', 'x' }, 'b', motion('b', { word, camelBackward, unpack(skipPunctuation) }))
    vim.keymap.set({ 'n', 'x' }, 'W', motion('w', { nonword }))

    vim.keymap.set({ 'n', 'x', 'o' }, 'e', motion('e', { word, unpack(skipPunctuation) }))
    vim.keymap.set({ 'n', 'x', 'o' }, 'ge', motion('ge', { word, unpack(skipPunctuation) }))

    vim.keymap.set({ 'o' }, 'w', 'iw')
    vim.keymap.set({ 'o' }, 'W', 'iW')
  end,
}
