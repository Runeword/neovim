local vim = vim

local TAB, S_TAB, CR = vim.keycode('<Tab>'), vim.keycode('<S-Tab>'), vim.keycode('<CR>')

-- <Tab> jumps to the first match after the cursor (where <CR> used to jump) and
-- <S-Tab> to the last one before it; pressing either again steps to the next or
-- previous match on screen, wrapping around. Once cycling starts the labels go
-- away: <Esc> or <CR> stop on the current match, and any other key stops there and
-- then runs as usual.
local function cycle(state, forward)
  -- This window's matches in buffer order (`results` spans every window).
  local matches = vim.tbl_filter(function(m)
    return m.win == state.win
  end, state.results)
  if #matches == 0 then
    return false
  end
  table.sort(matches, function(a, b)
    return a.pos < b.pos
  end)

  -- Start on flash's target, or for <S-Tab> on the last match before the cursor
  -- (wrapping to the end if there is none).
  local i = forward and 1 or #matches
  for k, m in ipairs(matches) do
    if forward and state.target and m.pos == state.target.pos then
      i = k
    elseif not forward and m.pos < state.pos then
      i = k
    end
  end

  -- Draw without labels, since label keys now pass through. Hiding the state
  -- stops flash's redraw hook from relabelling everything once the cursor moves.
  for _, m in ipairs(matches) do
    m.label = nil
  end
  state.results, state.visible = matches, false

  -- Only the starting point goes on the jumplist, however far we cycle.
  local jumplist = state.opts.jump.jumplist
  while true do
    state.target = matches[i]
    state:jump(state.target)
    state.opts.jump.jumplist = false
    require('flash.highlight').update(state)

    local key = state:get_char() -- nil on <Esc>
    if key ~= TAB and key ~= S_TAB then
      -- Back to the front of the typeahead, but not as typed ('t'), or a macro
      -- being recorded would get the key twice.
      if key and key ~= CR then
        vim.api.nvim_feedkeys(key, 'i', true)
      end
      -- Visible again so flash clears the highlights on the way out.
      state.visible, state.opts.jump.jumplist = true, jumplist
      return false
    end
    i = (i - 1 + (key == TAB and 1 or -1)) % #matches + 1
  end
end

-- flash hardcodes <CR> as "jump to first match" in its input loop but checks
-- `actions` first, so the no-op `<CR>` action disables that. Returning nil from an
-- action keeps flash reading keys; false exits.
local actions = {
  ['<Tab>'] = function(state)
    return cycle(state, true)
  end,
  ['<S-Tab>'] = function(state)
    return cycle(state, false)
  end,
  ['<CR>'] = function() end,
}

return {
  'folke/flash.nvim',

  event = 'VeryLazy',

  opts = {
    labels = ',pyaoeuidhtnsfgcrl;qjkxbmwvz',
    label = {
      uppercase = false,
      after = { 0, 1 },
    },

    highlight = {
      backdrop = false,
      matches = true,
      priority = 5000,
      groups = {
        match = 'FlashMatch',
        current = 'FlashCurrent',
        backdrop = 'FlashBackdrop',
        label = 'FlashLabel',
      },
    },

    prompt = {
      enabled = false,
      prefix = { { '>', 'FlashPromptIcon' } },

      win_config = {
        relative = 'cursor',
        width = 2,
        height = 1,
        col = 1, -- 2 columns to the right of the cursor
        row = 0, -- 1 row below the cursor
        zindex = 1000,
      },

      -- win_config = {
      --   relative = 'win',
      --   width = 20,
      --   height = 1,
      --   col = math.ceil(vim.api.nvim_win_get_width(0) / 2),
      --   row = math.ceil(vim.api.nvim_win_get_height(0) / 2),
      --   zindex = 1000,
      -- },
    },

    modes = {
      search = {
        enabled = false,
        highlight = {
          backdrop = false,
        },

        jump = {
          history = true,
          register = true,
          nohlsearch = true,
          autojump = true,
        },
      },

      char = {
        enabled = false,
        config = function(opts)
          opts.autohide = vim.fn.mode(true):find('no') and vim.v.operator == 'y'
          opts.jump_labels = opts.jump_labels and vim.v.count == 0
        end,

        autohide = false,
        jump_labels = false,
        multi_line = true,
        -- label = { exclude = 'hjkliardc', },
        keys = { 'f', 'F', 't', 'T', ';', ',' },

        char_actions = function(motion)
          return {
            [';'] = 'next',
            [','] = 'prev',
            [motion:lower()] = 'next',
            [motion:upper()] = 'prev',
          }
        end,

        search = { wrap = false },
        highlight = { backdrop = false },
        jump = { register = false },
      },
    },
  },

  init = function()
    vim.api.nvim_create_augroup('flash', { clear = true })
    vim.api.nvim_create_autocmd('ColorScheme', {
      group = 'flash',
      pattern = '*',
      callback = function()
        vim.api.nvim_set_hl(0, 'FlashMatch', { bg = '#222b66', fg = 'white', bold = false })
        vim.api.nvim_set_hl(0, 'FlashCurrent', { bg = '#49f5b0', fg = 'black', bold = false })
        vim.api.nvim_set_hl(0, 'FlashLabel', { bg = '#5d00ff', fg = 'white', bold = false })
      end,
    })
  end,

  keys = {
    {
      'f',
      mode = { 'n', 'x', 'o' },
      function()
        require('flash').jump({
          actions = actions,
          search = {
            -- labels = 'pyaoeuidhtnsfgcrlqjkxbmwvz',
            -- incremental = true,
          },
        })
      end,
      desc = 'Flash',
    },
    {
      '<C-f>',
      mode = { 'i' },
      function()
        require('flash').jump({ actions = actions })
      end,
      desc = 'Flash',
    },
  },
}
