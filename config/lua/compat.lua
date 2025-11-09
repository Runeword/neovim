local vim = vim

local function override_buf_get_clients()
  if vim.lsp and vim.lsp.buf_get_clients and vim.lsp.get_clients then
    local original = vim.lsp.buf_get_clients
    vim.lsp.buf_get_clients = function(bufnr)
      bufnr = bufnr or vim.api.nvim_get_current_buf()
      return vim.lsp.get_clients({ bufnr = bufnr })
    end
  end
end

override_buf_get_clients()

vim.schedule(function()
  override_buf_get_clients()
end)

vim.api.nvim_create_autocmd({ 'User', 'LspAttach' }, {
  callback = override_buf_get_clients,
})

return {}
