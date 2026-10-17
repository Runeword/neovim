local vim = vim

-- The tree's files on disk: the entries of each directory the tree shows open, read once
-- and kept (M.entries) while it's watched (M.watch): a change there has it read again once
-- changes settle, then the tree drawn again (M.on_change).
local M = {}

local HIDDEN = { ['.git'] = true } -- entries left out, as VS Code's files.exclude does
local SETTLE_MS = 100 -- the directories changed are read again this long after the first change

local listings = {} -- [directory] = its entries (see read), false if it can't be read
local watchers = {} -- [directory] = its fs_event handle
local changed = {} -- [directory] = true, changed on disk since it was read
local timer -- (while changes settle)
local on_change = function() end

-- `name` in directory `dir`
function M.join(dir, name)
  return (dir == '/' and '' or dir) .. '/' .. name
end

-- `path` relative to directory `dir`, if it's inside it
function M.relative(dir, path)
  local prefix = M.join(dir, '')
  if #path > #prefix and path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
end

-- Relative `path` goes through an entry the tree leaves out
function M.hidden(path)
  for part in path:gmatch('[^/]+') do
    if HIDDEN[part] then
      return true
    end
  end
  return false
end

local function digit(byte)
  return byte and byte >= 48 and byte <= 57
end

-- Entries in natural order of their names, case aside (file2 before file10), as file
-- managers sort them. (Byte by byte on the names lowercased once, see read: thousands of
-- entries are sorted at once.)
local function before(a, b)
  local x, y = a.key, b.key
  local i, j = 1, 1
  while i <= #x and j <= #y do
    local c, d = x:byte(i), y:byte(j)
    if digit(c) and digit(d) then
      local m, n = i, j -- (the numbers' first digits, past their leading zeros)
      while digit(x:byte(i)) do
        i = i + 1
      end
      while digit(y:byte(j)) do
        j = j + 1
      end
      while m < i - 1 and x:byte(m) == 48 do
        m = m + 1
      end
      while n < j - 1 and y:byte(n) == 48 do
        n = n + 1
      end
      if i - m ~= j - n then
        return i - m < j - n
      end
      local u, v = x:sub(m, i - 1), y:sub(n, j - 1)
      if u ~= v then
        return u < v
      end
    elseif c ~= d then
      return c < d
    else
      i, j = i + 1, j + 1
    end
  end
  if #x - i ~= #y - j then
    return #x - i < #y - j
  end
  return a.name < b.name
end

-- The entries of directory `dir`, as { name, path, dir (a directory, or a link to one), key
-- (the name lowercased, to sort by) }, directories first; false if it can't be read
local function read(dir)
  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return false
  end
  local entries = {}
  while true do
    local name, type = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if not HIDDEN[name] then
      local path = M.join(dir, name)
      if type ~= 'file' and type ~= 'directory' then
        local stat = vim.uv.fs_stat(path) -- (a link: what it points to)
        type = stat and stat.type
      end
      entries[#entries + 1] = { name = name, path = path, dir = type == 'directory', key = name:lower() }
    end
  end
  table.sort(entries, function(a, b)
    if a.dir ~= b.dir then
      return a.dir
    end
    return before(a, b)
  end)
  return entries
end

-- The entries of directory `dir` (see read), none if it can't be read
function M.entries(dir)
  if listings[dir] == nil then
    listings[dir] = read(dir)
  end
  return listings[dir] or {}
end

local function same(a, b)
  if not (a and b) or #a ~= #b then
    return a == b
  end
  for i = 1, #a do
    if a[i].name ~= b[i].name or a[i].dir ~= b[i].dir then
      return false
    end
  end
  return true
end

-- Forget what was read of directory `dir` and of the directories in it
local function forget(dir)
  local prefix = M.join(dir, '')
  for d in pairs(listings) do
    if d == dir or d:sub(1, #prefix) == prefix then
      listings[d] = nil
    end
  end
end

local function unwatch(dir)
  local handle = watchers[dir]
  watchers[dir] = nil
  if handle and not handle:is_closing() then
    handle:stop()
    handle:close()
  end
end

local settle -- (see below)

-- (in a fast event: vim.defer_fn only starts a timer)
local function change(dir)
  changed[dir] = true
  if not timer then
    timer = vim.defer_fn(settle, SETTLE_MS)
  end
end

local function watch(dir)
  local handle = vim.uv.new_fs_event()
  if handle then
    if handle:start(dir, {}, function()
      change(dir)
    end) then
      watchers[dir] = handle
    else
      handle:close() -- (watched no more than the tree reads on: FocusGained, R)
    end
  end
end

-- The changes settled: read the directories changed again, and if what they hold changed,
-- draw the tree again. Each is watched anew before it's read: one deleted and made again
-- (rm -rf build && mkdir build) is another directory, whose changes its old watcher misses.
settle = function()
  timer = nil
  local dirs = changed
  changed = {}
  local any = false
  for dir in pairs(dirs) do
    if watchers[dir] then
      unwatch(dir)
      if vim.uv.fs_stat(dir) then
        watch(dir)
      end
    end
    if listings[dir] ~= nil then
      local entries = read(dir)
      if not same(listings[dir], entries) then
        forget(dir) -- (its directories too: one deleted may come back holding other files)
        listings[dir] = entries
        any = true
      end
    end
  end
  if any then
    on_change()
  end
end

-- Watch the directories of the set `dirs` ([directory] = true), and those only. What was
-- read of the others is forgotten, their changes going unseen: they're read again when the
-- tree shows them. (None: stop watching, forget all, for the tree to read anew.)
function M.watch(dirs)
  for dir in pairs(watchers) do
    if not dirs[dir] then
      unwatch(dir)
    end
  end
  for dir in pairs(listings) do
    if not dirs[dir] then
      listings[dir] = nil
    end
  end
  for dir in pairs(dirs) do
    if not watchers[dir] then
      watch(dir)
    end
  end
end

-- Call `fn` when what a directory watched holds changed
function M.on_change(fn)
  on_change = fn
end

return M
