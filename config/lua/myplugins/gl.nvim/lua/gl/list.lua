local vim = vim

-- gl's lists, drawn in a buffer of its own (see gl): a repository's commits, a commit's files as
-- a tree, and the files with a staged change, an unstaged one, or either (gdc's, gdd's, gda's).
-- A row is laid out as the pickers of the same names lay out theirs in ~/terminal's shell: its
-- number from 1, right-aligned; its change, + if it only adds (a commit, files; a file, it's
-- new), - if it only deletes, ~ otherwise, in delta's bold green, red or blue; the commit's hash
-- and subject, or the path; then the author and date flush right. A commit's files are a tree,
-- each directory's directories before its files, as lazygit's file tree has them; several
-- commits' files, a tree each, under a row of the commit's own (● hash subject), as the shell's
-- gl lists the files of the commits Tab marked there. Each row has a key, by which it's marked
-- (see draw): a commit's hash, a file's path (in a commit's tree, after the commit's hash).
local M = {}

local ns = vim.api.nvim_create_namespace('gl.list')
local group = vim.api.nvim_create_augroup('gl.list', { clear = true })

-- The shell's colours: the changes' (as delta labels a file's), the tree's lines (its fzf's
-- border colour), a marked row's (its fzf's marker colour), a commit's ● over its files; the
-- cursor line, the file tree's and the references panel's (after/plugin/colors.lua)
local function highlights()
  for name, spec in pairs({
    GlListAdd = { fg = '#2f8f53', bold = true },
    GlListDelete = { fg = '#a84d5f', bold = true },
    GlListChange = { fg = '#3a5d99', bold = true },
    GlListTree = { fg = '#2f394a' },
    GlListDirectory = { link = 'Directory' },
    GlListMark = { fg = '#4534bf' },
    GlListHead = { fg = '#7272ed', bold = true }, -- (a commit's ●, the shell's fzf pointer colour)
    GlListCursorLine = { bg = '#1e2633' },
  }) do
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
end
highlights()
vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = highlights })

local CHANGE = { ['+'] = 'GlListAdd', ['-'] = 'GlListDelete', ['~'] = 'GlListChange' }

-- The verbs a subject starts with that its change says already, as auto-commit writes them
local VERB = { ['+'] = { 'Add ' }, ['-'] = { 'Delete ', 'Remove ' }, ['~'] = { 'Update ' } }

-- How long ago a time was, if less than an hour (23 minutes ago), else its local date and time,
-- the year in two digits (26-10-24 14:30)
local function when(now, t)
  local ago = now - t
  if ago >= 0 and ago < 90 then
    return ago .. (ago == 1 and ' second ago' or ' seconds ago')
  elseif ago >= 0 and ago < 3600 then
    return math.floor((ago + 30) / 60) .. ' minutes ago'
  end
  return os.date('%y-%m-%d %H:%M', t)
end

local function byline(author, date)
  return (author == '' or date == '') and author .. date or author .. ', ' .. date
end

-- A name as a line can hold it: its control characters (a newline) as ?
local function visible(s)
  return (s:gsub('%c', '?'))
end

