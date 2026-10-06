local vim = vim

-- The code the references panel shows for each line holding references: that line,
-- with REF_CONTEXT lines around it, highlighted as in its file. A file that isn't loaded
-- is read from disk, once per version of it, and parsed whole, once too; a big one (as
-- the config's b:big_file says of a loaded one) isn't parsed, and shows unhighlighted.
local M = {}

local REF_CONTEXT = 1 -- lines of code shown above and below each reference
local LINE_CAP = 500 -- bytes of a line shown (the list doesn't wrap): a minified line costs no more
local BIG_BYTES = 1024 * 1024 -- a file this big isn't parsed (the config's b:big_file threshold),
local BIG_LINE = 2048 -- nor one whose lines are this long on average (minified)
local MAX_READ = 16 * 1024 * 1024 -- nor read past this size
local KEPT_BYTES = 32 * 1024 * 1024 -- text of files kept from one show to the next
local KEPT_PARSERS = 16 -- and whose syntax tree
local WINDOW = 60 -- lines parsed around a reference in a big file, to tell its kind
local WHOLE_LINES = 1500 -- a file read from disk up to this long is parsed whole to highlight it,
local CONTEXT_MARGIN = 20 -- a longer one by block, with this many lines around it

local uses = 0 -- a clock for the caches' least recently used

-- Keep `cache` ([key] = { used, bytes, ... }) to `max` entries, or to `max_bytes` of them:
-- drop the least recently used
local function trim(cache, max, max_bytes)
  while true do
    local count, bytes, oldest = 0, 0, nil
    for key, e in pairs(cache) do
      count, bytes = count + 1, bytes + (e.bytes or 0)
      if not oldest or e.used < cache[oldest].used then
        oldest = key
      end
    end
    if count <= 1 or (count <= max and bytes <= (max_bytes or math.huge)) then
      return
    end
    cache[oldest] = nil
  end
end

-- The version of `filename` on disk (modification time and size), and its size
local function disk_version(filename)
  local stat = vim.uv.fs_stat(filename)
  if not stat then
    return '-', 0
  end
  return ('f%d.%d.%d'):format(stat.mtime.sec, stat.mtime.nsec, stat.size), stat.size
end

-- [filename] = { version, text, bytes, used, ft, starts (see index), all (see M.all) }:
-- a file's text is kept whole, and only the lines asked for are cut out of it (the list
-- needs a few lines of each of hundreds of files)
local files = {}

