local vim = vim

return {
  'akinsho/bufferline.nvim',

  dependencies = 'nvim-tree/nvim-web-devicons',

  init = function()
    vim.api.nvim_create_augroup('bufferline', { clear = true })
    vim.api.nvim_create_autocmd('ColorScheme', {
      group = 'bufferline',
      pattern = '*',
      callback = function()
        vim.api.nvim_set_hl(0, 'BufferLineBackground', { fg = '#7a7c9e' })
        vim.api.nvim_set_hl(0, 'BufferLineBufferSelected', { fg = 'white', bg = 'none' })
        vim.api.nvim_set_hl(0, 'BufferLineNumbers', { fg = '#7a7c9e', bg = 'none', italic = false })
        vim.api.nvim_set_hl(0, 'BufferLineNumbersSelected', { fg = 'white', bg = 'none', italic = false })
        vim.api.nvim_set_hl(0, 'BufferLineDuplicate', { fg = '#7a7c9e', bg = 'none', italic = false })
        vim.api.nvim_set_hl(0, 'BufferLineDuplicateSelected', { fg = 'white', bg = 'none', italic = false })
        vim.api.nvim_set_hl(0, 'BufferLineTab', { fg = '#7a7c9e', bg = 'none' })
        vim.api.nvim_set_hl(0, 'BufferLineTabSelected', { fg = 'white', bg = 'none' })
        vim.api.nvim_set_hl(0, 'BufferLineTabSeparator', { fg = 'black', bg = 'none' })
        vim.api.nvim_set_hl(0, 'BufferLineTabSeparatorSelected', { fg = 'black', bg = 'none' })
      end,
    })
  end,

  config = function()
    -- vim.keymap.set('n', '<C-t>', '<cmd>silent enew<CR>')
    -- vim.keymap.set('n', 'q',     '<cmd>silent bwipeout!<CR>')
    -- vim.keymap.set('n', '<C-w>', '<cmd>silent bwipeout!<CR>')

    -- vim.keymap.set("n", "<Tab>", "<cmd>bnext<CR>", { silent = true, })
    -- vim.keymap.set("n", "<S-Tab>", "<cmd>bprevious<CR>", { silent = true, })

    -- vim.keymap.set({ 'n', 'x', }, '<C-P>', '<cmd>BufferLineTogglePin<CR>', { silent = true, })
    vim.keymap.set({ 'n', 'x' }, '<tab>', '<cmd>BufferLineCycleNext<CR>', { silent = true })
    vim.keymap.set({ 'n', 'x' }, '<S-tab>', '<cmd>BufferLineCyclePrev<CR>', { silent = true })
    -- vim.keymap.set({ 'n', 'x', }, '<PageDown>', '<cmd>BufferLineCycleNext<CR>', { silent = true, })
    -- vim.keymap.set({ 'n', 'x', }, '<PageUp>', '<cmd>BufferLineCyclePrev<CR>', { silent = true, })
    vim.keymap.set({ 'n', 'x' }, '<S-PageDown>', '<cmd>BufferLineMoveNext<CR>', { silent = true })
    vim.keymap.set({ 'n', 'x' }, '<S-PageUp>', '<cmd>BufferLineMovePrev<CR>', { silent = true })

    vim.keymap.set({ 'n', 't', 'x' }, '1', function()
      require('bufferline').go_to_buffer(1)
    end)
    vim.keymap.set({ 'n', 't', 'x' }, '2', function()
      require('bufferline').go_to_buffer(2)
    end)
    vim.keymap.set({ 'n', 't', 'x' }, '3', function()
      require('bufferline').go_to_buffer(3)
    end)
    vim.keymap.set({ 'n', 't', 'x' }, '4', function()
      require('bufferline').go_to_buffer(4)
    end)
    vim.keymap.set({ 'n', 't', 'x' }, '5', function()
      require('bufferline').go_to_buffer(5)
    end)
    vim.keymap.set({ 'n', 't', 'x' }, '6', function()
      require('bufferline').go_to_buffer(6)
    end)
    vim.keymap.set({ 'n', 't', 'x' }, '7', function()
      require('bufferline').go_to_buffer(7)
    end)
    vim.keymap.set({ 'n', 't', 'x' }, '8', function()
      require('bufferline').go_to_buffer(8)
    end)
    vim.keymap.set({ 'n', 't', 'x' }, '9', function()
      require('bufferline').go_to_buffer(-1)
    end)

    require('bufferline').setup({
      -- No backgrounds: bufferline shades its own from nightfly's Normal (icons, the close-button cell, buffers
      -- visible in other windows, the fill). The icon groups are generated per filetype from these tables, out of
      -- reach of the overrides in init, and a bg-only override there is empty, so bufferline replaces it.
      highlights = function(defaults)
        local hls = {}
        for name in pairs(defaults.highlights) do
          hls[name] = { bg = 'NONE' }
        end
        return hls
      end,
      options = {
        numbers = function(opts)
          return string.format('%s', opts.id)
        end,
        indicator = { style = 'none' },
        separator_style = { '', '' },
        tab_size = 0,
        buffer_close_icon = '',
        modified_icon = '',
        close_icon = '',
        groups = {
          items = {
            require('bufferline.groups').builtin.pinned:with({ icon = '' }),
          },
        },
        -- A click on a buffer from a panel holding its own ('winfixbuf': the file tree, the
        -- references panel, gl's list) shows it in a code window (a file's, or gl's diff of
        -- one: myplugins/gl.nvim), the one left last if it's one
        left_mouse_command = function(buffer)
          if vim.wo.winfixbuf then
            local wins = vim.api.nvim_tabpage_list_wins(0)
            table.insert(wins, 1, vim.fn.win_getid(vim.fn.winnr('#')))
            for _, win in ipairs(wins) do
              local b = win ~= 0 and vim.api.nvim_win_get_buf(win)
              if
                b
                and not vim.wo[win].winfixbuf
                and (vim.bo[b].buftype == '' or vim.b[b].gl)
                and vim.api.nvim_win_get_config(win).relative == ''
              then
                vim.api.nvim_set_current_win(win)
                break
              end
            end
          end
          vim.cmd.buffer(buffer)
        end,
        -- Over the file tree (myplugins/filetree.nvim), the directory it shows
        offsets = {
          {
            filetype = 'filetree',
            text = function()
              return require('filetree').title()
            end,
            text_align = 'left',
            highlight = 'FileTreeTitle',
            separator = true,
          },
        },
      },
    })

    -- In the file tree (myplugins/filetree.nvim), the file under its cursor, open as a buffer,
    -- has its tab as the current buffer's (white)
    local Buffer = require('bufferline.models').Buffer
    local current = Buffer.current
    function Buffer:current()
      if vim.bo.filetype == 'filetree' then
        return require('filetree').cursor_buffer() == self.id
      end
      return current(self)
    end
  end,
}
