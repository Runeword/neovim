local vim = vim

return {
  'inside/vim-search-pulse',
  enabled = true,

  init = function()
    vim.g.vim_search_pulse_disable_auto_mappings = 1
    vim.g.vim_search_pulse_duration = 200
    vim.g.vim_search_pulse_mode = 'pattern'
  end,

  config = function()
    -- Keep n/N direction-consistent (n always searches forward, N always
    -- backward, whether the last search used / or ?) and pulse the match.
    -- Done as a function rather than an <expr> map returning '<Plug>Pulse':
    -- that form depends on replace_keycodes plus a remappable result, and
    -- when it misfires it feeds the raw RHS as keystrokes -- n runs `v`
    -- (starts visual mode) then `:` (opens the command line).
    local function search_next(forward)
      return function()
        local key = (vim.v.searchforward == 1) == forward and 'n' or 'N'
        local ok, err = pcall(vim.cmd, 'normal! ' .. vim.v.count1 .. key)
        if ok then
          vim.fn['search_pulse#Pulse']()
        else
          vim.api.nvim_echo({ { (err:gsub('.*Vim%(normal%):', '')), 'ErrorMsg' } }, true, {})
        end
      end
    end

    vim.keymap.set('n', 'n', search_next(true), { silent = true, desc = 'Next match + pulse' })
    vim.keymap.set('n', 'N', search_next(false), { silent = true, desc = 'Prev match + pulse' })
    vim.keymap.set('c', '<Enter>', 'search_pulse#PulseFirst()', { silent = true, expr = true })
  end,
}
