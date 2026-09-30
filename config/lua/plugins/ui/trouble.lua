-- Classify each location from `textDocument/references` as either a `Call`
-- (the symbol is immediately followed by `(`) or a plain `Reference`. The LSP
-- response is just bare locations with no such tag, so we read the source line
-- and derive it ourselves. This runs as the section `filter` (trouble accepts a
-- function filter — see trouble/filter.lua) which fires before grouping/sorting,
-- so the `ref_kind` we stash on each item marks the calls in the list below. Each
-- item also gets the widest line number in the list, to right-align the numbers.
local function classify_refs(items)
  local Util = require('trouble.util')

  -- Read each reference's line once, batched per file. Util.get_lines reads
  -- from disk when the buffer isn't loaded, so cross-file refs work too.
  local by_file, lnum_width = {}, 1
  for _, item in ipairs(items) do
    local f = by_file[item.filename]
    if not f then
      f = { buf = item.buf, rows = {}, items = {} }
      by_file[item.filename] = f
    end
    f.rows[#f.rows + 1] = item.end_pos[1]
    f.items[#f.items + 1] = item
    lnum_width = math.max(lnum_width, #tostring(item.pos[1]))
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
      item.lnum_width = lnum_width
    end
  end

  return items
end

-- The refs_follow list keeps a preview pane open under it. In the code it shows the
-- definition of the symbol under the cursor when that is in another file, and stays
-- blank when it's in this one (a jump away) or there is none; while you browse the
-- list, the reference under the list's cursor. Trouble's own preview only lives while
-- its list is focused, and it shows an open file's real buffer, so its highlight would
-- land in the code window too: the pane shows a scratch copy instead, labelled with
-- the file and line it comes from.
local pane = {} -- win, buf, what it shows (file, tick of the file's buffer, key), def, def_key
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

-- Where the cursor is, text version included: what a definition lookup is asked for
local function cursor_key()
  local buf, cursor = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)
  return table.concat({ buf, vim.api.nvim_buf_get_changedtick(buf), cursor[1], cursor[2] }, ':')
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
    local def -- nil until the lookup for this very cursor position is in
    if pane.def_key == cursor_key() then
      def = pane.def
    end
    return pane_show(list, def)
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

-- Look up the definition of the symbol under the cursor for the pane (the LSP's
-- go-to-definition): pane.def becomes the definition when it's in another file, else
-- false (in this file, or none). The pane keeps what it shows until the answer is in.
local function pane_definition()
  local key = cursor_key()
  if key == pane.def_key then
    return pane_sync()
  end
  pane.def_key, pane.def = key, nil
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  -- A request no attached server can answer would raise an error notification
  if #vim.lsp.get_clients({ bufnr = buf, method = 'textDocument/definition' }) == 0 then
    pane.def = false
    return pane_sync()
  end
  vim.lsp.buf_request_all(buf, 'textDocument/definition', function(client)
    return vim.lsp.util.make_position_params(win, client.offset_encoding)
  end, function(results)
    if pane.def_key ~= key then
      return
    end
    pane.def = false
    for id, res in pairs(results) do
      local client = vim.lsp.get_client_by_id(id)
      local locs = res.result and (vim.islist(res.result) and res.result or { res.result }) or {}
      local it = client and locs[1] and vim.lsp.util.locations_to_items({ locs[1] }, client.offset_encoding)[1]
      if it then
        -- Same buffer = same file (buffers are matched by file, symlinks included)
        local def_buf = vim.uri_to_bufnr(locs[1].uri or locs[1].targetUri)
        if def_buf ~= buf then
          pane.def = {
            filename = it.filename,
            buf = def_buf,
            pos = { it.lnum, it.col - 1 },
            end_pos = { it.end_lnum, it.end_col - 1 },
          }
        end
        break
      end
    end
    pane_sync()
  end)
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
      -- we landed meanwhile), and its pane's definition: their CursorHold updates fire
      -- once per typed key, possibly before this answer came in
      local view = require('trouble').open({ mode = 'refs_follow', refresh = false })
      if view then
        view:wait(function()
          view:refresh()
        end)
      end
      pane_definition()
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
    -- Fields for the refs_follow items below. Custom formatters take precedence
    -- over trouble's built-ins (trouble/format.lua).
    formatters = {
      -- 󰊕 in front of the calls (see classify_refs), blanks in front of the other
      -- references, so the line numbers stay aligned
      ref_kind = function(ctx)
        return ctx.item.ref_kind == 'Call' and { text = '󰊕 ', hl = 'Function' } or '  '
      end,
      -- The reference's line number, right-aligned to the widest in the list
      lnum = function(ctx)
        return { text = ('%' .. (ctx.item.lnum_width or 1) .. 'd'):format(ctx.item.pos[1]), hl = 'LineNr' }
      end,
    },
    modes = {
      -- Persistent right-hand split that re-runs `textDocument/references`
      -- for whatever symbol the cursor rests on (refreshes on CursorHold),
      -- grouped by file, with a preview pane under it (see pane_sync).
      refs_follow = {
        mode = 'lsp_references',
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
        filter = classify_refs,
        sort = { { buf = 0 }, 'filename', 'pos' }, -- the current file's group first
        groups = {
          { 'filename', format = '{file_icon} {filename} {count}' },
        },
        format = '{ref_kind}{lnum} {text:ts}',
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

    -- Re-sync the refs_follow pane after every redraw of its list (the list opened,
    -- re-rendered, or its cursor moved, trouble's follow included), and when a window
    -- closes (maybe the list). Trouble has no events for these.
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
      on_win = function(_, win)
        local t = vim.w[win].trouble
        if t and t.mode == 'refs_follow' then
          sync()
        end
        return false
      end,
    })
    vim.api.nvim_create_autocmd('WinClosed', { callback = sync })

    -- In the code, look up the definition for the pane whenever the cursor settles
    vim.api.nvim_create_autocmd('CursorHold', {
      callback = function()
        if vim.bo.buftype == '' and refs_view() then
          pane_definition()
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
