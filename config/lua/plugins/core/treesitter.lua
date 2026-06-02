local vim = vim

-- nvim-treesitter-textobjects' Lua loader still references the removed
-- `nvim-treesitter.configs` module, so we don't install the plugin; only
-- its query files are exposed by the wrapper. Add them to runtimepath so
-- mini.ai's `gen_spec.treesitter()` can find `queries/<lang>/textobjects.scm`.
local ts_to_queries = vim.env.NVIM_TS_TEXTOBJECTS_QUERIES
if ts_to_queries then
  vim.opt.runtimepath:append(ts_to_queries)
end

return {
  'nvim-treesitter/nvim-treesitter',

  config = function()
    -- Configures parser install paths. Grammars are Nix-installed under
    -- the plugin's own derivation, so install_dir is irrelevant in practice,
    -- but setup() must be called or :TSInstall et al. won't work.
    require('nvim-treesitter').setup({})

    -- Enable highlight + indent per buffer. The new API delegates to
    -- Neovim's built-in vim.treesitter; nvim-treesitter only provides
    -- the indent helper.
    vim.api.nvim_create_autocmd('FileType', {
      group = vim.api.nvim_create_augroup('TreesitterStart', { clear = true }),
      callback = function(args)
        local bufnr = args.buf
        local lang = vim.treesitter.language.get_lang(vim.bo[bufnr].filetype)
        if lang and pcall(vim.treesitter.start, bufnr, lang) then
          vim.bo[bufnr].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
        end
      end,
    })

    -- Operator-pending aliases: bare keys map to the inner/outer variant
    -- mini.ai exposes. `f`/`F`/`s` mirror the old `@function.outer`,
    -- `@call.outer`, `@statement.outer` behavior; `b`/`p` resolve to the
    -- inner block/loop to match prior muscle memory.
    vim.keymap.set({ 'o', 'x' }, 'f', 'af', { remap = true })
    vim.keymap.set({ 'o', 'x' }, 'F', 'aF', { remap = true })
    vim.keymap.set({ 'o', 'x' }, 's', 'as', { remap = true })
    vim.keymap.set({ 'o' }, 'b', 'ib', { remap = true })
    vim.keymap.set({ 'o' }, 'p', 'ip', { remap = true })
  end,
}
