local vim = vim

-- References: <Left>/<Right> hop between the symbols that have references (refs.hop),
-- and a panel listing the references of the symbol under the cursor (refs.panel), which
-- <Up>/<Down> go through while it's open.
local answers = require('refs.answers')
local hop = require('refs.hop')
local panel = require('refs.panel')

local M = {}

M.toggle = panel.toggle -- the panel
M.focus = panel.focus -- the panel, moving into it
M.go = panel.go -- to the panel's next (dir 1) or previous (-1) reference; false if it's closed
M.hop = hop.hop -- dir: 1 next, -1 previous

function M.setup()
  local group = vim.api.nvim_create_augroup('refs', { clear = true })

  -- The reference itself, in the list and the pane (after/plugin/colors.lua can set it)
  vim.api.nvim_set_hl(0, 'RefsMatch', { default = true, link = 'LspReferenceText' })
  -- Over it in the list, the one under the cursor, as a search's current match
  vim.api.nvim_set_hl(0, 'RefsCurrent', { default = true, link = 'CurSearch' })

  vim.api.nvim_create_autocmd('BufWritePost', { group = group, callback = answers.forget })

  -- In the code, whenever the cursor settles: show its symbol in the panel, and ask
  -- ahead about the next hop targets
  vim.api.nvim_create_autocmd('CursorHold', {
    group = group,
    callback = function()
      if vim.bo.buftype == '' and panel.is_open() then
        panel.refresh()
        panel.definition()
        hop.prefetch_here()
      end
    end,
  })

  vim.api.nvim_create_autocmd('WinEnter', { group = group, callback = panel.entered })
  vim.api.nvim_create_autocmd('WinClosed', { group = group, callback = panel.sync_later })

  -- Highlight the code of the list as it comes into view
  vim.api.nvim_set_decoration_provider(vim.api.nvim_create_namespace('refs'), {
    on_win = function(_, win, _, toprow)
      panel.highlight(win, toprow)
      return false
    end,
  })
end

return M
