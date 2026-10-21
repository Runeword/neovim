local vim = vim
local diff = require('gl.diff')

-- gl, the git log picker of ~/terminal's shell (<Space>gl at an empty prompt), in a split along
-- the bottom. It runs the shell's own function, __git_log in the shell config's
-- functions/git.bash, so its lists look and work as they do there and change with it: pick a
-- commit, then files of it. Its preview, git show through delta, gives way to the code window
-- showing the file under fzf's cursor (in the commits' list, the commit's first file) as the
-- commit leaves it, the commit's change marked in it (gl.diff). Where the shell opens the files
-- picked in a new Neovim ($EDITOR -- <files>), they open here, as buffers, the first in the
-- code window.
local M = {}

-- zsh -f gives gl the environment of a new shell: xdg.sh, which puts back the
-- XDG_CONFIG_HOME Neovim's wrapper changes, and variables.sh (FZF_DEFAULT_OPTS: fzf's keys,
-- the search off at start), which the shell's .zshrc sources before git.bash.
-- $PERMEANCE_TREE is the shell config's tree, live (~/terminal/sources) or bundled, as the
-- shell Neovim was started from exports it. Each fzf gl runs gets, last so that they win, the
-- split's height (not gl's 70%), no preview, and binds that tell Neovim, in OSC 5379
-- sequences on the terminal, that it starts (with the commit whose files it lists, $commit in
-- __git_log, else nothing) and which row has the cursor, by its second field: a commit's
-- hash, a file's path, or nothing when the search matches none. gl prints `$EDITOR --
-- <files>`, which $EDITOR, a function here, writes to $GL_FILES, absolute and NUL-separated.
local SCRIPT = [[
for f in xdg.sh variables.sh functions/git.bash; do
  . "$PERMEANCE_TREE/.config/shell/$f"
done
fzf() {
  command fzf "$@" --height=100% --preview-window=hidden \
    --bind "start:+execute-silent(printf '\\033]5379;gl;start;%s\\007' ${(q)commit-} >/dev/tty)" \
    --bind 'focus:+execute-silent(printf "\033]5379;gl;focus;%s\007" {2} >/dev/tty)' \
    --bind 'zero:+execute-silent(printf "\033]5379;gl;focus;\007" >/dev/tty)'
}
__gl_edit() {
  [ "$1" = -- ] && shift
  print -rN -- "${@:a}" >"$GL_FILES"
}
EDITOR=__gl_edit
cmd=$(__git_log) && [ -n "$cmd" ] && eval "$cmd"
]]

-- The code window's options a change sets (gl.diff: its winbar), given back with it
local SAVED = { 'winbar' }

local session -- gl, while it runs

-- The split's height: three tenths of the editor's, a few more rows than gl's list had in the
-- shell, and the diff the rest
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
-- floating, nor holding its buffer (the file tree's, the references')
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
  local ok, err = pcall(vim.cmd, ('edit %s%s'):format(line and '+' .. line .. ' ' or '', vim.fn.fnameescape(paths[1])))
  if not ok then
    vim.notify(err, vim.log.levels.ERROR)
  end
  for i = 2, #paths do
    vim.cmd('badd ' .. vim.fn.fnameescape(paths[i]))
  end
end

-- The files gl wrote, if any
local function picked(file)
  local f = io.open(file, 'rb')
  if not f then
    return {}
  end
  local data = f:read('*a')
  f:close()
  os.remove(file)
  return vim.split(data, '\0', { plain = true, trimempty = true })
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

local function give_back(s)
  if valid(s.made) then
    pcall(vim.api.nvim_win_close, s.made, true)
  end
  local g = s.give
  if not (g and valid(g.win) and vim.b[vim.api.nvim_win_get_buf(g.win)].gl) then
    return
  end
  if vim.api.nvim_buf_is_valid(g.buf) then
    swap(g.win, g.buf)
    vim.api.nvim_win_call(g.win, function()
      vim.fn.winrestview(g.view)
    end)
  else
    vim.api.nvim_win_call(g.win, vim.cmd.enew)
  end
  for opt, value in pairs(g.opts) do
    vim.api.nvim_set_option_value(opt, value, { win = g.win, scope = 'local' })
  end
end

-- From the diff, the file at the cursor's line (the work tree's, as delta's links open it),
-- closing gl
local function jump(s)
  local path = s.file and s.file.new
  if not (path and valid(s.view) and vim.uv.fs_stat(s.root .. '/' .. path)) then
    vim.notify('gl: ' .. (path or (s.file or {}).old or 'the file') .. ' is not in the work tree', vim.log.levels.WARN)
    return
  end
  s.jump = { path = s.root .. '/' .. path, line = vim.api.nvim_win_get_cursor(s.view)[1] }
  vim.fn.jobstop(s.job)
end

-- A version's buffer: gl's (gl.diff makes one each time), q closes gl, <CR> opens the file,
-- <C-j>/<C-k> take fzf's cursor to its next/previous row, the diff following it while the
-- cursor stays here, for j and k (join and treesj have nothing to do here; visual and
-- operator-pending <C-j>/<C-k> keep their jumps)
local function keys(s, buf)
  vim.b[buf].gl = true
  vim.keymap.set('n', 'q', function()
    vim.fn.jobstop(s.job)
  end, { buffer = buf, nowait = true, desc = 'gl: close' })
  vim.keymap.set('n', '<CR>', function()
    jump(s)
  end, { buffer = buf, desc = 'gl: open the file at this line' })
  -- (fzf's <Down> and <Up>, as the terminal sends them: whatever they do in its list, in the
  -- files' the next file, past the directories)
  for key, arrow in pairs({ ['<C-j>'] = '\27[B', ['<C-k>'] = '\27[A' }) do
    vim.keymap.set('n', key, function()
      pcall(vim.api.nvim_chan_send, s.job, arrow)
    end, { buffer = buf, desc = key == '<C-j>' and 'gl: next row' or 'gl: previous row' })
  end
end

-- The commit's files, once per commit
local function files(s, sha, cb)
  if s.files[sha] then
    return cb(s.files[sha])
  end
  diff.files(s.dir, sha, function(list)
    vim.schedule(function()
      s.files[sha] = list
      cb(list)
    end)
  end)
end

-- The file of the row: the one at its path (a directory's, ending in /: the first below it),
-- else the commit's first; one git doesn't list, as git has it at the path
local function pick(list, path)
  if not path then
    return list[1]
  end
  for _, f in ipairs(list) do
    if f.new == path or f.old == path or path:sub(-1) == '/' and (f.new or f.old):sub(1, #path) == path then
      return f
    end
  end
  return path:sub(-1) ~= '/' and { status = 'M', old = path, new = path } or nil
end

-- Shows the diff asked for last once git has it, one at a time
local function pump(s)
  local want = s.want
  if s.busy or s.closed or not want or want.key == s.shown then
    return
  end
  s.busy = true
  local function show(file, old, new, extra)
    s.busy = false
    if not s.closed and s.want == want then
      s.shown = want.key
      local w = diff_window(s)
      if w then
        diff.show(w, want.sha, file, old, new, extra, function(buf)
          keys(s, buf)
        end)
        s.file = file
      end
    end
    pump(s)
  end
  if want.sha == '' then -- no row: the search matches none
    return show()
  end
  files(s, want.sha, function(list)
    local file = pick(list, want.path)
    if not file or s.want ~= want then
      return show(file)
    end
    -- (in the commits' list, a commit's first file: says of how many)
    local extra = not want.path and #list > 1 and ('  · 1 of %d files'):format(#list) or nil
    diff.versions(s.dir, want.sha, file, function(old, new)
      vim.schedule(function()
        show(file, old, new, extra)
      end)
    end)
  end)
end

local function ask(s, sha, path)
  s.want = { key = sha .. '\0' .. (path or ''), sha = sha, path = path }
  pump(s)
end

-- fzf's word, in its OSC 5379 sequences: that it starts, listing the files of a commit (whose
-- hash comes with it, else the commit under the cursor when the commits' list closed) or the
-- commits; which row has the cursor (nothing, for none)
local function heard(s, sequence)
  local kind, arg = sequence:match('^\27%]5379;gl;(%a+);(.*)')
  if kind == 'start' then
    s.commit = arg ~= '' and arg or s.started and s.focused or nil
    s.started = true
  elseif kind == 'focus' and s.commit then
    ask(s, arg == '' and '' or s.commit, arg ~= '' and arg or nil)
  elseif kind == 'focus' then
    s.focused = arg
    ask(s, arg)
  end
end

-- fzf's keys for its preview (FZF_DEFAULT_OPTS) move the diff
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

-- gl in its split, for the session s (its directory and repository root, its files' cache, the
-- references panel to open again after)
local function launch(s)
  s.origin = vim.api.nvim_get_current_win()
  s.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[s.buf].bufhidden = 'wipe'
  local ok, win = pcall(vim.api.nvim_open_win, s.buf, true, { split = 'below', win = -1, height = height() })
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
  for opt, value in pairs({
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    foldcolumn = '0',
    statuscolumn = '',
    spell = false,
    list = false,
    colorcolumn = '',
    winfixheight = true,
    winfixbuf = true,
  }) do
    vim.api.nvim_set_option_value(opt, value, { win = s.win, scope = 'local' })
  end

  -- Every key goes to fzf, as in the shell's terminal: the keys the config gives terminal mode
  -- (<Esc> to normal mode, the bufferline's digits) type themselves here. But fzf's keys for
  -- its preview move the diff, and <C-Up> (focus the window above, in normal mode) goes to it.
  for _, map in ipairs(vim.api.nvim_get_keymap('t')) do
    vim.keymap.set('t', map.lhs, map.lhs, { buffer = s.buf, nowait = true })
  end
  for key, by in pairs({
    ['<S-Up>'] = -1,
    ['<S-Down>'] = 1,
    ['<S-PageUp>'] = -4,
    ['<S-PageDown>'] = 4,
    ['<S-Home>'] = 'top',
    ['<S-End>'] = 'bottom',
  }) do
    vim.keymap.set('t', key, function()
      scroll(s, by)
    end, { buffer = s.buf, nowait = true })
  end
  vim.keymap.set('t', '<C-Up>', function()
    if valid(s.view) and vim.b[vim.api.nvim_win_get_buf(s.view)].gl then
      vim.api.nvim_set_current_win(s.view)
    end
  end, { buffer = s.buf, nowait = true, desc = 'gl: focus the diff' })

  local group = vim.api.nvim_create_augroup('gl_' .. s.buf, { clear = true })
  vim.api.nvim_create_autocmd('TermRequest', {
    group = group,
    buffer = s.buf,
    callback = function(ev)
      heard(s, type(ev.data) == 'table' and ev.data.sequence or ev.data)
    end,
  })
  -- Back in gl's window, back to fzf
  vim.api.nvim_create_autocmd('BufEnter', { group = group, buffer = s.buf, command = 'startinsert' })
  vim.api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      if valid(s.win) then
        vim.api.nvim_win_set_height(s.win, height())
      end
    end,
  })

  local file = vim.fn.tempname()
  local function exited()
    s.closed = true
    vim.api.nvim_del_augroup_by_id(group)
    local paths = picked(file)
    give_back(s)
    -- (the last window, once the others were closed: it shows the code again)
    if valid(s.win) and not pcall(vim.api.nvim_win_close, s.win, true) then
      vim.wo[s.win].winfixbuf = false
      local buf = s.give and vim.api.nvim_buf_is_valid(s.give.buf) and s.give.buf
      vim.api.nvim_win_call(s.win, function()
        vim.cmd(buf and 'buffer ' .. buf or 'enew')
      end)
    end
    session = nil
    if #paths > 0 then
      edit(paths, s.origin)
    elseif s.jump then
      edit({ s.jump.path }, s.give and s.give.win or s.origin, s.jump.line)
    elseif valid(s.origin) then
      vim.api.nvim_set_current_win(s.origin)
    end
    if s.refs then
      s.refs.open()
    end
  end
  ok, s.job = pcall(vim.fn.jobstart, { 'zsh', '-f', '-c', SCRIPT }, {
    term = true,
    cwd = s.dir,
    env = { GL_FILES = file },
    on_exit = exited,
  })
  if not ok or s.job <= 0 then
    vim.notify('gl: ' .. (ok and 'zsh would not start' or s.job), vim.log.levels.ERROR)
    exited()
    return
  end
  vim.cmd.startinsert()
end

function M.open()
  if session then -- (one at a time) back to it
    if valid(session.win) then
      vim.api.nvim_set_current_win(session.win)
      vim.cmd.startinsert()
    end
    return
  end

  local tree = vim.env.PERMEANCE_TREE
  if not (tree and vim.uv.fs_stat(tree .. '/.config/shell/functions/git.bash')) then
    vim.notify('gl: no ~/terminal shell config ($PERMEANCE_TREE, which its shell sets)', vim.log.levels.ERROR)
    return
  end
  local dir = directory()
  local top = vim.system({ 'git', 'rev-parse', '--show-toplevel' }, { cwd = dir, text = true }):wait()
  if top.code ~= 0 then
    vim.notify('gl: ' .. vim.trim(top.stderr), vim.log.levels.ERROR)
    return
  end

  local s = { dir = dir, root = vim.trim(top.stdout), files = {} }
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
