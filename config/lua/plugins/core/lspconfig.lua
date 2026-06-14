local vim = vim

return {
  'neovim/nvim-lspconfig',

  dependencies = { 'hrsh7th/cmp-nvim-lsp' },

  enabled = true,

  config = function()
    local function on_attach_server(dfp)
      return function(client, buffer)
        client.server_capabilities.documentFormattingProvider = dfp
        client.server_capabilities.semanticTokensProvider = nil

        vim.keymap.set('n', 'gh', '<cmd>lua vim.lsp.buf.hover()<cr>', { buffer = buffer })
        vim.keymap.set('n', 'gd', '<cmd>lua vim.lsp.buf.definition()<cr>', { buffer = buffer })
        vim.keymap.set('n', 'gD', '<cmd>lua vim.lsp.buf.declaration()<cr>', { buffer = buffer })
        vim.keymap.set('n', 'gi', '<cmd>lua vim.lsp.buf.implementation()<cr>', { buffer = buffer })
        vim.keymap.set('n', 'gt', '<cmd>lua vim.lsp.buf.type_definition()<cr>', { buffer = buffer })
        vim.keymap.set('n', 'gf', '<cmd>lua vim.lsp.buf.references()<cr>', { buffer = buffer })
        vim.keymap.set('n', 'gS', '<cmd>lua vim.lsp.buf.signature_help()<cr>', { buffer = buffer })
        vim.keymap.set('n', 'gr', '<cmd>lua vim.lsp.buf.rename()<cr>', { buffer = buffer })
        -- vim.keymap.set({'n', 'x'}, '<F3>', '<cmd>lua vim.lsp.buf.format({async = true})<cr>', { buffer = buffer, })
        -- vim.keymap.set('n', '<F4>', '<cmd>lua vim.lsp.buf.code_action()<cr>', { buffer = buffer, })

        -- vim.keymap.set('n', 'gd', function()
        --   if not vim.lsp.buf.definition() then vim.lsp.buf.declaration() end
        -- end, { buffer = buffer, })

        -- vim.keymap.set('n', 'gr', vim.lsp.buf.references, { buffer = buffer, })

        -- vim.keymap.set('n', '<Leader>f', vim.lsp.buf.format, { buffer = buffer, })

        -- vim.keymap.set('n', '<leader>r', function() lsp.buf.rename(vim.fn.input('New Name: ')) end, { buffer = buffer })
        -- vim.keymap.set("n", '<ScrollWheelUp>', diagnostic.goto_prev, { buffer = buffer })
        -- vim.keymap.set("n", '<ScrollWheelDown>', diagnostic.goto_next, { buffer = buffer })

        -- vim.keymap.set('n', '<PageUp>', function() return vim.diagnostic.goto_prev({ float = { max_width = 50, }, }) end,
        -- { buffer = buffer, })

        -- vim.keymap.set('n', '<PageUp>',   vim.diagnostic.goto_prev, { buffer = buffer, })
        -- vim.keymap.set('n', '<PageDown>', vim.diagnostic.goto_next, { buffer = buffer, })

        -- vim.keymap.set('n', '<Leader>x', vim.diagnostic.setqflist,
        -- { noremap = true, silent = true, })

        -- vim.keymap.set('n', '<Leader>l', diagnostic.setloclist, { noremap = true, silent = true })
        -- lsp.buf.formatting_seq_sync(nil, 6000, { 'ts_ls', 'html', 'cssls', 'vuels', 'eslint' })
        -- lsp.buf.formatting_seq_sync
      end
    end

    local cmp_exists, cmp_nvim_lsp = pcall(require, 'cmp_nvim_lsp')

    local function safe_root_dir(markers)
      return function(fname)
        local root = vim.fs.root(fname, markers)
        if type(root) == 'table' then
          return root[1]
        end
        return root
      end
    end

    local function set_config(override_opts)
      local default_opts = {
        capabilities = cmp_exists and cmp_nvim_lsp.default_capabilities() or {}, -- hrsh7th/nvim-cmp
        on_attach = on_attach_server(true),
        flags = { debounce_text_changes = 0 },
      }
      return vim.tbl_deep_extend('force', default_opts, override_opts or {})
    end

    vim.lsp.config('lua_ls', set_config())
    vim.lsp.enable('lua_ls')
    vim.lsp.config('yamlls', set_config())
    vim.lsp.enable('yamlls')
    vim.lsp.config('ccls', set_config())
    vim.lsp.enable('ccls')
    vim.lsp.config(
      'eslint',
      set_config({
        root_dir = safe_root_dir({
          'package.json',
          '.eslintrc',
          '.eslintrc.js',
          '.eslintrc.json',
          '.eslintrc.yaml',
          '.eslintrc.yml',
        }),
      })
    )
    vim.lsp.enable('eslint')
    vim.lsp.config('jsonls', set_config())
    vim.lsp.enable('jsonls')
    vim.lsp.config(
      'gopls',
      set_config({
        settings = {
          gopls = {
            gofumpt = true,
          },
        },
      })
    )
    vim.lsp.enable('gopls')
    vim.lsp.config('rust_analyzer', set_config())
    vim.lsp.enable('rust_analyzer')
    vim.lsp.config('marksman', set_config())
    vim.lsp.enable('marksman')
    vim.lsp.config('terraformls', set_config())
    vim.lsp.enable('terraformls')
    vim.lsp.config('taplo', set_config())
    vim.lsp.enable('taplo')
    vim.lsp.config('jsonnet_ls', set_config())
    vim.lsp.enable('jsonnet_ls')
    vim.lsp.config('bashls', set_config({ filetypes = { 'sh', 'zsh' } }))
    vim.lsp.enable('bashls')
    vim.lsp.config('cssls', set_config())
    vim.lsp.enable('cssls')
    vim.lsp.config('vue_ls', set_config({ on_attach = on_attach_server(false) }))
    vim.lsp.enable('vue_ls')
    vim.lsp.config('pyright', set_config())
    vim.lsp.enable('pyright')
    -- vim.lsp.config('harper_ls', set_config({ filetypes = { 'markdown', }, }))
    -- vim.lsp.enable('harper_ls')

    vim.lsp.config(
      'ts_ls',
      set_config({
        on_attach = on_attach_server(false),
        autostart = true,
        root_dir = safe_root_dir({ 'package.json', 'tsconfig.json', 'jsconfig.json' }),
      })
    )
    vim.lsp.enable('ts_ls')

    vim.lsp.config(
      'nil_ls',
      set_config({
        settings = {
          ['nil'] = {
            formatting = {
              -- command = { 'alejandra', },
              command = { 'nixfmt' },
            },
          },
        },
      })
    )
    vim.lsp.enable('nil_ls')

    -------------------- https://github.com/neovim/nvim-lspconfig/wiki/UI-customization
    vim.diagnostic.config({
      signs = false,

      update_in_insert = false,

      virtual_text = {
        prefix = '',
        spacing = 2,
      },

      float = {
        border = {
          { '', 'FloatBorder' },
          { '', 'FloatBorder' },
          { '', 'FloatBorder' },
          { ' ', 'FloatBorder' },
          { ' ', 'FloatBorder' },
          { ' ', 'FloatBorder' },
          { ' ', 'FloatBorder' },
          { ' ', 'FloatBorder' },
        },

        max_width = 80,
        header = '',
        prefix = '',
        suffix = '',

        format = function(diag)
          local code = diag.user_data and diag.user_data.lsp and diag.user_data.lsp.code or ''
          return string.format('%s %s\n    %s', diag.source or '', code, diag.message)
        end,
      },
    })
  end,
}
