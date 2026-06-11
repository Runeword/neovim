local M = {}

local config = {
  hl = { fg = 'white', bg = 'none' },
}

local namespace = vim.api.nvim_create_namespace('appender')
local input_cache = nil
local pending_count = 1

local function apply_highlight()
  vim.api.nvim_set_hl(0, 'AppenderChar', config.hl)
end

local function getLineStr(row)
  return vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
end

local function colBeforeLine(row)
  return (string.find(getLineStr(row), '(%S)') or 1) - 1
end

local function colAfterLine(row)
  return string.len(getLineStr(row))
end

local function colBeforeCursor()
  return vim.api.nvim_win_get_cursor(0)[2]
end

local function colAfterCursor()
  return vim.api.nvim_win_get_cursor(0)[2] + 1
end

local function appendSingleChar(getColumn)
  local mode = vim.api.nvim_get_mode().mode
  local isVisual = mode:match('[vV\22]') ~= nil
  local startRow = vim.api.nvim_buf_get_mark(0, isVisual and '<' or '[')[1]
  local endRow = vim.api.nvim_buf_get_mark(0, isVisual and '>' or ']')[1]
  local lines = vim.api.nvim_buf_get_lines(0, startRow - 1, endRow, false)

  if not input_cache then
    local extmarks = {}

    for i, str in ipairs(lines) do
      local col = getColumn(startRow - 1 + i)
      local row = startRow - 2 + i
      local len = string.len(str)

      if len ~= 0 and len >= col then
        table.insert(extmarks, vim.api.nvim_buf_set_extmark(0, namespace, row, col, {
          virt_text = { { '_', 'AppenderChar' } },
          virt_text_pos = 'inline',
          priority = 200,
        }))
      end
    end

    if #extmarks == 0 then return end

    vim.api.nvim_command('redraw')

    local ok, charstr = pcall(vim.fn.getcharstr)

    for _, extmark in ipairs(extmarks) do
      vim.api.nvim_buf_del_extmark(0, namespace, extmark)
    end

    local exitKeys = { [''] = true }
    if not ok or exitKeys[charstr] then return end

    input_cache = charstr
  end

  for i, str in ipairs(lines) do
    local col = getColumn(startRow - 1 + i)
    local row = startRow - 2 + i
    local len = string.len(str)

    if len ~= 0 and len >= col then
      vim.api.nvim_buf_set_text(0, row, col, row, col, { string.rep(input_cache, pending_count) })
    end
  end
end

function M._appendCharEndLine()    return appendSingleChar(colAfterLine) end
function M._appendCharStartLine()  return appendSingleChar(colBeforeLine) end
function M._appendCharBeforeCursor() return appendSingleChar(colBeforeCursor) end
function M._appendCharAfterCursor()  return appendSingleChar(colAfterCursor) end

local function appendNewLine(rowOffset)
  local newLines = {}
  for i = 1, pending_count do newLines[i] = '' end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_buf_set_lines(0, row + rowOffset, row + rowOffset, false, newLines)
end

function M._appendNewlineBelow() appendNewLine(0) end
function M._appendNewlineAbove() appendNewLine(-1) end

local function expr_op(name)
  pending_count = vim.v.count1
  vim.go.operatorfunc = "v:lua.require'appender'." .. name
  local mode = vim.api.nvim_get_mode().mode
  return mode:match('[vV\22]') and 'g@' or 'g@l'
end

function M.appendCharEndLine()      input_cache = nil; return expr_op('_appendCharEndLine')      end
function M.appendCharStartLine()    input_cache = nil; return expr_op('_appendCharStartLine')    end
function M.appendCharBeforeCursor() input_cache = nil; return expr_op('_appendCharBeforeCursor') end
function M.appendCharAfterCursor()  input_cache = nil; return expr_op('_appendCharAfterCursor')  end

function M.appendNewlineAbove() return expr_op('_appendNewlineAbove') end
function M.appendNewlineBelow() return expr_op('_appendNewlineBelow') end

function M.setup(opts)
  config = vim.tbl_extend('force', config, opts or {})

  apply_highlight()
  vim.api.nvim_create_augroup('appender', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = 'appender',
    callback = apply_highlight,
  })
end

return M
