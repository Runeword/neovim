local vim = vim

-- The code the references panel shows for each line holding references: that line,
-- with REF_CONTEXT lines around it, highlighted as in its file.
local M = {}

local REF_CONTEXT = 1 -- lines of code shown above and below each reference
local CONTEXT_MARGIN = 20 -- lines parsed around a block of a file that isn't loaded

-- The lines of `filename`: its buffer's when loaded, else read from disk
function M.lines(filename, buf)
  if buf and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  local ok, lines = pcall(vim.fn.readfile, filename)
  return ok and lines or {}
end

-- Where byte `col` of `line`, a line of block `b` (see M.prepare), falls in the code the
-- list shows for it: dedented with the block, tabs expanded
local function shown_col(b, line, col)
  return #(line:sub(b.dedent + 1, col):gsub('\t', b.tab))
end

-- Whether reference `ref`, on a line of block `b` (see M.prepare), is a call: the symbol
-- is immediately followed by `(`. Servers answer bare locations with no such tag, so we
-- read the source line and derive it ourselves.
local function is_call(b, ref)
  local line = b.lines[ref.end_pos[1] - b.first + 1] or ''
  -- `end_pos[2]` is a 0-indexed byte column, so sub(col + 1) starts at the
  -- first character past the symbol.
  local after = line:sub(ref.end_pos[2] + 1)
  -- A definition's name (`function foo(`, `def foo(`, …) is also followed by
  -- `(` — don't count it as a call. Anchored at the start of the line so a
  -- genuine call such as `function_tbl.foo(` is not mistaken for a def.
  -- (C-family definitions have no keyword and will still read as calls.)
  local before = line:sub(1, ref.pos[2])
  local is_def = before:match('^%s*function%s')
    or before:match('^%s*local%s+function%s')
    or before:match('^%s*async%s+function%s')
    or before:match('^%s*def%s')
    or before:match('^%s*async%s+def%s')
    or before:match('^%s*func%s')
    or before:match('^%s*fn%s')
  return after:match('^%s*%(') ~= nil and not is_def
end

-- Prepare `refs`, references ({ filename, buf, pos, end_pos }, positions as { row,
-- col }: the row 1-based, the col a 0-indexed byte), for the list: grouped by file, an
-- item ({ filename, buf, pos, refs }) per line of code holding some, the references on
-- it in its `refs`, left to right, `pos` the first's.
--
-- Each item gets a `ref_kind`, `Call` when one of its references is a call (see
-- is_call), else `Reference`: it marks the calls in the list.
--
-- Each item also gets the code the list shows for it: its line (`code`, each of its
-- references at bytes `match` of it, the end excluded) and the REF_CONTEXT lines around
-- it (`above`, `below`: row ranges). Items close by share
-- a `block` of consecutive lines, so no line shows twice, dedented as a whole so the
-- indentation inside it stays true; `gap` marks a block that follows another in the
-- same file. Returns the files ({ filename, buf, refs, its items in order }) and the
-- widest line number shown, to right-align the numbers.
function M.prepare(refs)
  local files, by_name, lnum_width = {}, {}, 1
  for _, ref in ipairs(refs) do
    local f = by_name[ref.filename]
    if not f then
      f = { filename = ref.filename, buf = ref.buf, refs = {} }
      by_name[ref.filename] = f
      files[#files + 1] = f
    end
    f.refs[#f.refs + 1] = ref
  end

  for _, f in ipairs(files) do
    -- The file's lines: its buffer's when loaded, else from disk (whole, to know where
    -- it ends), so cross-file refs work too
    local loaded = f.buf and vim.api.nvim_buf_is_loaded(f.buf)
    local all = not loaded and M.lines(f.filename) or nil
    local count = loaded and vim.api.nvim_buf_line_count(f.buf) or #all
    local tab = (' '):rep(loaded and vim.bo[f.buf].tabstop or vim.o.tabstop)
    local ok, ft = true, loaded and vim.bo[f.buf].filetype
    if not loaded then
      ok, ft = pcall(vim.filetype.match, { filename = f.filename, contents = all })
    end
    -- Where M.highlight finds the code to parse, for the file's blocks
    local file = { lang = ok and ft and ft ~= '' and vim.treesitter.language.get_lang(ft) or nil, lines = all }
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
        block = { first = math.min(first, row), file = file, tab = tab, highlights = {} }
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
        or vim.list_slice(all, b.first, b.last)
      b.dedent = math.huge -- the indentation its lines share, blank lines aside
      for _, line in ipairs(b.lines) do
        local indent = #line:match('^%s*')
        if indent < #line then
          b.dedent = math.min(b.dedent, indent)
        end
      end
      b.dedent = b.dedent == math.huge and 0 or b.dedent
    end

    for _, item in ipairs(f) do
      local b = item.block
      local text = b.lines[item.pos[1] - b.first + 1] or ''
      item.code = (text:sub(b.dedent + 1):gsub('\t', b.tab))
      item.ref_kind = 'Reference'
      for _, ref in ipairs(item.refs) do
        local to = ref.end_pos[1] == ref.pos[1] and shown_col(b, text, ref.end_pos[2]) or #item.code
        ref.match = { shown_col(b, text, ref.pos[2]), to }
        if is_call(b, ref) then
          item.ref_kind = 'Call'
        end
      end
    end
  end
  return files, lnum_width
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
      for byte = (r == c[1] and c[2] or 0) + 1, r == c[3] and c[4] or #lines[r + 1] do
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
-- a parse of the block with a margin of code around it (a block cut out alone could
-- leave a construct open, its keywords unparsed)
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
  if f.buf and vim.api.nvim_buf_is_loaded(f.buf) and vim.api.nvim_buf_get_changedtick(f.buf) == f.tick then
    local ok, parser = pcall(vim.treesitter.get_parser, f.buf)
    if ok and parser then
      f.text = f.text or table.concat(vim.api.nvim_buf_get_lines(f.buf, 0, -1, false), '\n')
      chunks = highlight_rows(parser, f.text, first - 1, lines)
    end
  else
    if not b.snippet then
      local from = f.lines and math.max(b.first - CONTEXT_MARGIN, 1) or b.first
      local text = table.concat(f.lines and vim.list_slice(f.lines, from, b.last + CONTEXT_MARGIN) or b.lines, '\n')
      local ok, parser = pcall(vim.treesitter.get_string_parser, text, f.lang)
      b.snippet = { parser = ok and parser, text = text, from = from }
    end
    if b.snippet.parser then
      chunks = highlight_rows(b.snippet.parser, b.snippet.text, first - b.snippet.from, lines)
    end
  end
  for row = first, last do
    b.highlights[row] = chunks and chunks[row - first + 1] or { { lines[row - first + 1] or '' } }
  end
end

-- The code of row `r` of block `b` as chunks { text, hl }, as the list shows it:
-- dedented with its block, tabs expanded, highlighted once M.highlight went through
function M.chunks(b, r)
  local chunks, pos = {}, 0
  for _, c in ipairs(b.highlights[r] or { { b.lines[r - b.first + 1] or '' } }) do
    local from = pos + 1
    pos = pos + #c[1]
    if pos > b.dedent then
      chunks[#chunks + 1] = { (c[1]:sub(math.max(b.dedent - from + 2, 1)):gsub('\t', b.tab)), c[2] }
    end
  end
  return chunks
end

return M
