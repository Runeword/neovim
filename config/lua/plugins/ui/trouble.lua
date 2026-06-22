return {
  'folke/trouble.nvim',
  dependencies = { 'nvim-tree/nvim-web-devicons' },
  cmd = 'Trouble',
  opts = {
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
