local M = {}

local config = {
  notify_icon_undo = '󰕌',
  notify_icon_redo = '󰑎',
  notify_icon_delete = '',
  notify_timeout = 1200,
}

local function notify(msg, icon)
  vim.notify(msg, vim.log.levels.INFO, {
    icon = icon,
    render = 'wrapped-compact',
    timeout = config.notify_timeout,
  })
end

function M.undoAllChanges()
  local tree = vim.fn.undotree()
  if #tree.entries == 0 then
    return
  end
  local ok, output = pcall(vim.fn.execute, 'undo 0')
  if not ok then
    return
  end
  notify(output:gsub('^\n', ''), config.notify_icon_undo)
end

function M.redoAllChanges()
  local tree = vim.fn.undotree()
  if #tree.entries == 0 then
    return
  end
  local ok, output = pcall(vim.fn.execute, 'undo ' .. tree.seq_last)
  if not ok then
    return
  end
  notify(output:gsub('^\n', ''), config.notify_icon_redo)
end

function M.deleteUndoTree()
  if #vim.fn.undotree().entries == 0 then
    return
  end

  local was_modified = vim.bo.modified
  local old = vim.bo.undolevels
  vim.bo.undolevels = -1
  vim.cmd([[exe "normal! a \<BS>\<Esc>"]])
  vim.bo.undolevels = old
  if not was_modified then
    vim.bo.modified = false
  end

  notify('Delete undo tree', config.notify_icon_delete)
end

function M.setup(opts)
  config = vim.tbl_extend('force', config, opts or {})
end

return M
