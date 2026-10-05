local vim = vim

-- <Left>/<Right> hop to the previous/next symbol that has references, opening the panel
-- (refs.panel) if it is closed, so it shows the references of each symbol landed on.
-- Candidates are the identifiers treesitter finds, in every language tree (a .vue file's
-- <script> counts): keywords, strings and comments are never visited. Each is kept only
-- if `textDocument/references` comes back with a location other than the word itself,
-- so symbols nothing refers to are skipped too. The answers are memoized and asked for
-- ahead (see refs.answers), and a hop over known answers lands at once. One waiting on a
-- server lands only if nothing happened meanwhile (no key moved the cursor, edited, or
-- started an operator or Visual mode); keys that wait to run after the hop (a macro's)
-- wait for the server. Where hops can't work (no server, no parser, a language without
-- identifiers as markdown, a big file), the arrows move a character.
local answers = require('refs.answers')
local panel = require('refs.panel')

local M = {}

-- Per-language query for identifier nodes: `identifier`, every `*_identifier` (field_,
-- type_, property_, package_, ...), bash's `variable_name`, and bash's function names
-- (`word`s) with the commands calling them (`@command`, see symbols_in). Built from the
-- grammar's own node types, as a query naming a type the language lacks fails to parse.
local symbol_queries, function_queries = {}, {}
local function symbol_query(lang)
  if symbol_queries[lang] == nil then
    local info = vim.treesitter.language.inspect(lang)
    local types = {}
    for name, named in pairs(info.symbols) do
      if named and (name:match('^[%w_]*identifier$') or name == 'variable_name') then
        types[#types + 1] = '(' .. name .. ')'
      end
    end
    local source = #types > 0 and '[' .. table.concat(types, ' ') .. '] @symbol' or ''
    local symbols, fields = info.symbols, info.fields or {}
    if symbols.function_definition and symbols.command_name and symbols.word and vim.list_contains(fields, 'name') then
      source = source .. ' (function_definition name: (word) @symbol) (command_name (word) @command)'
      function_queries[lang] = vim.treesitter.query.parse(lang, '(function_definition name: (word) @name)')
    end
    local ok, query = pcall(vim.treesitter.query.parse, lang, source)
    symbol_queries[lang] = source ~= '' and ok and query
  end
  return symbol_queries[lang]
end

local HOP_ROWS = 100 -- rows scanned per batch for candidates

-- [buf] = { tick, [first:last] = candidates, [lang] = its functions }: a batch is scanned
-- once per text
local scans = {}

-- The names of the functions language tree `tree` (of `lang`, in `buf`) defines
local function functions_of(tree, lang, buf)
  local key = 'functions:' .. lang
  if not scans[buf][key] then
    local names = {}
    for _, node in function_queries[lang]:iter_captures(tree:root(), buf) do
      names[vim.treesitter.get_node_text(node, buf)] = true
    end
    scans[buf][key] = names
  end
  return scans[buf][key]
end

-- Identifier starts { row, col } (0-indexed) in rows [first, last), across every
-- language tree, sorted in travel order. Non-leaf matches (nested_identifier, ...) are
-- dropped: the identifiers inside them match on their own. A command counts when it
-- calls a function the script defines (bashls answers `echo` with its other uses).
local function symbols_in(parser, buf, first, last, dir)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if not (scans[buf] and scans[buf].tick == tick) then
    scans[buf] = { tick = tick }
  end
  local key = first .. ':' .. last
  local found = scans[buf][key]
  if not found then
    parser:parse({ first, last })
    local seen = {}
    found = {}
    parser:for_each_tree(function(tree, ltree)
      local query = symbol_query(ltree:lang())
      if query then
        for id, node in query:iter_captures(tree:root(), buf, first, last) do
          local row, col = node:start()
          local at = row .. ':' .. col
          local wanted = query.captures[id] ~= 'command'
            or functions_of(tree, ltree:lang(), buf)[vim.treesitter.get_node_text(node, buf)]
          if wanted and row >= first and row < last and node:named_child_count() == 0 and not seen[at] then
            seen[at] = true
            found[#found + 1] = { row, col }
          end
        end
      end
    end)
    table.sort(found, function(a, b)
      return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
    end)
    scans[buf][key] = found
  end
  if dir > 0 then
    return found
  end
  local reversed = {}
  for i = #found, 1, -1 do
    reversed[#reversed + 1] = found[i]
  end
  return reversed
end

local hop_job -- the hop waiting on the server, if any
local HOP_STALE_MS = 3000 -- a later press gives up on a hop the server left unanswered this long

-- Nothing happened since the hop left the cursor: same window, buffer, text and
-- position, in Normal mode (no operator pending, no Visual mode)
local function hop_intact(job)
  if not (vim.api.nvim_buf_is_valid(job.buf) and vim.api.nvim_win_is_valid(job.win)) then
    return false
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  return vim.api.nvim_get_current_win() == job.win
    and vim.api.nvim_win_get_buf(job.win) == job.buf
    and vim.api.nvim_buf_get_changedtick(job.buf) == job.tick
    and cursor[1] - 1 == job.at[1]
    and cursor[2] == job.at[2]
    and vim.api.nvim_get_mode().mode == 'n'
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

-- The next `count` landings from `pos` (or candidates not known yet, maybe landings):
-- the next presses land at once once they are known
local function ahead(buf, parser, pos, dir, count)
  local scan = { buf = buf, dir = dir, parser = parser, at = pos, row = pos[1], queue = {}, i = 0 }
  local found = {}
  while count > 0 do
    local p = next_symbol(scan)
    if not p then
      break
    end
    local refs = answers.known(buf, p, 'refs')
    if refs == nil or answers.lands(refs) then
      count = count - 1
      found[#found + 1] = { p, refs == nil }
    end
  end
  return found
end

-- Ask about those of `targets` (see ahead) not known yet, and the definitions of those
-- that are landings, for the pane and the list's marks
local function ask_ahead(buf, targets)
  for _, t in ipairs(targets) do
    if t[2] then
      answers.ask(buf, t[1], 'refs', function(refs)
        if answers.lands(refs) then
          answers.ask(buf, t[1], 'defs', function() end, 'prefetch')
        end
      end, 'prefetch')
    end
  end
end

-- Whether one of the languages of `parser`'s trees has identifiers to hop to (markdown's
-- has none)
local function hoppable(parser)
  if symbol_query(parser:lang()) then
    return true
  end
  for lang in pairs(parser:children()) do
    if symbol_query(lang) then
      return true
    end
  end
  return false
end

-- The buffer's parser, when hops work there: a named, not big file (as the config's
-- b:big_file says) with a parser of a language with identifiers, and a server serving
-- references
local function hop_parser(buf)
  if vim.api.nvim_buf_get_name(buf) == '' or vim.b[buf].big_file then
    return nil
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if ok and parser and hoppable(parser) then
    if #vim.lsp.get_clients({ bufnr = buf, method = 'textDocument/references' }) > 0 then
      return parser
    end
  end
end

local prefetched -- where the cursor last was when asking ahead, to ask once per stay

-- Ask ahead both ways from the cursor once it settled (its own answers in), so the
-- first press after moving around by other means lands at once too; questions about
-- where it was before, no longer of use, are cancelled
function M.prefetch_here()
  local buf = vim.api.nvim_get_current_buf()
  local parser = hop_parser(buf)
  if not parser then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local pos = { cursor[1] - 1, cursor[2] }
  local here = buf
    .. ':'
    .. vim.api.nvim_buf_get_changedtick(buf)
    .. ':'
    .. answers.epoch()
    .. ':'
    .. pos[1]
    .. ':'
    .. pos[2]
  if prefetched == here then
    return
  end
  prefetched = here
  local targets, keep = {}, {}
  for _, dir in ipairs({ 1, -1 }) do
    vim.list_extend(targets, ahead(buf, parser, pos, dir, HOP_AHEAD / 2))
  end
  for _, t in ipairs(targets) do
    local start = answers.word_start(buf, t[1])
    keep[buf .. ':' .. start[1] .. ':' .. start[2]] = true
  end
  answers.cancel('prefetch', keep)
  ask_ahead(buf, targets)
end

local LONG_LIST = 300 -- references from which a landing's list is drawn after the press

-- Land on `pos`, whose references are `refs`: the cursor there, the panel (opened if
-- needed) showing them and the pane its definition, the next landings asked about. The
-- panel follows in the same screen update, but for a long list, drawn right after it (if
-- the cursor is still there): the cursor never waits on a list of thousands.
local function land(job, pos, refs)
  vim.api.nvim_win_set_cursor(job.win, { pos[1] + 1, pos[2] })
  job.at, job.landed = pos, true
  job.steps = job.steps - 1
  panel.open()
  local function show()
    panel.show(job.buf, pos, refs, true)
    panel.definition()
  end
  local count = 0
  for _, r in ipairs(refs) do
    count = count + #r.result
  end
  if count < LONG_LIST then
    show()
  else
    vim.schedule(function()
      if vim.api.nvim_get_current_win() == job.win and vim.api.nvim_win_get_buf(job.win) == job.buf then
        local cursor = vim.api.nvim_win_get_cursor(job.win)
        if cursor[1] - 1 == pos[1] and cursor[2] == pos[2] then
          show()
        end
      end
    end)
  end
  ask_ahead(job.buf, ahead(job.buf, job.parser, pos, job.dir, HOP_AHEAD))
end

-- Whether keys wait to run after this one (a macro's, or :normal's, feedkeys()'): a hop
-- then waits for the server, so they run where it lands
local function keys_wait()
  return vim.fn.reg_executing() ~= '' or vim.fn.state('m') ~= ''
end

local stalled = 0 -- when a wait for the server last ran out (see wait_for)

-- The references of `pos` from the server, waiting for them: nil if it gave none in time
-- (and at once while it was just found silent, so a macro's hops don't wait in turn).
-- <C-c> stops it, and the keys waiting to run after it (the macro's rest), as it stops a
-- macro anywhere: they're read out of the typeahead, unrun.
local function wait_for(buf, pos)
  if vim.uv.now() - stalled < HOP_STALE_MS then
    return nil
  end
  local got, refs = false, nil
  answers.ask(buf, pos, 'refs', function(r)
    got, refs = true, r
  end, 'hop')
  local _, why = vim.wait(HOP_STALE_MS, function()
    return got
  end, 5)
  if why == -2 then
    while vim.fn.getchar(1) ~= 0 do
      vim.fn.getchar()
    end
    return nil
  elseif not got then
    stalled = vim.uv.now()
  end
  return got and (refs or { other = false }) or nil
end

-- Go through the candidates, landing on each that has references until the hop's steps
-- are spent: at once while their answers are known, else one server round trip at a
-- time. An answer is dropped if a newer hop took over, and ends the hop if anything
-- happened while it was pending (see hop_intact). Past the last landing, the cursor
-- stays.
local function hop_on(job)
  while job.steps > 0 do
    local pos = next_symbol(job)
    if not pos then
      break
    end
    local refs = answers.known(job.buf, pos, 'refs')
    if refs == nil and keys_wait() then
      refs = wait_for(job.buf, pos)
      if refs == nil then
        break -- (the server is silent)
      end
    end
    if refs == nil then
      job.sent = vim.uv.now()
      answers.ask(job.buf, pos, 'refs', function(r)
        if hop_job ~= job then
          return
        elseif not hop_intact(job) then
          hop_job = nil
          return
        end
        if answers.lands(r) then
          land(job, pos, r)
        end
        hop_on(job)
      end, 'hop')
      return
    elseif answers.lands(refs) then
      land(job, pos, refs)
    end
  end
  hop_job = nil
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
    sent = vim.uv.now(),
  }
  hop_on(hop_job)
end

return M
