-- Classify each location from `textDocument/references` as either a `Call`
-- (the symbol is immediately followed by `(`) or a plain `Reference`. The LSP
-- response is just bare locations with no such tag, so we read the source line
-- and derive it ourselves. This runs as the section `filter` (trouble accepts a
-- function filter — see trouble/filter.lua) which fires before grouping/sorting,
-- so the `ref_kind` we stash on each item drives the groups configured below.
local function classify_refs(items)
  local Util = require('trouble.util')

  -- Read each reference's line once, batched per file. Util.get_lines reads
  -- from disk when the buffer isn't loaded, so cross-file refs work too.
  local by_file = {}
  for _, item in ipairs(items) do
    local f = by_file[item.filename]
    if not f then
      f = { buf = item.buf, rows = {}, items = {} }
      by_file[item.filename] = f
    end
    f.rows[#f.rows + 1] = item.end_pos[1]
    f.items[#f.items + 1] = item
  end

  for name, f in pairs(by_file) do
    local lines = Util.get_lines({ rows = f.rows, buf = f.buf, path = name }) or {}
    for _, item in ipairs(f.items) do
      local line = lines[item.end_pos[1]] or ''
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

  return items
end

-- <Left>/<Right> hop to the previous/next symbol that has references, opening the
-- refs_follow panel (below) if it is closed, so the panel re-targets to each symbol
-- landed on. Candidates are the identifiers treesitter finds, in every language tree
-- (a .vue file's <script> counts): keywords, strings and comments are never visited.
-- Each is confirmed with the panel's own `textDocument/references` request and kept
-- only if a location other than the word itself comes back, so symbols nothing refers
-- to are skipped too.

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

-- Whether the symbol at `pos` has a reference besides that very word. Asks every
-- attached client that serves references (vue_ls and ts_ls share .vue files); cb(true)
-- on the first yes, else cb(false) once all have answered. Always calls back async.
local function has_refs(buf, clients, pos, cb)
  local line = vim.api.nvim_buf_get_lines(buf, pos[1], pos[1] + 1, false)[1] or ''
  local fname = vim.api.nvim_buf_get_name(buf)
  local pending, done = #clients, false
  local function answer(yes)
    pending = pending - 1
    if not done and (yes or pending == 0) then
      done = true
      cb(yes)
    end
  end
  for _, client in ipairs(clients) do
    local char = vim.str_utfindex(line, client.offset_encoding, pos[2], false)
    local params = {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      position = { line = pos[1], character = char },
      context = { includeDeclaration = true },
    }
    local sent = client:request('textDocument/references', params, function(_, locations)
      for _, loc in ipairs(locations or {}) do
        local range = loc.range
        local itself = range.start.line == pos[1]
          and range.start.character <= char
          and char <= range['end'].character
          and vim.uri_to_fname(loc.uri) == fname
        if not itself then
          return answer(true)
        end
      end
      answer(false)
    end, buf)
    if not sent then
      vim.schedule(function()
        answer(false)
      end)
    end
  end
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
  has_refs(job.buf, job.clients, pos, function(yes)
    if hop_job ~= job then
      return
    elseif not hop_intact(job) then
      hop_job = nil
      return
    end
    if yes then
      vim.api.nvim_win_set_cursor(job.win, { pos[1] + 1, pos[2] })
      job.at = pos
      job.steps = job.steps - 1
      -- Re-target the panel, opening it if needed (and again once it has opened, in case
      -- we landed meanwhile): its CursorHold refresh fires once per typed key, possibly
      -- before this answer came in
      local view = require('trouble').open({ mode = 'refs_follow', refresh = false })
      if view then
        view:wait(function()
          view:refresh()
        end)
      end
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
  local clients = vim.lsp.get_clients({ bufnr = buf, method = 'textDocument/references' })
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if #clients == 0 or not ok or not parser then
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
    clients = clients,
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
    -- Header labels for the Call/Reference split below. Custom formatters take
    -- precedence over trouble's built-ins (trouble/format.lua); the group header
    -- node inherits `ref_kind` from the first item in the group.
    formatters = {
      ref_kind = function(ctx)
        if ctx.item.ref_kind == 'Call' then
          return { text = '󰊕 Calls', hl = 'Function' }
        elseif ctx.item.ref_kind == 'Reference' then
          return { text = '󰌹 References', hl = 'Comment' }
        end
      end,
    },
    modes = {
      -- Persistent right-hand split that re-runs `textDocument/references`
      -- for whatever symbol the cursor rests on (refreshes on CursorHold),
      -- split into `Calls` and `References` groups, then by file.
      refs_follow = {
        mode = 'lsp_references',
        -- Keep the reference under the cursor in the results. lsp_base defaults
        -- to include_current=false, which drops *every* reference on the cursor's
        -- line -- so resting on a call site would hide the whole Calls group,
        -- leaving only References (and vice-versa). Keeping it means both groups
        -- stay visible as the cursor moves.
        params = { include_current = true },
        auto_refresh = true, -- re-fetch as the cursor moves in the code window
        auto_jump = false, -- don't teleport when a symbol has a single reference
        focus = false, -- keep the cursor in the code, let the panel follow
        warn_no_results = false, -- stay quiet when the cursor isn't on a symbol
        open_no_results = true, -- toggle open even before landing on a symbol
        win = { type = 'split', position = 'right', size = 0.35 },
        title = false, -- Calls/References groups are the top level; skip a title
        filter = classify_refs,
        -- 'Call' sorts before 'Reference', so the Calls group renders on top.
        sort = { 'ref_kind', 'filename', 'pos' },
        groups = {
          { 'ref_kind', format = '{ref_kind} {count}' },
          { 'filename', format = '{file_icon} {filename} {count}' },
        },
      },
    },
    keys = {
      ['<esc>'] = 'close',
    },
    win = {
      wo = {
        winhighlight = 'Normal:TroubleNormal,NormalNC:TroubleNormalNC,EndOfBuffer:TroubleNormal,CursorLine:TroubleCursorLine',
      },
    },
  },
}
