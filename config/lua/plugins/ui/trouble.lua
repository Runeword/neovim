local REF_CONTEXT = 1 -- lines of code the refs_follow list shows above and below each reference

-- Prepare the refs_follow items. This runs as the section `filter` (trouble accepts a
-- function filter — see trouble/filter.lua), which fires before grouping/sorting.
--
-- Classify each location from `textDocument/references` as either a `Call` (the symbol
-- is immediately followed by `(`) or a plain `Reference`. The LSP response is just bare
-- locations with no such tag, so we read the source line and derive it ourselves: the
-- `ref_kind` we stash on each item marks the calls in the list below.
--
-- Each item also gets the code the list shows for it: its line (`code`) and the
-- REF_CONTEXT lines around it (`above`, `below`: row ranges, drawn by show_context).
-- References close by share a `block` of consecutive lines, so no line shows twice,
-- dedented as a whole so the indentation inside it stays true; `gap` marks a block that
-- follows another in the same file. And each item gets the widest line number shown,
-- to right-align the numbers.
local function prepare_refs(items)
  local Util = require('trouble.util')

  local by_file, lnum_width = {}, 1
  for _, item in ipairs(items) do
    by_file[item.filename] = by_file[item.filename] or { buf = item.buf }
    table.insert(by_file[item.filename], item)
  end

  for name, refs in pairs(by_file) do
    -- The file's lines, from its buffer when loaded, else from disk (whole, to know
    -- where it ends), so cross-file refs work too
    local loaded = refs.buf and vim.api.nvim_buf_is_loaded(refs.buf)
    local all = not loaded and Util.get_lines({ buf = refs.buf, path = name }) or {}
    if all[#all] == '' then
      all[#all] = nil -- (what follows the file's final newline)
    end
    local count = loaded and vim.api.nvim_buf_line_count(refs.buf) or #all
    local tab = (' '):rep(loaded and vim.bo[refs.buf].tabstop or vim.o.tabstop)
    -- Where highlight_block finds the code to parse, for the file's blocks
    local file = { lang = refs[1]:get_lang(), lines = not loaded and all or nil }
    if loaded then
      file.buf, file.tick = refs.buf, vim.api.nvim_buf_get_changedtick(refs.buf)
    end

    table.sort(refs, function(a, b)
      return a.pos[1] < b.pos[1] or (a.pos[1] == b.pos[1] and a.pos[2] < b.pos[2])
    end)
    local blocks, block, shown = {}, nil, 0 -- shown: the last line shown so far
    for i, item in ipairs(refs) do
      local row = item.pos[1]
      local next_row = refs[i + 1] and refs[i + 1].pos[1] or math.huge
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
      b.lines = loaded and vim.api.nvim_buf_get_lines(refs.buf, b.first - 1, b.last, false)
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

    for _, item in ipairs(refs) do
      local b = item.block
      local text = b.lines[item.pos[1] - b.first + 1] or ''
      item.code = (text:sub(b.dedent + 1):gsub('\t', b.tab))
      local line = b.lines[item.end_pos[1] - b.first + 1] or ''
      -- `end_pos[2]` is a 0-indexed byte column, so sub(col + 1) starts at the
      -- first character past the symbol.
      local after = line:sub(item.end_pos[2] + 1)
      local is_call = after:match('^%s*%(') ~= nil
      -- A definition's name (`function foo(`, `def foo(`, …) is also followed by
      -- `(` — don't count it as a call. Anchored at the start of the line so a
      -- genuine call such as `function_tbl.foo(` is not mistaken for a def.
      -- (C-family definitions have no keyword and will still read as calls.)
      local before = line:sub(1, item.pos[2])
      local is_def = before:match('^%s*function%s')
        or before:match('^%s*local%s+function%s')
        or before:match('^%s*async%s+function%s')
        or before:match('^%s*def%s')
        or before:match('^%s*async%s+def%s')
        or before:match('^%s*func%s')
        or before:match('^%s*fn%s')
      item.ref_kind = (is_call and not is_def) and 'Call' or 'Reference'
    end
  end

  for _, item in ipairs(items) do
    item.lnum_width = lnum_width
  end
  return items
end

-- The context lines are virtual lines under the list's own lines, so the cursor steps
-- from reference to reference over them. They are set after each render of trouble's
-- (it has no event for that: see the hook in `config`), plain, and highlighted once in
-- view (from the decoration provider in `config`), which spares parsing the code of a
-- long list that is never scrolled through.
local context_ns = vim.api.nvim_create_namespace('refs_follow.context')
local context_marks = {} -- [list buf] = { [row] = { item, lines = { { prefix, block, row } }, id, done } }

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

local CONTEXT_MARGIN = 20 -- lines parsed around a block of a file that isn't loaded

-- Highlight rows first..last of block `b` (see prepare_refs) as in its file, into
-- b.highlights[row]: from the syntax tree of its buffer while that is unchanged (read
-- from a copy of its text, as the query's predicates go faster on a string), else from
-- a parse of the block with a margin of code around it (a block cut out alone could
-- leave a construct open, its keywords unparsed)
local function highlight_block(b, first, last)
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
-- dedented with its block, tabs expanded, highlighted once highlight_block went through
local function code_chunks(b, r)
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

-- A context line as virtual line chunks: its prefix, then its code (a gap between
-- blocks has no row: the guides alone)
local function context_line(line)
  local chunks = vim.list_slice(line.prefix)
  return line.row and vim.list_extend(chunks, code_chunks(line.block, line.row)) or chunks
end

-- Draw the context lines of a freshly rendered refs_follow list (see prepare_refs):
-- the lines above a reference go under the list line before it (a file header or the
-- previous reference), the lines below it under its own. Each gets the reference's
-- indent guides (continued down), then blanks and its line number under the
-- reference's '{ref_kind}{lnum} ' columns.
local function show_context(renderer, buf)
  vim.api.nvim_buf_clear_namespace(buf, context_ns, 0, -1)
  local symbols = require('trouble.view.indent').new(renderer.opts.icons.indent).symbols
  local guides = renderer.opts.indent_guides ~= false
  local padding = (' '):rep(renderer._opts.padding or 0)
  local rows = {} -- [list row] = { item: the reference on it, lines: the context lines under it }
  for row = 1, #renderer._lines do
    local loc = renderer._locations[row]
    local item = loc and loc.first_line and loc.item
    if item and item.block then
      rows[row] = rows[row] or {}
      rows[row].item = item
      local indent = {} -- the reference's indent guides, as trouble rendered them
      for _, segment in ipairs(renderer._lines[row]) do
        if not segment.type then
          break
        end
        indent[#indent + 1] = segment
      end
      local function add(at, guide, r)
        local prefix = padding ~= '' and { { padding } } or {}
        for k = 1, #indent - 1 do
          prefix[#prefix + 1] = { indent[k].str, indent[k].hl }
        end
        if #indent > 0 then
          local symbol = symbols[guides and guide or 'ws']
          prefix[#prefix + 1] = { symbol.str, symbol.hl }
        end
        if r then
          prefix[#prefix + 1] = { ('  %' .. item.lnum_width .. 'd '):format(r), 'NonText' }
        end
        rows[at] = rows[at] or {}
        rows[at].lines = rows[at].lines or {}
        table.insert(rows[at].lines, { prefix = prefix, block = item.block, row = r })
      end
      if row > 1 then
        if item.gap then
          add(row - 1, 'top')
        end
        for r = item.above[1], item.above[2] do
          add(row - 1, 'top', r)
        end
      end
      local last = indent[#indent] and indent[#indent].type -- the item's own guide
      for r = item.below[1], item.below[2] do
        add(row, last == 'middle' and 'top' or 'ws', r)
      end
    end
  end
  local marks = {} -- (by 0-indexed row)
  for row, mark in pairs(rows) do
    if mark.lines then
      local opts = { virt_lines = vim.tbl_map(context_line, mark.lines), virt_lines_overflow = 'scroll' }
      mark.id = vim.api.nvim_buf_set_extmark(buf, context_ns, row - 1, 0, opts)
    end
    marks[row - 1] = mark
  end
  context_marks[buf] = marks
end

-- Highlight the code in view not highlighted yet (the references' and their context's)
-- in `win` showing list `buf` from row `toprow` (0-indexed) down, as far as its height
-- goes: the decoration provider's botrow counts the list's own lines only. (Trouble's
-- own highlighting of a list's code gives up a hundred lines or so down.)
local function highlight_context(win, buf, toprow, botrow)
  local marks, room = context_marks[buf] or {}, vim.api.nvim_win_get_height(win)
  -- (the lines under the row above the top one can show at the top too)
  for row = math.max(toprow - 1, 0), botrow do
    local mark = marks[row]
    if mark and not mark.done then
      mark.done = true
      local spans = {} -- [block] = the rows of it to highlight
      local function need(b, r)
        local span = spans[b] or { r, r }
        spans[b] = { math.min(span[1], r), math.max(span[2], r) }
      end
      if mark.item then
        need(mark.item.block, mark.item.pos[1])
      end
      for _, line in ipairs(mark.lines or {}) do
        if line.row then
          need(line.block, line.row)
        end
      end
      for b, span in pairs(spans) do
        highlight_block(b, span[1], span[2])
      end
      if mark.item then -- its code ends the row's text (see the format below)
        local text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
        local col = #text - #mark.item.code
        for _, c in ipairs(code_chunks(mark.item.block, mark.item.pos[1])) do
          if c[2] then
            -- (over the code formatter's base highlight, at the extmarks' default 4096)
            local opts = { end_col = col + #c[1], hl_group = c[2], priority = 4097 }
            vim.api.nvim_buf_set_extmark(buf, context_ns, row, col, opts)
          end
          col = col + #c[1]
        end
      end
      if mark.lines then
        local opts =
          { id = mark.id, virt_lines = vim.tbl_map(context_line, mark.lines), virt_lines_overflow = 'scroll' }
        vim.api.nvim_buf_set_extmark(buf, context_ns, row, 0, opts)
      end
    end
    if row >= toprow then
      room = room - 1 - (mark and mark.lines and #mark.lines or 0)
      if room <= 0 then
        return
      end
    end
  end
end

-- What the servers answered about symbols, per position and buffer text, so hops land
-- and the panel and pane update without waiting on a server: lua_ls, for one, dozes
-- off ~50 ms after its last request and then takes 100 ms (or a second) to answer.
-- Hops ask ahead of the next press (see hop_prefetch). Per position:
--   refs: the references ({ client, result } per client serving them), or false when
--         none comes back besides the word itself
--   def:  the definition to preview (an item), or false when it's in the same file (a
--         jump away) or there is none
local memo = {} -- [buf] = { tick = changedtick, [row:col] = { refs, def, waiting } }

-- The memo entry for `pos` in `buf` as its text is now; `create` makes a missing one
local function memo_at(buf, pos, create)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if not (memo[buf] and memo[buf].tick == tick) then
    memo[buf] = { tick = tick }
  end
  local key = pos[1] .. ':' .. pos[2]
  if create and not memo[buf][key] then
    memo[buf][key] = { waiting = {} }
  end
  return memo[buf][key]
end

local ASK_STALE_MS = 3000 -- a question left unanswered this long is asked again

-- The `what` answer ('refs' or 'def') about `pos`: memoized, with one request shared
-- by everyone asking meanwhile. `fetch(done)` asks the servers; done(nil) means no
-- answer (an error), not memoized. Calls back async.
local function ask(buf, pos, what, fetch, cb)
  local entry = memo_at(buf, pos, true)
  if entry[what] ~= nil then
    return vim.schedule(function()
      cb(entry[what])
    end)
  end
  local waiting = entry.waiting[what]
  if waiting and vim.uv.now() - waiting.since < ASK_STALE_MS then
    waiting[#waiting + 1] = cb
    return
  end
  waiting = { cb, since = vim.uv.now() }
  entry.waiting[what] = waiting
  fetch(function(answer)
    entry[what] = answer
    if entry.waiting[what] == waiting then
      entry.waiting[what] = nil
    end
    vim.schedule(function()
      for _, f in ipairs(waiting) do
        f(answer)
      end
    end)
  end)
end

-- Params for position `pos` (0-indexed row, byte col) of `buf`, in `client`'s encoding
local function position_params(client, buf, pos)
  local line = vim.api.nvim_buf_get_lines(buf, pos[1], pos[1] + 1, false)[1] or ''
  return {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = pos[1], character = vim.str_utfindex(line, client.offset_encoding, pos[2], false) },
  }
end

-- `refs` for `pos`, asking every attached client that serves references (vue_ls and
-- ts_ls share .vue files) the panel's own question (declaration included)
local function fetch_refs(buf, pos, done)
  local clients = vim.lsp.get_clients({ bufnr = buf, method = 'textDocument/references' })
  local fname = vim.api.nvim_buf_get_name(buf)
  local results, pending, other, failed = {}, #clients, false, false
  local function answered()
    pending = pending - 1
    if pending == 0 then
      if other then
        done(results)
      elseif not failed then
        done(false)
      else
        done(nil)
      end
    end
  end
  for _, client in ipairs(clients) do
    local params = position_params(client, buf, pos)
    params.context = { includeDeclaration = true }
    local char = params.position.character
    local sent = client:request('textDocument/references', params, function(err, locations)
      failed = failed or err ~= nil
      results[#results + 1] = { client = client, result = locations }
      for _, loc in ipairs(locations or {}) do
        local range = loc.range
        local itself = range.start.line == pos[1]
          and range.start.character <= char
          and char <= range['end'].character
          and vim.uri_to_fname(loc.uri) == fname
        other = other or not itself
      end
      answered()
    end, buf)
    if not sent then
      failed = true
      answered()
    end
  end
  if #clients == 0 then
    done(false)
  end
end

-- `def` for `pos`: the first definition a client gives, when it's in another file
local function fetch_def(buf, pos, done)
  -- (a request no attached server can answer would raise an error notification)
  if #vim.lsp.get_clients({ bufnr = buf, method = 'textDocument/definition' }) == 0 then
    return done(false)
  end
  vim.lsp.buf_request_all(buf, 'textDocument/definition', function(client)
    return position_params(client, buf, pos)
  end, function(results)
    local failed = false
    for id, res in pairs(results) do
      failed = failed or res.err ~= nil
      local client = vim.lsp.get_client_by_id(id)
      local locs = res.result and (vim.islist(res.result) and res.result or { res.result }) or {}
      local it = client and locs[1] and vim.lsp.util.locations_to_items({ locs[1] }, client.offset_encoding)[1]
      if it then
        -- Same buffer = same file (buffers are matched by file, symlinks included)
        local def_buf = vim.uri_to_bufnr(locs[1].uri or locs[1].targetUri)
        return done(def_buf ~= buf and {
          filename = it.filename,
          buf = def_buf,
          pos = { it.lnum, it.col - 1 },
          end_pos = { it.end_lnum, it.end_col - 1 },
        })
      end
    end
    if not failed then
      done(false)
    else
      done(nil)
    end
  end)
end

-- The refs_follow panel's source: trouble's LSP references, answered from the memo when
-- the cursor sits where a hop asked already, which spares a server round trip
local refs_source = {
  get = function(cb, ctx)
    local lsp = require('trouble.sources.lsp')
    local cursor = vim.api.nvim_win_get_cursor(0)
    local entry = memo_at(vim.api.nvim_get_current_buf(), { cursor[1] - 1, cursor[2] })
    if not (entry and entry.refs) then
      return lsp.get.references(cb, ctx)
    end
    local items = {}
    for _, r in ipairs(entry.refs) do
      vim.list_extend(items, lsp.get_items(r.client, r.result, ctx.opts.params))
    end
    cb(items)
  end,
}

-- The refs_follow list keeps a preview pane open under it. In the code it shows the
-- definition of the symbol under the cursor when that is in another file, and stays
-- blank when it's in this one (a jump away) or there is none; while you browse the
-- list, the reference under the list's cursor. Trouble's own preview only lives while
-- its list is focused, and it shows an open file's real buffer, so its highlight would
-- land in the code window too: the pane shows a scratch copy instead, labelled with
-- the file and line it comes from.
local pane = {} -- win, buf, and what it shows: file, tick (of the file's buffer), key
local pane_ns = vim.api.nvim_create_namespace('refs_follow.pane')

-- The open refs_follow view, if any
local function refs_view()
  for _, v in ipairs(require('trouble.view').get({ open = true, mode = 'refs_follow' })) do
    if v.view.win:valid() then
      return v.view
    end
  end
end

local function scratch_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  return buf
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
  local lines = require('trouble.util').get_lines({ buf = item.buf, path = item.filename })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
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

-- Point the pane at `item`, opening it under the list first (blank). `false` blanks it,
-- nil keeps what it shows.
local function pane_show(list, item)
  if not (pane.win and vim.api.nvim_win_is_valid(pane.win)) then
    pane.win = vim.api.nvim_open_win(scratch_buf(), false, {
      split = 'below',
      win = list,
      height = math.max(math.floor(vim.api.nvim_win_get_height(list) / 2), 1),
      noautocmd = true,
    })
    pane.key = 'blank'
    vim.w[pane.win].trouble = { mode = 'refs_follow.pane' } -- so trouble never takes it for the code window
    local wo = vim.wo[pane.win]
    wo.number, wo.cursorline, wo.signcolumn, wo.foldcolumn, wo.wrap = true, true, 'no', '0', false
    wo.winfixheight, wo.winhighlight = true, 'CursorLine:TroubleCursorLine'
  end
  if item == nil then
    return
  elseif item == false then
    if pane.key ~= 'blank' then
      require('trouble.util').noautocmd(function()
        vim.api.nvim_win_set_buf(pane.win, scratch_buf())
      end)
      vim.wo[pane.win].winbar = ''
      pane.key = 'blank'
    end
    return
  end
  local buf = pane_buffer(item)
  local key = item.pos[1] .. ':' .. item.pos[2]
  if vim.api.nvim_win_get_buf(pane.win) == buf and pane.key == key then
    return
  end
  require('trouble.util').noautocmd(function()
    vim.api.nvim_win_set_buf(pane.win, buf)
  end)
  vim.api.nvim_buf_clear_namespace(buf, pane_ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, pane_ns, item.pos[1] - 1, item.pos[2], {
    end_row = item.end_pos[1] - 1,
    end_col = item.end_pos[2],
    hl_group = 'TroublePreview',
    strict = false,
  })
  pcall(vim.api.nvim_win_set_cursor, pane.win, item.pos)
  vim.api.nvim_win_call(pane.win, function()
    vim.cmd('normal! zz')
  end)
  local path = vim.fn.fnamemodify(item.filename, ':~:.'):gsub('%%', '%%%%')
  vim.wo[pane.win].winbar = ' ' .. path .. ':' .. item.pos[1]
  pane.key = key
end

-- Update the pane: while you browse the list, the reference under its cursor (or the
-- first one below a file header); in the code, what the definition lookup for the
-- cursor found, once it's in. Closes the pane once the list is gone.
local function pane_sync()
  local view = refs_view()
  if not view then
    if pane.win and vim.api.nvim_win_is_valid(pane.win) then
      vim.api.nvim_win_close(pane.win, true)
    end
    pane.win = nil
    return
  end
  local list = view.win.win
  if vim.api.nvim_get_current_win() ~= list then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local entry = memo_at(vim.api.nvim_get_current_buf(), { cursor[1] - 1, cursor[2] })
    return pane_show(list, entry and entry.def) -- nil until the lookup is in
  end
  local item
  for row = vim.api.nvim_win_get_cursor(list)[1], vim.api.nvim_buf_line_count(view.win.buf) do
    item = view:at({ row, 0 }).item
    if item then
      break
    end
  end
  pane_show(list, item)
end

-- Look up the definition of the symbol under the cursor for the pane (see fetch_def)
local function pane_definition()
  local buf, cursor = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)
  local pos = { cursor[1] - 1, cursor[2] }
  ask(buf, pos, 'def', function(done)
    fetch_def(buf, pos, done)
  end, pane_sync)
end

-- <Left>/<Right> hop to the previous/next symbol that has references, opening the
-- refs_follow panel (below) if it is closed, so the panel re-targets to each symbol
-- landed on. Candidates are the identifiers treesitter finds, in every language tree
-- (a .vue file's <script> counts): keywords, strings and comments are never visited.
-- Each is confirmed with the panel's own `textDocument/references` request and kept
-- only if a location other than the word itself comes back, so symbols nothing refers
-- to are skipped too. The answers are memoized and asked for ahead (see ask).

-- Per-language query for identifier nodes: `identifier`, every `*_identifier` (field_,
-- type_, property_, package_, ...) and bash's `variable_name`. Built from the grammar's
-- own node types, as a query naming a type the language lacks fails to parse.
local symbol_queries = {}
local function symbol_query(lang)
  if symbol_queries[lang] == nil then
    local types = {}
    for name, named in pairs(vim.treesitter.language.inspect(lang).symbols) do
      if named and (name:match('^[%w_]*identifier$') or name == 'variable_name') then
        types[#types + 1] = '(' .. name .. ')'
      end
    end
    local ok, query = pcall(vim.treesitter.query.parse, lang, '[' .. table.concat(types, ' ') .. '] @symbol')
    symbol_queries[lang] = #types > 0 and ok and query
  end
  return symbol_queries[lang]
end

local HOP_ROWS = 100 -- rows scanned per batch for candidates

-- Identifier starts { row, col } (0-indexed) in rows [first, last), across every
-- language tree, sorted in travel order. Non-leaf matches (nested_identifier, ...) are
-- dropped: the identifiers inside them match on their own.
local function symbols_in(parser, buf, first, last, dir)
  parser:parse({ first, last })
  local found, seen = {}, {}
  parser:for_each_tree(function(tree, ltree)
    local query = symbol_query(ltree:lang())
    if query then
      for _, node in query:iter_captures(tree:root(), buf, first, last) do
        local row, col = node:start()
        local key = row .. ':' .. col
        if row >= first and row < last and node:named_child_count() == 0 and not seen[key] then
          seen[key] = true
          found[#found + 1] = { row, col }
        end
      end
    end
  end)
  local function before(a, b)
    return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
  end
  table.sort(found, dir > 0 and before or function(a, b)
    return before(b, a)
  end)
  return found
end

local hop_job -- the hop waiting on the server, if any
local HOP_STALE_MS = 3000 -- a later press gives up on a hop the server left unanswered this long

-- The cursor is still where the hop left it: same window, buffer, text and position.
local function hop_intact(job)
  local cursor = vim.api.nvim_win_get_cursor(0)
  return vim.api.nvim_get_current_win() == job.win
    and vim.api.nvim_win_get_buf(job.win) == job.buf
    and vim.api.nvim_buf_get_changedtick(job.buf) == job.tick
    and cursor[1] - 1 == job.at[1]
    and cursor[2] == job.at[2]
end

-- The next candidate past the cursor in the hop's direction, scanning HOP_ROWS rows at
-- a time; nil at the end of the buffer.
local function next_symbol(job)
  while job.i >= #job.queue do
    local lines = vim.api.nvim_buf_line_count(job.buf)
    if job.row < 0 or job.row >= lines then
      return nil
    end
    local first = job.dir > 0 and job.row or math.max(job.row - HOP_ROWS + 1, 0)
    local last = job.dir > 0 and math.min(job.row + HOP_ROWS, lines) or job.row + 1
    job.row = job.dir > 0 and last or first - 1
    job.queue, job.i = {}, 0
    for _, pos in ipairs(symbols_in(job.parser, job.buf, first, last, job.dir)) do
      -- Only the first batch holds the cursor's row: keep what lies past the cursor
      local delta = pos[1] ~= job.at[1] and pos[1] - job.at[1] or pos[2] - job.at[2]
      if delta * job.dir > 0 then
        job.queue[#job.queue + 1] = pos
      end
    end
  end
  job.i = job.i + 1
  return job.queue[job.i]
end

local HOP_AHEAD = 4 -- landings known ahead of each one (half that each way on CursorHold)

-- Ask ahead about the next `count` landings from `pos` (the definitions too, for the
-- pane), so the next presses land, and the pane updates, at once. Candidates known to
-- have no references are passed over; only those not known yet are asked about.
local function hop_prefetch(buf, parser, pos, dir, count)
  local scan = { buf = buf, dir = dir, parser = parser, at = pos, row = pos[1], queue = {}, i = 0 }
  while count > 0 do
    local p = next_symbol(scan)
    local entry = p and memo_at(buf, p)
    if not p then
      return
    elseif not (entry and entry.refs == false) then -- a landing, or maybe one
      count = count - 1
      if not (entry and entry.refs) then
        ask(buf, p, 'refs', function(done)
          fetch_refs(buf, p, done)
        end, function(refs)
          if refs then
            ask(buf, p, 'def', function(done)
              fetch_def(buf, p, done)
            end, function() end)
          end
        end)
      end
    end
  end
end

-- The buffer's parser, when hops work there: it has one and a server with references
local function hop_parser(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if ok and parser and #vim.lsp.get_clients({ bufnr = buf, method = 'textDocument/references' }) > 0 then
    return parser
  end
end

-- Ask ahead both ways from the cursor once it settles, so the first press after moving
-- around by other means lands at once too
local function hop_prefetch_here()
  local buf = vim.api.nvim_get_current_buf()
  local parser = hop_parser(buf)
  if parser then
    local cursor = vim.api.nvim_win_get_cursor(0)
    for _, dir in ipairs({ 1, -1 }) do
      hop_prefetch(buf, parser, { cursor[1] - 1, cursor[2] }, dir, HOP_AHEAD / 2)
    end
  end
end

-- Try the candidates one server round trip at a time, landing on each that has
-- references until the hop's steps are spent. An answer is dropped if a newer hop took
-- over, and ends the hop if the cursor, window or text changed while it was pending.
local function hop_on(job)
  local pos = next_symbol(job)
  if not pos then
    hop_job = nil
    return
  end
  job.sent = vim.uv.now()
  ask(job.buf, pos, 'refs', function(done)
    fetch_refs(job.buf, pos, done)
  end, function(refs)
    if hop_job ~= job then
      return
    elseif not hop_intact(job) then
      hop_job = nil
      return
    end
    if refs then
      vim.api.nvim_win_set_cursor(job.win, { pos[1] + 1, pos[2] })
      job.at = pos
      job.steps = job.steps - 1
      -- Re-target the panel, opening it if needed (and again once it has opened, in case
      -- we landed meanwhile), and its pane's definition: their CursorHold updates fire
      -- once per typed key, possibly before this answer came in
      local view = require('trouble').open({ mode = 'refs_follow', refresh = false })
      if view then
        view:wait(function()
          view:refresh()
        end)
      end
      pane_definition()
      hop_prefetch(job.buf, job.parser, pos, job.dir, HOP_AHEAD)
      if job.steps == 0 then
        hop_job = nil
        return
      end
    end
    hop_on(job)
  end)
end

local function hop(dir)
  local count = vim.v.count1
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local parser = hop_parser(buf)
  if not parser then
    vim.cmd('normal! ' .. count .. (dir > 0 and 'l' or 'h')) -- no LSP here: a plain arrow
    return
  end
  if hop_job and hop_job.dir == dir and hop_intact(hop_job) and vim.uv.now() - hop_job.sent < HOP_STALE_MS then
    -- Pressed again before the server answered (key held down): queue one more hop at
    -- most, not a backlog that carries on after the key is released
    hop_job.steps = math.max(hop_job.steps, count + 1)
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  hop_job = {
    buf = buf,
    win = win,
    dir = dir,
    steps = count,
    parser = parser,
    tick = vim.api.nvim_buf_get_changedtick(buf),
    at = { cursor[1] - 1, cursor[2] },
    row = cursor[1] - 1,
    queue = {},
    i = 0,
  }
  hop_on(hop_job)
end

return {
  'folke/trouble.nvim',
  dependencies = { 'nvim-tree/nvim-web-devicons' },
  cmd = 'Trouble',
  keys = {
    { 'gF', '<cmd>Trouble refs_follow toggle<cr>', desc = 'References panel (follows cursor)' },
    {
      '<Left>',
      function()
        hop(-1)
      end,
      desc = 'Previous symbol with references',
    },
    {
      '<Right>',
      function()
        hop(1)
      end,
      desc = 'Next symbol with references',
    },
  },
  opts = {
    -- Fields for the refs_follow items below. Custom formatters take precedence
    -- over trouble's built-ins (trouble/format.lua).
    formatters = {
      -- 󰊕 in front of the calls (see prepare_refs), blanks in front of the other
      -- references, so the line numbers stay aligned
      ref_kind = function(ctx)
        return ctx.item.ref_kind == 'Call' and { text = '󰊕 ', hl = 'Function' } or '  '
      end,
      -- The reference's line number, right-aligned to the widest in the list
      lnum = function(ctx)
        return { text = ('%' .. (ctx.item.lnum_width or 1) .. 'd'):format(ctx.item.pos[1]), hl = 'LineNr' }
      end,
      -- The reference's line of code, indented as among its context lines, and
      -- highlighted like them, once in view (see highlight_context)
      code = function(ctx)
        return { text = ctx.item.code or vim.trim(ctx.item.text or ''), hl = 'TroubleText' }
      end,
    },
    modes = {
      -- Persistent right-hand split that re-runs `textDocument/references`
      -- for whatever symbol the cursor rests on (refreshes on CursorHold),
      -- grouped by file, with a preview pane under it (see pane_sync).
      refs_follow = {
        mode = 'lsp_references',
        source = 'refs_hop', -- lsp.references, served from the hops' memo when it can
        -- Keep the references on the cursor's line. lsp_base defaults to
        -- include_current=false, which drops *every* reference on that line: the
        -- one under the cursor could then never be highlighted, and the list would
        -- reshuffle as the cursor moves from one reference to another.
        params = { include_current = true },
        auto_refresh = true, -- re-fetch as the cursor moves in the code window
        auto_jump = false, -- don't teleport when a symbol has a single reference
        focus = false, -- keep the cursor in the code, let the panel follow
        warn_no_results = false, -- stay quiet when the cursor isn't on a symbol
        open_no_results = true, -- toggle open even before landing on a symbol
        win = { type = 'split', position = 'right', size = 0.35 },
        title = false, -- the file groups are the top level; skip a title
        filter = prepare_refs,
        sort = { { buf = 0 }, 'filename', 'pos' }, -- the current file's group first
        groups = {
          { 'filename', format = '{file_icon} {filename} {count}' },
        },
        format = '{ref_kind}{lnum} {code}', -- (show_context lines up with these columns)
        -- The pane is the preview here: no trouble preview on top of it
        auto_preview = false,
        keys = { p = false, P = false },
      },
    },
    keys = {
      ['<esc>'] = 'close',
      -- One reference at a time (j/k would otherwise do this config's 4-line jump)
      j = 'next',
      k = 'prev',
      ['<down>'] = 'next',
      ['<up>'] = 'prev',
    },
    win = {
      wo = {
        winhighlight = 'Normal:TroubleNormal,NormalNC:TroubleNormalNC,EndOfBuffer:TroubleNormal,CursorLine:TroubleCursorLine',
      },
    },
  },
  config = function(_, opts)
    require('trouble').setup(opts)
    require('trouble.sources').register('refs_hop', refs_source)
    -- Draw the context lines of each fresh render of the refs_follow list, before the
    -- view restores its scroll and follows the cursor
    local Render = require('trouble.view.render')
    local render = Render.render
    function Render:render(buf)
      render(self, buf)
      if self.opts.mode == 'refs_follow' then
        show_context(self, buf)
      end
    end
    -- An edit elsewhere can change what refers to what: forget all answers on a write
    vim.api.nvim_create_autocmd('BufWritePost', {
      callback = function()
        memo = {}
      end,
    })

    -- Re-sync the refs_follow pane after every redraw of its list (the list opened,
    -- re-rendered, or its cursor moved, trouble's follow included), and when a window
    -- closes (maybe the list). Trouble has no events for these. Each redraw of the list
    -- also highlights the code coming into view (see highlight_context).
    local pending = false
    local function sync()
      if not pending then
        pending = true
        vim.schedule(function()
          pending = false
          pane_sync()
        end)
      end
    end
    vim.api.nvim_set_decoration_provider(pane_ns, {
      on_win = function(_, win, buf, toprow, botrow)
        local t = vim.w[win].trouble
        if t and t.mode == 'refs_follow' then
          highlight_context(win, buf, toprow, botrow)
          sync()
        end
        return false
      end,
    })
    vim.api.nvim_create_autocmd('WinClosed', { callback = sync })

    -- In the code, whenever the cursor settles: look up the definition for the pane, and
    -- ask ahead about the next hop targets
    vim.api.nvim_create_autocmd('CursorHold', {
      callback = function()
        if vim.bo.buftype == '' and refs_view() then
          pane_definition()
          hop_prefetch_here()
        end
      end,
    })

    -- Entering the code or the list switches the pane to the definition or the list's
    -- selection. The pane itself is for looking only: landing in it (<C-Right> from the
    -- lower half of the screen, a click) moves on to the list.
    vim.api.nvim_create_autocmd('WinEnter', {
      callback = function()
        local view = refs_view()
        if not view then
          return
        elseif vim.api.nvim_get_current_win() == pane.win then
          vim.schedule(function()
            pcall(vim.api.nvim_set_current_win, view.win.win)
          end)
        elseif vim.bo.buftype == '' then
          pane_definition()
        else
          sync()
        end
      end,
    })
  end,
}
