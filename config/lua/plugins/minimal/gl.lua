local vim = vim

return {
  enabled = true,

  dir = vim.fn.stdpath('config') .. '/lua/myplugins/gl.nvim',

  -- Started by the shell's gdc (~/terminal's __git_diff staged runs `GL_OPEN=staged nvim --
  -- <files>`), Neovim opens in gdc, on the first of the files picked there
  init = function()
    local name = vim.env.GL_OPEN
    if not name then
      return
    end
    vim.env.GL_OPEN = nil -- (not for the shells and the Neovims started from here)
    vim.api.nvim_create_autocmd('UIEnter', {
      once = true,
      callback = function()
        vim.schedule(function() -- (after the file tree, which opens then too: gdc's split under it)
          require('lazy').load({ plugins = { 'gl.nvim' } })
          require('gl').open(name, { here = true })
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
      desc = "git log: the shell's gl picker (~/terminal), on/off",
    },
    {
      '<leader>gdc',
      function()
        require('gl').open('staged')
      end,
      desc = "git diff --cached: the shell's gdc picker (~/terminal), on/off",
    },
  },
}
