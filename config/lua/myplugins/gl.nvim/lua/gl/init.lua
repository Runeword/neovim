local vim = vim
local diff = require('gl.diff')
local list = require('gl.list')

-- gl, a git log in a split along the bottom, and gdc, gdd and gda, the files with a staged
-- change, an unstaged one, or either, the same way. The lists are gl's own (gl.list): they look
-- as the pickers of the same names in ~/terminal's shell do, but don't run them, so a change
-- there leaves them as they are. Commits, then a commit's files; or changed files. The code
-- window shows the change of the row under the list's cursor: in gl, the file (on a commit's
-- row, the commit's first) as the commit leaves it, or in gdc, gdd and gda the file itself,
-- opened as a buffer, with its change marked in it (gl.diff). The shell's pickers only start
-- Neovim in them, on the files picked there (see plugins/minimal/gl.lua). (Below, gdc stands
-- for all three where they work alike.)
local M = {}

-- gl's lists, by name (the shell's word for each, which plugins/minimal/gl.lua gets from it):
-- the revision whose files it lists, if any (gdc's: the index, the staged files; gdd's and
-- gda's: the work tree, the files changed since the index, or since HEAD), else gl's, the
-- commits, then a commit's; whether its files open, the work tree's, to edit with the change
-- marked on them (gl.diff), rather than show as a version of theirs (gl's); and whether its
-- change starts from the index (gdd's), which a staging changes: its files then listed and
-- marked again (see watch)
local TOOLS = {
  log = { name = 'log' },
  staged = { name = 'staged', rev = diff.INDEX, edit = true },
  unstaged = { name = 'unstaged', rev = diff.UNSTAGED, edit = true, index = true },
  changed = { name = 'changed', rev = diff.CHANGED, edit = true },
}

-- The code window's options a change sets (gl.diff: its winbar), given back with it
local SAVED = { 'winbar' }

-- The list's window's options, set for it alone, as the file tree's are: its rows as plain text
-- even in the background, and a cursor line of its own, shown there too
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
  colorcolumn = '',
  winfixheight = true,
  winfixbuf = true,
  fillchars = 'eob: ',
  winhighlight = 'NormalNC:Normal,EndOfBuffer:Normal,CursorLine:GlListCursorLine',
}

local session -- gl, while it runs

-- The split's height: three tenths of the editor's, and the diff the rest
local function height()
  return math.max(8, math.floor((vim.o.lines - vim.o.cmdheight) * 0.3))
end

-- The directory gl runs in, whose repository it shows: the current file's, else the working
-- directory (in the file tree, a terminal)
local function directory()
  local name = vim.api.nvim_buf_get_name(0)
  if vim.bo.buftype == '' and name ~= '' and vim.fn.isdirectory(vim.fs.dirname(name)) == 1 then
    return vim.fs.dirname(name)
  end
  return vim.fn.getcwd()
end

local function valid(w)
  return w and vim.api.nvim_win_is_valid(w)
end

-- A window showing a file (or a new one, or a directory's listing, Neovim's nvim.dir), not
-- floating, nor holding its buffer (the file tree's, the references', gl's list)
local function code_window(w)
  if not valid(w) or vim.api.nvim_win_get_config(w).relative ~= '' or vim.wo[w].winfixbuf then
    return false
  end
  local b = vim.api.nvim_win_get_buf(w)
  return vim.bo[b].buftype == '' or vim.b[b].nvim_dir ~= nil
end

local function first_code_window()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if code_window(w) then
      return w
    end
  end
end

-- Opens the files as buffers, the first (at the line) in the window gl was started from, else
-- in the first code window, as `nvim -- <files>` would show them
local function edit(paths, origin, line)
  local w = code_window(origin) and origin or first_code_window()
  if w then
    vim.api.nvim_set_current_win(w)
  end
  if vim.fn.bufadd(paths[1]) == vim.api.nvim_get_current_buf() then -- (shown: :edit would read it again)
    if line then
      vim.cmd(('normal! %dG'):format(line))
    end
  else
    local ok, err =
      pcall(vim.cmd, ('edit %s%s'):format(line and '+' .. line .. ' ' or '', vim.fn.fnameescape(paths[1])))
    if not ok then
      vim.notify(err, vim.log.levels.ERROR)
    end
  end
  for i = 2, #paths do
    vim.cmd('badd ' .. vim.fn.fnameescape(paths[i]))
  end
end

-- Puts a buffer in the window as a preview would, leaving the jump list, the alternate file
-- and the autocommands (the file tree's, the references') as if it hadn't
local function swap(w, buf)
  vim.api.nvim_win_call(w, function()
    vim.cmd('noautocmd keepalt keepjumps buffer ' .. buf)
  end)
end

local function scratch()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  return buf
end

-- The code window, from now on the diff's (its buffer, view and options kept to give back)
local function take(s, w)
  if w == s.made then -- (a file opened since in the window gl made: it stays, with the file)
    s.made = nil
  end
  s.give = { win = w, buf = vim.api.nvim_win_get_buf(w), opts = {} }
  s.give.view = vim.api.nvim_win_call(w, vim.fn.winsaveview)
  for _, opt in ipairs(SAVED) do
    s.give.opts[opt] = vim.api.nvim_get_option_value(opt, { win = w })
  end
end

-- The window of the diff: the code window (or another, if that one shows something else since),
-- else one made over gl's
local function diff_window(s)
  local w = s.view
  if valid(w) and vim.b[vim.api.nvim_win_get_buf(w)].gl then
    return w
  end
  w = valid(w) and code_window(w) and w or code_window(s.origin) and s.origin or first_code_window()
  if w then
    take(s, w)
  elseif valid(s.win) then
    w = vim.api.nvim_open_win(scratch(), false, { split = 'above', win = s.win })
    s.made = w
  else
    return
  end
  s.view = w
  return w
end

-- The code window back as gl found it (its buffer, view and options), gl's marks and keys off
-- the file it showed; turned off (s.off, see M.open), it keeps that file, as it is
local function give_back(s)
  if valid(s.made) then
    local b = vim.api.nvim_win_get_buf(s.made)
    if s.off and vim.bo[b].buftype == '' then -- (a code window from now on)
      diff.quiet(s.made, false)
      diff.release(b)
    else
      pcall(vim.api.nvim_win_close, s.made, true)
    end
  end
  local g = s.give
  if g and valid(g.win) then
    diff.quiet(g.win, false) -- (its own highlights back)
  end
  if not (g and valid(g.win) and vim.b[vim.api.nvim_win_get_buf(g.win)].gl) then
    return
  end
  local shown = vim.api.nvim_win_get_buf(g.win)
  local opened = vim.bo[shown].buftype == '' -- (a file gdc opened, not a version's buffer)
  local stay = s.off and opened
  local cmd
  if stay then
    -- (it stays)
  elseif not vim.api.nvim_buf_is_valid(g.buf) then
    -- (gone meanwhile, as the file tree's preview goes once a file takes its place: a file
    -- opened stays, else the one opened last, else a new buffer)
    local last = s.last and vim.api.nvim_buf_is_valid(s.last) and s.last
    cmd = not opened and (last and 'keepalt buffer ' .. last or 'enew') or nil
  elseif s.last then
    -- (after files opened, gdc's: back the same way, its autocommands run, and the alternate
    -- file isn't a version's buffer, wiped once it leaves)
    cmd = (opened and '' or 'keepalt ') .. 'buffer ' .. g.buf
  else
    swap(g.win, g.buf)
  end
  if cmd then
    local ok, err = pcall(vim.api.nvim_win_call, g.win, function()
      vim.cmd(cmd)
    end)
    if not ok then
      vim.notify('gl: ' .. err, vim.log.levels.ERROR)
    end
  end
  if not stay and vim.api.nvim_win_get_buf(g.win) == g.buf then
    vim.api.nvim_win_call(g.win, function()
      vim.fn.winrestview(g.view)
    end)
  end
  for opt, value in pairs(g.opts) do
    vim.api.nvim_set_option_value(opt, value, { win = g.win, scope = 'local' })
  end
  -- (a file of the work tree marked in place: its marks and gl's keys off, the file still open)
  diff.release(shown)
end

-- Closes gl: the code window given back (see give_back), the list's window closed (the last
-- window: it shows the code instead), and the files picked opened (gl's, from a commit's), else
-- the file at the diff's line (see jump); the cursor back where gl started, but turned off from
-- a window, there
local function close(s)
  if s.closed then
    return
  end
  s.closed = true
  if s.group then
    vim.api.nvim_del_augroup_by_id(s.group)
  end
  if s.rest then
    s.rest:close()
  end
  if s.watch then
    s.watch:close()
    s.watch_timer:close()
  end
  give_back(s)
  if valid(s.win) and not pcall(vim.api.nvim_win_close, s.win, true) then
    vim.wo[s.win].winfixbuf = false
    local buf = s.give and vim.api.nvim_buf_is_valid(s.give.buf) and s.give.buf
    vim.api.nvim_win_call(s.win, function()
      vim.cmd(buf and 'buffer ' .. buf or 'enew')
    end)
  end
  session = nil
  if s.picked then
    edit(s.picked, s.origin)
  elseif s.jump then
    edit({ s.jump.path }, s.give and s.give.win or s.origin, s.jump.line)
  elseif valid(s.off) then -- (turned off from that window: the cursor stays there)
    vim.api.nvim_set_current_win(s.off)
  elseif valid(s.origin) then
    vim.api.nvim_set_current_win(s.origin)
  end
  if s.refs then
    s.refs.open()
  end
end

-- From the diff, the file at the cursor's line (the work tree's, as delta's links open it; in
-- gdc, the file itself), closing gl
local function jump(s)
  local path = s.file and s.file.new
  if not (path and valid(s.view) and vim.uv.fs_stat(s.root .. '/' .. path)) then
    vim.notify('gl: ' .. (path or (s.file or {}).old or 'the file') .. ' is not in the work tree', vim.log.levels.WARN)
    return
  end
  s.jump = { path = s.root .. '/' .. path, line = vim.api.nvim_win_get_cursor(s.view)[1] }
  close(s)
end

-- The files of the revision (a commit, the index, the work tree), once per revision (asked again
-- while git lists them, all told at once); but listed before a new index (see restage), told
-- and not kept
local function files(s, rev, cb)
  if s.files[rev] then
    return cb(s.files[rev])
  elseif s.waiting[rev] then
    table.insert(s.waiting[rev], cb)
    return
  end
  local waiting, gen = { cb }, s.gen
  s.waiting[rev] = waiting
  diff.files(s.dir, rev, function(l)
    vim.schedule(function()
      if s.gen == gen then
        s.files[rev], s.waiting[rev] = l, nil
      end
      for _, f in ipairs(waiting) do
        f(l)
      end
    end)
  end)
end

-- The file of the row: the one at its path (a directory's, ending in /: the first below it),
-- else the commit's first; one git doesn't list, as git has it at the path
local function pick(l, path)
  if not path then
    return l[1]
  end
  for _, f in ipairs(l) do
    if f.new == path or f.old == path or path:sub(-1) == '/' and (f.new or f.old):sub(1, #path) == path then
      return f
    end
  end
  return path:sub(-1) ~= '/' and { status = 'M', old = path, new = path } or nil
end

local step -- (below)

-- The diff's buffer (a version's, gl.diff makes one each time; in gdc, the file's own, while
-- it's shown): q closes gl, <CR> opens the file, <C-j>/<C-k> take the list's cursor to its
-- next/previous row, the diff following it while the cursor stays here, for j and k (join and
-- treesj wait meanwhile; visual and operator-pending <C-j>/<C-k> keep their jumps)
local function keys(s, buf)
  vim.b[buf].gl = true
  vim.keymap.set('n', 'q', function()
    close(s)
  end, { buffer = buf, nowait = true, desc = 'gl: close' })
  vim.keymap.set('n', '<CR>', function()
    jump(s)
  end, { buffer = buf, desc = 'gl: open the file at this line' })
  vim.keymap.set('n', '<C-j>', function()
    step(s, 1)
  end, { buffer = buf, desc = 'gl: next row' })
  vim.keymap.set('n', '<C-k>', function()
    step(s, -1)
  end, { buffer = buf, desc = 'gl: previous row' })
end

-- Shows the diff asked for last once git has it, one at a time; asked to (want.focus), the
-- cursor then goes to it
local function pump(s)
  local want = s.want
  if s.busy or s.closed or not want or want.key == s.shown then
    return
  end
  s.busy = true
  local function show(file, old, new, extra)
    s.busy = false
    if want.follow and s.want == want and not (valid(s.view) and vim.api.nvim_win_get_buf(s.view) == want.follow) then
      s.want = nil -- (a file followed, gone from the window since: what shows instead stays)
    elseif not s.closed and s.want == want then
      s.shown = want.key
      local w = diff_window(s)
      if w then
        local path = s.tool.edit and file and file.new and s.root .. '/' .. file.new or nil
        local opened = diff.show(w, want.rev, file, old, new, extra, function(buf)
          keys(s, buf)
        end, path, want.follow ~= nil)
        s.last = opened and vim.api.nvim_win_get_buf(w) or s.last -- (the file gdc opened last)
        s.file = file
        -- (gdc's first file: the cursor goes to it, from where gdc started, if not there already)
        if s.tool.edit and file and not s.landed then
          s.landed = true
          if vim.api.nvim_get_current_win() == s.origin and w ~= s.origin then
            vim.api.nvim_set_current_win(w)
          end
        end
        if want.focus then
          vim.api.nvim_set_current_win(w)
        end
      end
    end
    pump(s)
  end
  files(s, want.rev, function(l)
    local file = pick(l, want.path)
    if not file or s.want ~= want then
      return show(file)
    end
    -- (on a commit's row, its first file: says of how many)
    local extra = not want.path and #l > 1 and ('  · 1 of %d files'):format(#l) or nil
    local v = s.versions[file] -- (gdc's, gdd's, gda's, see fetch: shown at once)
    if v then
      return show(file, v.old, v.new, extra)
    end
    diff.versions(s.dir, want.rev, file, function(old, new)
      vim.schedule(function()
        if s.tool.edit then
          s.versions[file] = { old = old, new = new }
        end
        show(file, old, new, extra)
      end)
    end)
  end)
end

-- (follow: the buffer of the file, shown already, see follow; focus: see pump)
local function ask(s, rev, path, follow, focus)
  s.want = { key = rev .. '\0' .. (path or ''), rev = rev, path = path, follow = follow, focus = focus }
  pump(s)
end

-- The revision and path whose change a row shows: a commit's first file's (a commit's row over
-- its files, too); a file's (a directory's: the first file below it, see pick), in its commit,
-- else in the list's revision
local function target(s, r)
  if r.kind == 'commit' or r.kind == 'head' then
    return r.hash, nil
  end
  return r.rev or s.rev, r.path
end

-- A row the cursor passes by: a directory's, a commit's over its files
local function passed(r)
  return r.kind == 'dir' or r.kind == 'head'
end

-- The commit hash names, by its first digits (the shell's hashes are as short as gl's)
local function same(a, b)
  return a and b and (vim.startswith(a, b) or vim.startswith(b, a))
end

-- The row of the file at path (in the commit rev, if given), if the list has it
local function row_of(s, path, rev)
  for i, r in ipairs(s.rows) do
    if r.path == path and r.kind ~= 'dir' and (not rev or same(r.rev, rev)) then
      return i
    end
  end
end

-- The list drawn again, as wide as its window, its cursor kept on its row
local function draw(s)
  if not (valid(s.win) and vim.api.nvim_buf_is_valid(s.buf)) then
    return
  end
  list.draw(s.buf, s.rows, vim.api.nvim_win_get_width(s.win), s.marked)
  if s.rows[s.row] then
    pcall(vim.api.nvim_win_set_cursor, s.win, { s.row, 0 })
  end
end

-- The list's cursor on row i, which it shows already (or is about to): no change asked for
local function put(s, i)
  s.row = i
  if valid(s.win) and s.rows[i] then
    pcall(vim.api.nvim_win_set_cursor, s.win, { i, 0 })
  end
end

-- The row i's change, shown at once; but rows going by faster than REST ms apart (a key held),
-- the one the cursor rests on, as the file tree's j/k show theirs: gdc doesn't open every file
-- passed
local REST = 80
local function settle(s, i)
  local r = s.rows[i]
  if not r then
    return
  end
  local rev, path = target(s, r)
  local now = vim.uv.now()
  local held = s.moved and now - s.moved < REST
  s.moved = now
  s.rest = s.rest or vim.uv.new_timer()
  s.rest:stop()
  if not held then
    return ask(s, rev, path)
  end
  s.rest:start(
    REST,
    0,
    vim.schedule_wrap(function()
      if not s.closed then
        ask(s, rev, path)
      end
    end)
  )
end

-- From the list or the diff: the list's cursor n rows on (back, n < 0), past a commit's
-- directories (and, of several commits, their rows), its row's change shown; at either end it
-- stops, as the shell's gl does. (Between two rows, its file gone from the list, see restage:
-- the first step is to one of them.)
step = function(s, n)
  local i, by = s.row or 0, n < 0 and -1 or 1
  local to = by > 0 and math.floor(i) or math.ceil(i)
  for _ = 1, math.abs(n) do
    local ahead = to + by
    while s.rows[ahead] and passed(s.rows[ahead]) do
      ahead = ahead + by
    end
    if not s.rows[ahead] then
      break
    end
    to = ahead
  end
  if to ~= i then
    put(s, to)
    settle(s, to)
  end
end

-- The list's cursor moved another way (a search, the mouse, gg, G): its row's change shown
local function moved(s)
  local i = valid(s.win) and vim.api.nvim_win_get_cursor(s.win)[1]
  if i and i ~= s.row and s.rows[i] then
    s.row = i
    settle(s, i)
  end
end

-- The list's rows from now on, drawn, its cursor on row i (none: the first the cursor doesn't
-- pass by), whose change shows: as `ask` asks for it (follow, see follow), at once
local function rows(s, new, i, follow)
  s.rows = new
  if not i then
    i = 1
    while s.rows[i] and passed(s.rows[i]) do
      i = i + 1
    end
  end
  draw(s)
  if s.rows[i] then
    put(s, i)
    local rev, path = target(s, s.rows[i])
    ask(s, rev, path, follow)
  end
end

-- gl's list of the commits, its cursor on the commit hash names, else on the newest, and the
-- commits marked named so (gl started on several by the shell, back from their files)
local function commits(s, hash, marked)
  list.commits(s.dir, function(new)
    vim.schedule(function()
      if s.closed then
        return
      end
      s.rev, s.groups, s.marked = nil, nil, {}
      local at
      for i, r in ipairs(new) do
        at = at or same(r.hash, hash) and i or nil
        for _, m in ipairs(marked or {}) do
          s.marked[r.key] = s.marked[r.key] or same(r.hash, m) or nil
        end
      end
      rows(s, new, at)
    end)
  end)
end

-- gl's list of a commit's files, its cursor on the file at path (gl started on a commit by the
-- shell's gl: the file it opened), else on the first
local function commit_files(s, hash, path)
  s.rev, s.groups, s.marked = hash, nil, {}
  files(s, hash, function(l)
    if not s.closed and s.rev == hash and not s.groups then
      local tree = list.tree(l, hash)
      s.rows = tree -- (for row_of)
      rows(s, tree, path and row_of(s, path))
    end
  end)
end

-- gl's list of the files of several commits, as the shell's gl lists them, the commits Tab
-- marked there (or here): each commit's under a row of its own (● hash subject), in the order
-- given (the commit list's); its cursor on the file at path in the commit start (the shell's
-- gl started Neovim on that file, picked in that commit), else on the first file
local function groups(s, hashes, start, path)
  s.rev, s.groups, s.marked = nil, hashes, {}
  local heads, trees, left = nil, {}, #hashes + 1
  local function done()
    left = left - 1
    if left > 0 or s.closed or s.groups ~= hashes then
      return
    end
    local new = {}
    for i, hash in ipairs(hashes) do
      new[#new + 1] = heads[i]
      vim.list_extend(new, list.tree(trees[i], hash))
    end
    s.rows = new -- (for row_of)
    rows(s, new, path and row_of(s, path, start))
  end
  list.heads(s.dir, hashes, function(h)
    vim.schedule(function()
      heads = h
      done()
    end)
  end)
  for i, hash in ipairs(hashes) do
    files(s, hash, function(l)
      trees[i] = l
      done()
    end)
  end
end

-- <CR> in the list: on a commit, its files (the commits marked: all of theirs, see groups); on a
-- commit's file, those marked (else it) opened, closing gl, as the shell's gl opens them; on
-- gdc's file, to it, in the code window
local function choose(s)
  local r = s.rows[s.row or 0]
  if not r or r.kind == 'head' then
    return
  elseif r.kind == 'commit' then
    local marked = {}
    for _, row in ipairs(s.rows) do
      if s.marked[row.key] then
        marked[#marked + 1] = row.hash
      end
    end
    s.back = { rows = s.rows, row = s.row, marked = s.marked }
    if #marked > 1 then
      return groups(s, marked)
    end
    return commit_files(s, marked[1] or r.hash)
  elseif s.tool.edit then
    local rev, path = target(s, r)
    if s.shown == rev .. '\0' .. path and valid(s.view) then
      return vim.api.nvim_set_current_win(s.view)
    end
    return ask(s, rev, path, nil, true)
  end
  local paths, seen = {}, {}
  for _, row in ipairs(s.rows) do
    if row.kind == 'file' and s.marked[row.key] and not seen[row.path] then
      seen[row.path] = true
      paths[#paths + 1] = row.path
    end
  end
  if #paths == 0 and r.kind == 'file' then
    paths[1] = r.path
  end
  local found = {}
  for _, path in ipairs(paths) do
    if vim.uv.fs_stat(s.root .. '/' .. path) then
      found[#found + 1] = s.root .. '/' .. path
    end
  end
  if #found == 0 then
    if #paths > 0 then
      vim.notify('gl: ' .. table.concat(paths, ', ') .. ' not in the work tree', vim.log.levels.WARN)
    end
    return
  end
  s.picked = found
  close(s)
end

-- <BS> in a commit's files (or several commits'): back to the commits, as they were (the
-- commits marked still marked); started there by the shell's gl, on the commit of the row under
-- the cursor, the commits it started on marked
local function back(s)
  if s.tool.edit or not (s.rev or s.groups) then
    return
  end
  local b, r = s.back, s.rows[s.row or 0]
  s.back = nil
  if b then
    s.rev, s.groups, s.marked = nil, nil, b.marked
    return rows(s, b.rows, b.row)
  end
  commits(s, r and r.rev or s.rev or s.groups[1], s.groups)
end

-- <Tab>/<S-Tab> on a commit, or a commit's file: it's marked (unmarked, back), then on to the next
-- row (back to the previous one), for <CR> to take them all; elsewhere, only on
local function mark(s, n)
  local r = s.rows[s.row or 0]
  if s.marked and r and (r.kind == 'commit' or r.kind == 'file') and not s.tool.edit then
    s.marked[r.key] = n > 0 or nil
    draw(s)
  end
  step(s, n)
end

-- The code window's diff scrolled from the list, by fzf's keys for its preview in the shell
local function scroll(s, by)
  if not (valid(s.view) and vim.b[vim.api.nvim_win_get_buf(s.view)].gl) then
    return
  end
  vim.api.nvim_win_call(s.view, function()
    if by == 'top' then
      vim.cmd('normal! gg')
    elseif by == 'bottom' then
      vim.cmd('normal! G')
    else
      vim.cmd(('normal! %d%s'):format(math.abs(by), by > 0 and '\5' or '\25'))
    end
  end)
end

-- The list's keys: j/k (and the arrows, <C-j>/<C-k>) a row at a time, past a commit's
-- directories (j/k would do this config's 4-line jump), its change shown; <CR>, <BS>, <Tab>,
-- <S-Tab> (see choose, back, mark), q to close; <C-Up> to the diff (<C-w>k would take the window
-- above the cursor's column, which can be the file tree's), the shell's preview keys scroll it
local function list_keys(s)
  local function map(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = s.buf, nowait = true, desc = 'gl: ' .. desc })
  end
  for _, lhs in ipairs({ 'j', '<Down>', '<C-j>' }) do
    map(lhs, function()
      step(s, vim.v.count1)
    end, 'next row')
  end
  for _, lhs in ipairs({ 'k', '<Up>', '<C-k>' }) do
    map(lhs, function()
      step(s, -vim.v.count1)
    end, 'previous row')
  end
  for _, lhs in ipairs({ '<CR>', '<2-LeftMouse>' }) do
    map(lhs, function()
      choose(s)
    end, "a commit's files, else open the file")
  end
  map('<BS>', function()
    back(s)
  end, 'back to the commits')
  map('<Tab>', function()
    mark(s, 1)
  end, 'mark the file, next row')
  map('<S-Tab>', function()
    mark(s, -1)
  end, 'unmark the file, previous row')
  map('q', function()
    close(s)
  end, 'close')
  map('<C-Up>', function()
    if valid(s.view) then
      vim.api.nvim_set_current_win(s.view)
    else
      vim.cmd.wincmd('k')
    end
  end, 'focus the diff')
  map('<C-Down>', '<Nop>', 'nothing below') -- (with none, it would walk the file tree)
  for key, by in pairs({
    ['<S-Up>'] = -1,
    ['<S-Down>'] = 1,
    ['<S-PageUp>'] = -4,
    ['<S-PageDown>'] = 4,
    ['<S-Home>'] = 'top',
    ['<S-End>'] = 'bottom',
  }) do
    map(key, function()
      scroll(s, by)
    end, 'scroll the diff')
  end
end

-- The path in the repository of the file buffer b holds, if it's one of the repository's
local function in_repo(s, b)
  local file = vim.bo[b].buftype == '' and vim.uv.fs_realpath(vim.api.nvim_buf_get_name(b))
  local root = vim.uv.fs_realpath(s.root)
  return file and root and file:sub(1, #root + 1) == root .. '/' and file:sub(#root + 2) or nil
end

-- In gdc, gdd and gda, a file of the list shown in the code window another way than by gl (see
-- launch) gets its change marked, as if picked in the list, whose cursor goes to its row
local function follow(s, b)
  local path = in_repo(s, b)
  if not path then
    return
  end
  files(s, s.rev, function(l)
    for _, f in ipairs(l) do
      if f.new == path and not s.closed and valid(s.view) and vim.api.nvim_win_get_buf(s.view) == b then
        ask(s, s.rev, path, b)
        local i = row_of(s, path)
        if i then
          put(s, i)
        end
        return
      end
    end
  end)
end

-- gdc's, gdd's and gda's files' versions, fetched all at once, each file then marked as it
-- shows, in the same moment, whatever shows it (see pump); but fetched before a new index (see
-- restage), not kept
local function fetch(s)
  local gen = s.gen
  files(s, s.rev, function(l)
    diff.prefetch(s.dir, s.rev, l, function(got)
      vim.schedule(function()
        if s.gen ~= gen then
          return
        end
        for file, v in pairs(got) do
          s.versions[file] = s.versions[file] or v
        end
      end)
    end)
  end)
end

-- gdd's change starts from the index: once git writes a new one (a staging, here or anywhere),
-- its files are listed (the list drawn again, its cursor on the same file if it's still there)
-- and fetched again, and the file the code window shows marked again from it, where it is (its
-- change all staged: no mark left); a file about to show is asked again
local function restage(s)
  if s.closed then
    return
  end
  s.gen = s.gen + 1
  s.files, s.waiting, s.versions = {}, {}, {}
  fetch(s)
  local was = s.row
  local at = s.rows[was or 0]
  files(s, s.rev, function(l)
    if s.closed then
      return
    end
    s.rows = list.changes(s.root, l, s.author)
    local i = at and row_of(s, at.path)
    s.row = nil
    draw(s)
    if i or not was then
      put(s, i or 1)
    else -- (its file gone, all staged: the cursor where it was, between its neighbours for step)
      put(s, math.min(was, #s.rows))
      s.row = was - 0.5
    end
  end)
  local want = s.want
  if want and want.key ~= s.shown then
    s.want = nil
    return ask(s, want.rev, want.path, want.follow)
  end
  local b = valid(s.view) and vim.api.nvim_win_get_buf(s.view)
  local path = b and vim.b[b].gl and in_repo(s, b)
  if path then
    s.want, s.shown = nil, nil
    ask(s, s.rev, path, b)
  end
end

-- Watches git's directory for gdd: the index is written as index.lock, then renamed to index;
-- marked again a moment after the last of a burst
local function watch(s)
  vim.system({ 'git', 'rev-parse', '--absolute-git-dir' }, { cwd = s.dir, text = true }, function(r)
    vim.schedule(function()
      if s.closed or r.code ~= 0 then
        return
      end
      s.watch, s.watch_timer = vim.uv.new_fs_event(), vim.uv.new_timer()
      s.watch:start(vim.trim(r.stdout), {}, function(err, name)
        if not err and name == 'index' then
          s.watch_timer:stop()
          s.watch_timer:start(
            100,
            0,
            vim.schedule_wrap(function()
              restage(s)
            end)
          )
        end
      end)
    end)
  end)
end

-- gl in its split, for the session s (its list, its directory and repository root, its files'
-- cache, the references panel to open again after), the cursor in its list; but gdc's stays on
-- the code, where its files open to edit (the first: see pump), the list below (<C-Down>),
-- moved from there with <C-j>/<C-k>
local function launch(s)
  s.origin = vim.api.nvim_get_current_win()
  s.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[s.buf].bufhidden = 'wipe'
  vim.bo[s.buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, s.buf, 'gl://' .. s.tool.name)
  local enter = not s.tool.edit
  local ok, win = pcall(vim.api.nvim_open_win, s.buf, enter, { split = 'below', win = -1, height = height() })
  if not ok then -- (no room)
    vim.api.nvim_buf_delete(s.buf, { force = true })
    vim.notify('gl: ' .. win, vim.log.levels.ERROR)
    session = nil
    if s.refs then
      s.refs.open()
    end
    return
  end
  s.win = win
  session = s
  for opt, value in pairs(WIN_OPTS) do
    vim.api.nvim_set_option_value(opt, value, { win = s.win, scope = 'local' })
  end
  vim.bo[s.buf].filetype = 'gl'
  list_keys(s)

  local group = vim.api.nvim_create_augroup('gl_' .. s.buf, { clear = true })
  s.group = group
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = s.buf,
    callback = function()
      moved(s)
    end,
  })
  -- A buffer shown in the code window another way than by gl (the file tree, the bufferline,
  -- :edit) stays: what gl was about to show there doesn't come, what it showed is gone (asked
  -- again, it shows again), and the window has its own highlights back; in gdc, it's followed
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    callback = function(ev)
      if vim.api.nvim_get_current_win() == s.view and not vim.b[ev.buf].gl then
        s.want, s.shown = nil, nil
        if s.rest then
          s.rest:stop() -- (nor the row the list's cursor rests on)
        end
        diff.quiet(s.view, false)
        if s.tool.edit then
          follow(s, ev.buf)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      if valid(s.win) then
        vim.api.nvim_win_set_height(s.win, height())
      end
    end,
  })
  -- (its rows as wide as the window: the author and date at its edge)
  vim.api.nvim_create_autocmd('WinResized', {
    group = group,
    callback = function()
      if vim.tbl_contains(vim.v.event.windows, s.win) then
        draw(s)
      end
    end,
  })
  -- (its window closed another way, :q, <C-w>o: gl closes)
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(s.win),
    callback = function()
      s.win = nil
      vim.schedule(function()
        close(s)
      end)
    end,
  })

  -- gdc on the code window's file: marked at once if in its list, in place, the cursor where it
  -- is (started by the shell, on the file it just opened: on its first change, as gdc's moves
  -- take it), its row the list's cursor's; else the list's first file, opened. gl on a commit,
  -- which the shell's gl starts on a file of it, shows the file's change in it so.
  local buf = (s.tool.edit or s.commit) and code_window(s.origin) and vim.api.nvim_win_get_buf(s.origin)
  local path = buf and in_repo(s, buf)
  if path then
    s.view = s.origin -- (the diff's window, see diff_window)
  end
  if s.tool.edit then
    files(s, s.rev, function(l)
      if s.closed then
        return
      end
      s.rows = list.changes(s.root, l, s.author)
      rows(s, s.rows, path and row_of(s, path), not s.from_shell and path and row_of(s, path) and buf or nil)
    end)
    fetch(s)
  elseif s.commits then
    groups(s, s.commits, s.commit, path)
  elseif s.commit then
    commit_files(s, s.commit, path)
  else
    commits(s)
  end
  if s.tool.index then
    watch(s)
  end
end

-- Opens gl's list of the name (see TOOLS): log, gl's, by default; staged, unstaged or changed:
-- gdc's, gdd's or gda's. These start on the current window's file, if it's in their list: its
-- change marked, the cursor where it is (with opts.from_shell, Neovim started by the shell's gdc
-- on the file, see plugins/minimal/gl.lua: on the change, the file just opened); else on the
-- list's first file. gl with opts.commit lists that commit's files, from the current window's
-- file's change in it, the way gdc starts (the shell's gl starts Neovim so, on the commit and
-- files picked there); with opts.commits too, several commits' files, each commit's under a row
-- of its own, the current file's in opts.commit (the shell's gl, its commits marked with Tab);
-- <BS> goes to the commits.
-- Open already, it's turned off: closed as q closes it, but a file it shows stays in the window,
-- its diff gone
function M.open(name, opts)
  local tool = TOOLS[name or 'log']
  if not tool then
    vim.notify('gl: no list ' .. name, vim.log.levels.ERROR)
    return
  elseif session and session.tool == tool and session.win then
    session.off = vim.api.nvim_get_current_win()
    close(session)
    return
  elseif session then -- (one at a time) back to it
    if valid(session.win) then
      vim.api.nvim_set_current_win(session.win)
    end
    return
  end

  local dir = directory()
  local top = vim.system({ 'git', 'rev-parse', '--show-toplevel' }, { cwd = dir, text = true }):wait()
  if top.code ~= 0 then
    vim.notify('gl: ' .. vim.trim(top.stderr), vim.log.levels.ERROR)
    return
  end

  local s =
    { dir = dir, root = vim.trim(top.stdout), files = {}, waiting = {}, versions = {}, tool = tool, rev = tool.rev }
  s.rows = {}
  s.gen = 0 -- (the index's generation, gdd's: see restage)
  s.from_shell = opts and opts.from_shell
  s.commit = tool == TOOLS.log and opts and opts.commit or nil
  s.commits = s.commit and opts.commits and #opts.commits > 1 and opts.commits or nil
  if tool.edit then
    -- (the author of a change not committed yet: the one git will commit it under)
    local who = vim.system({ 'git', 'config', 'user.name' }, { cwd = dir, text = true }):wait()
    s.author = who.code == 0 and vim.trim(who.stdout) or ''
  end
  -- The references panel (myplugins/refs.nvim) gives way: closed while gl runs, the diff having
  -- its room, and open again after. gl then starts once the file tree, which steps aside for
  -- that panel, is back (it comes back on the next tick, after the panel's WinClosed): gl's
  -- split is then along the whole bottom, under the tree too.
  local refs = package.loaded['refs.panel']
  if refs and refs.is_open() then
    s.refs = refs
    refs.close()
    session = s -- (pressed again meanwhile: nothing)
    vim.schedule(function()
      launch(s)
    end)
  else
    launch(s)
  end
end

return M
