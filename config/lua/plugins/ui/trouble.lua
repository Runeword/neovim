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

return {
  'folke/trouble.nvim',
  dependencies = { 'nvim-tree/nvim-web-devicons' },
  cmd = 'Trouble',
  keys = {
    { 'gF', '<cmd>Trouble refs_follow toggle<cr>', desc = 'References panel (follows cursor)' },
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
