local M = {}

local config = {
  split_height = 5,
}

local ns = vim.api.nvim_create_namespace('checker')

local severity_highlight = {
  [vim.diagnostic.severity.ERROR] = 'DiagnosticUnderlineError',
  [vim.diagnostic.severity.WARN] = 'DiagnosticUnderlineWarn',
  [vim.diagnostic.severity.INFO] = 'DiagnosticUnderlineInfo',
  [vim.diagnostic.severity.HINT] = 'DiagnosticUnderlineHint',
}

local function ensure_window()
  local buffer_id = vim.fn.bufnr('diagnostic_message')
  if buffer_id == -1 then
    buffer_id = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buffer_id, 'diagnostic_message')
  end
  if vim.fn.bufwinid(buffer_id) == -1 then
    vim.api.nvim_command('belowright ' .. config.split_height .. ' split')
    vim.api.nvim_win_set_buf(0, buffer_id)
    vim.wo[0].number = false
  end
  return buffer_id
end

local function openDiagnosticInSplit(diag)
  if not diag then
    return
  end

  local current_window = vim.api.nvim_get_current_win()
  local current_buffer = vim.api.nvim_get_current_buf()

  local buffer_id = ensure_window()

  local diag_line_raw = vim.api.nvim_buf_get_lines(current_buffer, diag.lnum, diag.lnum + 1, false)[1] or ''
  local diag_line = diag_line_raw:gsub('^%s*', '')
  local offset = math.abs(#diag_line_raw - #diag_line)

  vim.api.nvim_buf_set_lines(buffer_id, 0, -1, false, {
    diag_line,
    (diag.source or '') .. ' ' .. (diag.code or ''),
    (diag.message or ''),
  })

  vim.api.nvim_buf_clear_namespace(buffer_id, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buffer_id, ns, 0, math.max(diag.col - offset, 0), {
    end_col = math.max(diag.end_col - offset, 0),
    hl_group = severity_highlight[diag.severity],
  })

  vim.api.nvim_set_current_win(current_window)
end

function M.nextDiagnostic()
  openDiagnosticInSplit(vim.diagnostic.jump({ count = 1, float = false }))
end

function M.prevDiagnostic()
  openDiagnosticInSplit(vim.diagnostic.jump({ count = -1, float = false }))
end

function M.setup(opts)
  config = vim.tbl_extend('force', config, opts or {})
end

return M
