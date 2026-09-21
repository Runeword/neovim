local vim = vim

-- nvim-treesitter-textobjects' Lua loader still references the removed
-- `nvim-treesitter.configs` module, so we don't install the plugin; only
-- its query files are exposed by the wrapper. Add them to runtimepath so
-- mini.ai's `gen_spec.treesitter()` can find `queries/<lang>/textobjects.scm`.
local ts_to_queries = vim.env.NVIM_TS_TEXTOBJECTS_QUERIES
if ts_to_queries then
  vim.opt.runtimepath:append(ts_to_queries)
end

-- nvim-treesitter (master layout) keeps its highlight/indent/fold queries under
-- `runtime/queries/<lang>/`, but only the plugin root is on rtp, so Neovim finds
-- the parsers (top-level `parser/*.so`) yet not the queries. Without the queries
-- every Nix-bundled grammar parses but renders uncolored; only langs whose queries
-- ship inside Neovim core (lua, c, vim, markdown, query, vimdoc) highlight. The
-- flake exposes that `runtime/` dir as $NVIM_TS_QUERIES; add it so `queries/<lang>/
-- highlights.scm` resolves for bash, python, json, yaml, nix, … as well.
local ts_queries = vim.env.NVIM_TS_QUERIES
if ts_queries then
  vim.opt.runtimepath:append(ts_queries)
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
        -- Minified/long-line guard: a file can sit under big_file's byte
        -- threshold yet be a few pathologically long lines (minified JS/CSS/
        -- JSON) that still choke the parser. Average line length is an O(1)
        -- proxy (nvim_buf_get_offset caches offsets) that catches them.
        if not vim.b[bufnr].big_file then
          local lines = vim.api.nvim_buf_line_count(bufnr)
          if lines > 0 and vim.api.nvim_buf_get_offset(bufnr, lines) / lines > 2048 then
            vim.b[bufnr].big_file = true
          end
        end
        if vim.b[bufnr].big_file then
          return
        end
        local lang = vim.treesitter.language.get_lang(vim.bo[bufnr].filetype)
        if lang and pcall(vim.treesitter.start, bufnr, lang) then
          -- Force a synchronous initial parse so syntax highlights are present
          -- on the first redraw instead of flashing in a frame later: the
          -- highlighter's own first parse (highlighter.lua `_on_start`) uses the
          -- async callback form of `LanguageTree:parse`, which yields after a 3ms
          -- budget and only repaints once the async parse lands. Parsing here
          -- without a callback runs to completion, so the tree is valid on the
          -- first redraw. But a full parse is O(file size) (measured ~4-6ms at
          -- ~150-220 lines, ~15ms at ~1400, 100ms+ beyond), so cap it — larger
          -- buffers keep the async path (a brief flash beats a long freeze).
          -- Edits always re-parse asynchronously (we don't set the global
          -- `vim.g._ts_force_sync_parsing`); big/minified files returned above.
          if vim.api.nvim_buf_line_count(bufnr) <= 1500 then
            pcall(function()
              vim.treesitter.get_parser(bufnr, lang):parse(true)
            end)
          end
          vim.bo[bufnr].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
        end
      end,
    })

    -- Operator-pending aliases: bare keys map to the inner/outer variant
    -- mini.ai exposes. `F`/`s` mirror the old `@call.outer`/`@statement.outer`
    -- behavior; `b` resolves to the inner block, `p` to the inner paragraph
    -- (see textobjects/miniai.lua). `f` is flash.nvim's jump (see move/flash.lua).
    vim.keymap.set({ 'o', 'x' }, 'F', 'aF', { remap = true })
    vim.keymap.set({ 'o', 'x' }, 's', 'as', { remap = true })
    vim.keymap.set({ 'o' }, 'b', 'ib', { remap = true })
    vim.keymap.set({ 'o' }, 'p', 'ip', { remap = true })
  end,
}
