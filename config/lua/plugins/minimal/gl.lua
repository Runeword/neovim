local vim = vim

return {
  enabled = true,

  dir = vim.fn.stdpath('config') .. '/lua/myplugins/gl.nvim',

  -- Started by the shell's gdc, gdd or gda (~/terminal's __git_diff runs `GL_OPEN=<kind> nvim --
  -- <files>`: staged, unstaged or changed), Neovim opens in it, on the first of the files picked
  -- there, at its first change; by its gl (__git_log runs `GL_OPEN=log GL_COMMIT=<hash>
  -- GL_PATH=<path> nvim`), in gl, on the commit's files, at the change in it of the file picked
  -- there (GL_PATH, from the repository's root), on no file: gl shows the change alone, and q
  -- quits Neovim; of several commits marked there, all of their files, by commit
  -- (GL_COMMITS='<hash> <hash>…', GL_COMMIT the file's). The shell only names the list: gl's
  -- lists are its own, the shell's pickers aren't run here.
  init = function()
    local name, commit, commits, path = vim.env.GL_OPEN, vim.env.GL_COMMIT, vim.env.GL_COMMITS, vim.env.GL_PATH
    if not name then
      return
    end
    -- (not for the shells and the Neovims started from here)
    vim.env.GL_OPEN, vim.env.GL_COMMIT, vim.env.GL_COMMITS, vim.env.GL_PATH = nil, nil, nil, nil
    vim.api.nvim_create_autocmd('UIEnter', {
      once = true,
      callback = function()
        vim.schedule(function() -- (after the file tree, which opens then too: gdc's split under it)
          require('lazy').load({ plugins = { 'gl.nvim' } })
          require('gl').open(name, {
            from_shell = true,
            commit = commit,
            commits = commits and vim.split(commits, ' ', { trimempty = true }),
            path = path ~= '' and path or nil,
          })
        end)
      end,
    })
  end,

  keys = {
    {
      '<leader>gl',
      function()
        require('gl').open()
      end,
      desc = 'git log (gl), on/off',
    },
    {
      '<leader>gdc',
      function()
        require('gl').open('staged')
      end,
      desc = 'git diff --cached (gdc), on/off',
    },
    {
      '<leader>gdd',
      function()
        require('gl').open('unstaged')
      end,
      desc = 'git diff (gdd), on/off',
    },
    {
      '<leader>gda',
      function()
        require('gl').open('changed')
      end,
      desc = 'git diff HEAD (gda), on/off',
    },
    -- The shell's ga, gru and grd pickers: the files, then a file's hunks, to mark and apply
    {
      '<leader>ga',
      function()
        require('gl').open('stage')
      end,
      desc = 'git add: files, hunks (ga), on/off',
    },
    {
      '<leader>gru',
      function()
        require('gl').open('unstage')
      end,
      desc = 'git restore --staged: files, hunks (gru), on/off',
    },
    {
      '<leader>grd',
      function()
        require('gl').open('discard')
      end,
      desc = 'git restore: files, hunks (grd), on/off',
    },
  },
}
