local vim = vim

local function apply()
  -- #0a172e #10141f #012749 #1a1a3b #1e2633 #262e3b #424a57 #7a7c9e #222b66

  vim.api.nvim_set_hl(0, 'TreesitterObjectHighlight', { bg = '#161d29' })

  vim.api.nvim_set_hl(
    0,
    'function',
    vim.tbl_extend(
      'force',
      vim.api.nvim_get_hl(0, { name = vim.api.nvim_get_hl(0, { name = 'function' }).link }),
      { italic = true }
    )
  )

  vim.api.nvim_set_hl(
    0,
    'keyword',
    vim.tbl_extend(
      'force',
      vim.api.nvim_get_hl(0, { name = vim.api.nvim_get_hl(0, { name = 'keyword' }).link }),
      { italic = true, bold = true }
    )
  )

  vim.api.nvim_set_hl(
    0,
    'string',
    vim.tbl_extend(
      'force',
      vim.api.nvim_get_hl(0, { name = vim.api.nvim_get_hl(0, { name = 'string' }).link }),
      { italic = true }
    )
  )

  vim.api.nvim_set_hl(0, 'normalfloat', { bg = '#1e2633' })
  vim.api.nvim_set_hl(0, 'floatborder', { bg = 'none', fg = '#1e2633' })
  vim.api.nvim_set_hl(0, 'tablinefill', { bg = 'none' })

  vim.api.nvim_set_hl(0, 'pmenu', { bg = 'black', fg = '#7a7c9e' })
  vim.api.nvim_set_hl(0, 'pmenusel', { bg = '#1e2633', fg = 'white' })
  vim.api.nvim_set_hl(0, 'pmenusbar', { bg = 'black' })
  vim.api.nvim_set_hl(0, 'pmenuthumb', { bg = '#1e2633' })

  vim.api.nvim_set_hl(0, 'linenr', { bg = 'none', fg = '#4b586e' })
  vim.api.nvim_set_hl(0, 'cursorlinenr', { bg = 'none', fg = 'white' })
  vim.api.nvim_set_hl(0, 'cursorline', { bg = 'none' })
  vim.api.nvim_set_hl(0, 'cursorcolumn', { bg = '#1e2633' })
  vim.api.nvim_set_hl(0, 'virtcolumn', { bg = 'none', fg = '#424a57' })

  vim.api.nvim_set_hl(0, 'search', { bg = '#5d00ff' })
  vim.api.nvim_set_hl(0, 'CurSearch', { bg = '#5d00ff' })
  vim.api.nvim_set_hl(0, 'incsearch', { bg = '#faff00', fg = 'black' })
  vim.api.nvim_set_hl(0, 'normal', { bg = 'none' })
  vim.api.nvim_set_hl(0, 'visual', { bg = '#012749' })

  vim.api.nvim_set_hl(0, 'signcolumn', { bg = 'none' })
  vim.api.nvim_set_hl(0, 'foldcolumn', { bg = 'none' })
  vim.api.nvim_set_hl(0, 'folded', { bg = 'none' })

  vim.api.nvim_set_hl(0, 'nontext', { bg = 'none', fg = '#384354' })
  vim.api.nvim_set_hl(0, 'whitespace', { bg = 'none', fg = '#384354' })

  vim.api.nvim_set_hl(0, 'VertSplit', { bg = 'none', fg = '#1e2633' })
  vim.api.nvim_set_hl(0, 'StatusLine', { bg = 'none', fg = 'none' })
  vim.api.nvim_set_hl(0, 'StatusLineNc', { bg = 'none', fg = 'none' })

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
