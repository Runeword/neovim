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
  local function on(events, callback, opts)
    vim.api.nvim_create_autocmd(events, vim.tbl_extend('force', { group = group, callback = callback }, opts or {}))
  end

  -- The reference itself, in the list, the pane and the code (after/plugin/colors.lua can
  -- set it)
  vim.api.nvim_set_hl(0, 'RefsMatch', { default = true, link = 'LspReferenceText' })
  -- Over it in the list, the one under the code's cursor, as a search's current match
  vim.api.nvim_set_hl(0, 'RefsCurrent', { default = true, link = 'CurSearch' })

  -- In the code, whenever the cursor settles: show its symbol in the panel and its
  -- definition in the pane, then (its own questions answered first) ask ahead about the
  -- next hop targets
  local function settled()
    local buf = vim.api.nvim_get_current_buf()
    if vim.fn.win_gettype() == 'autocmd' then
      return -- (an autocommand's window, as :bwipeout runs LspDetach in, with the buffer going)
    elseif vim.bo[buf].buftype == '' and vim.api.nvim_buf_get_name(buf) ~= '' and panel.is_open() then
      panel.definition()
      panel.refresh(hop.prefetch_here)
    end
  end
  on('CursorHold', settled)

  -- What refers to what can change with any edit of a file, with a write (some servers
  -- read files on save), and while you were away (another program changing files)
  on({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, function(args)
    if vim.bo[args.buf].buftype == '' then
      answers.changed()
    end
  end)
  on('BufWritePost', function()
    answers.forget()
  end)
  on('FocusGained', function()
    answers.forget()
    settled()
  end)
  on('BufWipeout', function(args)
    answers.forget(args.buf)
    panel.wiped(args.buf)
  end)
  on('BufAdd', answers.buffer_added)

  -- The servers of a buffer changing, or one done loading the project (see
  -- answers.warm_up), its answers are to be asked again. (The panel opens at start,
  -- before any server attached.)
  local function renew(buf)
    answers.forget(buf)
    panel.attached(buf)
    -- (once out of the autocommand: a server leaves with its buffer, :bdelete, too)
    vim.schedule(function()
      if vim.api.nvim_buf_is_loaded(buf) and buf == vim.api.nvim_get_current_buf() then
        settled()
      end
    end)
  end
  local function serves(client)
    return client
      and (client:supports_method('textDocument/references') or client:supports_method('textDocument/definition'))
  end
  on({ 'LspAttach', 'LspDetach' }, function(args)
    if serves(vim.lsp.get_client_by_id(args.data.client_id)) then
      if args.event == 'LspAttach' then
        answers.warm_up(args.data.client_id)
      end
      renew(args.buf)
    end
  end)
  on('LspProgress', function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    local value = args.data.params and args.data.params.value or {}
    if serves(client) and answers.progress(client.id, value.kind) then
      for buf in pairs(client.attached_buffers) do
        renew(buf)
      end
    end
  end)

  on('WinEnter', panel.entered)
  on('WinClosed', panel.closed)
  on('BufWinEnter', panel.sync_later) -- (another buffer in the list's window)
  on('QuitPre', panel.quitting)
  on('VimResized', panel.resized)
  on('SessionWritePre', function()
    panel.session(true)
  end)
  on('SessionWritePost', function()
    panel.session(false)
  end)

  -- Draw the list's lines as they come into view, and the references it shows in the code
  vim.api.nvim_set_decoration_provider(vim.api.nvim_create_namespace('refs'), {
    on_win = function(_, win, buf, toprow, botrow)
      if panel.highlight(win, toprow) then
        return true -- (its lines are drawn one by one)
      end
      panel.mark(buf, toprow, botrow)
      return false
    end,
    on_line = function(_, _, buf, line)
      panel.draw_line(buf, line)
    end,
  })
end

return M
