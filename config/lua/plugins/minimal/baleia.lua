local vim = vim

return {
  "m00qek/baleia.nvim",
  version = "*",
  config = function()
    vim.g.baleia = require("baleia").setup({})
  end,
}
