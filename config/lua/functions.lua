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

-------------------- Hidden comments

-- Namespace holding the hide-comments conceal extmarks (populated by M.toggleComments,
-- far below). Declared up here because the movement flow that follows consults it: a
-- FULLY hidden comment line carries a `conceal_lines` extmark in this namespace, and
-- such lines are dropped from the flow -- j/k and the smart jump skip them, so
-- navigation never lands on (and thereby pops back open) a hidden comment.
local comment_ns = vim.api.nvim_create_namespace('hide_comments')

-- True when line `lnum` (1-indexed) is a fully-hidden comment line: comments are
-- toggled off in this buffer AND the line carries a conceal_lines extmark. A no-op
-- (single buffer-var read) whenever the toggle is off, so the movement flow pays
-- nothing in the common case. Inline/trailing comments keep their code line and so
-- are NOT hidden lines -- only whole-line conceals count.
local function is_hidden_comment_line(lnum)
  local buf = vim.api.nvim_get_current_buf()
  if not vim.b[buf].comments_hidden then
    return false
  end
  local marks = vim.api.nvim_buf_get_extmarks(buf, comment_ns, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })
  for _, m in ipairs(marks) do
    if m[4] and m[4].conceal_lines then
      return true
    end
  end
  return false
end

-- A line the jump/step logic is allowed to land on: it has real text and is not a
-- hidden comment line (those sit outside the movement flow).
local function is_content_line(lnum)
  return vim.fn.getline(lnum):find('%S') ~= nil and not is_hidden_comment_line(lnum)
end

-------------------- Move

local MIN_STRIDE = 2 -- never make a sub-2-line hop (avoids stutter-stepping)

-- Only WARN and above count as stops / cursor targets. Counting HINT/INFO would
-- degrade the motion to 1-line stutter hops in hint-dense buffers (e.g. lua_ls),
-- defeating MIN_STRIDE.
local DIAG_SEVERITY = { min = vim.diagnostic.severity.WARN }

