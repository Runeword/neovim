local api = vim.api
local ts = vim.treesitter

local M = {}

local config = {
  hl_label_start = { bg = '#5d00ff' },
  hl_label_end = { fg = '#000000', bg = '#00ff9f' },
  hl_node = { link = 'Visual' },
}

local label_map_cache
local function get_label_map()
  if label_map_cache then
    return label_map_cache
  end
  local ok, configs = pcall(require, 'nvim-treesitter.configs')
  if not ok then
    return {}
  end
  local ts_textobjects = configs.get_module('textobjects.select')
  if not ts_textobjects or not ts_textobjects.keymaps then
    return {}
  end
  local map = {}
  for key, capture in pairs(ts_textobjects.keymaps) do
    if #key == 1 then
      local name = capture:gsub('^@', '')
      map[name] = key
    end
  end
  label_map_cache = map
  return map
end

local label_ns_id = api.nvim_create_namespace('TreesitterTextobjectLabels')
local namespace_id = api.nvim_create_namespace('TreesitterObjectHighlight')

local function apply_highlights()
  api.nvim_set_hl(0, 'GraspLabelStart', config.hl_label_start)
  api.nvim_set_hl(0, 'GraspLabelEnd', config.hl_label_end)
  api.nvim_set_hl(0, 'TreesitterObjectHighlight', vim.tbl_extend('keep', config.hl_node, { default = true }))
end

function M.select_treesitter_node_under_cursor()
  local current_buffer_id = api.nvim_get_current_buf()

  local cursor_pos = api.nvim_win_get_cursor(0)
  local cursor_row = cursor_pos[1] - 1
  local cursor_col = cursor_pos[2]

  local success, ts_parser = pcall(ts.get_parser, current_buffer_id)
  if not success or not ts_parser then
    return
  end

  local ts_tree = ts_parser:tree_for_range({ cursor_row, cursor_col, cursor_row, cursor_col })
  if not ts_tree then
    return
  end

  local ts_node = ts_tree:root():named_descendant_for_range(cursor_row, cursor_col, cursor_row, cursor_col)
  if not ts_node then
    return
  end

  local start_row, start_col, end_row, end_col = ts_node:range()

  if end_col == 0 and end_row > start_row then
    end_row = end_row - 1
    end_col = #(api.nvim_buf_get_lines(current_buffer_id, end_row, end_row + 1, false)[1] or '')
  end

  api.nvim_buf_set_mark(current_buffer_id, '<', start_row + 1, start_col, {})
  api.nvim_buf_set_mark(current_buffer_id, '>', end_row + 1, math.max(end_col - 1, 0), {})

  api.nvim_command('normal! gv')
end

function M.move_to_next_treesitter_node()
  local current_buffer_id = api.nvim_get_current_buf()
  local current_buffer_filetype = api.nvim_get_option_value('filetype', { buf = current_buffer_id })

  local success, ts_parser = pcall(ts.get_parser, current_buffer_id)
  if not success or not ts_parser then
    return
  end

  local trees = ts_parser:parse()
  local ts_tree = trees and trees[1]
  if not ts_tree then
    return
  end

  local ts_lang = ts.language.get_lang(current_buffer_filetype)
  if not ts_lang then
    return
  end
  local ok, ts_query = pcall(ts.query.parse, ts_lang, '(_) @node')
  if not ok then
    return
  end

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
  if not success or not ts_parser then
    return
  end

  local trees = ts_parser:parse()
  local ts_tree = trees and trees[1]
  if not ts_tree then
    return
  end

  local ts_lang = ts.language.get_lang(current_buffer_filetype)
  if not ts_lang then
    return
  end
  local ok, ts_query = pcall(ts.query.parse, ts_lang, '(_) @node')
  if not ok then
    return
  end

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

local function show_textobject_labels()
  api.nvim_buf_clear_namespace(0, label_ns_id, 0, -1)

  local mode = api.nvim_get_mode().mode
  if mode ~= 'n' and mode ~= 'v' and mode ~= 'V' and mode ~= '\22' then
    return
  end

  local bufnr = api.nvim_get_current_buf()
  local cursor_row = api.nvim_win_get_cursor(0)[1] - 1

  local success, parser = pcall(ts.get_parser, bufnr)
  if not success or not parser then
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

  local used_positions = {}
  for id, node in query:iter_captures(tree:root(), bufnr, cursor_row, cursor_row + 1) do
    local name = query.captures[id]
    local key = get_label_map()[name]
    if key then
      local start_row, start_col, end_row, end_col = node:range()
      local contains_cursor = start_row <= cursor_row
        and (end_row > cursor_row or (end_row == cursor_row and end_col > 0))
      if contains_cursor then
        local label_col = math.max(start_col - 1, 0)
        local pos_key = start_row .. ':' .. label_col
        if not used_positions[pos_key] then
          used_positions[pos_key] = true
          api.nvim_buf_set_extmark(bufnr, label_ns_id, start_row, label_col, {
            virt_text = { { key, 'GraspLabelStart' } },
            virt_text_pos = 'overlay',
            hl_mode = 'replace',
            priority = 100,
          })
        end

        local end_pos_key = end_row .. ':' .. end_col
        if not used_positions[end_pos_key] then
          used_positions[end_pos_key] = true
          api.nvim_buf_set_extmark(bufnr, label_ns_id, end_row, end_col, {
            virt_text = { { key, 'GraspLabelEnd' } },
            virt_text_pos = 'overlay',
            hl_mode = 'replace',
            priority = 100,
          })
        end
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

function M.setup(opts)
  config = vim.tbl_extend('force', config, opts or {})

  apply_highlights()

  local group = api.nvim_create_augroup('grasp', { clear = true })
  api.nvim_create_autocmd({ 'CursorMoved', 'ModeChanged' }, {
    group = group,
    callback = highlight_treesitter_node,
  })
  api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = apply_highlights,
  })
end

return M