-- The commits of the repository at dir, newest first: cb(rows), each { kind = 'commit', hash,
-- subject, change, right = its author and date }, its date how long ago if less than an hour
-- (git's %ar), its change by its files (against the first parent, for a merge; none: nil). A
-- subject that starts with the verb of its change loses it.
function M.commits(dir, cb)
  local cmd = {
    'git',
    'log',
    '--no-renames',
    '--diff-merges=first-parent',
    '--name-status',
    '--date=format-local:%y-%m-%d %H:%M',
    '--format=%x1e%h%x1f%an%x1f%ad%x1f%at%x1f%ar%x1f%s',
  }
  vim.system(cmd, { cwd = dir, text = true }, function(r)
    local now, rows = os.time(), {}
    for chunk in (r.code == 0 and r.stdout or ''):gmatch('\30([^\30]*)') do
      local header, files = chunk:match('^([^\n]*)(.*)$')
      local f = vim.split(header, '\31', { plain = true })
      local a, d, o = false, false, false
      for status in files:gmatch('\n(%u)[^\n]*') do
        if status == 'A' then
          a = true
        elseif status == 'D' then
          d = true
        else
          o = true
        end
      end
      local change = a and not (d or o) and '+' or d and not (a or o) and '-' or (a or d or o) and '~' or nil
      local subject = table.concat(f, '\31', 6)
      for _, verb in ipairs(VERB[change] or {}) do
        if subject:sub(1, #verb) == verb then
          subject = subject:sub(#verb + 1)
          break
        end
      end
      local at = tonumber(f[4])
      local date = at and at <= now and now - at < 3600 and f[5] or f[3] or ''
      rows[#rows + 1] = {
        kind = 'commit',
        number = #rows + 1,
        hash = f[1],
        key = f[1],
        subject = visible(subject),
        change = change,
        right = byline(visible(f[2] or ''), date),
      }
    end
    cb(rows)
  end)
end

-- The rows of a list of files with a change (gl.diff's files: gdc's, gdd's, gda's), in git's
-- order, a path once: { kind = 'file', path, change, right = the author git will commit the
-- change under (user.name) and when the file was last saved (a deleted one: the author alone) }
function M.changes(root, files, author)
  local now, rows, seen = os.time(), {}, {}
  for _, f in ipairs(files) do
    local path = f.new or f.old
    if not seen[path] then
      seen[path] = true
      local stat = f.new and vim.uv.fs_stat(root .. '/' .. f.new)
      rows[#rows + 1] = {
        kind = 'file',
        number = #rows + 1,
        path = path,
        key = path,
        change = f.status == 'A' and '+' or f.status == 'D' and '-' or '~',
        right = byline(author, stat and when(now, stat.mtime.sec) or ''),
      }
    end
  end
  return rows
end

-- The rows of a commit's files as a tree, as the shell's gl draws it (git-hunk-pick tree): depth
-- first, each directory's directories (by name) before its files (in git's order), the top
-- level's with no lines of their own; a directory whose only entry is a directory shares its row
-- (git/hunk-pick/). { kind = 'file' or 'dir', path (a directory's ending in /), lines, name,
-- rev = the commit }
function M.tree(files, rev)
  local top = { dirs = {}, files = {} }
  for _, f in ipairs(files) do
    local path = f.new or f.old
    local node, parts = top, vim.split(path, '/', { plain = true })
    for i = 1, #parts - 1 do
      node.dirs[parts[i]] = node.dirs[parts[i]] or { dirs = {}, files = {} }
      node = node.dirs[parts[i]]
    end
    node.files[#node.files + 1] = path
  end
  local rows = {}
  local function walk(node, dir, lines, first)
    local names = vim.tbl_keys(node.dirs)
    table.sort(names)
    local last = #names + #node.files
    for i = 1, last do
      local branch, below = '├╴', '│ '
      if i == last then
        branch, below = '└╴', '  '
      end
      if first then
        branch, below = '', ''
      end
      if i > #names then
        local path = node.files[i - #names]
        rows[#rows + 1] = {
          kind = 'file',
          path = path,
          lines = lines .. branch,
          name = path:sub(#dir + 1),
          rev = rev,
          key = rev .. '\0' .. path,
        }
      else
        local name, sub = names[i] .. '/', node.dirs[names[i]]
        while #sub.files == 0 and vim.tbl_count(sub.dirs) == 1 do
          local only, d = next(sub.dirs)
          name, sub = name .. only .. '/', d
        end
        rows[#rows + 1] = { kind = 'dir', path = dir .. name, lines = lines .. branch, name = name, rev = rev }
        walk(sub, dir .. name, lines .. below, false)
      end
    end
  end
  walk(top, '', '', true)
  return rows
end

-- The rows over the trees of the commits given, in their order: cb(rows), each { kind = 'head',
-- hash, subject, key } (a commit git doesn't know: its hash alone)
function M.heads(dir, hashes, cb)
  local cmd = { 'git', 'log', '--no-walk=unsorted', '--format=%h%x1f%s' }
  vim.list_extend(cmd, hashes)
  vim.system(cmd, { cwd = dir, text = true }, function(r)
    local subjects = vim.split(r.code == 0 and r.stdout or '', '\n', { trimempty = true })
    local rows = {}
    for i, hash in ipairs(hashes) do
      local subject = (subjects[i] or ''):match('^[^\31]*\31(.*)$') or ''
      rows[i] = { kind = 'head', hash = hash, subject = visible(subject), key = 'head\0' .. hash }
    end
    cb(rows)
  end)
end

-- A string's width in cells, and the string cut to n cells: at its end (keep = 'start') or at its
-- start (keep = 'end'), … where it's cut
local function width(s)
  return s:find('[\128-\255]') and vim.fn.strdisplaywidth(s) or #s
end

local function cut(s, n, keep)
  if width(s) <= n then
    return s
  elseif n < 1 then
    return ''
  end
  local chars = vim.fn.strchars(s)
  local out = keep == 'start' and vim.fn.strcharpart(s, 0, n - 1) or vim.fn.strcharpart(s, chars - n + 1)
  while width(out) > n - 1 do
    out = keep == 'start' and vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1) or vim.fn.strcharpart(out, 1)
  end
  return keep == 'start' and out .. '…' or '…' .. out
end

-- By buffer: the highlights of each of its lines as drawn, { start, end, group } (see draw)
local drawn = {}

-- Drawn at each redraw, for the lines it shows only
vim.api.nvim_set_decoration_provider(ns, {
  on_win = function(_, _, buf)
    return drawn[buf] ~= nil
  end,
  on_line = function(_, _, buf, row)
    for _, h in ipairs(drawn[buf] and drawn[buf][row + 1] or {}) do
      vim.api.nvim_buf_set_extmark(
        buf,
        ns,
        row,
        h[1],
        { end_col = h[2], hl_group = h[3], ephemeral = true, strict = false }
      )
    end
  end,
})

-- Draws the rows in the buffer, as wide as the window (cols): each after a column for its mark
-- (marked: by key, a commit or a commit's file marked with <Tab>), its author and date flush
-- right, one cell short of the edge, its subject cut short at its end, a path at its start (its
-- file's name kept), and with no room left for them, the author and date left out
function M.draw(buf, rows, cols, marked)
  local count = 0
  for _, r in ipairs(rows) do
    count = math.max(count, r.number or 0)
  end
  local digits = #tostring(count)
  local lines, hls = {}, {}
  for i, r in ipairs(rows) do
    local mark = marked and r.key and marked[r.key] and '▌' or ' '
    local text, hl = mark, {}
    if mark ~= ' ' then
      hl[#hl + 1] = { 0, #mark, 'GlListMark' }
    end
    if r.kind == 'commit' or r.number then
      text = text .. ('%' .. digits .. 'd '):format(r.number)
      if r.change then
        hl[#hl + 1] = { #text, #text + 1, CHANGE[r.change] }
      end
      text = text .. (r.change or ' ') .. ' '
      local right = r.right or ''
      local room = cols - 1 - width(text) - (right ~= '' and width(right) + 1 or 0)
      if room < 12 and right ~= '' then
        right, room = '', cols - 1 - width(text)
      end
      local main = r.kind == 'commit' and cut(r.hash .. ' ' .. r.subject, room, 'start')
        or cut(visible(r.path), room, 'end')
      text = text .. main
      if right ~= '' then
        text = text .. (' '):rep(math.max(1, cols - 1 - width(text) - width(right))) .. right
      end
    elseif r.kind == 'head' then -- (over a commit's tree, of several)
      hl[#hl + 1] = { #text, #text + #'●', 'GlListHead' }
      text = text .. '● ' .. cut(r.hash .. ' ' .. r.subject, cols - 1 - width(text) - 2, 'start')
    else -- (a commit's files: the tree)
      if r.lines ~= '' then
        hl[#hl + 1] = { #text, #text + #r.lines, 'GlListTree' }
      end
      text = text .. r.lines
      local name = visible(r.name)
      if r.kind == 'dir' then
        hl[#hl + 1] = { #text, #text + #name, 'GlListDirectory' }
      end
      text = text .. name
    end
    lines[i], hls[i] = text, hl
  end
  if #lines == 0 then
    lines[1] = ''
  end
  if not drawn[buf] then
    vim.api.nvim_create_autocmd('BufWipeout', {
      group = group,
      buffer = buf,
      callback = function()
        drawn[buf] = nil
      end,
    })
  end
  drawn[buf] = hls
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

return M
