local M = {}

local config = {
  max_history = 50,
}

local closed_buffers = {}

function M.reopen_most_recent()
  if #closed_buffers == 0 then
    return
  end

  local buffer_info = table.remove(closed_buffers, 1)

  if buffer_info.file_path and vim.fn.filereadable(buffer_info.file_path) == 1 then
    pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(buffer_info.file_path))
  else
    pcall(vim.cmd, 'new')
    if buffer_info.name and buffer_info.name ~= '' then
      pcall(vim.api.nvim_buf_set_name, 0, buffer_info.name)
    end
  end
end

function M.setup(opts)
  config = vim.tbl_extend('force', config, opts or {})

  vim.api.nvim_create_augroup('buffer_history', { clear = true })
  vim.api.nvim_create_autocmd('BufDelete', {
    group = 'buffer_history',
    callback = function(event)
      local bufnr = event.buf
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      if vim.bo[bufnr].buftype ~= '' then
        return
      end

      local name = vim.api.nvim_buf_get_name(bufnr)
      if not name or name == '' then
        return
      end

      table.insert(closed_buffers, 1, {
        name = name,
        file_path = vim.fn.filereadable(name) == 1 and name or nil,
      })

      if #closed_buffers > config.max_history then
        closed_buffers[#closed_buffers] = nil
      end
    end,
  })
end

return M
