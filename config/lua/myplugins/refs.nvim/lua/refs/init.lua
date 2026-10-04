local vim = vim

-- References: <Left>/<Right> hop between the symbols that have references (refs.hop),
-- and a panel listing the references of the symbol under the cursor (refs.panel), which
-- <Up>/<Down> go through while it's open.
local answers = require('refs.answers')
local hop = require('refs.hop')
local panel = require('refs.panel')

local M = {}

M.open = panel.open -- the panel, if it's closed
M.toggle = panel.toggle -- the panel
M.focus = panel.focus -- the panel, moving into it
M.go = panel.go -- to the panel's next (dir 1) or previous (-1) reference; false if it's closed
M.hop = hop.hop -- dir: 1 next, -1 previous

function M.setup()
  local group = vim.api.nvim_create_augroup('refs', { clear = true })

  -- The reference itself, in the list, the pane and the code (after/plugin/colors.lua can
  -- set it)
  vim.api.nvim_set_hl(0, 'RefsMatch', { default = true, link = 'LspReferenceText' })
  -- Over it in the list, the one under the code's cursor, as a search's current match
  vim.api.nvim_set_hl(0, 'RefsCurrent', { default = true, link = 'CurSearch' })

  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = function()
      answers.forget()
    end,
  })

  -- In the code, whenever the cursor settles: show its symbol in the panel, and ask
  -- ahead about the next hop targets
  local function settled()
    if vim.bo.buftype == '' and panel.is_open() then
      panel.refresh()
      panel.definition()
      hop.prefetch_here()
    end
  end
  vim.api.nvim_create_autocmd('CursorHold', { group = group, callback = settled })

  -- A server attaching to a buffer can answer what was asked before it came (the panel
  -- opens at start, before any has): ask again
  vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      local serves = client
        and (client:supports_method('textDocument/references') or client:supports_method('textDocument/definition'))
      if serves then
        answers.forget(args.buf)
        panel.attached(args.buf)
        if args.buf == vim.api.nvim_get_current_buf() then
          settled()
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd('WinEnter', { group = group, callback = panel.entered })
  vim.api.nvim_create_autocmd('WinClosed', { group = group, callback = panel.sync_later })
  vim.api.nvim_create_autocmd('QuitPre', { group = group, callback = panel.quitting })

  -- Highlight the code of the list as it comes into view, and the references it shows in
  -- the code
  vim.api.nvim_set_decoration_provider(vim.api.nvim_create_namespace('refs'), {
    on_win = function(_, win, buf, toprow, botrow)
      panel.highlight(win, toprow)
      panel.mark(buf, toprow, botrow)
      return false
    end,
  })
end

return M
