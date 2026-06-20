local vim = vim

local function apply()
  -- #0a172e #10141f #012749 #1a1a3b #1e2633 #262e3b #424a57 #7a7c9e #222b66

  vim.api.nvim_set_hl(0, 'TreesitterObjectHighlight', { bg = '#161d29' })

  -- Add attributes to a group while keeping its resolved colours. link = false
  -- resolves through any link, so this works whether the group is a link or has
  -- direct attributes. The old nested get_hl(...).link form broke when a group
  -- had no link (name = nil then returned every highlight).
  local function add_attrs(group, attrs)
    local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
    vim.api.nvim_set_hl(0, group, vim.tbl_extend('force', hl, attrs))
  end

  -- @function.*/@string link to these base groups in nightfly, so italicising
  -- the base group reaches the treesitter captures.
  add_attrs('Function', { italic = true })
  add_attrs('Keyword', { italic = true, bold = true })
  add_attrs('String', { italic = true })

  vim.api.nvim_set_hl(0, 'NormalFloat', { bg = '#1e2633' })
  vim.api.nvim_set_hl(0, 'FloatBorder', { bg = 'none', fg = '#1e2633' })
  -- Pure-transparent groups link to Normal instead of bg = 'none': a none-only
  -- highlight is stored as empty, so a plugin defining it later with
  -- default = true would clobber it. A real link survives that.
  vim.api.nvim_set_hl(0, 'TablineFill', { link = 'Normal' })

  vim.api.nvim_set_hl(0, 'Pmenu', { bg = 'black', fg = '#7a7c9e' })
  vim.api.nvim_set_hl(0, 'PmenuSel', { bg = '#1e2633', fg = 'white' })
  vim.api.nvim_set_hl(0, 'PmenuSbar', { bg = 'black' })
  vim.api.nvim_set_hl(0, 'PmenuThumb', { bg = '#1e2633' })

  vim.api.nvim_set_hl(0, 'LineNr', { bg = 'none', fg = '#4b586e' })
  vim.api.nvim_set_hl(0, 'CursorLineNr', { bg = 'none', fg = 'white' })
  vim.api.nvim_set_hl(0, 'CursorLine', { link = 'Normal' })
  vim.api.nvim_set_hl(0, 'CursorColumn', { bg = '#1e2633' })
  vim.api.nvim_set_hl(0, 'VirtColumn', { bg = 'none', fg = '#424a57' })

  vim.api.nvim_set_hl(0, 'Search', { bg = '#5d00ff' })
  vim.api.nvim_set_hl(0, 'CurSearch', { bg = '#5d00ff' })
  vim.api.nvim_set_hl(0, 'IncSearch', { bg = '#faff00', fg = 'black' })
  vim.api.nvim_set_hl(0, 'Normal', { bg = 'none' })
  vim.api.nvim_set_hl(0, 'Visual', { bg = '#012749' })

  vim.api.nvim_set_hl(0, 'SignColumn', { link = 'Normal' })
  vim.api.nvim_set_hl(0, 'FoldColumn', { link = 'Normal' })
  vim.api.nvim_set_hl(0, 'Folded', { link = 'Normal' })

  vim.api.nvim_set_hl(0, 'NonText', { bg = 'none', fg = '#384354' })
  vim.api.nvim_set_hl(0, 'Whitespace', { bg = 'none', fg = '#384354' })

  vim.api.nvim_set_hl(0, 'VertSplit', { bg = 'none', fg = '#1e2633' })
  vim.api.nvim_set_hl(0, 'StatusLine', { bg = 'none', fg = 'none' })
  vim.api.nvim_set_hl(0, 'StatusLineNC', { bg = 'none', fg = 'none' })

  vim.api.nvim_set_hl(0, 'Error', { bg = 'none', fg = '#cf4e84' })
  vim.api.nvim_set_hl(0, 'ErrorMsg', { bg = 'none', fg = '#cf4e84' })
  vim.api.nvim_set_hl(0, 'Warning', { bg = 'none', fg = '#ab6d46' })
  vim.api.nvim_set_hl(0, 'WarningMsg', { bg = 'none', fg = '#ab6d46' })
  vim.api.nvim_set_hl(0, 'MsgArea', { bg = 'none', fg = '#cccccc' })

  vim.api.nvim_set_hl(0, 'DiagnosticError', { bg = 'NONE', fg = '#cf4e84', bold = false, italic = true })
  vim.api.nvim_set_hl(0, 'DiagnosticVirtualTextError', { bg = 'NONE', fg = '#cf4e84', bold = false, italic = true })
  vim.api.nvim_set_hl(0, 'DiagnosticUnderlineError', { bg = 'NONE', undercurl = true, sp = '#cf4e84' })
  vim.api.nvim_set_hl(0, 'DiagnosticWarn', { bg = 'NONE', fg = '#ff9d57', bold = false, italic = true })
  vim.api.nvim_set_hl(0, 'DiagnosticVirtualTextWarn', { bg = 'NONE', fg = '#ff9d57', bold = false, italic = true })
  vim.api.nvim_set_hl(0, 'DiagnosticUnderlineWarn', { bg = 'NONE', undercurl = true, sp = '#ff9d57' })
  vim.api.nvim_set_hl(0, 'DiagnosticInfo', { bg = 'NONE', fg = '#a6c8ff', bold = false, italic = true })
  vim.api.nvim_set_hl(0, 'DiagnosticVirtualTextInfo', { bg = 'NONE', fg = '#a6c8ff', bold = false, italic = true })
  vim.api.nvim_set_hl(0, 'DiagnosticUnderlineInfo', { bg = 'NONE', undercurl = true, sp = '#a6c8ff' })
  vim.api.nvim_set_hl(0, 'DiagnosticHint', { bg = 'NONE', fg = '#adb5bd', bold = false, italic = true })
  vim.api.nvim_set_hl(0, 'DiagnosticVirtualTextHint', { bg = 'NONE', fg = '#adb5bd', bold = false, italic = true })
  vim.api.nvim_set_hl(0, 'DiagnosticUnderlineHint', { bg = 'NONE', undercurl = true, sp = '#adb5bd' })
  vim.api.nvim_set_hl(0, 'DiagnosticUnnecessary', { bg = 'NONE', undercurl = true, sp = '#adb5bd' })

  vim.api.nvim_set_hl(0, 'MiniIndentscopeSymbol', { bg = 'none', fg = '#222b66' })
  vim.api.nvim_set_hl(0, 'MiniIndentscopeSymbolOff', { bg = 'none', fg = '#222b66' })

  vim.api.nvim_set_hl(0, 'TroubleNormal', { link = 'Normal' })
  vim.api.nvim_set_hl(0, 'TroubleNormalNC', { link = 'Normal' })
  vim.api.nvim_set_hl(0, 'TroubleCursorLine', { bg = '#1e2633' })

  vim.api.nvim_set_hl(0, 'NotifyERRORBorder', { link = 'FloatBorder' })
  vim.api.nvim_set_hl(0, 'NotifyWARNBorder', { link = 'FloatBorder' })
  vim.api.nvim_set_hl(0, 'NotifyINFOBorder', { link = 'FloatBorder' })
  vim.api.nvim_set_hl(0, 'NotifyDEBUGBorder', { link = 'FloatBorder' })
  vim.api.nvim_set_hl(0, 'NotifyTRACEBorder', { link = 'FloatBorder' })
end

vim.api.nvim_create_augroup('colors', { clear = true })
vim.api.nvim_create_autocmd('ColorScheme', {
  group = 'colors',
  pattern = '*',
  callback = apply,
})

-- after/plugin/ runs after lazy.setup() returns, by which point the
-- priority=1000 colorscheme has already fired ColorScheme. Apply once now
-- so the highlights land on the current scheme.
if vim.g.colors_name then
  apply()
end
