local vim = vim

-- <Left>/<Right> hop to the previous/next symbol that has references, opening the panel
-- (refs.panel) if it is closed, so it shows the references of each symbol landed on.
-- Candidates are the identifiers treesitter finds, in every language tree (a .vue file's
-- <script> counts): keywords, strings and comments are never visited. Each is kept only
-- if `textDocument/references` comes back with a location other than the word itself,
-- so symbols nothing refers to are skipped too. The answers are memoized and asked for
-- ahead (see refs.answers).
local answers = require('refs.answers')
local panel = require('refs.panel')

local M = {}

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
-- pane and the list's marks), so the next presses land, and the panel updates, at once.
-- Candidates known not to be landings are passed over; only those not known yet are
-- asked about.
local function prefetch(buf, parser, pos, dir, count)
  local scan = { buf = buf, dir = dir, parser = parser, at = pos, row = pos[1], queue = {}, i = 0 }
  while count > 0 do
    local p = next_symbol(scan)
    if not p then
      return
    end
    local entry = answers.at(buf, p)
    local known = entry ~= nil and entry.refs ~= nil
    if not known or answers.lands(entry.refs) then -- a landing, or maybe one
      count = count - 1
      if not known then
        answers.ask(buf, p, 'refs', function(refs)
          if answers.lands(refs) then
            answers.ask(buf, p, 'defs', function() end)
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
function M.prefetch_here()
  local buf = vim.api.nvim_get_current_buf()
  local parser = hop_parser(buf)
  if parser then
    local cursor = vim.api.nvim_win_get_cursor(0)
    for _, dir in ipairs({ 1, -1 }) do
      prefetch(buf, parser, { cursor[1] - 1, cursor[2] }, dir, HOP_AHEAD / 2)
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
  answers.ask(job.buf, pos, 'refs', function(refs)
    if hop_job ~= job then
      return
    elseif not hop_intact(job) then
      hop_job = nil
      return
    end
    if answers.lands(refs) then
      vim.api.nvim_win_set_cursor(job.win, { pos[1] + 1, pos[2] })
      job.at = pos
      job.steps = job.steps - 1
      -- Show its references, opening the panel if needed, and its definition in the pane
      panel.open()
      panel.show(job.buf, pos, refs)
      panel.definition()
      prefetch(job.buf, job.parser, pos, job.dir, HOP_AHEAD)
      if job.steps == 0 then
        hop_job = nil
        return
      end
    end
    hop_on(job)
  end)
end

function M.hop(dir)
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

return M
