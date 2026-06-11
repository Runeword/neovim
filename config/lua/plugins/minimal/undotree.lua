local vim = vim

return {
  enabled = true,

  dir = vim.fn.stdpath('config') .. '/lua/myplugins/undotree.nvim',

  config = function()
    require('undotree').setup()
    vim.keymap.set('n', 'U', require('undotree').undoAllChanges, { desc = 'Undo all changes' })
    vim.keymap.set('n', 'R', require('undotree').redoAllChanges, { desc = 'Redo all changes' })
    vim.keymap.set('n', '<Leader>s', require('undotree').deleteUndoTree, { desc = 'Delete undo tree' })
  end,
}
