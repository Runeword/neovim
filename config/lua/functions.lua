local vim = vim

local M = {}

-------------------- Word

local function isEndOfWord()
  local pos = vim.fn.getpos('.')
  vim.print(pos)
  vim.fn.execute('normal! gee')
  vim.print(vim.fn.getpos('.'))
  if table.concat(pos) == table.concat(vim.fn.getpos('.')) then
    return true
  else
    vim.fn.setpos('.', pos)
    return false
  end
end

local function isStartOfWord()
  local pos = vim.fn.getpos('.')
  vim.print(pos)
  vim.fn.execute('normal! gew')
  vim.print(vim.fn.getpos('.'))
  if table.concat(pos) == table.concat(vim.fn.getpos('.')) then
    return true
  else
    vim.fn.setpos('.', pos)
    return false
  end
end

function M.putWordwise()
  return function()
    local command
    if isStartOfWord() and not isEndOfWord() then
      command = 'P'
    else
      command = 'p'
    end
    -- putCharwise(command)
  end
end

-------------------- Snap

local function isPastEndOfLine()
  return (vim.o.virtualedit ~= '') and (vim.fn.col('.') >= vim.fn.col('$'))
end

local function isBeforeFirstNonBlank()
  return (vim.o.virtualedit ~= '') and (vim.fn.col('.') <= string.find(vim.fn.getline(vim.fn.line('.')), '(%S)') - 1)
end

function M.snapToLineStart(callback)
  return function()
    if isBeforeFirstNonBlank() then
      vim.fn.execute('normal! ^')
    end
    if type(callback) == 'string' then
      vim.fn.execute('normal! ' .. callback)
    else
      callback()
    end
  end
end

function M.snapToLineEnd(callback)
  return function()
    if isPastEndOfLine() then
      vim.fn.execute('normal! $')
    end
    if type(callback) == 'string' then
      vim.fn.execute('normal! ' .. callback)
    else
      callback()
    end
  end
end

-------------------- Jump

local function jumpToLine(command, callback)
  if isPastEndOfLine() or isBeforeFirstNonBlank() then
    vim.fn.execute('normal! ' .. command)
  end
  if type(callback) == 'string' then
    vim.fn.execute('normal! ' .. callback)
  else
    callback()
  end
end

function M.jumpToLine(command, callback)
  return function()
    jumpToLine(command, callback)
  end
end

function M.jumpToLineStart(callback)
  return function()
    jumpToLine('^', callback)
  end
end

function M.jumpToLineEnd(callback)
  return function()
    jumpToLine('$', callback)
  end
end

-------------------- Move

local MIN_STRIDE = 2 -- never make a sub-2-line hop (avoids stutter-stepping)

