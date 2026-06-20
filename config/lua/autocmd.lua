local vim = vim

local cursor_column_i = 0
vim.api.nvim_create_augroup('cursor_escape', { clear = true })
vim.api.nvim_create_autocmd({ 'InsertEnter', 'CursorMovedI' }, {
  group = 'cursor_escape',
  callback = function()
    cursor_column_i = vim.fn.col('.')
  end,
})
vim.api.nvim_create_autocmd('InsertLeave', {
  group = 'cursor_escape',
  callback = function()
    local col = vim.fn.col('.')
    if col ~= cursor_column_i then
      vim.fn.cursor(0, col + 1)
    end
  end,
  desc = 'Prevent escape from moving the cursor one character to the left',
})

-- vim.api.nvim_create_augroup('quit', { clear = true, })
-- vim.api.nvim_create_autocmd('BufDelete', {
--   group = 'quit',
--   callback = function()
--     local buffers = vim.fn.range(1, vim.fn.bufnr('$'))
--     local listed_buffers = vim.tbl_filter(function(buf)
--       return vim.fn.empty(vim.fn.bufname(buf)) == 0 and vim.fn.buflisted(buf) == 1
--     end, buffers)
--     if #listed_buffers == 1 then
--       vim.cmd('set guicursor=a:ver90')
--       vim.cmd('quit')
--     end
--   end,
--   desc = 'Quit if buffers list is empty',
-- })

vim.api.nvim_create_augroup('cursor', { clear = true })
vim.api.nvim_create_autocmd('ExitPre', {
  group = 'cursor',
  command = 'set guicursor=a:ver90',
  desc = 'Set cursor back to beam when leaving Neovim',
})

vim.api.nvim_create_augroup('shell', { clear = true })
vim.api.nvim_create_autocmd('BufWritePost', {
  group = 'shell',
  pattern = '*.sh',
  command = '!chmod +x %',
  desc = 'Make shell scripts executable after writing',
})

vim.api.nvim_create_augroup('term', { clear = true })
vim.api.nvim_create_autocmd('TermOpen', {
  group = 'term',
  callback = function()
    vim.o.relativenumber = false
    vim.o.number = false
    vim.cmd('startinsert')
  end,
  desc = 'Disable relative and absolute line numbers, and start insert mode in terminal buffers',
})

vim.api.nvim_create_augroup('view', { clear = true })
vim.api.nvim_create_autocmd({ 'BufWinLeave' }, {
  group = 'view',
  pattern = '*.*',
  callback = function(args)
    -- Only real file buffers; skip terminals, quickfix, help, plugin windows, etc.
    if vim.bo[args.buf].buftype ~= '' then
      return
    end
    vim.cmd('mkview')
  end,
  desc = 'Save cursor position and folds when leaving a buffer',
})
vim.api.nvim_create_autocmd({ 'BufWinEnter' }, {
  group = 'view',
  pattern = '*.*',
  callback = function(args)
    if vim.bo[args.buf].buftype ~= '' then
      return
    end
    vim.cmd('silent! loadview')
  end,
  desc = 'Restore cursor position and folds when entering a buffer',
})

vim.api.nvim_create_augroup('help', { clear = true })
vim.api.nvim_create_autocmd('FileType', {
  group = 'help',
  pattern = 'help',
  callback = function()
    vim.keymap.set('n', 'gx', '<C-]>')
  end,
  desc = 'Use gx instead of <C-]> to follow links for help files',
})

vim.api.nvim_create_augroup('tmux', { clear = true })
vim.api.nvim_create_autocmd('BufLeave', {
  group = 'tmux',
  pattern = 'tmux.conf',
  callback = function(args)
    vim.system({ 'tmux', 'source-file', vim.api.nvim_buf_get_name(args.buf) })
  end,
  desc = 'Reload tmux config on leaving the buffer',
})

vim.api.nvim_create_augroup('disableAutoComment', { clear = true })
vim.api.nvim_create_autocmd({ 'BufWinEnter', 'BufRead', 'BufNewFile' }, {
  group = 'disableAutoComment',
  pattern = '*',
  command = 'setlocal fo-=c fo-=r fo-=o fo+=t',
  desc = 'Disable auto-commenting for all file types',
})

vim.api.nvim_create_augroup('quickfix', { clear = true })
vim.api.nvim_create_autocmd('FileType', {
  group = 'quickfix',
  pattern = 'qf',
  callback = function(args)
    vim.bo[args.buf].buflisted = false
    local lines = vim.api.nvim_buf_line_count(args.buf)
    vim.cmd(math.max(math.min(lines, 10), 3) .. 'wincmd _')
    vim.schedule(function()
      vim.cmd('cfirst')
    end)
  end,
  desc = 'Quickfix: hide from buffer list, fit to 3-10 lines, jump to first item',
})

vim.api.nvim_create_augroup('lsp_keymaps', { clear = true })
vim.api.nvim_create_autocmd('LspAttach', {
  group = 'lsp_keymaps',
  callback = function()
    pcall(vim.keymap.del, 'n', 'grn')
    pcall(vim.keymap.del, { 'n', 'v' }, 'gra')
    pcall(vim.keymap.del, 'n', 'grr')
    pcall(vim.keymap.del, 'n', 'gri')
    pcall(vim.keymap.del, 'n', 'gO')
    pcall(vim.keymap.del, 'i', '<C-s>')
  end,
  desc = 'Remove LSP default global keymaps',
})

local searchcount_ns = vim.api.nvim_create_namespace('searchcount')
local searchcount_active = false
vim.api.nvim_create_augroup('searchcount', { clear = true })
vim.api.nvim_create_autocmd('CursorMoved', {
  group = 'searchcount',
  callback = function()
    -- Cheap path when not searching: only clear once, on the hlsearch 1->0 edge,
    -- so a stale count isn't left behind after :nohlsearch.
    if vim.v.hlsearch == 0 then
      if searchcount_active then
        vim.api.nvim_buf_clear_namespace(0, searchcount_ns, 0, -1)
        searchcount_active = false
      end
      return
    end
    vim.api.nvim_buf_clear_namespace(0, searchcount_ns, 0, -1)
    -- Bound the search: cap the count and time-limit it so huge files/match
    -- sets don't add cursor-movement latency.
    local ok, result = pcall(vim.fn.searchcount, { maxcount = 999, timeout = 100 })
    if not ok or result.total == 0 then
      searchcount_active = false
      return
    end
    local line = vim.api.nvim_get_current_line()
    vim.api.nvim_buf_set_extmark(0, searchcount_ns, vim.api.nvim_win_get_cursor(0)[1] - 1, #line, {
      virt_text = { { (' %d/%d'):format(result.current, result.total), 'CurSearch' } },
      virt_text_pos = 'inline',
    })
    searchcount_active = true
  end,
})

-- Close floating windows safely on BufLeave to prevent E5555 errors
vim.api.nvim_create_augroup('float_cleanup', { clear = true })
vim.api.nvim_create_autocmd('BufLeave', {
  group = 'float_cleanup',
  pattern = '*',
  callback = function()
    vim.schedule(function()
      local cur_win = vim.api.nvim_get_current_win()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if win ~= cur_win and vim.api.nvim_win_is_valid(win) then
          local config = vim.api.nvim_win_get_config(win)
          if config.relative ~= '' then
            local buf = vim.api.nvim_win_get_buf(win)
            if vim.bo[buf].filetype == '' then
              pcall(vim.api.nvim_win_close, win, false)
            end
          end
        end
      end
    end)
  end,
  desc = 'Close floating windows safely when leaving a buffer',
})
