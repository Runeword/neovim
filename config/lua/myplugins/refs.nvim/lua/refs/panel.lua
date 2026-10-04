local vim = vim

-- The references panel: a list on the right of the references of the symbol under the
-- cursor, grouped by file (the current file first), a line each (one for those sharing
-- a line of code) with lines of code around it (see refs.code), and a preview pane under
-- it. A line holding a definition of the symbol is marked 󰓾, else one holding a call 󰊕.
-- It follows the cursor: whenever it rests in the code, the list shows the references
-- of the symbol there, its own cursor on the reference under the code's, which it marks
-- as the current one (RefsCurrent). In the code, the pane shows the definition of that
-- symbol (the first, if several), in this file or another, and stays blank when there
-- is none; while you browse the list, the reference under the list's cursor. From the
-- code, <Up>/<Down> take the cursor to the list's previous/next reference (M.go). The
-- code shows the references the list shows marked RefsMatch, as the list does, without
-- the list's RefsCurrent on the current one: the cursor on it is mark enough.
local answers = require('refs.answers')
local code = require('refs.code')

local M = {}

local WIDTH = 0.4 -- of the editor's columns

-- The icon (and its highlight group) marking an item of the list by its `ref_kind` (see
-- code.prepare)
local KIND_ICONS = { Definition = { '󰓾 ', 'Constant' }, Call = { '󰊕 ', 'Function' } }

-- The list: win, buf, rows (per line: { file, item, hls, lines, id, done }), key (what it
-- shows: the code buffer, its changedtick, servers attached and the position), main (the
-- code window last entered, where references open), code (its references by buffer, see
-- mark_code)
local list = { rows = {}, code = {} }
local attached = {} -- [buf] = how many servers attached to it so far (see M.attached)
local ns = vim.api.nvim_create_namespace('refs.panel')
local current_ns = vim.api.nvim_create_namespace('refs.current') -- (see mark_current)
local code_ns = vim.api.nvim_create_namespace('refs.code') -- (see mark_code)

-- The references' marks in the code go over its syntax, semantic tokens and diagnostics,
-- and over the marks at the default priority (4096), as the list's go over its code's:
-- grasp.nvim's on the node under the cursor would hide the reference there. (Under
-- flash's labels, at 5000.)
local CODE_PRIORITY = 4097

-- The pane: win, buf, and what it shows: file, tick (of the file's buffer), key
local pane = {}
local pane_ns = vim.api.nvim_create_namespace('refs.pane')

-- Plain text even in the background, and a cursor line of the panel's own (see
-- after/plugin/colors.lua)
local WINHIGHLIGHT = 'NormalNC:Normal,EndOfBuffer:Normal,CursorLine:RefsCursorLine'

local function valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

-- A window showing a file, not floating
local function code_window(win)
  return vim.bo[vim.api.nvim_win_get_buf(win)].buftype == '' and vim.api.nvim_win_get_config(win).relative == ''
end

-- The list is open in this tab page
function M.is_open()
  return valid(list.win) and vim.api.nvim_win_get_tabpage(list.win) == vim.api.nvim_get_current_tabpage()
end

local function key_of(buf, pos)
  local version = vim.api.nvim_buf_get_changedtick(buf) .. '.' .. (attached[buf] or 0)
  return buf .. ':' .. version .. ':' .. pos[1] .. ':' .. pos[2]
end

