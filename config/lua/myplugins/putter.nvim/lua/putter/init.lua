local M = {}

local config = {
  highlight_duration = 500,
  highlight_color = '#00226b',
}

local ns = vim.api.nvim_create_namespace('putter')

local function apply_highlight()
  vim.api.nvim_set_hl(0, 'putter', { bg = config.highlight_color, default = true })
end

local function highlightChange()
  local bufnr = vim.api.nvim_get_current_buf()
  local start = vim.api.nvim_buf_get_mark(bufnr, '[')
  local finish = vim.api.nvim_buf_get_mark(bufnr, ']')

  vim.hl.range(bufnr, ns, 'putter', { start[1] - 1, start[2] }, { finish[1] - 1, finish[2] }, { inclusive = true })

  local timer = vim.uv.new_timer()
  timer:start(
    config.highlight_duration,
    0,
    vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, ns, start[1] - 1, finish[1])
      end
      timer:stop()
      timer:close()
    end)
  )
end

local function getRegister(command)
  local register = {}
  register.name = command:match('^"(.)') or vim.v.register
  register.contents = vim.fn.getreg(register.name)
  register.type = vim.fn.getregtype(register.name)
  return register
end

local function putLinewise(command)
  local register = getRegister(command)
  local str = register.contents

  vim.fn.setreg(register.name, str, 'V')
  vim.fn.execute('normal! ' .. vim.v.count1 .. '"' .. register.name .. command)
  vim.fn.setreg(register.name, register.contents, register.type)
end

local function putCharwise(command)
  local register = getRegister(command)
  local str

  if register.type ~= 'V' and register.type ~= 'v' then
    vim.fn.execute('normal! ' .. vim.v.count1 .. '"' .. register.name .. command)
    return
  end

  if register.type == 'V' then
    str = register.contents:gsub('^%s*(.-)%s*$', '%1')
  else
    str = register.contents
  end

  vim.fn.setreg(register.name, str, 'v')
  vim.fn.execute('normal! ' .. vim.v.count1 .. '"' .. register.name .. command)
  vim.fn.setreg(register.name, register.contents, register.type)
end

function M.putCharwiseAfter()
  putCharwise('p')
  highlightChange()
end

function M.putCharwiseBefore()
  putCharwise('P')
  highlightChange()
end

function M.putLinewiseAfter()
  putLinewise(']p`]')
  highlightChange()
end

function M.putLinewiseBefore()
  putLinewise(']P`]')
  highlightChange()
end

function M.setup(opts)
  config = vim.tbl_extend('force', config, opts or {})

  apply_highlight()
  vim.api.nvim_create_augroup('putter', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = 'putter',
    callback = apply_highlight,
  })
end

return M
