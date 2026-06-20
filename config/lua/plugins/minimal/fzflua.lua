local vim = vim

return {
  'ibhagwan/fzf-lua',
  enabled = true,

  keys = {
    {
      '<Leader><Tab>',
      function()
        require('fzf-lua').files()
      end,
      desc = 'fzf: files',
    },
    {
      '<Leader><CR>',
      function()
        require('fzf-lua').live_grep_resume()
      end,
      desc = 'fzf: live grep',
    },
    {
      '<Leader>h',
      function()
        require('fzf-lua').help_tags()
      end,
      desc = 'fzf: help tags',
    },
    {
      '<Leader>k',
      function()
        require('fzf-lua').keymaps()
      end,
      desc = 'fzf: keymaps',
    },
    {
      '<Leader>i',
      function()
        require('fzf-lua').highlights()
      end,
      desc = 'fzf: highlights',
    },
    {
      '<leader>a',
      mode = { 'n', 'x' },
      function()
        require('fzf-lua').lsp_code_actions({
          winopts = {
            relative = 'cursor',
            width = 0.6,
            height = 0.6,
            row = 1,
            preview = { vertical = 'up:70%' },
          },
        })
      end,
      desc = 'fzf: code actions',
    },
    -- { '<Leader>x', function() require('fzf-lua').quickfix({ multiprocess = true }) end, },
  },

  config = function()
    local actions = require('fzf-lua.actions')

    require('fzf-lua').setup({
      -- 'fzf-native',
      winopts = {
        fullscreen = false,
        border = 'single',
        preview = {
          layout = 'horizontal',
          horizontal = 'up:70%',
          title = false,
          delay = 0,
          scrollchars = { '▎', '' },
        },
      },

      fzf_opts = {
        ['--no-separator'] = true,
      },

      keymap = {
        builtin = {},
        fzf = {
          -- ["tab"] = "down",
          -- ["btab"] = "up",
          ['ctrl-e'] = 'preview-page-down',
          ['ctrl-u'] = 'preview-page-up',
        },
      },

      lsp = {
        code_actions = {
          previewer = 'codeaction_native',
          preview_pager = "delta --side-by-side --width=$FZF_PREVIEW_COLUMNS --hunk-header-style='omit' --file-style='omit'",
        },
      },

      actions = {
        files = {
          ['default'] = actions.file_edit,
        },
        buffers = {
          ['default'] = actions.buf_edit,
        },
      },
    })
  end,
}
