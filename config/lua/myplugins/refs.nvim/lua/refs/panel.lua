local vim = vim

-- The references panel: a list on the right of the references of the symbol under the
-- cursor, grouped by file (the current file first), a line each (one for those sharing
-- a line of code) with lines of code around it (see refs.code), and a preview pane under
-- it. A line holding a definition of the symbol is marked 󰓾, else one assigning it 󰏫,
-- else one holding a call 󰊕.
-- It follows the cursor: whenever it rests in the code, the list shows the references
-- of the symbol there, its own cursor on the reference under the code's, which it marks
-- as the current one (RefsCurrent). The same answer again (another use of the symbol)
-- only moves that cursor, and the files keep their order while the cursor is on a
-- reference the list shows (as when <Up>/<Down> take it from file to file). In the
-- code, the pane shows the definition of that symbol (the first, if several), in this
-- file or another, and stays blank when there is none; while you browse the list, the
-- reference under the list's cursor. From the code, <Up>/<Down> take the cursor to the
-- list's previous/next reference (M.go), where it is now: the references are tracked
-- through edits. The code shows the references the list shows marked RefsMatch, as the
-- list does, without the list's RefsCurrent on the current one: the cursor on it is
-- mark enough.
--
-- The panel's windows hold their buffers ('winfixbuf'), and are never all a tab page
-- holds: when its last code window closes (:bdelete there), a code window takes its
-- place.
local answers = require('refs.answers')
local code = require('refs.code')

local M = {}

local WIDTH = 0.4 -- of the editor's columns
local DEFS_WAIT_MS = 150 -- how long the list waits for definitions not known yet, to be drawn once

-- The icon (and its highlight group) marking an item of the list by its `ref_kind` (see
-- code.prepare)
local KIND_ICONS = {
  Definition = { 'ƒ ', 'Constant' },
  Assignment = { '= ', 'Statement' },
  Call = { '󰅲 ', 'Function' },
}

-- The list: win, buf, rows (per line: { file, item, hls, lines, id, done }), key (the word
-- it was last asked about or shown for, see key_of), sig (of the answer it shows), order
-- (of its files), gen (counts its drawings), asked (counts the questions M.refresh asked),
-- main (the code window last entered, where references open), prev (the window the list
-- was entered from), code (its references by buffer, see mark_code)
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

-- The pane: win, buf (a copy of a file), blank (an empty buffer), and what it shows:
-- file, version (of the file's text), key
local pane = {}
local pane_ns = vim.api.nvim_create_namespace('refs.pane')

-- Plain text even in the background, and a cursor line of the panel's own (see
-- after/plugin/colors.lua)
local WINHIGHLIGHT = 'NormalNC:Normal,EndOfBuffer:Normal,CursorLine:RefsCursorLine'

-- The window options the panel sets, and their values in a code window (taken when it
-- opens), for a window it gives back as a code window (see release)
local WIN_OPTS = {
  'number',
  'relativenumber',
  'signcolumn',
  'foldcolumn',
  'statuscolumn',
  'cursorline',
  'wrap',
  'list',
  'spell',
  'winfixwidth',
  'winfixheight',
  'winfixbuf',
  'winbar',
  'fillchars',
  'winhighlight',
}
local code_opts

local function valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

-- A window showing a file, not floating, not the panel's
local function code_window(win)
  return valid(win)
    and win ~= list.win
    and win ~= pane.win
    and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ''
    and vim.api.nvim_win_get_config(win).relative == ''
end

-- The list is open in this tab page
function M.is_open()
  return valid(list.win)
    and vim.api.nvim_win_get_buf(list.win) == list.buf
    and vim.api.nvim_win_get_tabpage(list.win) == vim.api.nvim_get_current_tabpage()
end

-- Take the options of code window `win`, for those the panel gives back
local function snapshot(win)
  if valid(win) then
    code_opts = {}
    for _, name in ipairs(WIN_OPTS) do
      code_opts[name] = vim.wo[win][name]
    end
  end
end

-- Give `win`, a window the panel had (or one split from it), back as a code window
local function release(win)
  for _, name in ipairs(WIN_OPTS) do
    local value = code_opts and code_opts[name]
    if value == nil then
      value = vim.api.nvim_get_option_info2(name, {}).default
    end
    pcall(vim.api.nvim_set_option_value, name, value, { win = win })
  end
  pcall(vim.api.nvim_win_set_config, win, { focusable = true })
  vim.w[win].refs = nil
end

-- What the list shows, or the pane previews, for the word at `pos` in `buf`, as its text
-- is now: the word, the buffer's text, the servers attached to it, and the text of the
-- other files (see answers.epoch)
local function key_of(buf, pos)
  local start = answers.word_start(buf, pos)
  local version = vim.api.nvim_buf_get_changedtick(buf) .. '.' .. (attached[buf] or 0) .. '.' .. answers.epoch()
  return buf .. ':' .. version .. ':' .. start[1] .. ':' .. start[2]
end

-- The word at `pos` in `buf`, as refs.answers keys its questions (for answers.cancel)
local function word_key(buf, pos)
  local start = answers.word_start(buf, pos)
  return { [buf .. ':' .. start[1] .. ':' .. start[2]] = true }
end

-- A server attached to `buf` or left it: what the list shows of it is to be asked again
function M.attached(buf)
  attached[buf] = (attached[buf] or 0) + 1
end

-- `buf` was wiped: the list draws again what it showed in it (a file opened again gets
-- another buffer)
function M.wiped(buf)
  attached[buf] = nil
  if list.code[buf] then
    list.code[buf], list.sig = nil, nil
  end
end

-- The item (see code.prepare) under the cursor of `win` (a window showing the list): the
-- one a context line goes with, the file's first under a file header
local function selected(win)
  local row = list.rows[vim.api.nvim_win_get_cursor(win or list.win)[1]]
  return row and (row.item or row.owner or row.file[1])
end

-- The file's icon and its highlight group: mini.icons', else nvim-web-devicons'
local icons = {} -- [file name] = { icon, hl }, or false without one
local icon_of -- the icons' source: mini.icons, else nvim-web-devicons, else none (false)

