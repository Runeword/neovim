local vim = vim

-- The file tree: a panel on the left showing the working directory as a tree, where the
-- files open as buffers (those the bufferline shows) are highlighted, FileTreeOpened, the
-- code window's own FileTreeCurrent, and so are the directories holding them,
-- FileTreeOpenedDir: a closed directory tells there's an open file inside. The tree
-- follows the code window's file: it opens the directories down to it and puts its cursor
-- on it (not while you're in the panel, browsing). It follows the working directory too
-- (:cd, project.nvim), and the disk (see filetree.fs).
--
-- In the panel: <CR> opens the file in the code window and goes there, or opens/closes the
-- directory; a click opens the file staying in the panel (a double click goes there, as in
-- VS Code), or opens/closes the directory, and so does <Tab>, then going to the next entry
-- (<S-Tab> goes to the previous one); j/k (<Down>/<Up>) go to the next/previous entry,
-- showing its file in the code window, as a preview if it isn't open (see show_preview);
-- o opens the file and closes the panel; l/<Right> opens the directory (on an open one,
-- goes to its first entry), or shows the file in the code
-- window, staying in the panel; h/<Left> closes the directory, else goes to its parent;
-- - closes the directory holding the entry; W closes them all; R reads the disk again;
-- q closes the panel.
--
-- The panel holds its buffer ('winfixbuf') and is never all a tab page holds: when the last
-- code window closes (:bdelete, :close), a code window takes its place. :q there closes the
-- panel too, so Neovim quits, or the tab page closes, as it would without it. Beside the
-- references panel (myplugins/refs.nvim), it steps aside while the code would have too
-- little room (see make_room).
local fs = require('filetree.fs')

local M = {}

local WIDTH = 30 -- columns, at first: then the width you last gave the panel
local MIN_WIDTH = 10 -- (a panel closed narrower was squeezed, by <C-w>| in another window)
-- Beside the references panel (myplugins/refs.nvim), the code window keeps this many
-- columns: the panel steps aside for it rather than leave fewer (see make_room)
local MIN_CODE = 100

-- Nerd Font glyphs (nvim-tree's): a directory's chevron and folder, closed and open, and a
-- file's without nvim-web-devicons
local CLOSED, OPEN = '', ''
local FOLDER, FOLDER_OPEN = '', ''
local FILE = ''

-- Plain text even in the background, and a cursor line of the panel's own (see
-- after/plugin/colors.lua)
local WINHIGHLIGHT = 'NormalNC:Normal,EndOfBuffer:Normal,CursorLine:FileTreeCursorLine'

-- The panel's window options, set for it alone (:setlocal): a window split from it to show
-- another buffer has a code window's (see restore)
local WIN_OPTS = {
  number = false,
  relativenumber = false,
  signcolumn = 'no',
  foldcolumn = '0',
  statuscolumn = '',
  cursorline = true,
  wrap = false,
  list = false,
  spell = false,
  winfixwidth = true,
  winfixbuf = true,
  fillchars = 'eob: ',
  winhighlight = WINHIGHLIGHT,
}

local ns = vim.api.nvim_create_namespace('filetree')

local buf -- the panel's buffer, while a window shows it
local width = WIDTH
local root -- the directory the tree shows: the working directory
local expanded = {} -- [directory] = true, for those shown open
local rows = {} -- [line] = { path, dir, depth, name_col, name_end, hls }, what the panel shows
local line_of = {} -- [path] = its line in the panel
local opened = {} -- [path] = true, for the files open as buffers and the directories holding them
local current -- the code window's file
local revealed -- current was shown in the panel (see update)
local main -- the code window last entered, where files open
local code_opts -- a code window's options, for one split from the panel (see snapshot)
local closing = false -- the panel is being closed by M.close
local deleted = 0 -- counts the listed buffers deleted (see closed)
local deleting = false -- a listed buffer was deleted this turn of the event loop
local closes -- the windows a command closes, until they're checked (see closed)
local dragged = false -- the mouse was dragged since it was last pressed (see keymaps)

local function valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

-- The working directory, the tab page's own if it has one (:tcd); deleted (getcwd() is
-- empty then), the one the tree shows
local function cwd()
  local dir = vim.fn.getcwd(-1, 0)
  return dir ~= '' and vim.fs.normalize(dir) or root or '/'
end

-- The panel's window in this tab page
local function panel_win()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win].filetree and vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
end

-- A window showing a file (or a new one, or a directory's listing, Neovim's nvim.dir), not
-- floating, nor holding its buffer, nor the panel's (taken by another buffer, see taken)
local function code_window(win)
  if
    not valid(win)
    or vim.w[win].filetree
    or vim.wo[win].winfixbuf
    or vim.api.nvim_win_get_config(win).relative ~= ''
  then
    return false
  end
  local b = vim.api.nvim_win_get_buf(win)
  return vim.bo[b].buftype == '' or vim.b[b].nvim_dir ~= nil
