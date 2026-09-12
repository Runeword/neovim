local vim = vim

return {
  'lewis6991/gitsigns.nvim',
  enabled = true,

  event = { 'BufReadPre', 'BufNewFile' },

  config = function()
    require('gitsigns').setup({

      signs_staged_enable = true,
      word_diff = false,
      linehl = false,
      current_line_blame = true,
      current_line_blame_opts = { delay = 200 },
      current_line_blame_formatter = ' <abbrev_sha> · <author>, <author_time:%Y-%m-%d %H:%M> (<author_time:%R>) · <summary> ',

      on_attach = function(buffer)
        local gs = package.loaded.gitsigns

        vim.keymap.set({ 'n', 'x' }, '<leader>ga', gs.stage_buffer, { buffer = buffer, desc = 'git add file' })
        vim.keymap.set({ 'n', 'x' }, '<leader>gr', gs.reset_buffer_index, { buffer = buffer, desc = 'git reset file' })
        vim.keymap.set({ 'n', 'x' }, '<leader>gc', gs.reset_buffer, { buffer = buffer, desc = 'git checkout -- file' })
        vim.keymap.set(
          { 'n', 'x' },
          '<leader>gb',
          gs.toggle_current_line_blame,
          { buffer = buffer, desc = 'git blame' }
        )
        vim.keymap.set({ 'n', 'x' }, '<leader>gd', gs.toggle_deleted, { buffer = buffer })
        vim.keymap.set({ 'n', 'x' }, '<C-g>', function()
          gs.nav_hunk('next', { target = 'all' })
        end, { buffer = buffer, desc = 'next hunk' })
        vim.keymap.set({ 'n', 'x' }, '<C-S-g>', function()
          gs.nav_hunk('prev', { target = 'all' })
        end, { buffer = buffer, desc = 'prev hunk' })
      end,

      signs = {
        add = { text = '+' },
        change = { text = '~' },
        delete = { text = '_' },
        topdelete = { text = '‾' },
        changedelete = { text = '~' },
      },

      -- Staged signs reuse the unstaged glyphs so the sign shape always encodes
      -- the change *type*. Staged vs unstaged is distinguished by a dim backdrop
      -- behind the glyph (the GitSignsStaged* overrides in
      -- after/plugin/colors.lua), not by gitsigns' default of dimming the glyph
      -- foreground (fg_factor = 0.5) which those overrides suppress.
      signs_staged = {
        add = { text = '+' },
        change = { text = '~' },
        delete = { text = '_' },
        topdelete = { text = '‾' },
        changedelete = { text = '~' },
      },
    })
  end,
}
