local vim = vim

local M = {}

function M.undoAllChanges()
  if #vim.fn.undotree().entries == 0 then
    return
  end

  local output = vim.fn.execute('undo 0')

  vim.notify('' .. output:gsub('^\n', ''), 'info', { icon = '󰕌', render = 'wrapped-compact', timeout = 1200 })
end

function M.redoAllChanges()
  if #vim.fn.undotree().entries == 0 then
    return
  end

  local output = vim.fn.execute('undo ' .. vim.fn.undotree().seq_last)

  vim.notify('' .. output:gsub('^\n', ''), 'info', { icon = '󰑎', render = 'wrapped-compact', timeout = 1200 })
end

function M.deleteUndoTree()
  if #vim.fn.undotree().entries == 0 then
    return
  end

  local start = vim.fn.getpos("'[")
  local finish = vim.fn.getpos("']")

  local view = vim.fn.winsaveview()
  vim.o.undoreload = 0
  vim.cmd('edit')
  vim.fn.winrestview(view)

  vim.fn.setpos("'[", start)
  vim.fn.setpos("']", finish)

  vim.notify('Delete undo tree', 'info', { icon = '', render = 'wrapped-compact', timeout = 1200 })
end

return M
