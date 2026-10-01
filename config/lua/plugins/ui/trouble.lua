-- Trouble lists (`gf`: the references of the symbol under the cursor). The references
-- panel that follows the cursor (`gF`, the <Left>/<Right> hops) is refs.nvim's: see
-- plugins/ui/refs.lua.
return {
  'folke/trouble.nvim',
  dependencies = { 'nvim-tree/nvim-web-devicons' },
  cmd = 'Trouble',
  opts = {
    keys = {
      ['<esc>'] = 'close',
      -- One item at a time (j/k would otherwise do this config's 4-line jump)
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
}