local function file_icon(filename)
  local name = vim.fs.basename(filename)
  if icons[name] == nil then
    if icon_of == nil then
      local ok, mini = pcall(require, 'mini.icons')
      local devicons_ok, devicons = pcall(require, 'nvim-web-devicons')
      icon_of = ok and function(n)
        return mini.get('file', n)
      end or devicons_ok and function(n)
        return devicons.get_icon(n, vim.fn.fnamemodify(n, ':e'), { default = true })
      end or false
    end
    local ok, icon, hl = false, nil, nil
    if icon_of then
      ok, icon, hl = pcall(icon_of, name)
    end
    icons[name] = ok and icon and { icon, hl } or false
  end
  if icons[name] then
    return icons[name][1], icons[name][2]
  end
end

-- The file as the list's headers and the pane's winbar name it, as { text, hl }
-- segments: its icon, then its path. Given a `width` to fit in, the path loses leading
-- directories as needed (a winbar would cut it anywhere, marking the cut with a '<').
local paths = {} -- [cwd \0 filename] = its path as shown

local function file_label(filename, width)
  local icon, icon_hl = file_icon(filename)
  local label = { { ' ' } }
  if icon then
    label[#label + 1] = { icon .. ' ', icon_hl }
  end
  label[#label + 1] = { ' ' }
  local key = vim.uv.cwd() .. '\0' .. filename
  paths[key] = paths[key] or vim.fn.fnamemodify(filename, ':p:~:.')
  local path = paths[key]
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

-- The byte of character `char` (counted in `encoding`) of row `row` (0-indexed) of `f`
-- (see locations): the same in an ASCII line (once known to be, a minified file's line
-- isn't counted through for each reference on it)
local function byte_of(f, row, encoding, char)
  local line = f.line(row + 1)
  if f.ascii[row] == nil then
    f.ascii[row] = not line:find('[\128-\255]')
  end
  if encoding == 'utf-8' or f.ascii[row] then
    return math.min(char, #line)
  end
  return vim.str_byteindex(line, encoding, char, false)
end

-- The locations in `answer`, the references or the definitions (see refs.answers), as
-- code.prepare takes them: { filename, buf, pos, end_pos }, positions as { row, col },
-- the row 1-based, the col a 0-indexed byte (servers count characters, in their own
-- encoding). A location past the end of its file (from a server behind on edits) is
-- left out. Its `buf` is the file's buffer, if it has one. The files not loaded are read
-- into `read_files`, for code.prepare.
local function locations(answer, read_files)
  local items, seen, files = {}, {}, {}
  read_files = read_files or {}
  for _, r in ipairs(answer or {}) do
    for _, loc in ipairs(r.result) do
      local uri, range = loc.uri or loc.targetUri, loc.range or loc.targetSelectionRange
      local f = files[uri]
      if not f then
        local buf, filename = answers.uri_buf(uri), vim.uri_to_fname(uri)
        local line
        if buf and vim.api.nvim_buf_is_loaded(buf) then
          local got = {}
          line = function(n)
            got[n] = got[n] or vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1] or false
            return got[n] or nil
          end
        else
          read_files[filename] = read_files[filename] or code.file(filename)
          local file = read_files[filename]
          line = function(n)
            return code.line(file, n)
          end
        end
        f = { buf = buf, filename = filename, line = line, ascii = {} }
        files[uri] = f
      end
      local s, e = range.start, range['end']
      if f.line(s.line + 1) and f.line(e.line + 1) then
        local encoding = r.client.offset_encoding
        local item = {
          filename = f.filename,
          buf = f.buf,
          pos = { s.line + 1, byte_of(f, s.line, encoding, s.character) },
          end_pos = { e.line + 1, byte_of(f, e.line, encoding, e.character) },
        }
        local key = f.filename .. ':' .. item.pos[1] .. ':' .. item.pos[2]
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
-- marks them. Each gets an extmark there, without highlight (so it moves with edits, and
-- tells where the reference is now, see ref_pos), once the buffer is loaded; the
-- decoration provider highlights those in view (M.mark), in the panel's tab page only.

-- Redraw the windows of this tab page showing a buffer of `bufs` ([buf] = anything), with
-- the next screen update (without `flush = false`, nvim__redraw draws the screen at once)
local function redraw_code(bufs)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if bufs[vim.api.nvim_win_get_buf(win)] then
      vim.api.nvim__redraw({ win = win, valid = false, flush = false })
    end
  end
end

-- Set the extmarks on the references the list shows in `buf`, if not there yet (the
-- buffer unloaded since drops them) and it's loaded
local function track(buf)
  local refs = list.code[buf]
  if not (refs and vim.api.nvim_buf_is_loaded(buf)) then
    return
  end
  local first = refs[1] and refs[1].mark
  if first and #vim.api.nvim_buf_get_extmark_by_id(buf, code_ns, first, {}) > 0 then
    return
  end
  for _, ref in ipairs(refs) do
    ref.mark = vim.api.nvim_buf_set_extmark(buf, code_ns, ref.pos[1] - 1, ref.pos[2], {
      end_row = ref.end_pos[1] - 1,
      end_col = ref.end_pos[2],
      strict = false,
      invalidate = true, -- (gone with its text)
    })
  end
end

-- Mark the references of `files` (see code.prepare) in the code, in place of those
-- marked so far; none without `files`. A file without a buffer gets its references once
-- it has one (see adopt).
local function mark_code(files)
  local redraw = {} -- the buffers that had some, and those getting some
  for buf in pairs(list.code) do
    redraw[buf] = true
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, code_ns, 0, -1)
    end
  end
  list.code, list.bufless = {}, {}
  for _, f in ipairs(files or {}) do
    if f.buf then
      redraw[f.buf] = true
      -- (a file reached by two paths, as through a symlink, is one buffer)
      list.code[f.buf] = vim.list_extend(list.code[f.buf] or {}, f.refs)
    else
      list.bufless[f.filename] = f
    end
  end
  for buf in pairs(list.code) do
    track(buf)
  end
  redraw_code(redraw)
end

-- A file of the list without a buffer (see locations) has one now, `buf`: its items and
-- references go with it, as if it had had it all along
local function adopt(buf)
  local f = list.bufless and list.bufless[vim.api.nvim_buf_get_name(buf)]
  if f then
    list.bufless[f.filename], f.buf = nil, buf
    for _, item in ipairs(f) do
      item.buf = buf
    end
    for _, ref in ipairs(f.refs) do
      ref.buf = buf
    end
    list.code[buf] = vim.list_extend(list.code[buf] or {}, f.refs)
  end
end

-- Where reference `ref` (see code.prepare) is now, start and end: its extmark follows the
-- edits of its buffer; nil once its text is gone
local function ref_pos(ref)
  if ref.mark and ref.buf and vim.api.nvim_buf_is_loaded(ref.buf) then
    local m = vim.api.nvim_buf_get_extmark_by_id(ref.buf, code_ns, ref.mark, { details = true })
    if m[1] then
      if m[3].invalid then
        return nil
      end
      return { m[1] + 1, m[2] }, { m[3].end_row + 1, m[3].end_col }
    end
  end
  return ref.pos, ref.end_pos
end

-- Highlight the references the list shows in `buf`, rows `toprow`..`botrow` (0-indexed)
-- of it being drawn: RefsMatch (in the panel's tab page only)
function M.mark(buf, toprow, botrow)
  if not M.is_open() then
    return
  elseif not list.code[buf] then
    adopt(buf) -- (a file opened since the list showed it)
    if not list.code[buf] then
      return
    end
  end
  track(buf) -- (loaded since the list showed them)
  local opts = { details = true, overlap = true }
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, code_ns, { toprow, 0 }, { botrow, -1 }, opts)) do
    if not m[4].invalid then
      vim.api.nvim_buf_set_extmark(buf, code_ns, m[2], m[3], {
        end_row = m[4].end_row,
        end_col = m[4].end_col,
        hl_group = 'RefsMatch',
        priority = CODE_PRIORITY,
        ephemeral = true,
      })
    end
  end
end

-------------------- Pane

-- The pane shows a copy of the file, not its buffer, so the pane's highlight and cursor
-- never reach a code window showing that buffer; a winbar names the file it comes from,
-- as the list's headers do. The copy is kept while hidden behind a blank, for the next
-- preview of that file.

local function scratch_buf(bufhidden)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = bufhidden or 'wipe'
  return buf
end

-- Show `buf` in the pane without the autocommands of entering a buffer
local function pane_set_buf(buf)
  local eventignore = vim.o.eventignore
  vim.o.eventignore = 'all'
  vim.wo[pane.win].winfixbuf = false
  pcall(vim.api.nvim_win_set_buf, pane.win, buf)
  vim.wo[pane.win].winfixbuf = true
  vim.o.eventignore = eventignore
end

-- Delete the pane's buffers
local function drop_pane_buffers()
  for _, buf in ipairs({ pane.buf, pane.blank }) do
    if vim.api.nvim_buf_is_valid(buf or -1) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  pane.buf, pane.blank, pane.file, pane.version = nil, nil, nil, nil
end

-- A copy of the item's file (its buffer if loaded, else read from disk) with the same
-- highlighting (none for a big file, see code.big) and tab stops, kept while the pane
-- shows that file and its text is unchanged
local function pane_buffer(item)
  local loaded = item.buf and vim.api.nvim_buf_is_loaded(item.buf)
  local version = loaded and 'b' .. vim.api.nvim_buf_get_changedtick(item.buf) or code.version(item.filename)
  if pane.file == item.filename and pane.version == version and vim.api.nvim_buf_is_valid(pane.buf or -1) then
    return pane.buf
  end
  local buf = scratch_buf('hide')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, code.lines(item.filename, item.buf))
  vim.bo[buf].tabstop = loaded and vim.bo[item.buf].tabstop or vim.o.tabstop
  if not code.big(item.filename, item.buf) then
    local ft = loaded and vim.bo[item.buf].filetype or vim.filetype.match({ filename = item.filename, buf = buf })
    if ft and ft ~= '' then
      local lang = vim.treesitter.language.get_lang(ft)
      if not (lang and pcall(vim.treesitter.start, buf, lang)) then
        vim.bo[buf].syntax = ft
      end
    end
  end
  local old = pane.buf
  pane.buf, pane.file, pane.version = buf, item.filename, version
  if old and old ~= buf and vim.api.nvim_buf_is_valid(old) then
    vim.schedule(function() -- (once the pane shows the new one)
      if vim.api.nvim_buf_is_valid(old) and #vim.fn.win_findbuf(old) == 0 then
        pcall(vim.api.nvim_buf_delete, old, { force = true })
      end
    end)
  end
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

