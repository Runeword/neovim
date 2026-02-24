local api = vim.api
local ts = vim.treesitter

local label_map = {
  ['function.outer'] = 'f',
  ['call.outer'] = 'F',
  ['block.outer'] = 'b',
  ['loop.outer'] = 'p',
  ['statement.outer'] = 's',
}

local label_ns_id = api.nvim_create_namespace('TreesitterTextobjectLabels')

local M = {}

function M.select_treesitter_node_under_cursor()
  local current_buffer_id = api.nvim_get_current_buf()

  local cursor_pos = api.nvim_win_get_cursor(0)
  local cursor_row = cursor_pos[1] - 1 -- Convert row to 0-based index
  local cursor_col = cursor_pos[2]

  local success, ts_parser = pcall(ts.get_parser, current_buffer_id)
  if not success then
    return
  end

  local ts_tree = ts_parser:tree_for_range({ cursor_row, cursor_col, cursor_row, cursor_col })

  -- Find the smallest named node at the cursor position
  local ts_node = ts_tree:root():named_descendant_for_range(cursor_row, cursor_col, cursor_row, cursor_col)

  -- Get the node's range
  local start_row, start_col, end_row, end_col = ts_node:range()

  -- Set marks for the start and end of the node
  api.nvim_buf_set_mark(current_buffer_id, '<', start_row + 1, start_col, {})
  api.nvim_buf_set_mark(current_buffer_id, '>', end_row + 1, end_col - 1, {})

  -- Visually select the node
  api.nvim_command('normal! gv')
end

function M.move_to_next_treesitter_node()
  local current_buffer_id = api.nvim_get_current_buf()
  local current_buffer_filetype = api.nvim_get_option_value('filetype', { buf = current_buffer_id })

  local success, ts_parser = pcall(ts.get_parser, current_buffer_id)
  if not success then
    return
  end

  local ts_tree = ts_parser:parse()[1]
  local ts_lang = ts.language.get_lang(current_buffer_filetype)
  local ts_query = ts.query.parse(ts_lang, '(_) @node')

  local cursor_pos = api.nvim_win_get_cursor(0)
  local cursor_row = cursor_pos[1]
  local cursor_col = cursor_pos[2]

  for _, ts_node in ts_query:iter_captures(ts_tree:root(), current_buffer_id, cursor_row - 1) do
    local ts_range = { ts_node:range() }
    local row_start = ts_range[1] + 1
    local col_start = ts_range[2]

    if row_start > cursor_row or (row_start == cursor_row and col_start > cursor_col) then
      api.nvim_win_set_cursor(0, { row_start, col_start })
      break
    end
  end
end

function M.move_to_prev_treesitter_node()
  local current_buffer_id = api.nvim_get_current_buf()
  local current_buffer_filetype = api.nvim_get_option_value('filetype', { buf = current_buffer_id })

  local success, ts_parser = pcall(ts.get_parser, current_buffer_id)
  if not success then
    return
  end

  local ts_tree = ts_parser:parse()[1]
  local ts_lang = ts.language.get_lang(current_buffer_filetype)
  local ts_query = ts.query.parse(ts_lang, '(_) @node')

  local cursor_pos = api.nvim_win_get_cursor(0)
  local cursor_row = cursor_pos[1]
  local cursor_col = cursor_pos[2]

  local ts_nodes = {}
  for _, ts_node in ts_query:iter_captures(ts_tree:root(), current_buffer_id, 0, cursor_row) do
    table.insert(ts_nodes, 1, ts_node)
  end

  for i = 1, #ts_nodes do
    local ts_range = { ts_nodes[i]:range() }
    local row_start = ts_range[1] + 1
    local col_start = ts_range[2]

    if row_start < cursor_row or (row_start == cursor_row and col_start < cursor_col) then
      api.nvim_win_set_cursor(0, { row_start, col_start })
      break
    end
  end
end

local namespace_id = api.nvim_create_namespace('TreesitterObjectHighlight')

local function show_textobject_labels()
  api.nvim_buf_clear_namespace(0, label_ns_id, 0, -1)

  if api.nvim_get_mode().mode ~= 'n' then
    return
  end

  local bufnr = api.nvim_get_current_buf()
  local cursor_row = api.nvim_win_get_cursor(0)[1] - 1

  local success, parser = pcall(ts.get_parser, bufnr)
  if not success then
    return
  end

  local lang = parser:lang()
  local query = ts.query.get(lang, 'textobjects')
  if not query then
    return
  end

  local tree = parser:tree_for_range({ cursor_row, 0, cursor_row, -1 })
  if not tree then
    return
  end

  local used_cols = {}
  for id, node in query:iter_captures(tree:root(), bufnr, cursor_row, cursor_row + 1) do
    local name = query.captures[id]
    local key = label_map[name]
    if key then
      local start_row, start_col = node:range()
      if start_row == cursor_row and not used_cols[start_col] then
        used_cols[start_col] = true
        api.nvim_buf_set_extmark(bufnr, label_ns_id, start_row, start_col, {
          virt_text = { { key, 'SpecialChar' } },
          virt_text_pos = 'overlay',
          hl_mode = 'combine',
          priority = 100,
        })
      end
    end
  end
end

local function highlight_treesitter_node()
  api.nvim_buf_clear_namespace(0, namespace_id, 0, -1)

  if api.nvim_get_mode().mode ~= 'n' then
    show_textobject_labels()
    return
  end

  local ts_node = ts.get_node({ ignore_injections = false })
  if not ts_node then
    show_textobject_labels()
    return
  end

  local start_row, start_col, end_row, end_col = ts_node:range()

  api.nvim_buf_set_extmark(0, namespace_id, start_row, start_col, {
    end_row = end_row,
    end_col = end_col,
    hl_group = 'TreesitterObjectHighlight',
  })

  show_textobject_labels()
end

api.nvim_create_autocmd({ 'CursorMoved', 'ModeChanged' }, {
  group = api.nvim_create_augroup('TreesitterObjectHighlight', { clear = true }),
  callback = highlight_treesitter_node,
})

return M
