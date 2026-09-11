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

      -- In-buffer staging (e.g. <leader>ga) does one synchronous sign repaint,
      -- but the .git-dir watcher then fires a *second* full clear+repaint
      -- ~100ms later: its invalidate() resets the "old hunks" to nil, so
      -- gitsigns' compare_heads no-op short-circuit never triggers and it
      -- redraws every sign again. That second sweep is the top-to-bottom
      -- ripple. Disabling the watcher gives a single clean flip (measured:
      -- 2 repaint passes -> 1). Trade-off: signs no longer auto-update after
      -- *external* git ops, so we refresh on focus/resume below instead.
      watch_gitdir = { enable = false },

      on_attach = function(buffer)
        vim.keymap.set(
          { 'n', 'x' },
          '<leader>ga',
          package.loaded.gitsigns.stage_buffer,
          { buffer = buffer, desc = 'git add file' }
        )
        vim.keymap.set(
          { 'n', 'x' },
          '<leader>gr',
          package.loaded.gitsigns.reset_buffer_index,
          { buffer = buffer, desc = 'git reset file' }
        )
        vim.keymap.set(
          { 'n', 'x' },
          '<leader>gc',
          package.loaded.gitsigns.reset_buffer,
          { buffer = buffer, desc = 'git checkout -- file' }
        )
        vim.keymap.set(
          { 'n', 'x' },
          '<leader>gb',
          package.loaded.gitsigns.toggle_current_line_blame,
          { buffer = buffer, desc = 'git blame' }
        )
        vim.keymap.set({ 'n', 'x' }, '<leader>gd', package.loaded.gitsigns.toggle_deleted, { buffer = buffer })
        vim.keymap.set({ 'n', 'x' }, '<C-g>', function()
          package.loaded.gitsigns.nav_hunk('next', { target = 'all' })
        end, { buffer = buffer, desc = 'next hunk' })
        vim.keymap.set({ 'n', 'x' }, '<C-S-g>', function()
          package.loaded.gitsigns.nav_hunk('prev', { target = 'all' })
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

    -- Compensate for the disabled .git-dir watcher: refresh signs when
    -- returning to Neovim (e.g. after staging/committing in external lazygit).
    vim.api.nvim_create_autocmd({ 'FocusGained', 'VimResume' }, {
      group = vim.api.nvim_create_augroup('gitsigns_refresh_on_focus', { clear = true }),
      callback = function()
        pcall(function()
          require('gitsigns').refresh()
        end)
      end,
    })
  end,
}