end

-- The code window to open files in: the one last entered, else any in this tab page (not
-- `except`)
local function main_win(except)
  if
    main ~= except
    and code_window(main)
    and vim.api.nvim_win_get_tabpage(main) == vim.api.nvim_get_current_tabpage()
  then
    return main
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= except and code_window(win) then
      return win
    end
  end
end

-- The references panel (myplugins/refs.nvim) is open in this tab page
local function refs_open()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win].refs == 'list' then
      return true
    end
  end
  return false
end

local function set_opts(win, opts)
  for name, value in pairs(opts) do
    pcall(vim.api.nvim_set_option_value, name, value, { win = win, scope = 'local' })
  end
end

-- Take code window `win`'s values of the options the panel sets
local function snapshot(win)
  code_opts = {}
  for name in pairs(WIN_OPTS) do
    code_opts[name] = vim.api.nvim_get_option_value(name, { win = win })
  end
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

-- Give `win`, a window the panel had (or one split from it), back as a code window: the
-- options the panel sets as a code window has them (`opts`, else the last one entered's,
-- else their global values)
local function release(win, opts)
  opts = opts or code_opts or {}
  vim.w[win].filetree = nil
  for name in pairs(WIN_OPTS) do
    local value = opts[name]
    if value == nil then
      value = vim.api.nvim_get_option_value(name, { scope = 'global' })
    end
    pcall(vim.api.nvim_set_option_value, name, value, { win = win, scope = 'local' })
  end
end

-- A code window right of the panel `panel`, there being none (`enter`: and go there); the
-- panel `columns` wide, as it was (else as it is)
local function restore(panel, enter, columns)
  columns = columns or vim.api.nvim_win_get_width(panel)
  local opts = code_opts -- (entering the window takes its options, before they're set)
  local win = vim.api.nvim_open_win(code_buffer(), enter, { split = 'right', win = panel })
  release(win, opts)
  pcall(vim.api.nvim_win_set_width, panel, columns) -- (it gave the new window half of its own)
  main = win
  return win
end

-------------------- Drawing

-- The file's icon and its highlight group: nvim-web-devicons', else a plain one. A name
-- without an icon of its own has its extension's, looked up once for all of them (a
-- lookup takes ~10µs: thousands of files in a directory would take tens of ms).
local icons = {} -- [file name] = { icon, hl }
local ext_icons = {} -- [extension] = { icon, hl }
local devicons -- the module, false without it

local function lookup(name, ext)
  local icon, hl
  if devicons then
    icon, hl = devicons.get_icon(name, ext, { default = true })
  end
  return { icon or FILE, hl }
end