-- A server attached to `buf`: what the list shows of it is to be asked again, and an
-- answer to a question asked before is outdated (it lacks this server's part)
function M.attached(buf)
  attached[buf] = (attached[buf] or 0) + 1
end

-- The item (see code.prepare) under the list's cursor, or the file's first under a file
-- header
local function selected()
  local row = list.rows[vim.api.nvim_win_get_cursor(list.win)[1]]
  return row and (row.item or row.file[1])
end

-- The file's icon and its highlight group: mini.icons', else nvim-web-devicons'
local function file_icon(filename)
  local name = vim.fn.fnamemodify(filename, ':t')
  local ok, icon, hl = pcall(function()
    return require('mini.icons').get('file', name)
  end)
  if not (ok and icon) then
    ok, icon, hl = pcall(function()
      return require('nvim-web-devicons').get_icon(name, vim.fn.fnamemodify(name, ':e'), { default = true })
    end)
  end
  if ok then
    return icon, hl
  end
end

-- The file as the list's headers and the pane's winbar name it, as { text, hl }
-- segments: its icon, then its path. Given a `width` to fit in, the path loses leading
-- directories as needed (a winbar would cut it anywhere, marking the cut with a '<').
local function file_label(filename, width)
  local icon, icon_hl = file_icon(filename)
  local label = { { ' ' } }
  if icon then
    label[#label + 1] = { icon .. ' ', icon_hl }
  end
  label[#label + 1] = { ' ' }
  local path = vim.fn.fnamemodify(filename, ':p:~:.')
  if width then
    local room = width
    for _, s in ipairs(label) do
      room = room - vim.fn.strdisplaywidth(s[1])
    end
    while vim.fn.strdisplaywidth(path) > room and path:find('/') do
      path = path:gsub('^[^/]*/', '')
    end
    while vim.fn.strdisplaywidth(path) > room and path ~= '' do -- (the name alone is too long)
      path = vim.fn.strcharpart(path, 1)
    end
  end
  label[#label + 1] = { path, 'Directory' }
  return label
end

-- The locations in `answer`, the references or the definitions (see refs.answers), as
-- code.prepare takes them: { filename, buf, pos, end_pos }, positions as { row, col },
-- the row 1-based, the col a 0-indexed byte (servers count characters, in their own
-- encoding). A location past the end of its file (from a server behind on edits) is
-- left out.
local function locations(answer)
  local items, seen, lines = {}, {}, {}
  for _, r in ipairs(answer or {}) do
    for _, loc in ipairs(r.result) do
      local uri, range = loc.uri or loc.targetUri, loc.range or loc.targetSelectionRange
      local buf, filename = vim.uri_to_bufnr(uri), vim.uri_to_fname(uri)
      lines[uri] = lines[uri] or code.lines(filename, buf)
      local first, last = lines[uri][range.start.line + 1], lines[uri][range['end'].line + 1]
      if first and last then
        local encoding = r.client.offset_encoding
        local item = {
          filename = filename,
          buf = buf,
          pos = { range.start.line + 1, vim.str_byteindex(first, encoding, range.start.character, false) },
          end_pos = { range['end'].line + 1, vim.str_byteindex(last, encoding, range['end'].character, false) },
        }
        local key = filename .. ':' .. item.pos[1] .. ':' .. item.pos[2]
        if not seen[key] then -- (servers sharing a file can both answer)
          seen[key] = true
          items[#items + 1] = item
        end
      end
    end
  end
  return items
end

-------------------- Code

-- The references the list shows are marked in their files' buffers too, as the list
-- marks them. Each gets an extmark there, without highlight (so it moves with edits),
-- once the buffer is loaded; the decoration provider highlights those in view (M.mark),
-- in the panel's tab page only.

-- Redraw the windows of this tab page showing a buffer of `bufs` ([buf] = anything), with
-- the next screen update (without `flush = false`, nvim__redraw draws the screen at once)
local function redraw_code(bufs)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if bufs[vim.api.nvim_win_get_buf(win)] then
      vim.api.nvim__redraw({ win = win, valid = false, flush = false })
    end
  end
end

-- Set the extmarks on the references the list shows in `buf`, if not done yet and it's
-- loaded
local function track(buf)
  local refs = list.code[buf]
  if refs.marked or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  for _, ref in ipairs(refs) do
    vim.api.nvim_buf_set_extmark(buf, code_ns, ref.pos[1] - 1, ref.pos[2], {
      end_row = ref.end_pos[1] - 1,
      end_col = ref.end_pos[2],
      strict = false,
    })
  end
  refs.marked = true
end

-- Mark the references of `files` (see code.prepare) in the code, in place of those
-- marked so far; none without `files`
local function mark_code(files)
  local redraw = {} -- the buffers that had some, and those getting some
  for buf, refs in pairs(list.code) do
    redraw[buf] = true
    if refs.marked and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, code_ns, 0, -1)
    end
  end
  list.code = {}
  for _, f in ipairs(files or {}) do
    redraw[f.buf] = true
    -- (a file reached by two paths, as through a symlink, is one buffer)
    list.code[f.buf] = vim.list_extend(list.code[f.buf] or {}, f.refs)
  end
  for buf in pairs(list.code) do
    track(buf)
  end
  redraw_code(redraw)
end

-- Highlight the references the list shows in `buf`, rows `toprow`..`botrow` (0-indexed)
-- of it being drawn: RefsMatch (in the panel's tab page only)
function M.mark(buf, toprow, botrow)
  if not (list.code[buf] and M.is_open()) then
    return
  end
  track(buf) -- (loaded since the list showed them)
  local opts = { details = true, overlap = true }
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, code_ns, { toprow, 0 }, { botrow, -1 }, opts)) do
    vim.api.nvim_buf_set_extmark(buf, code_ns, m[2], m[3], {
      end_row = m[4].end_row,
      end_col = m[4].end_col,
      hl_group = 'RefsMatch',
      priority = CODE_PRIORITY,
      ephemeral = true,
    })
  end
end

-------------------- Pane

-- The pane shows a scratch copy of the file, not its buffer, so the pane's highlight
-- and cursor never reach a code window showing that buffer; a winbar names the file it
-- comes from, as the list's headers do.

local function scratch_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  return buf
end

-- Show `buf` in the pane without the autocommands of entering a buffer
local function pane_set_buf(buf)
  local eventignore = vim.o.eventignore
  vim.o.eventignore = 'all'
  pcall(vim.api.nvim_win_set_buf, pane.win, buf)
  vim.o.eventignore = eventignore
end

-- A scratch copy of the item's file (its buffer if loaded, else read from disk) with
-- the same highlighting, kept while the pane shows that file and its buffer is unchanged
local function pane_buffer(item)
  local loaded = item.buf and vim.api.nvim_buf_is_loaded(item.buf)
  local tick = loaded and vim.api.nvim_buf_get_changedtick(item.buf) or 0
  if pane.file == item.filename and pane.tick == tick and pane.buf and vim.api.nvim_buf_is_valid(pane.buf) then
    return pane.buf
  end
  local buf = scratch_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, code.lines(item.filename, item.buf))
  local ft = loaded and vim.bo[item.buf].filetype or vim.filetype.match({ filename = item.filename, buf = buf })
  if ft and ft ~= '' then
    local lang = vim.treesitter.language.get_lang(ft)
    if not (lang and pcall(vim.treesitter.start, buf, lang)) then
      vim.bo[buf].syntax = ft
    end
  end
  pane.buf, pane.file, pane.tick = buf, item.filename, tick
  return buf
end

-- { text, hl } segments as a winbar
local function winbar(segments)
  local parts = {}
  for _, s in ipairs(segments) do
    local text = s[1]:gsub('%%', '%%%%')
    parts[#parts + 1] = s[2] and ('%#' .. s[2] .. '#' .. text .. '%*') or text
  end
  return table.concat(parts)
end

-- What the pane shows around the code: the winbar `label`, line numbers and the cursor
-- line. None of it while blank (`label` nil): the empty buffer would show its one line.
local function pane_frame(label)
  local wo = vim.wo[pane.win]
  wo.winbar, wo.number, wo.cursorline = label or '', label ~= nil, label ~= nil
end

-- Point the pane at `item`, opening it under the list first (blank). `false` blanks it,
-- nil keeps what it shows.
local function pane_show(item)
  if not valid(pane.win) then
    pane.win = vim.api.nvim_open_win(scratch_buf(), false, {
      split = 'below',
      win = list.win,
      height = math.max(math.floor(vim.api.nvim_win_get_height(list.win) / 2), 1),
      noautocmd = true,
    })
    pane.key = 'blank'
    vim.w[pane.win].refs = 'pane'
    local wo = vim.wo[pane.win]
    wo.signcolumn, wo.foldcolumn, wo.wrap = 'no', '0', false
    -- (the winbar on the plain background, as the list's file headers)
    wo.winfixheight, wo.winhighlight = true, 'CursorLine:RefsCursorLine,WinBar:Normal,WinBarNC:Normal'
    pane_frame(nil)
  end
  if item == nil then
    return
  elseif item == false then
    if pane.key ~= 'blank' then
      pane_set_buf(scratch_buf())
      pane_frame(nil)
      pane.key = 'blank'
    end
    return
  end
  local buf = pane_buffer(item)
  local refs = item.refs or { item } -- (an item of the list: the references on its line)
  local key = item.pos[1] .. ':' .. item.pos[2] .. ':' .. #refs
  if vim.api.nvim_win_get_buf(pane.win) == buf and pane.key == key then
    return
  end
  pane_set_buf(buf)
  local label = file_label(item.filename, vim.api.nvim_win_get_width(pane.win))
  pane_frame(winbar(label)) -- (before centering: the winbar takes a row)
  vim.api.nvim_buf_clear_namespace(buf, pane_ns, 0, -1)
  for _, ref in ipairs(refs) do
    vim.api.nvim_buf_set_extmark(buf, pane_ns, ref.pos[1] - 1, ref.pos[2], {
      end_row = ref.end_pos[1] - 1,
      end_col = ref.end_pos[2],
      hl_group = 'RefsMatch',
      strict = false,
    })
  end
  pcall(vim.api.nvim_win_set_cursor, pane.win, item.pos)
  vim.api.nvim_win_call(pane.win, function()
    vim.cmd('normal! zz')
  end)
  pane.key = key
end

-- Update the pane: while you browse the list, the reference under its cursor; in the
-- code, what the definition lookup for the cursor found, once it's in. Closes the pane
-- once the list is gone (closed other than by M.close, as by :only), and drops the marks
-- of its references in the code.
function M.sync()
  if not valid(list.win) then
    if valid(pane.win) then
      pcall(vim.api.nvim_win_close, pane.win, true)
    end
    pane.win = nil
    mark_code()
    return
  elseif not M.is_open() then
    return -- (open in another tab page)
  end
  if vim.api.nvim_get_current_win() ~= list.win then
    local buf, cursor = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)
    local entry = answers.at(buf, { cursor[1] - 1, cursor[2] })
    if not (entry and entry.defs ~= nil) then
      return pane_show(nil) -- (until the lookup is in)
    end
    return pane_show(locations(entry.defs)[1] or false)
  end
  pane_show(selected())
end

local sync_pending = false

-- M.sync once the current event is done (a window being closed is still there)
function M.sync_later()
  if not sync_pending then
    sync_pending = true
    vim.schedule(function()
      sync_pending = false
      M.sync()
    end)
  end
end

-- Look up the definitions of the symbol under the cursor, for the pane
function M.definition()
  local buf, cursor = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)
  answers.ask(buf, { cursor[1] - 1, cursor[2] }, 'defs', M.sync)
end

-------------------- List

-- A context line as virtual line chunks: its prefix, then its code (a gap between
-- blocks has no row: the guide and '...' alone)
local function context_line(line)
  local chunks = vim.list_slice(line.prefix)
  return line.row and vim.list_extend(chunks, code.chunks(line.block, line.row)) or chunks
end

-- Draw `files` (see code.prepare), the code buffer's file first: a header per file,
-- then a line per item, a line of code with each reference on it marked (RefsMatch).
-- The context lines go under these as virtual lines (so the cursor steps from item to
-- item over them): the lines above an item under the list line before it, those below
-- it under its own. Each gets the tree guide continued down, then blanks and its line
-- number under the reference's icon and line number columns. The code is highlighted
-- once in view (M.highlight).
local function render(files, lnum_width, code_buf)
  table.sort(files, function(a, b)
    if (a.buf == code_buf) ~= (b.buf == code_buf) then
      return a.buf == code_buf
    end
    return a.filename < b.filename
  end)
  local lines, rows = {}, {}
  -- A list line of { text, hl } segments, for `row`
  local function add(segments, row)
    local text, col = {}, 0
    row.hls = {}
    for _, s in ipairs(segments) do
      text[#text + 1] = s[1]
      if s[2] then
        row.hls[#row.hls + 1] = { col, col + #s[1], s[2] }
      end
      col = col + #s[1]
    end
    lines[#lines + 1] = table.concat(text)
    rows[#lines] = row
  end
  -- A context line under the last list line: `guide`, then row `r` of `block`; with no
  -- row, a gap (lines left out), marked '...' ending under the line numbers
  local function context(guide, block, r)
    local prefix = { { ' ' }, { guide, 'LineNr' } }
    if r then
      prefix[3] = { ('  %' .. lnum_width .. 'd '):format(r), 'NonText' }
    else
      prefix[3] = { ('%' .. (lnum_width + 2) .. 's'):format('...'), 'NonText' }
    end
    local row = rows[#lines]
    row.lines = row.lines or {}
    row.lines[#row.lines + 1] = { prefix = prefix, block = block, row = r }
  end
  for _, f in ipairs(files) do
    local header = file_label(f.filename)
    vim.list_extend(header, { { ' ' }, { (' %d '):format(#f.refs), 'TabLineSel' } })
    add(header, { file = f })
    for i, item in ipairs(f) do
      local more = i < #f -- (the tree's guide goes on down)
      if item.gap then
        context('│ ')
      end
      for r = item.above[1], item.above[2] do
        context('│ ', item.block, r)
      end
      add({
        { ' ' },
        { more and '├╴' or '└╴', 'LineNr' },
        KIND_ICONS[item.ref_kind] or { '  ' },
        { ('%' .. lnum_width .. 'd'):format(item.pos[1]), 'LineNr' },
        { ' ' },
        { item.code }, -- (last: see M.highlight)
      }, { file = f, item = item })
      for r = item.below[1], item.below[2] do
        context(more and '│ ' or '  ', item.block, r)
      end
    end
  end

  local buf = list.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, current_ns, 0, -1)
  for i, row in ipairs(rows) do
    for _, hl in ipairs(row.hls) do
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, hl[1], { end_col = hl[2], hl_group = hl[3] })
    end
    if row.item then -- (its code ends the line; the marks go over the code's highlighting)
      local col = #lines[i] - #row.item.code
      for _, ref in ipairs(row.item.refs) do
        local opts = { end_col = col + ref.match[2], hl_group = 'RefsMatch', priority = 4097 }
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, col + ref.match[1], opts)
      end
    end
    if row.lines then
      local opts = { virt_lines = vim.tbl_map(context_line, row.lines), virt_lines_overflow = 'scroll' }
      row.id = vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, opts)
    end
  end
  list.rows = rows
end

-- Highlight the code in view not highlighted yet, the references' and their context's,
-- in the list's window from line `toprow` (0-indexed) down, as far as its height goes
-- (the decoration provider's botrow can be stale, and counts the buffer's lines only)
function M.highlight(win, toprow)
  if win ~= list.win then
    return
  end
  local room = vim.api.nvim_win_get_height(win)
  -- (from the line above the top one: the lines under it can show at the top too)
  for i = math.max(toprow, 1), #list.rows do
    local row = list.rows[i]
    if row and not row.done then
      row.done = true
      local spans = {} -- [block] = the rows of it to highlight
      local function need(b, r)
        local span = spans[b] or { r, r }
        spans[b] = { math.min(span[1], r), math.max(span[2], r) }
      end
      if row.item then
        need(row.item.block, row.item.pos[1])
      end
      for _, line in ipairs(row.lines or {}) do
        if line.row then
          need(line.block, line.row)
        end
      end
      for b, span in pairs(spans) do
        code.highlight(b, span[1], span[2])
      end
      if row.item then -- its code ends the line (see render)
        local text = vim.api.nvim_buf_get_lines(list.buf, i - 1, i, false)[1] or ''
        local col = #text - #row.item.code
        for _, c in ipairs(code.chunks(row.item.block, row.item.pos[1])) do
          if c[2] then
            vim.api.nvim_buf_set_extmark(list.buf, ns, i - 1, col, { end_col = col + #c[1], hl_group = c[2] })
          end
          col = col + #c[1]
        end
      end
      if row.lines then
        local opts = { id = row.id, virt_lines = vim.tbl_map(context_line, row.lines), virt_lines_overflow = 'scroll' }
        vim.api.nvim_buf_set_extmark(list.buf, ns, i - 1, 0, opts)
      end
    end
    if i > toprow then
      room = room - 1 - (row and row.lines and #row.lines or 0)
      if room <= 0 then
        return
      end
    end
  end
end

-- Which of the references of `item` (see code.prepare) is the one at `pos` (0-indexed
-- row, byte col) in `buf`: its index in `item.refs`, if any
local function ref_at(item, buf, pos)
  if item.buf == buf and item.pos[1] == pos[1] + 1 then
    for k, ref in ipairs(item.refs) do
      if ref.pos[2] <= pos[2] and pos[2] <= ref.end_pos[2] then
        return k
      end
    end
  end
end

-- Mark reference `k` of the item on list line `row` as the current one, the one under
-- the code's cursor, over its RefsMatch (RefsCurrent); without a `row`, none
local function mark_current(row, k)
  vim.api.nvim_buf_clear_namespace(list.buf, current_ns, 0, -1)
  local item = row and list.rows[row].item
  if item then
    local text = vim.api.nvim_buf_get_lines(list.buf, row - 1, row, false)[1] or ''
    local col, match = #text - #item.code, item.refs[k].match -- (its code ends the line, see render)
    local opts = { end_col = col + match[2], hl_group = 'RefsCurrent', priority = 4098 }
    vim.api.nvim_buf_set_extmark(list.buf, current_ns, row - 1, col + match[1], opts)
  end
end

-- Mark the reference at `pos` in `code_buf` as the current one, and put the list's
-- cursor on the item holding it, else on its file's header (the cursor stays put while
-- you browse the list: M.show can draw it again then)
local function follow(code_buf, pos)
  local at, header
  for i, row in ipairs(list.rows) do
    local k = row.item and ref_at(row.item, code_buf, pos)
    if k then
      at = i
      mark_current(i, k)
      break
    elseif not row.item and row.file.buf == code_buf then
      header = header or i
    end
  end
  if not at then
    mark_current()
  end
  if vim.api.nvim_get_current_win() ~= list.win then
    vim.api.nvim_win_set_cursor(list.win, { at or header or 1, 0 })
  end
end

-- Whether position `p` ({ row, col }) comes before `q`
local function before(p, q)
  return p[1] < q[1] or (p[1] == q[1] and p[2] < q[2])
end

-- Set `def` on the references (see locations) that are definitions. What the servers
-- call definitions, `defs`, can be assignments too (lua_ls, pyright and bashls give
-- those): each is the first reference in its file that its range overlaps (a server can
-- give a whole construct's, as bashls gives a function's: uses of the symbol in its body
-- fall in it too), and of these, the declarations are the definitions (see
-- code.assignment). A symbol that only ever gets assigned (a Lua field, a Python or
-- shell variable) is defined where it's first assigned, in the file of the first.
local function mark_definitions(refs, defs)
  local found = {}
  for _, def in ipairs(defs) do
    local first
    for _, ref in ipairs(refs) do
      local overlap = ref.buf == def.buf and not before(def.end_pos, ref.pos) and not before(ref.end_pos, def.pos)
      if overlap and not (first and before(first.pos, ref.pos)) then
        first = ref
      end
    end
    found[#found + 1] = first
  end
  local parsers, declared = {}, false
  for _, ref in ipairs(found) do
    if code.assignment(ref, parsers) ~= 'affectation' then
      ref.def, declared = true, true
    end
  end
  if declared or #found == 0 then
    return
  end
  local first
  for _, ref in ipairs(refs) do
    if ref.buf == found[1].buf and not (first and before(first.pos, ref.pos)) and code.assignment(ref, parsers) then
      first = ref
    end
  end
  first = first or found[1]
  first.def = true
end

-- Show `refs` (see refs.answers), the references of the symbol at `pos` in `code_buf`,
-- its definitions marked: when they aren't known yet, it shows them again once they are
-- (if the list still shows that position)
function M.show(code_buf, pos, refs)
  if not M.is_open() then
    return
  end
  local key = key_of(code_buf, pos)
  list.key = key
  local entry, items = answers.at(code_buf, pos), locations(refs)
  local defs = entry and entry.defs
  mark_definitions(items, locations(defs))
  local files, lnum_width = code.prepare(items)
  local view = vim.api.nvim_win_call(list.win, vim.fn.winsaveview)
  render(files, lnum_width, code_buf)
  -- The view keeps the context lines the old list showed above its top line (topfill):
  -- no more than the new list has there, or Neovim draws the rest as a diff's deleted
  -- lines ('-'s), and in an empty list never takes them away
  local above = list.rows[math.min(view.topline, #list.rows) - 1] -- (its context lines go there)
  view.topfill = math.min(view.topfill, above and above.lines and #above.lines or 0)
  vim.api.nvim_win_call(list.win, function()
    vim.fn.winrestview(view)
  end)
  mark_code(files)
  vim.wo[list.win].cursorline = #list.rows > 0 -- (an empty list still has a line to highlight)
  follow(code_buf, pos)
  M.sync()
  if defs == nil then
    answers.ask(code_buf, pos, 'defs', function(found)
      -- (not once the code is edited: the references' positions are its text's before,
      -- and the code would mark them where they were)
      if found and #found > 0 and list.key == key and key_of(code_buf, pos) == key then
        M.show(code_buf, pos, refs)
      end
    end)
  end
end

-- Show the references of the symbol under the cursor, once the servers have answered
function M.refresh()
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local pos = { cursor[1] - 1, cursor[2] }
  local key = key_of(buf, pos)
  if not M.is_open() or list.key == key then
    return
  end
  answers.ask(buf, pos, 'refs', function(refs)
    if refs == nil or list.key == key or not valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
      return
    end
    local now = vim.api.nvim_win_get_cursor(win)
    if key_of(buf, { now[1] - 1, now[2] }) == key then -- (still there)
      M.show(buf, pos, refs)
    end
  end)
end

-- Show the references of the symbol under the cursor and move into the list, onto the
-- reference under the cursor, once the servers have answered; with none, say so and
-- stay (`gf`)
function M.focus()
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local pos = { cursor[1] - 1, cursor[2] }
  local key = key_of(buf, pos)
  answers.ask(buf, pos, 'refs', function(refs)
    local here = vim.api.nvim_get_current_win() == win and vim.api.nvim_win_get_buf(win) == buf
    local now = here and vim.api.nvim_win_get_cursor(win)
    if refs == nil or not (now and key_of(buf, { now[1] - 1, now[2] }) == key) then
      return -- (no answer, or you moved on meanwhile)
    end
    local found = 0
    for _, r in ipairs(refs or {}) do
      found = found + #r.result
    end
    if found == 0 then
      return vim.notify('No references', vim.log.levels.WARN)
    end
    M.open()
    if list.key ~= key then
      M.show(buf, pos, refs)
    end
    follow(buf, pos)
    vim.api.nvim_set_current_win(list.win)
  end)
end

-- The code window to open references in: the one last entered, else any showing a file
local function main_win()
  if valid(list.main) and vim.api.nvim_win_get_tabpage(list.main) == vim.api.nvim_get_current_tabpage() then
    return list.main
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if code_window(win) then
      return win
    end
  end
end

-- Show `item` in code window `win` with the cursor on it (the jump list keeps where it
-- was), centered; with `keep_view`, centered only if it was out of view
local function open(item, win, keep_view)
  local buf = item.buf or vim.fn.bufadd(item.filename)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  local in_view = keep_view
    and vim.api.nvim_win_get_buf(win) == buf
    and vim.fn.line('w0', win) <= item.pos[1]
    and item.pos[1] <= vim.fn.line('w$', win)
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! m'") -- (the jump list)
  end)
  vim.api.nvim_win_set_buf(win, buf)
  pcall(vim.api.nvim_win_set_cursor, win, item.pos)
  vim.api.nvim_win_call(win, function()
    vim.cmd(in_view and 'normal! zv' or 'normal! zzzv')
  end)
end

-- Open the reference under the list's cursor in the code window, and move there
local function jump()
  local item, win = selected(), main_win()
  if item and win then
    open(item, win)
    vim.api.nvim_set_current_win(win)
  end
end

-- The list line of the next item after line `row` (`dir` 1) or the previous (-1), if any
local function item_row(row, dir)
  repeat
    row = row + dir
  until not list.rows[row] or list.rows[row].item
  return list.rows[row] and row
end

-- Move the list's cursor to the next (`dir` 1) or previous (-1) item, [count] times
local function step(dir)
  local row = vim.api.nvim_win_get_cursor(list.win)[1]
  for _ = 1, vim.v.count1 do
    row = item_row(row, dir) or row
  end
  vim.api.nvim_win_set_cursor(list.win, { row, 0 })
end

-- From a code window, take the cursor to the list's next (`dir` 1) or previous (-1)
-- reference, [count] times on, the list's cursor along (<Up>/<Down>): the references an
-- item holds come in turn, so the list's cursor stays on it meanwhile. The list holds
-- still, where following would reorder it to put the file landed in first. False when
-- the list isn't open here or this isn't a code window.
function M.go(dir)
  local win = vim.api.nvim_get_current_win()
  if not (M.is_open() and code_window(win)) then
    return false
  end
  local row, cursor = vim.api.nvim_win_get_cursor(list.win)[1], vim.api.nvim_win_get_cursor(win)
  local item = list.rows[row] and list.rows[row].item
  -- (from the reference under the cursor, when the list's item holds it)
  local k = item and ref_at(item, vim.api.nvim_win_get_buf(win), { cursor[1] - 1, cursor[2] })
  local ref
  for _ = 1, vim.v.count1 do
    if not (k and item.refs[k + dir]) then -- (on to the next item)
      local i = item_row(row, dir)
      if not i then
        break
      end
      row, item = i, list.rows[i].item
      k = dir > 0 and 0 or #item.refs + 1
    end
    k = k + dir
    ref = item.refs[k]
  end
  if ref then
    vim.api.nvim_win_set_cursor(list.win, { row, 0 })
    mark_current(row, k)
    open(ref, win, true)
    cursor = vim.api.nvim_win_get_cursor(win)
    list.key = key_of(vim.api.nvim_win_get_buf(win), { cursor[1] - 1, cursor[2] })
    M.definition()
  end
  return true
end

function M.close()
  for _, win in ipairs({ pane.win, list.win }) do
    if valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  pane.win, list.win = nil, nil
  mark_code()
end

-- Open the panel on the right, then show the symbol under the cursor
function M.open()
  if M.is_open() then
    return
  end
  M.close() -- (open in another tab page)
  local buf = scratch_buf()
  vim.bo[buf].filetype = 'refs'
  vim.bo[buf].modifiable = false
  list.buf, list.rows, list.key = buf, {}, nil
  local function map(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  map('<cr>', jump, 'Open the reference')
  map('<2-LeftMouse>', jump, 'Open the reference')
  map('o', function()
    jump()
    M.close()
  end, 'Open the reference and close the panel')
  map('q', M.close, 'Close the panel')
  map('<esc>', M.close, 'Close the panel')
  -- One item at a time (j/k would otherwise do this config's 4-line jump)
  for _, lhs in ipairs({ 'j', '<down>' }) do
    map(lhs, function()
      step(1)
    end, 'Next reference')
  end
  for _, lhs in ipairs({ 'k', '<up>' }) do
    map(lhs, function()
      step(-1)
    end, 'Previous reference')
  end
  vim.api.nvim_create_autocmd('CursorMoved', { buffer = buf, callback = M.sync })

  list.win = vim.api.nvim_open_win(buf, false, { split = 'right', win = -1, width = math.floor(vim.o.columns * WIDTH) })
  vim.w[list.win].refs = 'list'
  local wo = vim.wo[list.win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn, wo.statuscolumn = false, false, 'no', '0', ''
  wo.cursorline, wo.wrap, wo.list, wo.spell, wo.winfixwidth = false, false, false, false, true -- (see M.show)
  wo.winbar, wo.fillchars, wo.winhighlight = '', 'eob: ', WINHIGHLIGHT
  M.sync() -- (opens the pane)
  if vim.bo.buftype == '' then
    M.refresh()
    M.definition()
  end
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

-- Close the panel when the window being quit (QuitPre) is the tab page's last code
-- window, so :q there quits Neovim, or closes the tab page or the window, as it would
-- without the panel
function M.quitting()
  if not M.is_open() then
    return
  end
  local win = vim.api.nvim_get_current_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= win and code_window(w) then
      return -- (code is left to show the references of)
    end
  end
  M.close()
end

-- Track the code window last entered; keep the pane in step with where you are. The
-- pane itself is for looking only: landing in it (<C-Right> from the lower half of the
-- screen, a click) moves on to the list.
function M.entered()
  local win = vim.api.nvim_get_current_win()
  local code_win = code_window(win)
  if code_win then
    list.main = win
  end
  if not M.is_open() then
    return
  elseif win == pane.win then
    vim.schedule(function()
      if valid(list.win) then
        pcall(vim.api.nvim_set_current_win, list.win)
      end
    end)
  elseif code_win then
    M.definition()
  else
    M.sync_later()
  end
end

return M
