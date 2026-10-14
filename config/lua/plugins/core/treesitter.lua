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

    local group = vim.api.nvim_create_augroup('TreesitterStart', { clear = true })

    -- Parse what a buffer's windows are about to draw, without yielding, so a
    -- file opens already colored. The highlighter's own first parse
    -- (highlighter.lua `_on_start`) yields after 3ms and repaints once done, so
    -- any file that takes longer (~1500+ lines of Lua) first shows a frame of
    -- plain white text. Measured on fresh buffers: the root tree, always parsed
    -- whole, costs ~0.2ms/KB of Lua (61KB: 12ms), 0.15 Python, 0.07 TS, 0.4
    -- markdown. Injections cost little per screen (Lua 0.3ms, markdown 5ms) but
    -- a lot per file (that 61KB Lua: 22ms in all, a 60KB README: 72ms). So a
    -- small file gets all its injections, sparing its scrolling a repaint per
    -- new screen (markdown's 5ms exceed the 3ms); a bigger one only those in
    -- the rows on screen (the rows `_on_start` asks for); and past ~50ms of Lua
    -- (~100ms of markdown) a white frame beats the freeze, so it stays async.
    -- Edits always re-parse asynchronously (we don't set the global
    -- `vim.g._ts_force_sync_parsing`).
    local parse_all_max_bytes = 64 * 1024
    local sync_parse_max_bytes = 256 * 1024
    local function parse_before_draw(buf)
      local highlighter = vim.treesitter.highlighter.active[buf]
      local bytes = vim.api.nvim_buf_get_offset(buf, vim.api.nvim_buf_line_count(buf))
      if not highlighter or bytes > sync_parse_max_bytes then
        return
      end
      local ranges = {}
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        table.insert(ranges, { vim.fn.line('w0', win) - 1, vim.fn.line('w$', win) + 1 })
      end
      if #ranges == 0 then
        return
      end
      table.sort(ranges, function(a, b)
        return a[1] < b[1]
      end)
      pcall(highlighter.tree.parse, highlighter.tree, bytes <= parse_all_max_bytes or ranges)
    end

    -- Enable highlight + indent per buffer. The new API delegates to
    -- Neovim's built-in vim.treesitter; nvim-treesitter only provides
    -- the indent helper.
    vim.api.nvim_create_autocmd('FileType', {
      group = group,
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
          parse_before_draw(bufnr)
          vim.bo[bufnr].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
        end
      end,
    })

    -- A buffer entering a window shows new rows, and at startup or :edit this
    -- runs after the view autocmd (autocmd.lua, defined first) has restored the
    -- cursor, so these are the rows the first redraw draws.
    vim.api.nvim_create_autocmd('BufWinEnter', {
      group = group,
      callback = function(args)
        if vim.b[args.buf].ts_highlight then
          parse_before_draw(args.buf)
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
