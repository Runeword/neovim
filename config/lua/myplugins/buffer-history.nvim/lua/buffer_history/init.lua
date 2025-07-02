local vim = vim

local M = {}

local closed_buffers = {}

function M.reopen_most_recent()
  if #closed_buffers == 0 then
    return
  end

  local buffer_info = table.remove(closed_buffers, 1)

  pcall(function()
    if buffer_info.file_path and vim.fn.filereadable(buffer_info.file_path) == 1 then
      vim.cmd("edit " .. vim.fn.fnameescape(buffer_info.file_path))
    else
      vim.cmd("new")
      if buffer_info.name and buffer_info.name ~= "" then
        vim.api.nvim_buf_set_name(0, buffer_info.name)
      end
    end
  end)
end

function M.setup()
  vim.api.nvim_create_augroup('buffer_history', { clear = true })
  vim.api.nvim_create_autocmd('BufDelete', {
    group = 'buffer_history',
    callback = function(event)
      local bufnr = event.buf
      if vim.api.nvim_buf_is_valid(bufnr) then
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name and name ~= "" then
          table.insert(closed_buffers, 1, {
            name = name,
            file_path = vim.fn.filereadable(name) == 1 and name or nil
          })

          -- Keep only the most recent 50 buffers
          if #closed_buffers > 50 then
            table.remove(closed_buffers, #closed_buffers)
          end
        end
      end
    end,
  })
end

return M
