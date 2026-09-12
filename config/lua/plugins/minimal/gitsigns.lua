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
        local gs = package.loaded.gitsigns

        -- stage_buffer / reset_buffer_index are async git writes that mutate
        -- gitsigns' in-memory copy of the index (compare_text). Mashing
        -- <leader>ga fires overlapping calls that race and corrupt compare_text;
        -- because the gitdir watcher is disabled below, nothing re-reads git to
        -- heal the drift, so the signs then show phantom hunks and keep flipping
        -- on every further press even with no new edits. Drop re-entrant presses
        -- until the in-flight write completes (the callback fires on every path,
        -- including the "nothing to stage" early return, so busy can't wedge).
        local busy = false
        local function guard(action)
          return function()
            if busy then
              return
            end
            busy = true
            action(function()
              busy = false
            end)
          end
        end

        vim.keymap.set({ 'n', 'x' }, '<leader>ga', guard(gs.stage_buffer), { buffer = buffer, desc = 'git add file' })
        vim.keymap.set(
          { 'n', 'x' },
          '<leader>gr',
          guard(gs.reset_buffer_index),
          { buffer = buffer, desc = 'git reset file' }
        )
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
