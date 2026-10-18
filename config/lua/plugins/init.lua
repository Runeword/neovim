local vim = vim

return {
  { 'jghauser/mkdir.nvim' },

  {
    'DrKJeff16/project.nvim',
    config = function()
      require('project').setup()
      -- Its root lookup on entering a buffer (or an LSP attaching) runs git twice and walks
      -- up the directories twice: ~25-45 ms at each buffer switch, before the buffer could
      -- be drawn. Past startup it runs once the screen shows the buffer, once for the
      -- buffers entered in a row (the last one).
      local group = vim.api.nvim_create_augroup('project.nvim', { clear = false })
      local pending -- { callback, args } of the last event, until it runs
      for _, au in ipairs(vim.api.nvim_get_autocmds({ group = group, event = { 'BufEnter', 'LspAttach' } })) do
        vim.api.nvim_del_autocmd(au.id)
        vim.api.nvim_create_autocmd(au.event, {
          group = group,
          callback = function(args)
            if vim.v.vim_did_enter == 0 then
              au.callback(args) -- (the file tree opens in the project, see plugins/ui/filetree.lua)
              return
            end
            if not pending then
              vim.schedule(function()
                local callback, last = unpack(pending)
                pending = nil
                callback(last)
              end)
            end
            pending = { au.callback, args }
          end,
        })
      end
    end,
  },

  {
    'willothy/flatten.nvim',
    enabled = true,
    config = true,
    lazy = false,
    priority = 1001,
  },

  -- { 'HiPhish/rainbow-delimiters.nvim', },
  -- { 'mbbill/undotree', },
  -- { 'kana/vim-arpeggio', },

  -- { 'smjonas/inc-rename.nvim',
  --   config = function()
  --     require('inc_rename').setup()
  --   end,
  -- },

  -- { 'mattn/vim-gist',
  --   dependencies = { 'mattn/webapi-vim' },
  -- },
}

-- for key, value in pairs(plugins) do
--   plugins[key].enabled = false
-- end
