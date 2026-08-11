return {
  'folke/trouble.nvim',
  dependencies = { 'nvim-tree/nvim-web-devicons' },
  cmd = 'Trouble',
  keys = {
    { 'gF', '<cmd>Trouble refs_follow toggle<cr>', desc = 'References panel (follows cursor)' },
  },
  opts = {
    modes = {
      -- Persistent right-hand split that re-runs `textDocument/references`
      -- for whatever symbol the cursor rests on (refreshes on CursorHold).
      refs_follow = {
        mode = 'lsp_references',
        auto_refresh = true, -- re-fetch as the cursor moves in the code window
        auto_jump = false, -- don't teleport when a symbol has a single reference
        focus = false, -- keep the cursor in the code, let the panel follow
        warn_no_results = false, -- stay quiet when the cursor isn't on a symbol
        open_no_results = true, -- toggle open even before landing on a symbol
        win = { type = 'split', position = 'right', size = 0.35 },
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
