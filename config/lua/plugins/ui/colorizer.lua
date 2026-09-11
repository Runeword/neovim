return {
  'catgoose/nvim-colorizer.lua',
  event = { 'BufReadPre', 'BufNewFile' },

  config = function()
    require('colorizer').setup({
      filetypes = { '*' },
      lazy_load = true,
      user_default_options = {
        mode = 'virtualtext',
        virtualtext = '██',
        virtualtext_inline = true,
        names = false,
        tailwind = false,
      },
    })
  end,
}