-- Diagnostic lines (1-indexed) in the current buffer.
local function diagnostic_lines()
  local t = {}
  for _, d in ipairs(vim.diagnostic.get(0, { severity = DIAG_SEVERITY })) do
    t[#t + 1] = d.lnum + 1
  end
  return t
end

-- Leftmost diagnostic column (1-indexed) on line `lnum`, or nil if none.
local function diagnostic_col(lnum)
  local best
  for _, d in ipairs(vim.diagnostic.get(0, { lnum = lnum - 1, severity = DIAG_SEVERITY })) do
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
      -- A top-of-file deletion is reported as added = { start = 0, count = 0 };
      -- clamp to line 1 so it can't coalesce into a { 0, N } block that then
      -- bricks upward motion near the top of the file.
      local s = math.max(h.added.start, 1)
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
-- <C-j> and <C-k> land on the same set of lines -- the motion is near-symmetric
-- (off-grid starts self-correct after one hop). Cost is O(1) arithmetic per grid
-- step; the loop iterates only over
-- blank grid lines, so O(1) in dense text, at worst O(blank-run / stride).
local function grid_stop(cur, stride, down, firstC, lastC)
  if down then
    local g = cur - ((cur - 1) % stride) + stride
    while g <= lastC do
      if g - cur >= MIN_STRIDE and is_content_line(g) then
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
    if cur - g >= MIN_STRIDE and is_content_line(g) then
      return g
    end
    g = g - stride
  end
  return firstC
end

function M.move_to_non_empty_line(lines)
  local cur = vim.fn.line('.')
  local down = lines > 0
  -- Content edges, skipping not just blanks but any leading/trailing run of hidden
  -- comment lines (nextnonblank stops on them -- they carry text -- so step past).
  local firstC = vim.fn.nextnonblank(1)
  while firstC ~= 0 and is_hidden_comment_line(firstC) do
    firstC = vim.fn.nextnonblank(firstC + 1)
  end
  local lastC = vim.fn.prevnonblank(vim.fn.line('$'))
  while lastC ~= 0 and is_hidden_comment_line(lastC) do
    lastC = vim.fn.prevnonblank(lastC - 1)
  end
  if firstC == 0 then
    return -- nothing but blank / hidden-comment lines: nowhere in-flow to move
  end

  -- Default landing: the nearest absolute grid stop in the travel direction (see
  -- grid_stop) -- an absolute grid makes <C-j>/<C-k> near-inverses (self-correcting
  -- after one hop), in O(1).
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
    para = vim.fn.search([[^\s*$\n\s*\%>]] .. (cur + MIN_STRIDE - 1) .. [[l\zs\S]], 'nW', cap + MIN_STRIDE)
  else
    para = vim.fn.search(
      [[^\s*$\n\s*\%<]] .. math.max(cur - MIN_STRIDE + 1, 1) .. [[l\zs\S]],
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
    if
      target > r.s
      and target <= r.e
      and r.e - r.s <= math.abs(lines)
      and not diagnostic_col(target) -- a diagnostic in the body is a stop; keep it reachable
    then
      if down then
        local after = vim.fn.nextnonblank(r.e + 1)
        if after == 0 then
          target = math.min(r.e, lastC) -- nothing past the hunk: last content line, not "stay put"
        else
          target = math.min(after, cap) -- skip past the hunk, but never past the cap
        end
      else
        target = r.s
      end
    end
  end

  -- Hidden comment lines are outside the movement flow: a paragraph top, diagnostic
  -- or hunk start can still name one, so if the chosen target is hidden, slide to the
  -- next content line in the travel direction (the reverse-direction guard below turns
  -- an overshoot past the last content line into a stay-put no-op).
  if is_hidden_comment_line(target) then
    local probe = target
    repeat
      probe = probe + (down and 1 or -1)
    until probe < firstC or probe > lastC or is_content_line(probe)
    target = (probe >= firstC and probe <= lastC) and probe or cur
  end

  -- Never reverse direction: on trailing/leading blank lines the edge fallbacks
  -- can land on the far content edge (behind the cursor) -- stay put instead.
  if target == 0 or (down and target < cur) or (not down and target > cur) then
    target = cur
  end

  -- A genuine no-op: leave the cursor entirely alone. cursor() would still reset
  -- the column (e.g. (2,3) -> (2,1) on a blank line), perturbing a visual selection.
  if target == cur then
    return
  end

  -- Land on the diagnostic's own column when the target line carries one (right
  -- on the offending token); otherwise the first non-blank character. Hunks are
  -- line-scoped (no column), so they also fall back to the first non-blank.
  local col = diagnostic_col(target) or vim.fn.getline(target):find('%S') or 1
  vim.fn.cursor(target, col)
end

-- One-line j/k that steps over hidden-comment lines (part of the hide-comments
-- feature) so a single move never rests on -- and thereby reveals -- one; they're
-- outside the movement flow. Bail at the buffer edge (the move became a no-op) so a
-- file ending in hidden comments can't loop forever.
local function jk_step(dir)
  vim.cmd('normal! ' .. dir)
  while is_hidden_comment_line(vim.fn.line('.')) do
    local before = vim.fn.line('.')
    vim.cmd('normal! ' .. dir)
    if vim.fn.line('.') == before then
      break
    end
  end
end

-- Public one-line step, exposed for gj/gk (see mappings.lua): a deliberate single line
-- for when you want to opt out of j/k's default 4-line jump. Shares jk_step's hidden-
-- comment skipping, so it stays on the movement flow exactly like the sticky submode.
function M.jkStep(dir)
  jk_step(dir)
end

-------------------- Sticky motion

-- Sticky hjkl navigation submode -- a dependency-free replacement for the old
-- hydra 'scroll' hydra. While active, h/j/k/l move one step at a time (shadowing
-- j/k's usual 4-line jump) and every other key works exactly as normal.
--
-- Entering: a broad set of motions (STICKY_ENTRY) is wrapped by M.armStickyEntry
-- so pressing one does its usual thing AND arms the submode. Wrapping (rather than
-- a global vim.on_key) is deliberate: a mapping only fires when the key is a
-- command, so `fw`, `rw`, `"wp` etc. -- where the letter is an argument -- do NOT
-- trip it, and each key's existing plugin behaviour (spider w/b/e, asterisk */#,
-- the custom `,` search, ...) is preserved by capturing and re-invoking its
-- original mapping.
--
-- Leaving: <Esc> (an on_key watcher, live only while active), or mashing
-- j/k -- a rapid jj/kk/jk/kj (the second tap within RAPID_MS of the first) does its
-- step and then drops out. It is all non-blocking, so the cursor stays visible (cf.
-- the getcharstr "busy" cursor bug, neovim/neovim#20793).
local STICKY_KEYS = { 'h', 'j', 'k', 'l' } -- one-step moves while active
-- Motions that enter the submode (wrapped by armStickyEntry). `ge`/`gj`/`gk` are two-key
-- motions; gj/gk carry their own jkStep mapping (mappings.lua) that armStickyEntry
-- captures, so their single-line step survives the entry wrap.
local STICKY_ENTRY =
  { 'h', 'l', 'w', 'b', 'e', 'W', 'B', 'E', 'ge', 'gj', 'gk', '$', '^', 'n', 'N', ';', ',', '.', '*', '#' }
local STICKY_ESC = vim.keycode('<Esc>')
-- "Rapid burst" gap (ms): the largest pause between two j/k taps for them to count as
-- mashed rather than deliberate. Used by the sticky submode -- a rapid jj/kk/jk/kj
-- leaves it. Lower = must mash faster.
local RAPID_MS = 100
local sticky_ns = vim.api.nvim_create_namespace('sticky_motion')
local sticky_active = false
local sticky_armed = false
local sticky_rapid_last = 0 -- vim.uv.now() of the previous j/k tap while active (rapid-exit)

local function sticky_stop()
  if not sticky_active then
    return
  end
  sticky_active = false
  vim.on_key(nil, sticky_ns)
  for _, key in ipairs(STICKY_KEYS) do
    pcall(vim.keymap.del, 'n', key, { buffer = 0 })
  end
end

local function sticky_start()
  if sticky_active then
    return
  end
  sticky_active = true
  sticky_rapid_last = 0 -- fresh burst window, so the first j/k tap is never "rapid"
  -- Buffer-local hjkl (shadowing j/k's 4-line jump and default h/l) do the moves;
  -- deleting them on exit restores the originals. j/k step one line (via jk_step, which
  -- skips hidden-comment lines) and watch for a rapid burst: a second j/k within
  -- RAPID_MS (jj/kk/jk/kj) does its step and then leaves the submode, so a quick mash
  -- escapes it. h/l move but break the j/k burst chain.
  for _, key in ipairs(STICKY_KEYS) do
    vim.keymap.set('n', key, function()
      if key == 'j' or key == 'k' then
        jk_step(key)
        local now = vim.uv.now()
        local rapid = now - sticky_rapid_last <= RAPID_MS
        sticky_rapid_last = now
        if rapid then
          sticky_stop() -- rapid jj/kk/jk/kj -> leave the submode
        end
      else
        vim.cmd('normal! ' .. key) -- h / l: one-step horizontal move
        sticky_rapid_last = 0 -- h / l break the j/k burst chain
      end
    end, { buffer = 0, desc = 'Sticky motion: ' .. key })
  end
  -- Live only while active: observe (never consume) to catch the <Esc> exit.
  vim.on_key(function(_, typed)
    if typed == STICKY_ESC then
      vim.schedule(sticky_stop)
    end
  end, sticky_ns)
end

-- Wrap every STICKY_ENTRY motion so it runs its current behaviour and then arms
-- the submode. Call once from a `User VeryLazy` autocmd (see mappings.lua): spider
-- / asterisk / ... set their maps during startup, after mappings.lua, so we
-- capture the live mapping here and re-invoke it, preserving that behaviour.
function M.armStickyEntry()
  if sticky_armed then
    return
  end
  sticky_armed = true
  for _, key in ipairs(STICKY_ENTRY) do
    local orig = vim.fn.maparg(key, 'n', false, true)
    local run
    if orig.callback then
      run = orig.callback
    elseif type(orig.rhs) == 'string' and orig.rhs ~= '' then
      local keys, remap = vim.keycode(orig.rhs), orig.noremap == 1 and 'n' or 'm'
      run = function()
        vim.api.nvim_feedkeys(keys, remap, false)
      end
    else
      run = function()
        vim.cmd('normal! ' .. key)
      end
    end
    vim.keymap.set('n', key, function()
      run()
      sticky_start()
    end, { desc = 'Sticky-enter (' .. key .. ')' })
  end
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

-------------------- Comments

-- Toggle hiding every comment in the current buffer (per-buffer, so it's "in a
-- file"). Treesitter finds each @comment capture across the main tree and every
-- injected language; each is concealed by kind: a line that is nothing but a comment
-- collapses away entirely (conceal_lines), a comment sharing its line with code has
-- just its text concealed (and the whitespace gap before a trailing comment swallowed,
-- so no dangling run is left). conceal only renders at conceallevel > 0, so we raise it
-- while hidden and restore the prior value on toggle-off. The cursor's own line is
-- always revealed (built-in conceal behaviour) -- navigate onto a hidden comment to
-- read or edit it. State is a buffer var + a private namespace; edits made while
-- hidden aren't re-scanned until the next toggle. (comment_ns -- the namespace these
-- conceal extmarks live in -- is declared up by the Move section, which reads it to
-- keep hidden comment lines out of the j/k movement flow.)

-- Every comment node range in `buf` as { srow, scol, erow, ecol } (0-indexed, ecol
-- exclusive). Walks the main parser and every injected child tree, matching the
-- @comment / @comment.* highlight captures -- portable across languages, where the
-- node type itself is line_comment / block_comment / ... per grammar. {} if the
-- buffer has no treesitter parser.
local function comment_ranges(buf)
  local ranges = {}
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return ranges
  end
  parser:parse(true)
  local function walk(ltree)
    local query = vim.treesitter.query.get(ltree:lang(), 'highlights')
    if query then
      for _, tree in pairs(ltree:trees()) do
        for id, node in query:iter_captures(tree:root(), buf, 0, -1) do
          local name = query.captures[id]
          if name == 'comment' or name:sub(1, 8) == 'comment.' then
            ranges[#ranges + 1] = { node:range() }
          end
        end
      end
    end
    for _, child in pairs(ltree:children()) do
      walk(child)
    end
  end
  walk(parser)
  return ranges
end

-- Place the conceal extmarks for every comment, one buffer line at a time: a line
-- whose comment span has only whitespace on both sides is a pure comment line and is
-- collapsed (conceal_lines); otherwise the comment shares the line with code, so only
-- its text is concealed -- extended left over any whitespace right before it. Returns
-- the number of comments found, so the caller can no-op when there are none.
local function conceal_comments(buf)
  local ranges = comment_ranges(buf)
  for _, r in ipairs(ranges) do
    local sr, sc, er, ec = r[1], r[2], r[3], r[4]
    for lnum = sr, er do
      local line = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1] or ''
      local scol = (lnum == sr) and sc or 0
      local ecol = (lnum == er) and ec or #line
      local left_clear = line:sub(1, scol):match('^%s*$') ~= nil
      local right_clear = line:sub(ecol + 1):match('^%s*$') ~= nil
      if left_clear and right_clear then
        vim.api.nvim_buf_set_extmark(buf, comment_ns, lnum, 0, { conceal_lines = '' })
      else
        local cstart = left_clear and scol or #(line:sub(1, scol):gsub('%s+$', ''))
        vim.api.nvim_buf_set_extmark(buf, comment_ns, lnum, cstart, {
          end_row = lnum,
          end_col = ecol,
          conceal = '',
        })
      end
    end
  end
  return #ranges
end

function M.toggleComments()
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  if vim.b[buf].comments_hidden then
    vim.api.nvim_buf_clear_namespace(buf, comment_ns, 0, -1)
    vim.wo[win].conceallevel = vim.b[buf].comments_prev_cl or 0
    vim.b[buf].comments_hidden = false
    return
  end
  if conceal_comments(buf) == 0 then
    vim.notify('No comments to hide', vim.log.levels.INFO)
    return
  end
  vim.b[buf].comments_prev_cl = vim.wo[win].conceallevel
  vim.wo[win].conceallevel = 2
  vim.b[buf].comments_hidden = true
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