-- Point the pane at `item` (a location, or an item of the list: the references on its
-- line, where they are now), opening it under the list first (blank). `false` blanks it,
-- nil keeps what it shows.
local function pane_show(item)
  if not valid(pane.win) then
    pane.blank = vim.api.nvim_buf_is_valid(pane.blank or -1) and pane.blank or scratch_buf('hide')
    pane.win = vim.api.nvim_open_win(pane.blank, false, {
      split = 'below',
      win = list.win,
      height = math.max(math.floor(vim.api.nvim_win_get_height(list.win) / 2), 1),
      noautocmd = true,
    })
    pane.key = 'blank'
    vim.w[pane.win].refs = 'pane'
    local wo = vim.wo[pane.win]
    wo.signcolumn, wo.foldcolumn, wo.wrap, wo.winfixbuf, wo.winfixheight = 'no', '0', false, true, false
    -- (the winbar on the plain background, as the list's file headers)
    wo.winhighlight = 'CursorLine:RefsCursorLine,WinBar:Normal,WinBarNC:Normal'
    -- (for looking only: plugins jumping into windows, as flash, leave it out)
    pcall(vim.api.nvim_win_set_config, pane.win, { focusable = false })
    pane_frame(nil)
  end
  if item == nil then
    return
  elseif item == false then
    if pane.key ~= 'blank' then
      pane.blank = vim.api.nvim_buf_is_valid(pane.blank or -1) and pane.blank or scratch_buf('hide')
      pane_set_buf(pane.blank)
      pane_frame(nil)
      pane.key = 'blank'
    end
    return
  end
  local buf = pane_buffer(item)
  local marks = {}
  for _, ref in ipairs(item.refs or { item }) do
    local from, to = ref_pos(ref)
    if from then
      marks[#marks + 1] = { from, to }
    end
  end
  local at = marks[1] and marks[1][1] or item.pos
  local key = at[1] .. ':' .. at[2] .. ':' .. #marks
  if vim.api.nvim_win_get_buf(pane.win) == buf and pane.key == key then
    return
  end
  pane_set_buf(buf)
  local label = file_label(item.filename, vim.api.nvim_win_get_width(pane.win))
  pane_frame(winbar(label)) -- (before centering: the winbar takes a row)
  vim.api.nvim_buf_clear_namespace(buf, pane_ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, pane_ns, m[1][1] - 1, m[1][2], {
      end_row = m[2][1] - 1,
      end_col = m[2][2],
      hl_group = 'RefsMatch',
      strict = false,
    })
  end
  pcall(vim.api.nvim_win_set_cursor, pane.win, at)
  vim.api.nvim_win_call(pane.win, function()
    vim.cmd('normal! zz')
  end)
  pane.key = key
end

-------------------- Windows

-- The tab page holds no window but the panel's (floating ones aside)
local function alone()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= list.win and win ~= pane.win and vim.api.nvim_win_get_config(win).relative == '' then
      return false
    end
  end
  return true
end

-- The buffer for a code window made anew: the file buffer used last, else a new one
local function code_buffer()
  local best
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    if vim.bo[info.bufnr].buftype == '' and (not best or info.lastused > best.lastused) then
      best = info
    end
  end
  return best and best.bufnr or vim.api.nvim_create_buf(true, false)
end

-- A code window on the left again, after the last one closed (`enter`: and go there)
local function restore_code(enter)
  local win = vim.api.nvim_open_win(code_buffer(), false, { split = 'left', win = -1 })
  release(win) -- (split from the panel, it has the panel's options)
  pcall(vim.api.nvim_win_set_width, list.win, math.floor(vim.o.columns * WIDTH))
  list.main = win
  if enter then
    vim.api.nvim_set_current_win(win)
  end
end

-- Close `win`, a window of the panel; the last window of the last tab page can't be
-- closed (E444): it's given back as a code window instead
local function close_win(win)
  if valid(win) and not pcall(vim.api.nvim_win_close, win, true) and valid(win) then
    vim.wo[win].winfixbuf = false
    pcall(vim.api.nvim_win_set_buf, win, code_buffer())
    release(win)
  end
end

-------------------- Sync

-- Update the pane: while you browse the list, the reference under its cursor; in the
-- code, what the definition lookup for the cursor found, once it's in. Closes the pane
-- once the list is gone (closed other than by M.close, as by :only) and drops the marks
-- of its references in the code; gives back the list's window if another buffer took it
-- (:edit! there); makes a code window again if none is left.
function M.sync()
  if valid(list.win) and vim.api.nvim_win_get_buf(list.win) ~= list.buf then
    release(list.win)
    list.win = nil
  end
  if not valid(list.win) then
    local win = pane.win
    pane.win = nil
    close_win(win)
    drop_pane_buffers()
    mark_code()
    return
  elseif not M.is_open() then
    return -- (open in another tab page)
  end
  if alone() then
    restore_code(list.closed_current)
  end
  list.closed_current = nil
  local win = vim.api.nvim_get_current_win()
  if win == list.win then
    pane_show(selected(win))
  elseif code_window(win) then
    local buf, cursor = vim.api.nvim_win_get_buf(win), vim.api.nvim_win_get_cursor(win)
    local pos = { cursor[1] - 1, cursor[2] }
    local defs = answers.known(buf, pos, 'defs')
    if defs == nil and pane.defs and pane.defs.key == key_of(buf, pos) then
      defs = pane.defs.answer -- (see M.definition)
    end
    if defs == nil then
      return pane_show(nil) -- (until the lookup is in)
    end
    pane_show(locations(defs)[1] or false)
  end
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

-- A window is closing (WinClosed): sync once it's gone, going to the code window made
-- in its place if it was the current one and the last code window
function M.closed(args)
  if tonumber(args.match) == vim.api.nvim_get_current_win() then
    list.closed_current = true
  end
  M.sync_later()
end

-- Look up the definitions of the symbol under the cursor, for the pane (the questions
-- about where the cursor was before, no longer of use, cancelled)
function M.definition()
  local buf, cursor = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)
  local pos = { cursor[1] - 1, cursor[2] }
  answers.cancel('definition', word_key(buf, pos))
  local key = key_of(buf, pos)
  answers.ask(buf, pos, 'defs', function(defs)
    -- (kept for the pane: one passed on but not remembered, as when a server failed its
    -- part, counts too)
    pane.defs = { key = key, answer = defs }
    M.sync()
  end, 'definition')
end

-------------------- List

-- The list's buffer holds its text only, a list line per file header, item, context line
-- and gap; what it looks like is drawn as it comes into view (M.highlight, M.draw_line):
-- a list of thousands of references is drawn as fast as one of ten.

-- Write `files` (see code.prepare): in the `order` of their names given, the others after
-- by name; without one, the code buffer's file first. A header per file, then a line per
-- item, a line of code with each reference on it marked (RefsMatch), between its context
-- lines (j/k step from item to item over them), gaps marked '...' ending under the line
-- numbers. A context line gets the tree guide continued down, then blanks and its line
-- number under the reference's icon and line number columns. list.rows gets per line
-- { file, header | item | owner (the item a context line or gap goes with), block and row
-- (of a context line's code), hls ({ from, to, hl }), code_col (where its code starts) }.
-- Returns the drawing: { lines, rows, order (of the files' names), files } (see write).
local function build(files, lnum_width, code_buf, order)
  local rank = {}
  for i, filename in ipairs(order or {}) do
    rank[filename] = i
  end
  table.sort(files, function(a, b)
    local ra, rb = rank[a.filename], rank[b.filename]
    if order and ra ~= rb then
      if ra and rb then
        return ra < rb
      end
      return ra ~= nil
    elseif not order and (a.buf == code_buf) ~= (b.buf == code_buf) then
      return a.buf == code_buf
    end
    return a.filename < b.filename
  end)
  local names, lines, rows = {}, {}, {}
  -- A list line of { text, hl } segments, for `row`; `code` given, it ends the line
  local function add(segments, row, text)
    local parts, col = {}, 0
    row.hls = {}
    for _, s in ipairs(segments) do
      parts[#parts + 1] = s[1]
      if s[2] then
        row.hls[#row.hls + 1] = { col, col + #s[1], s[2] }
      end
      col = col + #s[1]
    end
    if text then
      parts[#parts + 1], row.code_col = text, col
    end
    lines[#lines + 1] = table.concat(parts)
    rows[#lines] = row
  end
  -- A context line, row `r` of `block` after `guide`, going with `owner`; with no row, a
  -- gap (lines left out)
  local function context(f, owner, guide, block, r)
    local prefix = { { ' ' }, { guide, 'LineNr' } }
    if r then
      prefix[3] = { ('  %' .. lnum_width .. 'd '):format(r), 'NonText' }
      add(prefix, { file = f, owner = owner, block = block, row = r }, code.text(block, r))
    else
      prefix[3] = { ('%' .. (lnum_width + 2) .. 's'):format('...'), 'NonText' }
      add(prefix, { file = f, owner = owner })
    end
  end
  for _, f in ipairs(files) do
    names[#names + 1] = f.filename
    local header = file_label(f.filename)
    vim.list_extend(header, { { ' ' }, { (' %d '):format(#f.refs), 'TabLineSel' } })
    add(header, { file = f, header = true })
    for i, item in ipairs(f) do
      local more = i < #f -- (the tree's guide goes on down)
      if item.gap then
        context(f, item, '│ ')
      end
      for r = item.above[1], item.above[2] do
        context(f, item, '│ ', item.block, r)
      end
      add({
        { ' ' },
        { more and '├╴' or '└╴', 'LineNr' },
        KIND_ICONS[item.ref_kind] or { '  ' },
        { ('%' .. lnum_width .. 'd'):format(item.pos[1]), 'LineNr' },
        { ' ' },
      }, { file = f, item = item, block = item.block, row = item.pos[1] }, item.code)
      for r = item.below[1], item.below[2] do
        context(f, item, more and '│ ' or '  ', item.block, r)
      end
    end
  end

  return { lines = lines, rows = rows, order = names, files = files }
end

-- Write `drawing` (see build) into the list
local function write(drawing)
  local buf = list.buf
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, current_ns, 0, -1)
  vim.bo[buf].modifiable = true
  local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, drawing.lines)
  vim.bo[buf].modifiable = false
  if not ok then
    error(err)
  end
  list.rows, list.order = drawing.rows, drawing.order
end

-- The last drawings (see build), by answer and order: going back to a symbol shown a
-- moment ago draws it at once
local drawings, drawn = {}, 0
local KEPT_DRAWINGS, KEPT_LINES = 4, 60000

local function keep(key, drawing)
  drawn = drawn + 1
  drawing.used, drawings[key] = drawn, drawing
  while true do
    local count, lines, oldest = 0, 0, nil
    for k, d in pairs(drawings) do
      count, lines = count + 1, lines + #d.lines
      if not oldest or d.used < drawings[oldest].used then
        oldest = k
      end
    end
    if count <= 1 or (count <= KEPT_DRAWINGS and lines <= KEPT_LINES) then
      return
    end
    drawings[oldest] = nil
  end
end

-- The list's window `win` about to be drawn from line `toprow` (0-indexed): highlight the
-- code of the lines in view not highlighted yet, a block's rows at once (each parse goes
-- for a span of rows). Whether it's the list's (its lines are then drawn, M.draw_line).
function M.highlight(win, toprow)
  if win ~= list.win then
    return false
  end
  local spans = {} -- [block] = the rows of it to highlight
  local last = math.min(toprow + vim.api.nvim_win_get_height(win) + 1, #list.rows)
  for i = toprow + 1, last do
    local row = list.rows[i]
    if row.row and not row.block.highlights[row.row] then
      local span = spans[row.block] or { row.row, row.row }
      spans[row.block] = { math.min(span[1], row.row), math.max(span[2], row.row) }
    end
  end
  for b, span in pairs(spans) do
    code.highlight(b, span[1], span[2])
  end
  return true
end

-- Draw line `line` (0-indexed) of the list, in view: its header's, guides', icon's and
-- line numbers' highlights, its code's, and the references on an item's line (RefsMatch,
-- over the code's)
function M.draw_line(buf, line)
  local row = list.rows[line + 1]
  if buf ~= list.buf or not row then
    return
  end
  local function mark(from, to, hl, priority)
    vim.api.nvim_buf_set_extmark(
      buf,
      ns,
      line,
      from,
      { end_col = to, hl_group = hl, priority = priority, ephemeral = true }
    )
  end
  for _, hl in ipairs(row.hls) do
    mark(hl[1], hl[2], hl[3])
  end
  if row.row then
    local col = row.code_col
    for _, c in ipairs(code.chunks(row.block, row.row)) do
      if c[2] then
        mark(col, col + #c[1], c[2])
      end
      col = col + #c[1]
    end
  end
  for _, ref in ipairs(row.item and row.item.refs or {}) do
    mark(row.code_col + ref.match[1], row.code_col + ref.match[2], 'RefsMatch', 4097)
  end
end

-- Which of the references of `item` (see code.prepare) is the one at `pos` (0-indexed
-- row, byte col) in `buf`, where they are now: its index in `item.refs`, if any
local function ref_at(item, buf, pos)
  if item.buf ~= buf then
    return nil
  end
  for k, ref in ipairs(item.refs) do
    local from, to = ref_pos(ref)
    if from and from[1] == pos[1] + 1 and from[2] <= pos[2] and (to[1] > from[1] or pos[2] <= to[2]) then
      return k
    end
  end
end

-- The list line of the item holding the reference at `pos` in `buf`, and that
-- reference's index in it; else nil, and the line of the file's header if it's listed
local function find(buf, pos)
  local header
  for i, row in ipairs(list.rows) do
    local k = row.item and ref_at(row.item, buf, pos)
    if k then
      return i, k
    elseif row.header and row.file.buf == buf then
      header = header or i
    end
  end
  return nil, header
end

-- Mark reference `k` of the item on list line `row` as the current one, the one under
-- the code's cursor, over its RefsMatch (RefsCurrent); without a `row`, none
local function mark_current(row, k)
  vim.api.nvim_buf_clear_namespace(list.buf, current_ns, 0, -1)
  local item = row and list.rows[row].item
  if item then
    local col, match = list.rows[row].code_col, item.refs[k].match
    local opts = { end_col = col + match[2], hl_group = 'RefsCurrent', priority = 4098 }
    vim.api.nvim_buf_set_extmark(list.buf, current_ns, row - 1, col + match[1], opts)
  end
end

-- Put the list's cursor on line `row`, scrolled so that 'scrolloff' holds there: the
-- list's window entered later (gf, <C-w>l) keeps it there, where with 'splitkeep' set
-- Neovim would move it to make 'scrolloff' hold (onto a context line)
local function place(row)
  local win = list.win
  local height = vim.api.nvim_win_get_height(win)
  local so = vim.wo[win].scrolloff
  so = math.min(so >= 0 and so or vim.o.scrolloff, math.floor((height - 1) / 2))
  vim.api.nvim_win_call(win, function()
    local top = vim.fn.winsaveview().topline
    if row - so < top then
      top = math.max(row - so, 1)
    elseif row + so > top + height - 1 then
      top = row + so - height + 1
    end
    vim.fn.winrestview({ lnum = row, col = 0, topline = top })
  end)
end

-- Mark the reference at `pos` in `code_buf` as the current one, and put the list's
-- cursor on the item holding it, else on its file's header (the cursor stays put while
-- you browse the list: M.show can draw it again then)
local function follow(code_buf, pos)
  local row, k = find(code_buf, pos)
  local header
  if row then
    mark_current(row, k)
  else
    header = k
    mark_current()
  end
  if vim.api.nvim_get_current_win() ~= list.win then
    place(row or header or 1)
  end
end

-- Whether position `p` ({ row, col }) comes before `q`
local function before(p, q)
  return p[1] < q[1] or (p[1] == q[1] and p[2] < q[2])
end

-- Whether locations `a` and `b` (see locations) are in the same file
local function same_file(a, b)
  return (a.buf ~= nil and a.buf == b.buf) or a.filename == b.filename
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
      local overlap = same_file(ref, def) and not before(def.end_pos, ref.pos) and not before(ref.end_pos, def.pos)
      if overlap and not (first and before(first.pos, ref.pos)) then
        first = ref
      end
    end
    found[#found + 1] = first
  end
  local declared = false
  for _, ref in ipairs(found) do
    if code.assignment(ref) ~= 'affectation' then
      ref.def, declared = true, true
    end
  end
  if declared or #found == 0 then
    return
  end
  local first
  for _, ref in ipairs(refs) do
    if same_file(ref, found[1]) and not (first and before(first.pos, ref.pos)) and code.assignment(ref) then
      first = ref
    end
  end
  first = first or found[1]
  first.def = true
end

-- Show `refs` (see refs.answers), the references of the symbol at `pos` in `code_buf`,
-- its definitions marked. When those aren't known yet, it asks for them, and waits for
-- them a moment (DEFS_WAIT_MS) to draw the list once, unless `now` (a hop landing): drawn
-- without them, it draws again once they come (if it still shows that, the code buffer
-- unedited).
function M.show(code_buf, pos, refs, now, given_defs)
  if not (M.is_open() and vim.api.nvim_buf_is_valid(code_buf)) then
    return
  end
  local key = key_of(code_buf, pos)
  list.key = key
  local defs = answers.known(code_buf, pos, 'defs')
  if defs == nil then
    defs = given_defs -- (passed on but not remembered, see refs.answers)
  end
  if defs == nil and not now then
    list.waiting = key
    local function draw(found)
      if list.waiting == key and list.key == key and vim.api.nvim_buf_is_valid(code_buf) then
        list.waiting = nil
        if key_of(code_buf, pos) == key then
          M.show(code_buf, pos, refs, true, found)
        end
      end
    end
    answers.ask(code_buf, pos, 'defs', draw, 'show')
    vim.defer_fn(draw, DEFS_WAIT_MS)
    return
  end
  list.waiting = nil
  local sig = answers.sig(refs) .. ':' .. answers.sig(defs)
  if sig ~= list.sig then
    local same = list.sig ~= nil and find(code_buf, pos) ~= nil -- (the cursor on a reference the list shows)
    local order = same and list.order or nil
    local drawn_key = sig .. '\0' .. (order and table.concat(order, '\0') or vim.api.nvim_buf_get_name(code_buf))
    local drawing = drawings[drawn_key]
    if drawing then
      drawn = drawn + 1
      drawing.used = drawn
    else
      local read_files = {} -- (each file read once, see code.prepare)
      local items = locations(refs, read_files)
      mark_definitions(items, locations(defs, read_files))
      local files, lnum_width = code.prepare(items, read_files)
      drawing = build(files, lnum_width, code_buf, order)
      keep(drawn_key, drawing)
    end
    local view = vim.api.nvim_win_call(list.win, vim.fn.winsaveview)
    write(drawing)
    vim.api.nvim_win_call(list.win, function()
      vim.fn.winrestview(view)
    end)
    list.sig, list.gen = sig, (list.gen or 0) + 1
    mark_code(drawing.files)
    vim.wo[list.win].cursorline = #list.rows > 0 -- (an empty list still has a line to highlight)
  end
  follow(code_buf, pos)
  M.sync()
  if defs == nil then
    local gen = list.gen
    answers.ask(code_buf, pos, 'defs', function(found)
      local again = found and #found > 0 and list.gen == gen and list.key == key
      if again and vim.api.nvim_buf_is_valid(code_buf) and key_of(code_buf, pos) == key then
        M.show(code_buf, pos, refs, true, found)
      end
    end, 'show')
  end
end

-- Show the references of the symbol under the cursor, once the servers have answered
-- (only the answer to the latest question, while the cursor is still there), then call
-- `after`, if given (refs.hop asks ahead then, so the cursor's own questions go first)
function M.refresh(after)
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local pos = { cursor[1] - 1, cursor[2] }
  if not M.is_open() then
    return
  end
  local key = key_of(buf, pos)
  list.asked = (list.asked or 0) + 1 -- (an answer to a question asked before is dropped)
  -- (the list shows it, unless its answer no longer holds: a file changed on disk)
  if list.key == key and answers.known(buf, pos, 'refs') ~= nil then
    return after and after()
  end
  local asked = list.asked
  list.asking = key -- (see M.go)
  answers.cancel('refresh', word_key(buf, pos))
  answers.ask(buf, pos, 'refs', function(refs)
    -- (still the latest question, its window showing the buffer, entered the list since
    -- or not)
    if asked ~= list.asked or not valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
      return
    end
    list.asking = nil
    local now = vim.api.nvim_win_get_cursor(win)
    now = { now[1] - 1, now[2] }
    if key_of(buf, now) ~= key then
      return -- (moved on meanwhile)
    end
    if refs ~= nil then
      M.show(buf, now, refs) -- (an answer the same as the one shown only moves the list's cursor)
    end
    if after then
      after()
    end
  end, 'refresh')
end

-- Show the references of the symbol under the cursor and move into the list, onto the
-- reference under the cursor, once the servers have answered; with none, say so and
-- stay (`gf`)
function M.focus()
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local pos = { cursor[1] - 1, cursor[2] }
  if vim.api.nvim_buf_get_name(buf) == '' then
    return vim.notify('No references', vim.log.levels.WARN)
  end
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
    if list.key ~= key or list.waiting == key then -- (not drawn yet, or waiting on the definitions to be)
      M.show(buf, pos, refs, true)
    end
    follow(buf, pos)
    vim.api.nvim_set_current_win(list.win)
    -- (on its line again once in the window: entering it can move the cursor to make
    -- 'scrolloff' hold, as in a window too short for it)
    local row = find(buf, pos)
    if row then
      vim.api.nvim_win_set_cursor(list.win, { row, 0 })
    end
  end, 'focus')
end

-- The code window to open references in: the one last entered, else any showing a file
local function main_win()
  if code_window(list.main) and vim.api.nvim_win_get_tabpage(list.main) == vim.api.nvim_get_current_tabpage() then
    return list.main
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if code_window(win) then
      return win
    end
  end
end

-- Show `target` (a reference, or an item of the list) in code window `win` with the
-- cursor on it, where it is now (the jump list keeps where it was), centered; with
-- `keep_view`, centered only if it was out of view
local function open(target, win, keep_view)
  local buf = target.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = vim.fn.bufadd(target.filename)
  end
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  if not list.code[buf] then
    adopt(buf)
  end
  track(buf)
  local pos = ref_pos(target) or target.pos
  local in_view = keep_view
    and vim.api.nvim_win_get_buf(win) == buf
    and vim.fn.line('w0', win) <= pos[1]
    and pos[1] <= vim.fn.line('w$', win)
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! m'") -- (the jump list)
  end)
  vim.api.nvim_win_set_buf(win, buf)
  pcall(vim.api.nvim_win_set_cursor, win, pos)
  vim.api.nvim_win_call(win, function()
    vim.cmd(in_view and 'normal! zv' or 'normal! zzzv')
  end)
end

-- Open the reference under the list's cursor in the code window, and move there
local function jump()
  local item, win = selected(vim.api.nvim_get_current_win()), main_win()
  if item and win then
    local first = item.refs and item.refs[1]
    open(first and ref_pos(first) and first or item, win)
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

-- Move the cursor of the window showing the list to the next (`dir` 1) or previous (-1)
-- item, [count] times
local function step(dir)
  local win = vim.api.nvim_get_current_win()
  local row = vim.api.nvim_win_get_cursor(win)[1]
  for _ = 1, vim.v.count1 do
    row = item_row(row, dir) or row
  end
  vim.api.nvim_win_set_cursor(win, { row, 0 })
end

-- From a code window, take the cursor to the list's next (`dir` 1) or previous (-1)
-- reference, [count] times on, the list's cursor along (<Up>/<Down>): the references an
-- item holds come in turn, so the list's cursor stays on it meanwhile. A reference is
-- gone to where it is now (edits since the list was drawn moved it); one whose text is
-- gone is passed over. False when the list isn't open here, holds nothing, or this isn't
-- a code window: the arrows then do what they do without it.
function M.go(dir)
  local win = vim.api.nvim_get_current_win()
  if not (M.is_open() and code_window(win)) then
    return false
  end
  local buf, cursor = vim.api.nvim_win_get_buf(win), vim.api.nvim_win_get_cursor(win)
  if not item_row(0, 1) then
    -- (empty while the references of the word under the cursor are on their way: wait
    -- for them, as the panel just opened)
    local key = key_of(buf, { cursor[1] - 1, cursor[2] })
    return list.asking == key or list.waiting == key
  end
  local row = vim.api.nvim_win_get_cursor(list.win)[1]
  local item = list.rows[row] and list.rows[row].item
  -- (from the reference under the cursor, when the list's item holds it)
  local k = item and ref_at(item, buf, { cursor[1] - 1, cursor[2] })
  local target, target_row, target_k
  for _ = 1, vim.v.count1 do
    local found = false
    while not found do
      if not (k and item.refs[k + dir]) then -- (on to the next item)
        local i = item_row(row, dir)
        if not i then
          break
        end
        row, item = i, list.rows[i].item
        k = dir > 0 and 0 or #item.refs + 1
      end
      k = k + dir
      if ref_pos(item.refs[k]) then
        target, target_row, target_k, found = item.refs[k], row, k, true
      end
    end
    if not found then
      break
    end
  end
  if target then
    place(target_row)
    mark_current(target_row, target_k)
    open(target, win, true)
    M.definition()
  end
  return true
end

function M.close()
  local pane_win, list_win = pane.win, list.win
  pane.win, list.win = nil, nil
  close_win(pane_win)
  if valid(list_win) and vim.api.nvim_win_get_buf(list_win) ~= list.buf then
    release(list_win) -- (another buffer took it: it stays, as a code window)
  else
    close_win(list_win)
  end
  drop_pane_buffers()
  mark_code()
end

-- Go to the next window, as <C-w>w does, passing over the pane (for looking only: it
-- would send you back to the list)
local function cycle()
  if vim.v.count > 0 then
    return vim.cmd(vim.v.count .. 'wincmd w')
  end
  local wins, cur = {}, vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= pane.win and vim.api.nvim_win_get_config(win).relative == '' then
      wins[#wins + 1] = win
    end
  end
  for i, win in ipairs(wins) do
    if win == cur then
      return vim.api.nvim_set_current_win(wins[i % #wins + 1])
    end
  end
end

-- Open the panel on the right, then show the symbol under the cursor
function M.open()
  if M.is_open() then
    return
  end
  M.close() -- (open in another tab page)
  local from = vim.api.nvim_get_current_win()
  snapshot(code_window(from) and from or main_win())
  local buf = scratch_buf()
  vim.bo[buf].filetype = 'refs'
  vim.bo[buf].modifiable = false
  list.buf, list.rows, list.key, list.sig, list.order = buf, {}, nil, nil, nil
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
  -- (the list's window starts with the code window's jumps, which it can't go to)
  map('<C-o>', function()
    local win = main_win()
    if win then
      vim.api.nvim_set_current_win(win)
    end
  end, 'Back to the code')
  map('<C-w>w', cycle, 'Next window, past the pane')
  map('<C-w><C-w>', cycle, 'Next window, past the pane')
  -- Counts (3j), where this config's 1-9 switch buffers, which the list's window can't
  for d = 1, 9 do
    map(tostring(d), function()
      vim.api.nvim_feedkeys(tostring(d), 'ni', false) -- (before the keys typed after it)
    end, 'Count')
  end
  -- This config's keys going to another buffer (the next quickfix item, the alternate
  -- buffer) do it in the code window
  for _, lhs in ipairs({ '<Tab>', '<S-Tab>', '<C-Space>', '<C-^>' }) do
    map(lhs, function()
      local win = main_win()
      if win then
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_feedkeys(vim.keycode(lhs), 'm', false)
      end
    end, 'In the code window')
  end
  vim.api.nvim_create_autocmd('CursorMoved', { buffer = buf, callback = M.sync })

  list.win = vim.api.nvim_open_win(buf, false, { split = 'right', win = -1, width = math.floor(vim.o.columns * WIDTH) })
  vim.w[list.win].refs = 'list'
  local wo = vim.wo[list.win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn, wo.statuscolumn = false, false, 'no', '0', ''
  wo.cursorline, wo.wrap, wo.list, wo.spell, wo.winfixwidth = false, false, false, false, true -- (see M.show)
  wo.winbar, wo.fillchars, wo.winhighlight, wo.winfixbuf = '', 'eob: ', WINHIGHLIGHT, true
  vim.api.nvim_win_call(list.win, function()
    vim.cmd('clearjumps')
  end)
  M.sync() -- (opens the pane)
  if vim.bo.buftype == '' and vim.api.nvim_buf_get_name(0) ~= '' then
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
-- without the panel; it opens again if the quit is refused (changes not written)
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
  vim.schedule(function()
    if code_window(win) and vim.api.nvim_get_current_win() == win and not M.is_open() then
      M.open()
    end
  end)
end

-- The editor resized: the pane takes half the list's column again (resizing gives the
-- new rows to one of them)
function M.resized()
  if M.is_open() and valid(pane.win) then
    local total = vim.api.nvim_win_get_height(list.win) + vim.api.nvim_win_get_height(pane.win)
    pcall(vim.api.nvim_win_set_height, pane.win, math.max(math.floor(total / 2), 1))
  end
end

-- Clear the marks other plugins left in the pane's buffer while it was the current one
-- (a search count at the cursor): it's for looking only
local function clear_foreign()
  local buf = vim.api.nvim_win_get_buf(pane.win)
  for _, id in pairs(vim.api.nvim_get_namespaces()) do
    if id ~= pane_ns then
      vim.api.nvim_buf_clear_namespace(buf, id, 0, -1)
    end
  end
end

-- Track the code window last entered; keep the pane in step with where you are. The
-- pane itself is for looking only: landing in it (<C-Right> from the lower half of the
-- screen, a click) moves on to the list, the window you came from kept as the previous
-- one (<C-w>p), or the list's own when you came from the list. A second window showing
-- the list (:split there, <C-w>T) is closed.
function M.entered()
  local win = vim.api.nvim_get_current_win()
  local from = vim.fn.win_getid(vim.fn.winnr('#'))
  if code_window(win) then
    list.main = win
  end
  if list.buf and win ~= list.win and vim.api.nvim_win_get_buf(win) == list.buf then
    -- Split from the list, a window shows the list until it gets its own buffer (:help,
    -- :split file, :copen, a quickfix jump, the cmdline window): one still showing the
    -- list then is a copy, closed; one showing a file gets a code window's options
    vim.schedule(function()
      if not valid(win) or win == list.win or vim.fn.getcmdwintype() ~= '' then
        return
      elseif vim.api.nvim_win_get_buf(win) == list.buf then
        close_win(win)
        if valid(list.win) then
          pcall(vim.api.nvim_win_set_width, list.win, math.floor(vim.o.columns * WIDTH))
        end
      elseif vim.bo[vim.api.nvim_win_get_buf(win)].buftype == '' then
        release(win)
      end
    end)
  elseif not M.is_open() then
    if valid(list.win) then
      M.sync_later() -- (another buffer may have taken the list's window)
    end
  elseif win == pane.win then
    vim.schedule(function()
      if vim.api.nvim_get_current_win() ~= pane.win or not M.is_open() then
        return
      end
      clear_foreign()
      local back = from == list.win and list.prev or from
      if valid(back) and back ~= pane.win and back ~= list.win then
        vim.cmd('noautocmd call win_gotoid(' .. back .. ')')
      end
      vim.api.nvim_set_current_win(list.win)
    end)
  elseif win == list.win then
    if valid(from) and from ~= pane.win and from ~= list.win then
      list.prev = from
    end
    M.sync_later()
  elseif code_window(win) then
    M.definition()
  else
    M.sync_later()
  end
end

-- A session is being written (`writing`) or was: the panel's windows are left out of it
-- (they come back blank otherwise), as 'sessionoptions' without "blank" leaves windows
-- of buffers without a file; it opens anew at start
function M.session(writing)
  if writing and (valid(list.win) or valid(pane.win)) then
    list.ssop = vim.o.sessionoptions
    vim.opt.sessionoptions:remove('blank')
  elseif not writing and list.ssop then
    vim.o.sessionoptions, list.ssop = list.ssop, nil
  end
end

return M
