local vim = vim

return {
  'echasnovski/mini.align',

  version = false,

  event = 'VeryLazy',

  config = function()
    require('mini.align').setup({
      mappings = {
        start = 'gl',
        start_with_preview = '',
      },
    })
  end,
}