-- Diagnostic lines (1-indexed) in the current buffer.
local function diagnostic_lines()
  local t = {}
  for _, d in ipairs(vim.diagnostic.get(0)) do
    t[#t + 1] = d.lnum + 1
  end
  return t
end

-- Leftmost diagnostic column (1-indexed) on line `lnum`, or nil if none.
local function diagnostic_col(lnum)
  local best
  for _, d in ipairs(vim.diagnostic.get(0, { lnum = lnum - 1 })) do
    if not best or d.col + 1 < best then
      best = d.col + 1
    end
  end
  return best
end

local HUNK_GAP = 2 -- hunks within this many lines merge into one block (tunable)

-- Git hunk blocks as { s = start, e = end } (1-indexed), sorted, with hunks that
-- sit within HUNK_GAP lines of each other coalesced into one block. {} if
-- gitsigns is absent / not attached.
local gitsigns -- cached module handle so the hot path skips pcall(require) each call
local function hunk_regions()
  if not gitsigns then
    local ok, gs = pcall(require, 'gitsigns')
    if not ok then
      return {}
    end
    gitsigns = gs
  end
  if not gitsigns.get_hunks then
    return {}
  end
  local raw = {}
  for _, h in ipairs(gitsigns.get_hunks(vim.api.nvim_get_current_buf()) or {}) do
    if h.added and h.added.start then
      local s = h.added.start
      raw[#raw + 1] = { s = s, e = s + math.max(h.added.count or 1, 1) - 1 }
    end
  end
  table.sort(raw, function(a, b)
    return a.s < b.s
  end)
  local regions = {}
  for _, r in ipairs(raw) do
    local last = regions[#regions]
    if last and r.s - last.e - 1 <= HUNK_GAP then
      last.e = math.max(last.e, r.e)
    else
      regions[#regions + 1] = { s = r.s, e = r.e }
    end
  end
  return regions
end

-- Nearest ABSOLUTE grid line (1, 1+stride, 1+2*stride, ...) in the travel
-- direction that is non-blank and >= MIN_STRIDE from `cur`, else the buffer's
-- content edge. Because the grid is absolute (not cursor- or block-relative),
-- <C-j> and <C-k> land on the same set of lines -- the motion is exactly
-- symmetric. Cost is O(1) arithmetic per grid step; the loop iterates only over
-- blank grid lines, so O(1) in dense text, at worst O(blank-run / stride).
local function grid_stop(cur, stride, down, firstC, lastC)
  if down then
    local g = cur - ((cur - 1) % stride) + stride
    while g <= lastC do
      if g - cur >= MIN_STRIDE and vim.fn.getline(g):find('%S') then
        return g
      end
      g = g + stride
    end
    return lastC
  end
  local g = cur - ((cur - 1) % stride)
  if g >= cur then
    g = g - stride
  end
  while g >= firstC do
    if cur - g >= MIN_STRIDE and vim.fn.getline(g):find('%S') then
      return g
    end
    g = g - stride
  end
  return firstC
end

function M.move_to_non_empty_line(lines)
  local cur = vim.fn.line('.')
  local down = lines > 0
  local firstC = vim.fn.nextnonblank(1)
  local lastC = vim.fn.prevnonblank(vim.fn.line('$'))

  -- Default landing: the nearest absolute grid stop in the travel direction (see
  -- grid_stop) -- an absolute grid makes <C-j>/<C-k> exact inverses, in O(1).
  local cap = grid_stop(cur, math.abs(lines), down, firstC, lastC)

  -- Nearest paragraph top within reach. Scan MIN_STRIDE past the grid stop so both
  -- directions see a top that straddles the grid line; the explicit test then keeps
  -- only the acceptable ones -- a top within MIN_STRIDE of the grid stop dominates
  -- it (so <C-j>/<C-k> agree), else the nearer of the two wins. \%>Nl / \%<Nl keep
  -- the top itself >= MIN_STRIDE from the cursor. NB: the filter is explicit rather
  -- than folded into the stopline because search()'s stopline bounds the match START
  -- (here the blank line), not the returned content line.
  local para
  if down then
    para = vim.fn.search([[^$\n\s*\%>]] .. (cur + MIN_STRIDE - 1) .. [[l\zs\S]], 'nW', cap + MIN_STRIDE)
  else
    para = vim.fn.search(
      [[^$\n\s*\%<]] .. math.max(cur - MIN_STRIDE + 1, 1) .. [[l\zs\S]],
      'nWb',
      math.max(cap - MIN_STRIDE, 1)
    )
  end
  if para ~= 0 and (math.abs(para - cap) < MIN_STRIDE or (down and para < cap) or (not down and para > cap)) then
    cap = para
  end

  -- Fold in diagnostics and git hunks as extra stops: high-value edit sites, so
  -- (unlike paragraph stops) they fire even closer than MIN_STRIDE -- but never
  -- past the cap, so the stride stays bounded and predictable.
  local target = cap
  local function consider(v)
    if v and v ~= 0 then
      if down and v > cur and v < target then
        target = v
      elseif not down and v < cur and v > target then
        target = v
      end
    end
  end

  -- Endpoint absorb: a structural stop within MIN_STRIDE of a content edge is
  -- visited going one way but skipped (min-stride) the other; snap it to the edge
  -- so both directions agree. Diagnostics/hunks fold in after and can still pull shorter.
  if down then
    if lastC > target and lastC - target < MIN_STRIDE then
      target = lastC
    end
  else
    if firstC < target and target - firstC < MIN_STRIDE then
      target = firstC
    end
  end

  for _, l in ipairs(diagnostic_lines()) do
    consider(l)
  end
  local regions = hunk_regions()
  for _, r in ipairs(regions) do
    consider(r.s) -- a hunk block is a single stop, at its start line
  end

  -- A SMALL hunk block (spanning <= one stride) is a single waypoint: never land
  -- in its body, only its start -- moving down skip past its end, moving up jump
  -- to its start. A BIG block is stepped through at the normal stride instead.
  for _, r in ipairs(regions) do
    if target > r.s and target <= r.e and r.e - r.s <= math.abs(lines) then
      if down then
        target = vim.fn.nextnonblank(r.e + 1)
      else
        target = r.s
      end
    end
  end

  -- Never reverse direction: on trailing/leading blank lines the edge fallbacks
  -- can land on the far content edge (behind the cursor) -- stay put instead.
  if target == 0 or (down and target < cur) or (not down and target > cur) then
    target = cur
  end

  -- Land on the diagnostic's own column when the target line carries one (right
  -- on the offending token); otherwise the first non-blank character. Hunks are
  -- line-scoped (no column), so they also fall back to the first non-blank.
  local col = diagnostic_col(target) or vim.fn.getline(target):find('%S') or 1
  vim.fn.cursor(target, col)
end

-------------------- Edit

-- When the line is empty, move the cursor to the beginning of the line
function M.insert()
  if #vim.fn.getline('.') == 0 then
    return [["_cc]]
  else
    return 'i'
  end
end

function M.visualSelectToEndOfline()
  local current_pos = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_win_set_cursor(0, { current_pos[1], #vim.api.nvim_get_current_line() })
  vim.api.nvim_feedkeys('v', 'nx', false)
  vim.api.nvim_win_set_cursor(0, current_pos)
end

-------------------- Fold

local isFolded = false

function M.toggleFold()
  if not isFolded then
    vim.api.nvim_feedkeys('zR', 'n', false)
    isFolded = true
  else
    vim.api.nvim_feedkeys('zM', 'n', false)
    isFolded = false
  end
end

------------------- Buffers

-- Wipe all the active buffers, quit vim if it's the last buffer
function M.wipe_active_buffers()
  local buffers_count = 0
  local active_buffers = {}

  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer) then
      if vim.api.nvim_get_option_value('buflisted', { buf = buffer }) then
        buffers_count = buffers_count + 1
      end

      if vim.fn.bufwinid(buffer) ~= -1 then
        table.insert(active_buffers, buffer)
      end
    end
  end

  -- print(vim.inspect(active_buffers))

  for _, active_buffer in ipairs(active_buffers) do
    -- Check if buffer is still valid before attempting to delete
    if vim.api.nvim_buf_is_valid(active_buffer) then
      vim.api.nvim_buf_delete(active_buffer, { force = true })
    end
  end

  if buffers_count == 1 then
    vim.cmd('quit!')
  end
end

------------------- Windows

function M.cancel()
  -- Quit diagnostic window
  local buffer_id = vim.fn.bufnr('diagnostic_message')
  if buffer_id ~= -1 then
    vim.api.nvim_buf_delete(buffer_id, { force = true, unload = false })
  end

  -- Quit messages window
  local bff = vim.fn.bufnr('messages')
  if bff ~= -1 then
    vim.api.nvim_buf_delete(bff, { force = true, unload = false })
  end

  -- Close the quickfix list if it is open
  vim.cmd('cclose')

  -- Move cursor to the beginning of the line
  vim.api.nvim_feedkeys(string.format('%c%s', 27, 'g^'), 'n', true) -- <Esc>g^
end

------------------- Messages

-- Display messages in a floating window
function M.displayMessages()
  local messages_string = vim.fn.split(vim.api.nvim_exec2('silent messages', { output = true }).output, '\n')
  if next(messages_string) == nil then
    return
  end

  local buffer_id = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buffer_id, 'messages')

  vim.api.nvim_buf_set_lines(buffer_id, 0, -1, false, messages_string)

  local width = 80
  local height = #messages_string

  local window_opts = {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
  }

  vim.api.nvim_set_option_value('modifiable', false, { buf = buffer_id })
  vim.api.nvim_open_win(buffer_id, true, window_opts)
end

return M

-- ----------------------------------- Write while keeping last changes position
-- vim.keymap.set('n', 'gs', function()
--   local start = vim.fn.getpos("'[")
--   local finish = vim.fn.getpos("']")

--   vim.cmd('silent! write')

--   vim.fn.setpos("'[", start)
--   vim.fn.setpos("']", finish)
-- end)

-- ----------------------------------- Treesitter text object hook

-- local ts = vim.treesitter
-- local api = vim.api

-- -- Function to get the node at cursor
-- local function get_node_at_cursor()
--   local bufnr = api.nvim_get_current_buf()
--   local row, col = unpack(api.nvim_win_get_cursor(0))
--   row = row - 1 -- API uses 0-based rows

--   local parser = ts.get_parser(bufnr)
--   if not parser then return end

--   local root = parser:parse()[1]:root()
--   return root:named_descendant_for_range(row, col, row, col)
-- end

-- -- Function to check if cursor is on a specific text object
-- local function is_cursor_on_text_object(object_type)
--   local node = get_node_at_cursor()
--   if not node then return false end

--   return node:type() == object_type
-- end

-- -- Function to print message when cursor is on specific text object
-- local function print_message_on_text_object(object_type, message)
--   if is_cursor_on_text_object(object_type) then
--     print(message)
--   end
-- end

-- -- Function to attach a mapping when cursor is on specific text object
-- local function attach_mapping_on_text_object(object_type, mode, lhs, rhs, opts)
--   if is_cursor_on_text_object(object_type) then
--     local buffer = api.nvim_get_current_buf()
--     opts = opts or { noremap = true, silent = true, buffer = buffer, }
--     api.nvim_buf_set_keymap(buffer, mode, lhs, rhs, opts)
--   else
--     -- Remove the mapping if it exists and we're not on the text object
--     pcall(api.nvim_buf_del_keymap, api.nvim_get_current_buf(), mode, lhs)
--   end
-- end

-- -- Set up an autocommand to check cursor position
-- api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', }, {
--   pattern = '*',
--   callback = function()
--     -- Example: Print message when cursor is on a function declaration
--     print_message_on_text_object('function_declaration', 'Cursor is on a function declaration!')
--     attach_mapping_on_text_object(
--       'function_declaration',
--       'n',
--       '<leader>f',
--       ":echo 'Function action'<CR>",
--       { desc = 'Perform action on function', }
--     )

--     -- You can add more checks for different text objects here
--     -- For example:
--     -- print_message_on_text_object("if_statement", "Cursor is on an if statement!")
--     -- print_message_on_text_object("variable_declaration", "Cursor is on a variable declaration!")
--   end,
-- })
