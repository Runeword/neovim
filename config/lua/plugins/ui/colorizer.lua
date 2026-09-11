return {
  'catgoose/nvim-colorizer.lua',
  event = { 'BufReadPre', 'BufNewFile' },

  config = function()
    require('colorizer').setup({
      filetypes = {
        'css',
        'scss',
        'sass',
        'less',
        'stylus',
        'html',
        'javascript',
        'javascriptreact',
        'typescript',
        'typescriptreact',
        'vue',
        'svelte',
        'lua',
        'json',
        'jsonc',
        'yaml',
        'toml',
        'conf',
      },
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