-- `filename` as read from disk ({ version, text, bytes }, see M.line), kept while
-- unchanged there
local function read(filename)
  local version, size = disk_version(filename)
  uses = uses + 1
  local f = files[filename]
  if f and f.version == version then
    f.used = uses
    return f
  end
  local text = ''
  local fd = size <= MAX_READ and io.open(filename, 'rb')
  if fd then
    text = fd:read('*a') or ''
    fd:close()
    if text:sub(1, 3) == '\239\187\191' then
      text = text:sub(4) -- (a UTF-8 byte order mark, which a buffer doesn't show either)
    end
  end
  f = { version = version, text = text, bytes = size, used = uses }
  files[filename] = f
  if size > 0 then
    trim(files, math.huge, KEPT_BYTES)
  end
  return f
end

-- Where each line of `f` (see read) starts in its text
local function index(f)
  if not f.starts then
    local starts, text, pos = { 1 }, f.text, 1
    while true do
      local nl = text:find('\n', pos, true)
      if not nl then
        break
      end
      pos = nl + 1
      starts[#starts + 1] = pos
    end
    if starts[#starts] > #text then
      starts[#starts] = nil -- (a newline ends the last line)
    end
    f.starts = starts
  end
  return f.starts
end

-- How many lines `f` has (see read)
function M.count(f)
  return #index(f)
end

-- Line `n` (1-based) of `f` (see read), without its line break (\r\n too); nil past the end
function M.line(f, n)
  local starts, text = index(f), f.text
  local from = starts[n]
  if not from then
    return nil
  end
  local to = starts[n + 1] and starts[n + 1] - 2 or (text:byte(-1) == 10 and #text - 1 or #text)
  local line = text:sub(from, to)
  return line:byte(-1) == 13 and line:sub(1, -2) or line
end

-- Lines `first`..`last` of `f` (see read)
function M.slice(f, first, last)
  local lines = {}
  for n = math.max(first, 1), math.min(last, M.count(f)) do
    lines[#lines + 1] = M.line(f, n)
  end
  return lines
end

-- Every line of `f` (see read), cut once (the table is shared: not to be changed)
function M.all(f)
  f.all = f.all or M.slice(f, 1, M.count(f))
  return f.all
end

-- The lines of `filename`: its buffer's when loaded, else read from disk (the table is
-- shared: not to be changed)
function M.lines(filename, buf)
  if buf and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  return M.all(read(filename))
end

-- The version of `filename`'s text: its buffer's changedtick while that has changes not
-- written, else the file's on disk
function M.version(filename, buf)
  if buf and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
    return 'b' .. vim.api.nvim_buf_get_changedtick(buf)
  end
  return (disk_version(filename))
end

-- `filename` as read from disk: { version, text, bytes } (see M.line)
M.file = read

-- Whether `filename` is too big to parse: the config's b:big_file says so of a loaded
-- buffer, else its size or the average length of its lines (read from disk as `f`, if
-- given)
function M.big(filename, buf, f)
  local bytes, count
  if buf and vim.api.nvim_buf_is_loaded(buf) then
    if vim.b[buf].big_file then
      return true
    end
    count = vim.api.nvim_buf_line_count(buf)
    bytes = vim.api.nvim_buf_get_offset(buf, count)
  else
    f = f or read(filename)
    if f.bytes > BIG_BYTES then
      return true
    end
    bytes, count = f.bytes, M.count(f)
  end
  return bytes > BIG_BYTES or (count > 0 and bytes / count > BIG_LINE)
end

-- The treesitter language of `filename`, read from disk as `f` (see read): from its name,
-- else its first lines (a shebang)
local function lang_of(filename, f)
  if f.ft == nil then
    local ok, ft = pcall(vim.filetype.match, { filename = filename })
    if not (ok and ft) then
      ok, ft = pcall(vim.filetype.match, { filename = filename, contents = M.slice(f, 1, 20) })
    end
    f.ft = ok and ft or false
  end
  return f.ft and f.ft ~= '' and vim.treesitter.language.get_lang(f.ft) or nil
end

local parsers = {} -- [filename] = { version, parser, text, used }

-- A parser of `filename` read from disk, whole (injected languages included), and its
-- text; kept while the file is unchanged. Its parser is nil when it has no language.
local function file_parser(filename)
  local f = read(filename)
  uses = uses + 1
  local p = parsers[filename]
  if p and p.version == f.version then
    p.used = uses
    return p
  end
  local lang, text = lang_of(filename, f), f.text
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  p = { version = f.version, parser = lang and ok and parser or nil, text = text, used = uses }
  parsers[filename] = p
  trim(parsers, KEPT_PARSERS)
  return p
end

-- `line` cut to LINE_CAP bytes, at a character's start
local function cap(line)
  if #line <= LINE_CAP then
    return line
  end
  local cut = LINE_CAP
  while cut > 0 and (line:byte(cut + 1) or 0) >= 0x80 and line:byte(cut + 1) < 0xC0 do
    cut = cut - 1
  end
  return line:sub(1, cut)
end

-- `line` with its tabs expanded to the next tab stop (every `ts` columns, as a window
-- shows them), and the bytes each adds ({ its byte (1-based), bytes added } in order),
-- nil without tabs
local function expand(line, ts)
  if not line:find('\t', 1, true) then
    return line, nil
  end
  local parts, shifts, width, from = {}, {}, 0, 1
  while true do
    local tab = line:find('\t', from, true)
    local text = line:sub(from, (tab or #line + 1) - 1)
    parts[#parts + 1] = text
    width = width + vim.api.nvim_strwidth(text)
    if not tab then
      break
    end
    local n = ts - width % ts
    parts[#parts + 1] = (' '):rep(n)
    width = width + n
    shifts[#shifts + 1] = { tab, n - 1 }
    from = tab + 1
  end
  return table.concat(parts), shifts
end

-- Where byte `col` (0-indexed) of row `r` of block `b` (see M.prepare) falls in the code
-- the list shows for it: tabs expanded, dedented with the block
local function shown_col(b, r, col)
  local view, shifted = b.view[r - b.first + 1], col
  for _, s in ipairs(view.shifts or {}) do
    if s[1] > col then -- (the tabs before byte `col` of the line, not of its expansion)
      break
    end
    shifted = shifted + s[2]
  end
  return math.max(math.min(shifted, #view.text) - b.dedent, 0)
end

-- The definition keywords before a name (`function M.foo(`, `def foo(`, `func (r T) foo(`,
-- ...): that name followed by `(` isn't a call. Each must reach the name.
local DEF_BEFORE = {
  '^%s*local%s+function%s+$',
  '^%s*function%f[^%w_]%s*%*?%s*[%w_%.:]*$', -- (not `functions.foo(`)
  '^%s*async%s+function%s*%*?%s*$',
  '^%s*export%s+function%s+$',
  '^%s*export%s+async%s+function%s+$',
  '^%s*export%s+default%s+function%s+$',
  '^%s*def%s+$',
  '^%s*async%s+def%s+$',
  '^%s*func%s+$',
  '^%s*func%s*%b()%s*$',
  '^%s*fn%s+$',
  '^%s*pub%s+fn%s+$',
  '^%s*pub%b()%s+fn%s+$',
  '^%s*async%s+fn%s+$',
  '^%s*pub%s+async%s+fn%s+$',
}
-- What follows a called name: `(`, maybe after Rust's type arguments (`foo::<T>(`), or
-- `?.(`; in a language with type arguments also those (`foo<T>(`, right after the name:
-- `foo < a or b > (c)` is no call); in Lua a table or a string (`foo{...}`, `foo 'x'`)
local CALL_AFTER = { '^%s*%(', '^::%b<>%(', '^%?%.%(' }
local GENERIC_CALL_AFTER = { '^%b<>%(' }
local LUA_CALL_AFTER = { '^%s*{', '^%s*["\']', '^%s*%[=*%[' }
local GENERIC_LANGS = {
  typescript = true,
  tsx = true,
  c_sharp = true,
  cpp = true,
  java = true,
  kotlin = true,
  dart = true,
  swift = true,
}

-- Whether reference `ref`, on a line of block `b` (see M.prepare), is a call. Servers
-- answer bare locations with no such tag, so we read the source line and derive it
-- ourselves. (C-family definitions have no keyword and still read as calls.)
local function is_call(b, ref)
  local line = b.lines[ref.end_pos[1] - b.first + 1] or ''
  local after = line:sub(ref.end_pos[2] + 1) -- (end_pos[2] is a 0-indexed byte: the first past the symbol)
  local called = false
  local lang = b.file.lang
  local patterns = { CALL_AFTER, GENERIC_LANGS[lang] and GENERIC_CALL_AFTER, lang == 'lua' and LUA_CALL_AFTER }
  for i = 1, 3 do
    for _, pattern in ipairs(patterns[i] or {}) do
      called = called or after:find(pattern) ~= nil
    end
  end
  if not called then
    return false
  end
  local before = (b.lines[ref.pos[1] - b.first + 1] or ''):sub(1, ref.pos[2])
  for _, pattern in ipairs(DEF_BEFORE) do
    if before:find(pattern) then
      return false
    end
  end
  return true
end

-- Whether a node of `type` reaches an element of a container (`d[k]`, `arr[$i]`): what it
-- holds is assigned, neither the container nor the index
local function index_like(type)
  return type:find('subscript') or (type:find('index') and not type:find('dot_index')) or type == 'element_reference'
end

-- Whether a node of `type` reaches a member of an object (`M.x`, `self.x`, `a.b`): only
-- its last part, the member, is assigned
local function member_like(type)
  for _, part in ipairs({ 'member', 'attribute', 'selector', 'dot_index', 'field_expression', 'field_access' }) do
    if type:find(part) then
      return true
    end
  end
  return type == 'call' -- (Ruby's `a.b = 1`)
end

-- Whether reference `ref` ({ filename, buf, pos }, see M.prepare) is what an assignment
-- assigns, its left side: 'declaration' when the assignment declares it (Lua's
-- `local x = 1`, bash's `local x=1`), else 'affectation' (`x = 1`, `M.x = 1`, `x += 1`,
-- bash's `x=1`); nil when it isn't (another form of declaration, as `function M.x()`,
-- JavaScript's `let x = 1`, Go's `x := 1` or a parameter, or a use, `M` in `M.x = 1` and
-- `k` in `d[k] = 1` included). Read from the syntax tree, through the nearest assignment
-- around it (a destructuring pattern isn't one); for a big file, from a parse of the
-- lines around it.
function M.assignment(ref)
  local row, col = ref.pos[1] - 1, ref.pos[2]
  local parser, from = nil, 0
  if ref.buf and vim.api.nvim_buf_is_loaded(ref.buf) then
    if M.big(ref.filename, ref.buf) then
      return nil
    end
    local ok, p = pcall(vim.treesitter.get_parser, ref.buf)
    parser = ok and p or nil
  elseif M.big(ref.filename) then
    local f = read(ref.filename)
    local lang = lang_of(ref.filename, f)
    from = math.max(row - WINDOW, 0)
    local text = table.concat(M.slice(f, from + 1, row + WINDOW + 1), '\n')
    local ok, p = pcall(vim.treesitter.get_string_parser, text, lang)
    parser = lang and ok and p or nil
  else
    parser = file_parser(ref.filename).parser
  end
  if not parser then
    return nil
  end
  row = row - from
  parser:parse({ row, row + 1 })
  local node = parser:named_node_for_range({ row, col, row, col + 1 }, { ignore_injections = false })
  local parent = node and node:parent()
  while parent do
    local type = parent:type()
    if type:find('assignment') and not type:find('pattern') then
      local left = parent:named_child(0)
      if not (left and left:equal(node)) then
        return nil -- (on its right side)
      end
      local wrapper = parent:parent()
      return wrapper and wrapper:type():find('declaration') and 'declaration' or 'affectation'
    elseif index_like(type) then
      return nil
    elseif member_like(type) then
      local last = parent:named_child(parent:named_child_count() - 1)
      if not (last and last:equal(node)) then
        return nil -- (the object, not its member)
      end
    end
    node, parent = parent, parent:parent()
  end
end

-- What follows a name that an assignment doesn't assign, being the object, the
-- container or the function of what follows it: `x.y`, `x->y`, `x?.y`, `x[k]`, `x(`
local UNASSIGNED_AFTER = { '^%s*[%.%[%(]', '^%s*%->', '^%s*%?%.' }

-- Whether reference `ref`, on a line of block `b` (see M.prepare), is what an assignment
-- assigns (see M.assignment), never in a big file (which isn't parsed). Its line rules
-- most references out before the syntax tree is read, sparing a list across many files
-- their parses: one with no `=` after it there, or that UNASSIGNED_AFTER follows. (An
-- assignment whose `=` comes on a later line is missed.)
local function is_assigned(b, ref)
  if b.file.big then
    return false
  end
  local line = b.lines[ref.end_pos[1] - b.first + 1] or ''
  local after = line:sub(ref.end_pos[2] + 1)
  if not after:find('=', 1, true) then
    return false
  end
  for _, pattern in ipairs(UNASSIGNED_AFTER) do
    if after:find(pattern) then
      return false
    end
  end
  return M.assignment(ref) ~= nil
end

-- Prepare `refs`, references ({ filename, buf, pos, end_pos }, positions as { row,
-- col }: the row 1-based, the col a 0-indexed byte; `def` set on a definition), for the
-- list: grouped by file, an item ({ filename, buf, pos, refs }) per line of code holding
-- some, the references on it in its `refs`, left to right, `pos` the first's.
--
-- Each item gets a `ref_kind`: `Definition` when one of its references is a definition,
-- else `Assignment` when one is what an assignment assigns (see is_assigned), else
-- `Call` when one is a call (see is_call), else `Reference`: it marks the definitions,
-- the assignments and the calls in the list.
--
-- Each item also gets the code the list shows for it: its line (`code`, each of its
-- references at bytes `match` of it, the end excluded) and the REF_CONTEXT lines around
-- it (`above`, `below`: row ranges). Items close by share a `block` of consecutive
-- lines, so no line shows twice, dedented as a whole so the indentation inside it stays
-- true, tabs expanded to the file's tab stops; `gap` marks a block that follows another
-- in the same file. Lines are cut to LINE_CAP bytes. `read_files` ([filename] = as
-- M.file gives it) holds files already read for this (a list of more files than the
-- cache keeps would read them all again). Returns the files ({ filename, buf, refs, its
-- items in order }) and the widest line number shown, to right-align the numbers.
function M.prepare(refs, read_files)
  local files_list, by_name, lnum_width = {}, {}, 1
  for _, ref in ipairs(refs) do
    local f = by_name[ref.filename]
    if not f then
      f = { filename = ref.filename, buf = ref.buf, refs = {} }
      by_name[ref.filename] = f
      files_list[#files_list + 1] = f
    end
    f.refs[#f.refs + 1] = ref
  end

  for _, f in ipairs(files_list) do
    -- The file's lines: its buffer's when loaded, else from disk (whole, to know where
    -- it ends), so cross-file refs work too
    local loaded = f.buf and vim.api.nvim_buf_is_loaded(f.buf)
    local disk = not loaded and (read_files and read_files[f.filename] or read(f.filename)) or nil
    local count = loaded and vim.api.nvim_buf_line_count(f.buf) or M.count(disk)
    local ts = loaded and vim.bo[f.buf].tabstop or vim.o.tabstop
    local lang
    if loaded then
      local ft = vim.bo[f.buf].filetype
      lang = ft ~= '' and vim.treesitter.language.get_lang(ft) or nil
    else
      lang = lang_of(f.filename, disk)
    end
    -- Where M.highlight finds the code to parse, for the file's blocks
    local file = { filename = f.filename, lang = lang, big = M.big(f.filename, f.buf, disk) }
    if loaded then
      file.buf, file.tick = f.buf, vim.api.nvim_buf_get_changedtick(f.buf)
    end

    table.sort(f.refs, function(a, b)
      return a.pos[1] < b.pos[1] or (a.pos[1] == b.pos[1] and a.pos[2] < b.pos[2])
    end)
    for _, ref in ipairs(f.refs) do
      local item = f[#f]
      if item and item.pos[1] == ref.pos[1] then
        item.refs[#item.refs + 1] = ref
      else
        f[#f + 1] = { filename = ref.filename, buf = ref.buf, pos = ref.pos, refs = { ref } }
      end
    end

    local blocks, block, shown = {}, nil, 0 -- shown: the last line shown so far
    for i, item in ipairs(f) do
      local row = item.pos[1]
      local next_row = f[i + 1] and f[i + 1].pos[1] or math.huge
      local first = math.max(row - REF_CONTEXT, shown + 1, 1)
      local last = math.min(row + REF_CONTEXT, next_row - 1, count)
      local gap = block ~= nil and math.min(first, row) > shown + 1 -- lines left out since the last
      if not block or gap then
        block = { first = math.min(first, row), file = file, highlights = {} }
        blocks[#blocks + 1] = block
      end
      item.gap = gap and REF_CONTEXT > 0
      item.block, item.above, item.below = block, { first, row - 1 }, { row + 1, last }
      shown = math.max(shown, row, last)
      block.last = shown
    end
    lnum_width = math.max(lnum_width, #tostring(shown))

    for _, b in ipairs(blocks) do
      b.lines = loaded and vim.api.nvim_buf_get_lines(f.buf, b.first - 1, b.last, false)
        or M.slice(disk, b.first, b.last)
      b.view, b.dedent = {}, math.huge -- (dedent: the indentation its lines share, blank lines aside)
      for i, line in ipairs(b.lines) do
        b.lines[i] = cap(line)
        local text, shifts = expand(b.lines[i], ts)
        b.view[i] = { text = text, shifts = shifts }
        local indent = #text:match('^ *')
        if indent < #text and not text:match('^%s*$') then
          b.dedent = math.min(b.dedent, indent)
        end
      end
      b.dedent = b.dedent == math.huge and 0 or b.dedent
    end

    for _, item in ipairs(f) do
      local b, r = item.block, item.pos[1]
      item.code = b.view[r - b.first + 1].text:sub(b.dedent + 1)
      item.ref_kind = 'Reference'
      for _, ref in ipairs(item.refs) do
        local to = ref.end_pos[1] == ref.pos[1] and shown_col(b, r, ref.end_pos[2]) or #item.code
        ref.match = { shown_col(b, r, ref.pos[2]), to }
        local kind = item.ref_kind
        if ref.def then
          item.ref_kind = 'Definition'
        elseif (kind == 'Reference' or kind == 'Call') and is_assigned(b, ref) then
          item.ref_kind = 'Assignment'
        elseif kind == 'Reference' and is_call(b, ref) then
          item.ref_kind = 'Call'
        end
      end
    end
  end
  return files_list, lnum_width
end

-- Highlight chunks { text, hl } for each of `lines`, rows first.. (0-indexed) of
-- `source` (a buffer or a string), as `parser`, its language tree, highlights them
local function highlight_rows(parser, source, first, lines)
  local last, captures = first + #lines, {}
  parser:parse({ first, last })
  parser:for_each_tree(function(tree, ltree)
    local query = vim.treesitter.query.get(ltree:lang(), 'highlights')
    local top, _, bottom = tree:root():range()
    if not (query and top < last and bottom >= first) then
      return
    end
    for id, node, metadata in query:iter_captures(tree:root(), source, first, last) do
      local name = query.captures[id]
      if not (name:match('^_') or name == 'spell' or name == 'nospell' or name == 'conceal') then
        local sr, sc, er, ec = node:range()
        local priority = metadata.priority or metadata[id] and metadata[id].priority
        captures[#captures + 1] = {
          hl = '@' .. name .. '.' .. ltree:lang(),
          priority = tonumber(priority) or 100,
          order = #captures,
          sr - first,
          sc,
          er - first,
          ec,
        }
      end
    end
  end)
  -- Each byte takes the last of the highest-priority captures covering it, as when
  -- treesitter highlights a buffer (an injected language's last)
  table.sort(captures, function(a, b)
    return a.priority < b.priority or (a.priority == b.priority and a.order < b.order)
  end)
  local hls = {} -- [line][byte] = highlight group
  for i = 1, #lines do
    hls[i] = {}
  end
  for _, c in ipairs(captures) do
    for r = math.max(c[1], 0), math.min(c[3], #lines - 1) do
      for byte = (r == c[1] and c[2] or 0) + 1, math.min(r == c[3] and c[4] or #lines[r + 1], #lines[r + 1]) do
        hls[r + 1][byte] = c.hl
      end
    end
  end
  local result = {}
  for i, line in ipairs(lines) do
    local chunks, from = {}, 1
    for byte = 1, #line do
      if byte == #line or hls[i][byte + 1] ~= hls[i][from] then
        chunks[#chunks + 1] = { line:sub(from, byte), hls[i][from] }
        from = byte + 1
      end
    end
    result[i] = chunks
  end
  return result
end

-- Highlight rows first..last of block `b` (see M.prepare) as in its file, into
-- b.highlights[row]: from the syntax tree of its buffer while that is unchanged (read
-- from a copy of its text, as the query's predicates go faster on a string), else from
-- a parse of the file read from disk: whole up to WHOLE_LINES lines, so a block inside an
-- injected language (a .vue file's <script>, a fence) is read as that language; else of
-- the block with a margin of code around it (a block cut out alone could leave a
-- construct open, its keywords unparsed). A big file isn't parsed.
function M.highlight(b, first, last)
  while first <= last and b.highlights[first] do
    first = first + 1
  end
  while last >= first and b.highlights[last] do
    last = last - 1
  end
  if first > last then
    return
  end
  local f, lines, chunks = b.file, vim.list_slice(b.lines, first - b.first + 1, last - b.first + 1), nil
  if f.big then -- (left plain)
  elseif f.buf and vim.api.nvim_buf_is_loaded(f.buf) and vim.api.nvim_buf_get_changedtick(f.buf) == f.tick then
    local ok, parser = pcall(vim.treesitter.get_parser, f.buf)
    if ok and parser then
      f.text = f.text or table.concat(vim.api.nvim_buf_get_lines(f.buf, 0, -1, false), '\n')
      chunks = highlight_rows(parser, f.text, first - 1, lines)
    end
  -- (else as on disk: a buffer changed since, back to its file's text, as by an undo; a
  -- different text is another answer, drawn anew)
  elseif M.count(read(f.filename)) <= WHOLE_LINES then
    local p = file_parser(f.filename)
    if p.parser then
      chunks = highlight_rows(p.parser, p.text, first - 1, lines)
    end
  else
    if not b.snippet then
      local from = math.max(b.first - CONTEXT_MARGIN, 1)
      local text = table.concat(M.slice(read(f.filename), from, b.last + CONTEXT_MARGIN), '\n')
      local ok, parser = pcall(vim.treesitter.get_string_parser, text, f.lang)
      b.snippet = { parser = f.lang and ok and parser or nil, text = text, from = from }
    end
    if b.snippet.parser then
      chunks = highlight_rows(b.snippet.parser, b.snippet.text, first - b.snippet.from, lines)
    end
  end
  for row = first, last do
    b.highlights[row] = chunks and chunks[row - first + 1] or { { lines[row - first + 1] or '' } }
  end
end

-- The code of row `r` of block `b` as the list shows it: tabs expanded, dedented with its
-- block
function M.text(b, r)
  return b.view[r - b.first + 1].text:sub(b.dedent + 1)
end

-- The code of row `r` of block `b` as chunks { text, hl }, as the list shows it: tabs
-- expanded, dedented with its block, highlighted once M.highlight went through
function M.chunks(b, r)
  local text, chunks, pos = b.view[r - b.first + 1].text, {}, 0
  for _, c in ipairs(b.highlights[r] or { { b.lines[r - b.first + 1] or '' } }) do
    local from, to = shown_col(b, r, pos), shown_col(b, r, pos + #c[1])
    pos = pos + #c[1]
    if to > from then
      chunks[#chunks + 1] = { text:sub(b.dedent + from + 1, b.dedent + to), c[2] }
    end
  end
  return chunks
end

return M