local function file_icon(name)
  local icon = icons[name]
  if not icon then
    if devicons == nil then
      local ok, module = pcall(require, 'nvim-web-devicons')
      devicons = ok and module or false
    end
    local ext = name:match('^.+%.(.-)$')
    local named = ext and devicons and devicons.get_icons and devicons.get_icons() -- (nil until it's set up)
    if named and not named[name:lower()] then
      ext_icons[ext] = ext_icons[ext] or lookup(name, ext)
      icon = ext_icons[ext]
    else
      icon = lookup(name, ext)
    end
    icons[name] = icon
  end
  return icon[1], icon[2]
end

-- The cursor of window `win` (0: the current one) on line `line`, at the entry's name
local function set_cursor(win, line)
  local row = rows[line]
  pcall(vim.api.nvim_win_set_cursor, win, { line, row and row.name_col or 0 })
end

-- The same, centered if the line was out of view
local function show(win, line)
  local in_view = vim.fn.line('w0', win) <= line and line <= vim.fn.line('w$', win)
  set_cursor(win, line)
  if not in_view then
    vim.api.nvim_win_call(win, function()
      vim.cmd('normal! zz')
    end)
  end
end

-- Write the tree in the panel's buffer again, from what's on disk (see filetree.fs) and the
-- directories open; with the panel's window `win`, its cursor kept on its entry, or if a
-- directory above it closed, on that one; gone from disk, on the line it was on (the next
-- entry)
local function render(win)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local line = win and vim.api.nvim_win_get_cursor(win)[1]
  local at = line and rows[line]
  local lines, shown = {}, { [root] = true }
  rows, line_of = {}, {}

  local function walk(dir, depth)
    for _, entry in ipairs(fs.entries(dir)) do
      local open = entry.dir and expanded[entry.path]
      local text, hls = string.rep(' ', 1 + 2 * depth), {}
      local function add(s, hl)
        if hl then
          hls[#hls + 1] = { #text, #text + #s, hl }
        end
        text = text .. s .. ' '
      end
      if entry.dir then
        add(open and OPEN or CLOSED, 'FileTreeFolderIcon')
        add(open and FOLDER_OPEN or FOLDER, 'FileTreeFolderIcon')
      else
        add(' ') -- (under a directory's chevron)
        add(file_icon(entry.name))
      end
      local name_col = #text
      text = text .. (entry.name:gsub('%c', '?'))
      lines[#lines + 1] = text
      rows[#lines] = {
        path = entry.path,
        dir = entry.dir,
        depth = depth,
        name_col = name_col,
        name_end = #text,
        hls = hls,
      }
      line_of[entry.path] = #lines
      if open then
        shown[entry.path] = true
        walk(entry.path, depth + 1)
      end
    end
  end
  walk(root, 0)

  if #lines == 0 then
    lines[1] = '' -- (an empty directory)
  end
  if not vim.deep_equal(lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end
  if win then
    local path = at and at.path
    while path and not line_of[path] do
      local up = vim.fs.dirname(path)
      path = fs.relative(root, up) and up or nil
    end
    local gone = path ~= (at and at.path) and (not path or expanded[path])
    set_cursor(win, not gone and path and line_of[path] or math.min(line, #lines))
  end
  fs.watch(shown)
end

-- The highlights of line `row` (0-based) of the panel's buffer `b`, as it's drawn: its
-- icons', and its name's, by whether it's open as a buffer
local function draw_line(b, row)
  local r = rows[row + 1]
  if not r then
    return
  end
  local function mark(col, end_col, group)
    vim.api.nvim_buf_set_extmark(b, ns, row, col, {
      end_col = end_col,
      hl_group = group,
      ephemeral = true,
      strict = false,
    })
  end
  for _, hl in ipairs(r.hls) do
    mark(hl[1], hl[2], hl[3])
  end
  local group
  if r.dir then
    group = opened[r.path] and 'FileTreeOpenedDir' or 'FileTreeDirectory'
  elseif r.path == current then
    group = 'FileTreeCurrent'
  elseif opened[r.path] then
    group = 'FileTreeOpened'
  end
  if group then
    mark(r.name_col, r.name_end, group)
  end
end

-------------------- Following the buffers

-- The file buffer `b` holds, if it holds one
local function file_of(b)
  if vim.bo[b].buftype ~= '' then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(b)
  if name ~= '' then
    return vim.fs.normalize(name)
  end
end

-- The files open as buffers (listed: those the bufferline shows), and the directories
-- holding them
local function find_opened()
  opened = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local path = vim.bo[b].buflisted and file_of(b)
    if path and not opened[path] and vim.fn.isdirectory(path) == 0 then
      opened[path] = true
      local dir = vim.fs.dirname(path)
      while not opened[dir] do
        opened[dir] = true
        local up = vim.fs.dirname(dir)
        if up == dir then
          break
        end
        dir = up
      end
    end
  end
end

-- Open the directories down to file `path`; false if the tree doesn't show it (it's out of
-- the working directory, or under an entry left out, .git)
local function expand_to(path)
  local relative = fs.relative(root, path)
  if not relative or fs.hidden(relative) then
    return false
  end
  local dir = vim.fs.dirname(path)
  while dir ~= root do
    expanded[dir] = true
    local up = vim.fs.dirname(dir)
    if up == dir then
      break -- (/: past the root, written otherwise than the path)
    end
    dir = up
  end
  return true
end

-- Bring the panel up to date with the buffers: the files open, and the code window's,
-- shown once it's another (the directories down to it opened, the panel's cursor put on it
-- unless you're in the panel); a new file, once it's on disk
local function update()
  local win = panel_win()
  if not win then
    return
  end
  find_opened()
  local code = main_win()
  local path = code and file_of(vim.api.nvim_win_get_buf(code))
  if path ~= current then
    current, revealed = path, false
  end
  if not revealed and path and expand_to(path) then
    render(win)
    if line_of[path] then
      revealed = true
      if vim.api.nvim_get_current_win() ~= win then
        show(win, line_of[path])
      end
    end
  end
  vim.api.nvim__redraw({ win = win, valid = false, flush = false })
end

local update_pending = false

-- update once the current event is done (a buffer being deleted is still listed)
local function update_later()
  if buf and not update_pending then
    update_pending = true
    vim.schedule(function()
      update_pending = false
      update()
    end)
  end
end

-------------------- Preview

-- j/k (<Down>/<Up>) show the file under the panel's cursor in the code window, the panel
-- kept, as VS Code's explorer shows a preview: a file not open as a buffer shows unlisted
-- (no tab in the bufferline, not highlighted as open), and goes once another takes its
-- place, unless it's kept (see keep_preview): opened from the panel (<Tab>, <CR>, l, o, a
-- click), gone to (the code window entered), or changed. A file open shows as it is.
local PREVIEW_MS = 80 -- held, j/k show the file they rest on this long after the last move
local PREVIEW_MAX = 5 * 1024 * 1024 -- bytes: bigger files aren't shown on the way (<CR> opens them)

local preview -- the file shown as a preview: { buf, made (the buffer was made for it) }
local preview_timer -- (while j/k are held)
local moved = 0 -- vim.uv.now() of j/k's last move
local passing = false -- going to the code window to switch buffers there, passing the preview by

-- The buffer of file `path`, if there's one
local function buffer_of(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if file_of(b) == path then
      return b
    end
  end
end

-- The preview, kept: open as a buffer from now on, a tab like the others
local function keep_preview()
  if preview and vim.api.nvim_buf_is_valid(preview.buf) then
    vim.bo[preview.buf].buflisted = true
  end
  preview = nil
end

-- Unlist buffer `b` without the BufDelete of a buffer closed: buffer-history's <C-t>
-- doesn't reopen previews
local function unlist(b)
  local eventignore = vim.o.eventignore
  vim.opt.eventignore:append('BufDelete')
  vim.bo[b].buflisted = false
  vim.o.eventignore = eventignore
end

-- A preview gone: its buffer wiped if it was made for it (an unlisted one: no BufDelete)
local function drop_preview(gone)
  local b = gone.buf
  if
    gone.made
    and vim.api.nvim_buf_is_valid(b)
    and not vim.bo[b].buflisted
    and not vim.bo[b].modified
    and #vim.fn.win_findbuf(b) == 0
  then
    pcall(vim.api.nvim_buf_delete, b, {})
  end
end

-- Show the file under the panel's cursor in the code window, as a preview if it isn't open
local function show_preview()
  local win, code = panel_win(), main_win()
  if not (win and code) or vim.api.nvim_get_current_win() ~= win then
    return
  end
  local row = rows[vim.api.nvim_win_get_cursor(win)[1]]
  local shown = vim.api.nvim_win_get_buf(code)
  if not row or row.dir or file_of(shown) == row.path then
    return
  end
  local stat = vim.uv.fs_stat(row.path)
  if not stat or stat.type ~= 'file' or stat.size > PREVIEW_MAX then
    return
  end
  local before = buffer_of(row.path)
  local listed = before and vim.bo[before].buflisted
  -- (replacing a preview, the alternate file stays the one shown before them, for <C-^>)
  local keepalt = preview and shown == preview.buf and 'keepalt ' or ''
  local ok = pcall(vim.api.nvim_win_call, code, function()
    vim.cmd(keepalt .. 'keepjumps edit ' .. vim.fn.fnameescape(row.path))
  end)
  local b = vim.api.nvim_win_get_buf(code)
  if ok and not listed and file_of(b) == row.path then
    unlist(b) -- (:edit listed it)
    preview = { buf = b, made = before == nil }
  end
end

-- After j/k: the file shown at once; j/k held (moves PREVIEW_MS apart or
-- less), once they rest
local function preview_soon()
  local now = vim.uv.now()
  local resting = now - moved > PREVIEW_MS
  moved = now
  if preview_timer then
    preview_timer:stop()
  end
  if resting then
    show_preview()
  else
    preview_timer = preview_timer or vim.uv.new_timer()
    preview_timer:start(PREVIEW_MS, 0, vim.schedule_wrap(show_preview))
  end
end

-------------------- The panel

-- Open file `path` in the code window (a new one if there's none), then go there (`how`:
-- 'go'), close the panel ('close'), or stay in the panel ('stay')
local function open_file(path, how)
  local win = main_win() or restore(vim.api.nvim_get_current_win(), false)
  if file_of(vim.api.nvim_win_get_buf(win)) ~= path then -- (:edit would read it again)
    vim.api.nvim_win_call(win, function()
      vim.cmd('edit ' .. vim.fn.fnameescape(path))
    end)
  end
  if preview and vim.api.nvim_win_get_buf(win) == preview.buf then
    keep_preview() -- (opened)
  end
  if how ~= 'stay' then
    vim.api.nvim_set_current_win(win)
  end
  if how == 'close' then
    M.close()
  end
end

local function keymaps(b)
  local function map(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = b, nowait = true, desc = desc })
  end
  local function selected()
    return rows[vim.api.nvim_win_get_cursor(0)[1]]
  end
  local function toggle(row)
    expanded[row.path] = not expanded[row.path] or nil
    render(vim.api.nvim_get_current_win())
  end
  local function choose(how)
    return function()
      local row = selected()
      if row and row.dir then
        toggle(row)
      elseif row then
        open_file(row.path, how)
      end
    end
  end

  map('<CR>', choose('go'), 'Open the file, or open/close the directory')
  -- A click opens the file, staying in the panel, or opens/closes the directory: released
  -- over an entry, not past the last one (getmousepos() has the last line there), nor after
  -- a drag (as the panel's resizing). A double click goes to the file: its second press
  -- comes to the panel, kept by the first.
  map('<LeftRelease>', function()
    local pos = vim.fn.getmousepos()
    local row = rows[pos.line]
    if
      dragged
      or not row
      or pos.winid ~= vim.api.nvim_get_current_win()
      or pos.winrow ~= pos.line - vim.fn.line('w0') + 1
    then
      return
    elseif row.dir then
      toggle(row)
    else
      open_file(row.path, 'stay')
    end
  end, 'Open the file, staying here, or open/close the directory')
  map('<2-LeftMouse>', function()
    local row = selected()
    if row and not row.dir then
      open_file(row.path, 'go')
    end
  end, 'Go to the file')
  map('o', choose('close'), 'Open the file and close the panel')
  for _, lhs in ipairs({ 'l', '<Right>' }) do
    map(lhs, function()
      local row = selected()
      if not row then
        return
      elseif not row.dir then
        open_file(row.path, 'stay')
      elseif not expanded[row.path] then
        toggle(row)
      else
        local below = line_of[row.path] + 1
        if rows[below] and rows[below].depth > row.depth then
          set_cursor(0, below)
        end
      end
    end, 'Open the directory (go into an open one), or show the file')
  end
  for _, lhs in ipairs({ 'h', '<Left>' }) do
    map(lhs, function()
      local row = selected()
      if not row then
        return
      elseif row.dir and expanded[row.path] then
        toggle(row)
      elseif line_of[vim.fs.dirname(row.path)] then
        set_cursor(0, line_of[vim.fs.dirname(row.path)])
      end
    end, 'Close the directory, or go to its parent')
  end
  -- Up a level, as - does in Neovim's directory listing (nvim.dir), which would take the
  -- panel's window
  map('-', function()
    local row = selected()
    local parent = row and rows[line_of[vim.fs.dirname(row.path)]]
    if parent then
      expanded[parent.path] = nil
      render(vim.api.nvim_get_current_win()) -- (the cursor on it, the nearest shown)
    end
  end, 'Close the directory holding the entry, and go to it')
  -- One entry at a time (j/k would otherwise do this config's 4-line jump), showing the file
  -- landed on (see show_preview)
  local function step(n)
    set_cursor(0, math.max(1, math.min(vim.api.nvim_win_get_cursor(0)[1] + n, vim.api.nvim_buf_line_count(0))))
    preview_soon()
  end
  for _, lhs in ipairs({ 'j', '<Down>' }) do
    map(lhs, function()
      step(vim.v.count1)
    end, 'Next entry, its file shown')
  end
  for _, lhs in ipairs({ 'k', '<Up>', '<S-Tab>' }) do
    map(lhs, function()
      step(-vim.v.count1)
    end, 'Previous entry, its file shown')
  end
  -- Keep the file open (or open/close the directory), then on to the next entry, as j does:
  -- <Tab> after <Tab> opens the files in a row
  local keep = choose('stay')
  map('<Tab>', function()
    keep()
    step(1)
  end, 'Open the file (kept as a buffer) or the directory, then go to the next entry')
  map('W', function()
    expanded = {}
    render(vim.api.nvim_get_current_win())
  end, 'Close every directory')
  map('R', function()
    fs.watch({}) -- (the watchers too)
    render(vim.api.nvim_get_current_win())
  end, 'Read the disk again')
  map('q', M.close, 'Close the panel')
  -- (the panel's window starts with the code window's jumps, which it can't go to)
  map('<C-o>', function()
    local win = main_win()
    if win then
      vim.api.nvim_set_current_win(win)
    end
  end, 'Back to the code')
  -- Counts (3j), where this config's 1-9 switch buffers, which the panel's window can't
  for d = 1, 9 do
    map(tostring(d), function()
      vim.api.nvim_feedkeys(tostring(d), 'ni', false) -- (before the keys typed after it)
    end, 'Count')
  end
  -- This config's keys going to another buffer (the alternate one, the one closed last) do
  -- it in the code window, and so do its <Leader> keys (<Space>), which mostly act on a file
  -- (fzf-lua's pickers, harpoon's files, document symbols)
  for _, lhs in ipairs({ '<C-Space>', '<C-^>', '<C-t>', '<Space>' }) do
    map(lhs, function()
      local win = main_win()
      if win then
        -- (switching buffers there passes a preview by; <Leader> keys act on it: kept)
        passing = lhs ~= '<Space>'
        vim.api.nvim_set_current_win(win)
        passing = false
        vim.api.nvim_feedkeys(vim.keycode(lhs), 'mi', false) -- (before the keys typed after it)
      end
    end, 'In the code window')
  end
end

-- The panel is open in this tab page
function M.is_open()
  return panel_win() ~= nil
end

-- Open the panel on the left (`focus`: and go there), its cursor on the code window's file
function M.open(focus)
  local win = panel_win()
  if not win then
    local from = vim.api.nvim_get_current_win()
    if code_window(from) then
      main = from
      snapshot(from)
    end
    root = cwd()
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then -- (else shown in another tab page)
      buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = 'wipe'
      vim.bo[buf].undolevels = -1
      vim.bo[buf].modifiable = false
      vim.bo[buf].filetype = 'filetree'
      keymaps(buf)
      -- (the tab of the file under the cursor shown as the current one, see M.cursor_buffer:
      -- moving the cursor doesn't draw the tabline again)
      vim.api.nvim_create_autocmd('CursorMoved', { buffer = buf, command = 'redrawtabline' })
    end
    local columns = math.min(width, math.floor(vim.o.columns / 2))
    win = vim.api.nvim_open_win(buf, false, { split = 'left', win = -1, width = columns })
    vim.w[win].filetree = true
    set_opts(win, WIN_OPTS)
    vim.api.nvim_win_call(win, function()
      vim.cmd('clearjumps')
    end)
    revealed = false -- (the code window's file shown)
    vim.t.filetree_yielded = nil -- (back, see make_room)
    render(win)
    update()
  end
  if focus then
    vim.api.nvim_set_current_win(win)
  end
end

-- Close the panel (the last window can't close, E444: it shows code instead)
function M.close()
  local win = panel_win()
  closing = true
  local ok = win and pcall(vim.api.nvim_win_close, win, true)
  closing = false
  if win and not ok and valid(win) then
    vim.w[win].filetree = nil
    pcall(vim.api.nvim_set_option_value, 'winfixbuf', false, { win = win, scope = 'local' })
    vim.api.nvim_win_set_buf(win, code_buffer())
    release(win)
  end
end

-- Close the panel, or open it and go there; opened beside the references panel, it stays
-- there, however little room the code has (see make_room)
function M.toggle()
  vim.t.filetree_yielded = nil
  if panel_win() then
    M.close()
  else
    vim.t.filetree_kept = refs_open() or nil
    M.open(true)
  end
end

-- The buffer of the file under the panel's cursor if it's open (listed), the panel being
-- the current window: its tab shows as the current buffer's (see the bufferline's spec),
-- asked for each tab (the buffer of a file is looked for once, until the buffers change)
local under_cursor = {} -- { path, buf (false: none) }

function M.cursor_buffer()
  local win = vim.api.nvim_get_current_win()
  local row = vim.w[win].filetree and rows[vim.api.nvim_win_get_cursor(win)[1]]
  if not row or row.dir then
    return nil
  end
  if under_cursor.path ~= row.path then
    under_cursor = { path = row.path, buf = buffer_of(row.path) or false }
  end
  local b = under_cursor.buf
  return b and vim.api.nvim_buf_is_valid(b) and vim.bo[b].buflisted and b or nil
end

-- The directory the tree shows, as the bufferline writes it over the panel
function M.title()
  return root and vim.fn.fnamemodify(root, ':~') or ''
end

-- At start (UIEnter): the panel opens beside the file if the tree shows it (not a commit
-- message, a temporary file, a man page, help, a diff), or without one. Started on a
-- directory (nvim .), the panel takes the place of its listing (Neovim's nvim.dir, netrw
-- being off here), the directory the working one; later, :edit of one still lists it.
function M.start()
  local b = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(b)
  if vim.wo.diff then
    return
  end
  root = cwd()
  if vim.fn.isdirectory(name) == 1 and (vim.bo[b].buftype == '' or vim.b[b].nvim_dir ~= nil) then
    vim.cmd('cd ' .. vim.fn.fnameescape(name))
    vim.cmd.enew()
    pcall(vim.api.nvim_buf_delete, b, { force = true })
    M.open(true)
  elseif vim.bo[b].buftype ~= '' then
    return
  elseif name == '' then
    if vim.api.nvim_buf_line_count(b) == 1 and vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == '' then
      M.open() -- (not on text read from stdin)
    end
  elseif expand_to(vim.fs.normalize(name)) then
    M.open()
  end
end

-------------------- Events

-- A window split from the panel shows its buffer (:split there, or a command opening
-- something in a split as the panel holds its buffer, as fzf-lua does). Once the command is
-- done, one still showing the panel is closed; one showing a file gives it to the code
-- window, and closes.
local function copied(win)
  vim.schedule(function()
    if not valid(win) or vim.w[win].filetree or vim.fn.getcmdwintype() ~= '' then
      return
    end
    local b = vim.api.nvim_win_get_buf(win)
    if b == buf then
      pcall(vim.api.nvim_win_close, win, true)
      return
    end
    local code = main_win(win)
    if code and file_of(b) then
      local cursor = vim.api.nvim_win_get_cursor(win)
      vim.api.nvim_win_set_buf(code, b)
      pcall(vim.api.nvim_win_set_cursor, code, cursor)
      pcall(vim.api.nvim_win_close, win, true)
      vim.api.nvim_set_current_win(code)
    end
  end)
end

-- A buffer entered a window (BufWinEnter): the panel's taken by another buffer (:edit!
-- there, or :%bdelete run from it, which leaves the empty buffer there) is a code window
-- from then on; buffers being deleted, the panel comes back beside it, as when :%bdelete
-- runs in the code window (see closed)
local function taken()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win].filetree and vim.api.nvim_win_get_buf(win) ~= buf then
      release(win)
      local before, now = deleted, deleting
      vim.schedule(function()
        if (now or deleted > before) and vim.v.exiting == vim.NIL and not panel_win() then
          M.open()
        end
      end)
    end
  end
end

-- A window was entered: track the code window last entered, where files open
local function entered()
  local win = vim.api.nvim_get_current_win()
  if code_window(win) then
    main = win
    snapshot(win)
    if preview and vim.api.nvim_win_get_buf(win) == preview.buf and not passing then
      keep_preview() -- (gone to)
    end
  elseif buf and vim.api.nvim_win_get_buf(win) == buf and not vim.w[win].filetree then
    copied(win)
  end
  update_later()
end

-- The windows changed (a panel opened or closed, the editor resized): beside the
-- references panel, the code window keeps MIN_CODE columns, as VS Code shows the
-- references in its side bar in place of the files. The panel steps aside while the code
-- window has fewer, and comes back once that panel is closed or there's room again; opened
-- by you beside it (M.toggle), it stays.
local function make_room()
  if vim.v.exiting ~= vim.NIL then
    return
  end
  local panel, refs = panel_win(), refs_open()
  if not refs then
    vim.t.filetree_kept = nil
  end
  local code = main_win()
  local columns = code and vim.api.nvim_win_get_width(code)
  if panel and refs and columns and columns < MIN_CODE and not vim.t.filetree_kept then
    M.close()
    vim.t.filetree_yielded = true
  elseif
    not panel
    and vim.t.filetree_yielded
    and (not refs or columns and columns - width - 1 >= MIN_CODE) -- (- 1: the separator)
  then
    M.open()
  end
end

local room_pending = false

-- make_room once the current event is done (the window closing still has its columns)
local function make_room_later()
  if not room_pending then
    room_pending = true
    vim.schedule(function()
      room_pending = false
      make_room()
    end)
  end
end

-- A window is closing (WinClosed): the panel's keeps its width for the next time. Closed
-- from another window while buffers are deleted, its tab page left, it comes back:
-- deleting the last buffer (:%bdelete, :%bdelete|edit #) has Neovim close every window but
-- one, the panel too, the last buffer deleted after (unlike :only, or q closing the tab
-- page). Another window leaving the panels alone in the tab page (the windows holding
-- their buffers, this one's and the references panel's) has a code window take its place,
-- the current one if it was.
local function closed(args)
  local win = tonumber(args.match)
  make_room_later()
  if vim.w[win].filetree then
    local columns = vim.api.nvim_win_get_width(win)
    if columns >= MIN_WIDTH then
      width = columns
    end
    if not closing and win ~= vim.api.nvim_get_current_win() then
      local before, now, tab = deleted, deleting, vim.api.nvim_win_get_tabpage(win)
      vim.schedule(function()
        if
          (now or deleted > before)
          and vim.v.exiting == vim.NIL
          and tab == vim.api.nvim_get_current_tabpage()
          and not panel_win()
        then
          M.open()
        end
      end)
    end
    return
  end
  -- (one check for all the windows a command closes, as :bwipeout of several: whether the
  -- current one was among them, and the widths from before the first one closed, before
  -- another window is given its columns)
  if not closes then
    closes = { current = false, wins = {}, widths = {} }
    vim.schedule(function()
      local c = closes
      closes = nil
      local panel = panel_win()
      if not panel or vim.v.exiting ~= vim.NIL then
        return
      end
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if not vim.wo[w].winfixbuf and vim.api.nvim_win_get_config(w).relative == '' then
          return -- (another window is left: code, help, quickfix, a terminal)
        end
      end
      restore(panel, c.current, c.widths[panel])
      -- The other panels (the references panel) as wide as they were: the code window has
      -- the columns
      for w, columns in pairs(c.widths) do
        if w ~= panel and not c.wins[w] and valid(w) and vim.wo[w].winfixbuf then
          pcall(vim.api.nvim_win_set_width, w, columns)
        end
      end
    end)
  end
  closes.wins[win] = true
  closes.current = closes.current or win == vim.api.nvim_get_current_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))) do
    if closes.widths[w] == nil then
      closes.widths[w] = vim.api.nvim_win_get_width(w)
    end
  end
end

-- Close the panel when the window being quit (QuitPre) is the tab page's last code window,
-- so :q there quits Neovim, or closes the tab page or the window, as it would without the
-- panel; it opens again if the quit is refused (changes not written)
local function quitting()
  local panel, win = panel_win(), vim.api.nvim_get_current_win()
  if not panel or win == panel then
    return
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= win and code_window(w) then
      return -- (code is left beside the panel)
    end
  end
  M.close()
  vim.schedule(function()
    if valid(win) and vim.api.nvim_get_current_win() == win and not panel_win() then
      M.open()
    end
  end)
end

-- The working directory changed (:cd, project.nvim), or the tab page (:tcd): the tree shows
-- the new one, the code window's file in it
local function moved()
  local dir = cwd()
  if dir ~= root then
    root, revealed = dir, false
    local win = panel_win()
    if win then
      render(win)
      update()
    end
  end
end

local function highlights()
  for name, link in pairs({
    FileTreeDirectory = 'Directory',
    FileTreeFolderIcon = 'Directory',
    FileTreeOpened = 'Special', -- a file open as a buffer
    FileTreeOpenedDir = 'FileTreeOpened', -- a directory holding one
    FileTreeCurrent = 'FileTreeOpened', -- the code window's file
    FileTreeCursorLine = 'CursorLine',
    FileTreeTitle = 'Directory', -- the directory, over the panel (bufferline's offset)
  }) do
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup('filetree', { clear = true })
  local function on(events, callback, opts)
    vim.api.nvim_create_autocmd(events, vim.tbl_extend('force', { group = group, callback = callback }, opts or {}))
  end

  highlights()
  on('ColorScheme', highlights)

  -- The buffers listed, named, written as another file, and the one in the code window
  on({ 'BufEnter', 'BufAdd', 'BufFilePost', 'BufWritePost' }, update_later)
  on({ 'BufAdd', 'BufDelete', 'BufWipeout', 'BufFilePost' }, function()
    under_cursor = {} -- (see M.cursor_buffer)
  end)
  on('BufDelete', function(args)
    if vim.bo[args.buf].buflisted then
      deleted = deleted + 1
      if not deleting then
        deleting = true
        vim.schedule(function()
          deleting = false
        end)
      end
    end
    update_later()
  end)
  on('BufWipeout', function(args)
    if args.buf == buf then
      buf, rows, line_of = nil, {}, {}
      fs.watch({}) -- (closed in every tab page)
    end
    update_later()
  end)
  -- A preview another buffer took the place of goes (see drop_preview); a preview changed
  -- is kept (see show_preview)
  on('BufHidden', function(args)
    if preview and args.buf == preview.buf then
      local gone = preview
      preview = nil
      vim.schedule(function()
        drop_preview(gone)
      end)
    end
  end)
  -- (BufModifiedSet is gone: OptionSet, which doesn't tell the buffer)
  on('OptionSet', function()
    if preview and vim.api.nvim_buf_is_valid(preview.buf) and vim.bo[preview.buf].modified then
      keep_preview()
    end
  end, { pattern = 'modified' })
  on('BufWinEnter', taken)
  on('WinEnter', entered)
  on('WinClosed', closed)
  on('QuitPre', quitting)
  on('DirChanged', moved, { pattern = { 'global', 'tabpage' } })
  on('TabEnter', function()
    moved()
    update_later()
    make_room_later()
  end)
  on({ 'WinNew', 'VimResized' }, make_room_later)
  -- (what the watchers may have missed: a directory couldn't be watched)
  on('FocusGained', function()
    if buf then
      fs.watch({})
      render(panel_win())
    end
  end)
  fs.on_change(function()
    render(panel_win())
    update_later() -- (a new file written: shown)
  end)

  -- (a release ending a drag opens nothing, see keymaps)
  local press, drag = vim.keycode('<LeftMouse>'), vim.keycode('<LeftDrag>')
  vim.on_key(function(_, typed)
    if typed == press then
      dragged = false
    elseif typed == drag then
      dragged = true
    end
  end, vim.api.nvim_create_namespace('filetree.mouse'))

  vim.api.nvim_set_decoration_provider(ns, {
    on_win = function(_, _, b)
      return b == buf
    end,
    on_line = function(_, _, b, row)
      draw_line(b, row)
    end,
  })
end

return M
