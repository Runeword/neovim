local vim = vim

-- A file's change in a commit as a one-way diff, in a buffer of the file itself, all of it: the
-- file as the commit leaves it (one the commit deletes, as it was), with its filetype, so its
-- highlighting. The lines the commit added are on the added-line background, the ones it removed
-- come back as virtual lines where they were, highlighted as treesitter would in the file before
-- the commit, on the deleted-line background, and the part of a changed line that changed is on
-- a brighter one. Code the commit moves is on purple and blue ones instead, as git's
-- diff.colorMoved marks it and delta paints it in the shell. Each file is a new buffer, wiped
-- once it leaves its window.
local M = {}

local ns = vim.api.nvim_create_namespace('gl.diff')

local LARGE = 4 * 1024 * 1024 -- (bytes) a version past this isn't shown
local LINE, TEXT = 10, 20 -- priorities: an added line's background, then its changed part

-- Dark tints of delta's green and red (gitsigns' in after/plugin/colors.lua), as in GitHub's
-- dark theme: the syntax colours keep a contrast of 4 to 10 on them (3 to 7 on the brighter ones,
-- of a changed line's changed part), where delta's own (#405744, #664046), made for white text,
-- left them 2 to 5 (1.2 to 3.3). Moved code's are tints as dark of the purples and blues delta
-- paints it with (map-styles, in the shell's delta config), for the same contrast: blue for a
-- block right after another (git's zebra), and darker where the code was than where it went.
local function highlights()
  for name, bg in pairs({
    GlDiffAdd = '#163a26',
    GlDiffAddText = '#1d5030', -- the part of a changed line that changed
    GlDiffDelete = '#3a1a22',
    GlDiffDeleteText = '#5c2332',
    GlDiffAddMoved = '#3f2a5e', -- (code moved here)
    GlDiffAddMovedAlt = '#183463',
    GlDiffDeleteMoved = '#311b55', -- (code moved away)
    GlDiffDeleteMovedAlt = '#052659',
  }) do
    vim.api.nvim_set_hl(0, name, { default = true, bg = bg })
  end
end
highlights()
local group = vim.api.nvim_create_augroup('gl.diff', {})
vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = highlights })

-- Moved lines' groups, by side and colour (see moves)
local MOVED_HL = {
  old = { 'GlDiffDeleteMoved', 'GlDiffDeleteMovedAlt' },
  new = { 'GlDiffAddMoved', 'GlDiffAddMovedAlt' },
}

-- By buffer: the rows of its changes
local shown = {}

-- The commit's files, as git show lists them: with renames and copies as git's config finds
-- them, against the first parent for a merge (as gl's list counts its change). Each is
-- { status = A, C, D, M, R or T, old = its path before (nil if added), new = after (nil if
-- deleted) }.
function M.files(dir, sha, cb)
  local cmd = { 'git', 'show', '--format=', '--name-status', '-z', '--diff-merges=first-parent', sha }
  vim.system(cmd, { cwd = dir }, function(r)
    local list, f, i = {}, vim.split(r.code == 0 and r.stdout or '', '\0', { plain = true }), 1
    while f[i + 1] do
      local status = f[i]:sub(1, 1)
      if status == 'R' or status == 'C' then
        list[#list + 1] = { status = status, old = f[i + 1], new = f[i + 2] }
        i = i + 3
      else
        local path = f[i + 1]
        list[#list + 1] = { status = status, old = status ~= 'A' and path or nil, new = status ~= 'D' and path or nil }
        i = i + 2
      end
    end
    cb(list)
  end)
end

-- The file's text before the commit and after it (nil where it isn't there)
function M.versions(dir, sha, file, cb)
  local specs = {}
  specs.old = file.old and sha .. '^:' .. file.old
  specs.new = file.new and sha .. ':' .. file.new
  local text, left = {}, vim.tbl_count(specs)
  if left == 0 then
    return cb(nil, nil)
  end
  for side, spec in pairs(specs) do
    vim.system({ 'git', 'show', spec }, { cwd = dir }, function(r)
      text[side] = r.code == 0 and r.stdout or nil
      left = left - 1
      if left == 0 then
        cb(text.old, text.new)
      end
    end)
  end
end

-- A version's lines, or why there are none
local function lines(text)
  if not text then
    return {}
  elseif #text > LARGE then
    return {}, 'too large'
  elseif text:sub(1, 8000):find('\0', 1, true) then
    return {}, 'binary'
  end
  local list = vim.split(text, '\n', { plain = true })
  if list[#list] == '' then
    list[#list] = nil
  end
  -- (CRLF throughout, as a file Neovim reads as fileformat=dos)
  local crlf = #list > 0
  for _, l in ipairs(list) do
    crlf = crlf and l:sub(-1) == '\r'
  end
  for i, l in ipairs(crlf and list or {}) do
    list[i] = l:sub(1, -2)
  end
  return list
end

-- A line's words, runs of blanks and other characters, with where each starts (0-based)
local function tokens(s)
  local list, starts, i = {}, {}, 1
  while i <= #s do
    local j = s:match('^[%w_\128-\255]+()', i) or s:match('^%s+()', i) or i + 1
    list[#list + 1], starts[#starts + 1] = s:sub(i, j - 1), i - 1
    i = j
  end
  return list, starts
end

-- The background of the buffer's row (1-based), to the window's edge. Not a line_hl_group: that
-- one covers the changed part's brighter one, whatever their priorities.
local function line(buf, row, hl)
  local opts = { end_row = row, end_col = 0, hl_group = hl, hl_eol = true, priority = LINE }
  vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, opts)
end

local function joined(list)
  return #list > 0 and table.concat(list, '\n') .. '\n' or ''
end

-- The changed parts of a removed line and an added one, as byte ranges ({ start, end }, 0-based,
-- end excluded) in each, if they're alike: no further apart than 0.6, as delta pairs lines, in
-- the share of their characters (blanks aside) they don't have in common
local function changed(a, b)
  if #a > 1000 or #b > 1000 then
    return
  end
  local ta, sa = tokens(a)
  local tb, sb = tokens(b)
  local ca, cb = {}, {}
  for _, h in ipairs(vim.text.diff(joined(ta), joined(tb), { result_type = 'indices' })) do
    for i = h[1], h[1] + h[2] - 1 do
      ca[i] = true
    end
    for i = h[3], h[3] + h[4] - 1 do
      cb[i] = true
    end
  end
  local common, total = 0, 0
  for _, t in ipairs({ { ta, ca }, { tb, cb } }) do
    for i, tok in ipairs(t[1]) do
      if not tok:find('^%s') then
        total = total + #tok
        common = common + (t[2][i] and 0 or #tok)
      end
    end
  end
  if total == 0 or common / total < 0.4 then
    return
  end
  local function ranges(toks, starts, flags)
    local out, i = {}, 1
    while i <= #toks do
      if flags[i] then
        local j = i
        while flags[j + 1] do
          j = j + 1
        end
        out[#out + 1] = { starts[i], starts[j] + #toks[j] }
        i = j
      end
      i = i + 1
    end
    return out
  end
  return ranges(ta, sa, ca), ranges(tb, sb, cb)
end

-- The code the commit moves, as git finds it with the shell's config (diff.colorMoved = zebra,
-- diff.colorMovedWS = allow-indentation-change; mark_color_as_moved in git's diff.c). Going
-- through the lines in git's order (each hunk's removed lines, then its added ones), a block of
-- moved lines is a run of them alike, in the same order, to lines on the other side, their
-- indentation changed by as much on each (a blank line's, any). A block with fewer than 20
-- letters and digits isn't one, and the search starts again on its second line; a block right
-- after another, on the same side, gets the other colour. Returns the rows moved of old and new:
-- by row, 1, or 2 for the other colour.
local BLOCK = 20 -- (letters and digits) the least a block holds, as git's
local STEPS = 1e6 -- (steps) a diff that takes more to look into has none marked
local function moves(old, new, hunks)
  local moved = { old = {}, new = {} }
  -- The lines (false between hunks, for those git leaves as they are), each with the next one of
  -- its side in the hunk, its indentation's width (tabs to the next multiple of 8) and its text
  -- after it ('' and no width, blank); by side and text, where they are
  local seq, at = {}, { old = {}, new = {} }
  for _, h in ipairs(hunks) do
    for _, side in ipairs({ { 'old', old, h[1], h[2] }, { 'new', new, h[3], h[4] } }) do
      local name, list, first, count = unpack(side)
      for row = first, first + count - 1 do
        local s = list[row]
        local i, width = s:find('[^ \t]') or #s + 1, 0
        for c in s:sub(1, i - 1):gmatch('.') do
          width = c == '\t' and width + 8 - width % 8 or width + 1
        end
        local text = s:sub(i)
        if not text:find('%S') then
          text, width = '', nil
        end
        seq[#seq + 1] = { side = name, row = row, line = s, text = text, width = width }
        if row > first then
          seq[#seq - 1].next = #seq
        end
        at[name][text] = at[name][text] or {}
        table.insert(at[name][text], #seq)
      end
    end
    seq[#seq + 1] = false
  end

  -- Whether the block of the length before n is one; if not, its lines aren't moved
  local function block(n, length)
    local count = 0
    for i = n - length, n - 1 do
      count = count + select(2, seq[i].line:gsub('%w', ''))
      if count >= BLOCK then
        return true
      end
    end
    for i = n - length, n - 1 do
      seq[i].moved = nil
    end
    return false
  end

  -- The blocks the current one could be, each by its last line on the other side and the
  -- indentation change of its lines (none yet, if all blank)
  local blocks, length, side, alt, steps, n = {}, 0, nil, false, 0, 1
  while n <= #seq do
    local l = seq[n]
    local alike = l and at[l.side == 'old' and 'new' or 'old'][l.text]
    if not l then
      alt = false
    end
    if #blocks > 0 and (not alike or l.side ~= side) then
      if not block(n, length) and length > 1 then
        alike, n = nil, n - length
      end
      blocks, length, alt = {}, 0, false
    end
    if not alike then
      side = nil
    else
      local kept = {}
      for _, b in ipairs(blocks) do
        local i = seq[b.at].next
        local o = i and seq[i]
        if o and o.text == l.text then
          local change = o.width and l.width - o.width
          b.change = b.change or change
          if change == nil or change == b.change then
            b.at = i
            kept[#kept + 1] = b
          end
        end
      end
      steps = steps + #blocks
      blocks = kept
      if #blocks == 0 then
        local after = block(n, length)
        if not after and length > 1 then
          n = n - length
        else
          for _, i in ipairs(alike) do
            blocks[#blocks + 1] = { at = i, change = seq[i].width and l.width - seq[i].width }
          end
          steps = steps + #alike
        end
        alt = after and #blocks > 0 and side == l.side and not alt
        side = #blocks > 0 and l.side or nil
        length = 0
      end
      if #blocks > 0 then
        length = length + 1
        l.moved = alt and 2 or 1
      end
    end
    if steps > STEPS then
      return moved -- (none)
    end
    n = n + 1
  end
  block(n, length)

  for _, l in ipairs(seq) do
    if l and l.moved then
      moved[l.side][l.row] = l.moved
    end
  end
  return moved
end

-- The highlights treesitter gives the rows (0-based, { first, last } ranges) of a version of a
-- file of the filetype, as its highlighter would in a buffer of it: by row, by byte (1-based),
-- the capture's group and priority (the higher one's over a byte, else the later one's)
local function syntax(list, ft, ranges)
  local out, text = {}, joined(list)
  local lang = ft and ranges[1] and vim.treesitter.language.get_lang(ft)
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not (lang and ok) then -- (no parser for it)
    return out
  end
  parser:parse(#text <= 256 * 1024 or nil) -- (a large file's injections aside)
  parser:for_each_tree(function(tree, ltree)
    local query = vim.treesitter.query.get(ltree:lang(), 'highlights')
    for _, range in ipairs(query and ranges or {}) do
      for id, node, metadata in query:iter_captures(tree:root(), text, range[1], range[2] + 1) do
        local name = query.captures[id]
        if not (name:find('^_') or name:find('^n?o?spell$') or name:find('conceal$')) then
          local hl = '@' .. name .. '.' .. ltree:lang()
          local prio = tonumber(metadata.priority or metadata[id] and metadata[id].priority) or 100
          local r = vim.treesitter.get_range(node, text, metadata[id])
          for row = math.max(r[1], range[1]), math.min(r[4], range[2]) do
            local bytes = out[row] or {}
            out[row] = bytes
            for b = (row == r[1] and r[2] or 0) + 1, row == r[4] and r[5] or #list[row + 1] do
              if not bytes[b] or prio >= bytes[b][2] then
                bytes[b] = { hl, prio }
              end
            end
          end
        end
      end
    end
  end)
  return out
end

-- A removed line as a virtual line: highlighted as its syntax (by byte, see syntax) has it, its
-- changed parts brighter, its tabs as spaces (as the buffer would show them), its background (bg)
-- to the window's edge
local function virtual(text, parts, tabstop, syn, bg)
  local chunks, col = {}, 0
  local function add(s, hl)
    local out = {}
    for piece, tab in s:gmatch('([^\t]*)(\t?)') do
      out[#out + 1] = piece
      col = col + vim.api.nvim_strwidth(piece)
      if tab ~= '' then
        out[#out + 1] = (' '):rep(tabstop - col % tabstop)
        col = col + tabstop - col % tabstop
      end
    end
    if s ~= '' then
      chunks[#chunks + 1] = { table.concat(out), hl }
    end
  end
  local changed_byte = {}
  for _, p in ipairs(parts or {}) do
    for b = p[1] + 1, p[2] do
      changed_byte[b] = true
    end
  end
  -- Runs of bytes alike (changed or not, the same capture), each a chunk: the line's background
  -- under the capture's group
  local from, key, base, group = 1, nil, nil, nil
  for b = 1, #text + 1 do
    local cap = syn and syn[b] and syn[b][1]
    local k = b <= #text and (changed_byte[b] and '+' or '-') .. (cap or '') or nil
    if k ~= key then
      if key then
        add(text:sub(from, b - 1), group and { base, group } or base)
      end
      from, key = b, k
      base, group = changed_byte[b] and 'GlDiffDeleteText' or bg, cap
    end
  end
  chunks[#chunks + 1] = { '', bg } -- (an empty last chunk: its highlight to the edge)
  return chunks
end

-- Marks the change from old (of the filetype) to new in the buffer (holding new); returns the
-- rows of its changes
local function mark(buf, old, new, ft)
  local rows = {}
  local hunks = vim.text.diff(joined(old), joined(new), {
    result_type = 'indices',
    algorithm = 'histogram',
    indent_heuristic = true,
  })
  local removed = {}
  for _, h in ipairs(hunks) do
    if h[2] > 0 then
      removed[#removed + 1] = { h[1] - 1, h[1] + h[2] - 2 }
    end
  end
  local syn = syntax(old, ft, removed)
  local moved = moves(old, new, hunks)
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = unpack(h)
    for r = sb, sb + cb - 1 do
      line(buf, r, MOVED_HL.new[moved.new[r]] or 'GlDiffAdd')
    end
    -- Each removed line with the first alike of the next three added ones, moved ones aside (as
    -- git and delta show them: moved, not changed)
    local olds, news = {}, {}
    for i = sa, sa + ca - 1 do
      if not moved.old[i] then
        olds[#olds + 1] = i
      end
    end
    for j = sb, sb + cb - 1 do
      if not moved.new[j] then
        news[#news + 1] = j
      end
    end
    local parts, k = {}, 1
    for _, i in ipairs(olds) do
      for j = k, math.min(#news, k + 2) do
        local po, pn = changed(old[i], new[news[j]])
        if po then
          parts[i] = po
          for _, p in ipairs(pn) do
            vim.api.nvim_buf_set_extmark(buf, ns, news[j] - 1, p[1], {
              end_col = p[2],
              hl_group = 'GlDiffAddText',
              priority = TEXT,
            })
          end
          k = j + 1
          break
        end
      end
    end
    -- The removed lines over the added ones, else under the line before them (over the first
    -- line, before it)
    local row = cb > 0 and sb or math.max(sb, 1)
    if ca > 0 then
      local virt = {}
      for i = sa, sa + ca - 1 do
        local bg = MOVED_HL.old[moved.old[i]] or 'GlDiffDelete'
        virt[#virt + 1] = virtual(old[i], parts[i], vim.bo[buf].tabstop, syn[i - 1], bg)
      end
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
        virt_lines = virt,
        virt_lines_above = cb > 0 or sb == 0,
        virt_lines_overflow = 'scroll',
      })
    end
    rows[#rows + 1] = row
  end
  return rows
end

-- Shows the file's change in the window (no file: nothing, as for a search matching none), the
-- cursor on its first change, under a winbar with the revision and path, what else there is to
-- say about it and extra. map(buf) sets the buffer's keys; ]c and [c go to its next and
-- previous changes.
function M.show(win, sha, file, old_text, new_text, extra, map)
  local f = file or {}
  local deleted = f.old and not f.new
  local old, why_old = lines(old_text)
  local new, why_new = lines(new_text)
  local body = deleted and old or new
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
  map(buf)
  for key, dir in pairs({ [']c'] = 1, ['[c'] = -1 }) do
    vim.keymap.set('n', key, function()
      M.step(dir)
    end, { buffer = buf, desc = dir > 0 and 'gl: next change' or 'gl: previous change' })
  end
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      shown[buf] = nil
    end,
  })
  vim.api.nvim_win_call(win, function()
    vim.cmd('noautocmd keepalt keepjumps buffer ' .. buf)
  end)
  local path = f.new or f.old
  local ft = path and vim.filetype.match({ filename = path, contents = body })
  if path then
    pcall(vim.api.nvim_buf_set_name, buf, ('gl://%s%s/%s'):format(sha, deleted and '^' or '', path))
    -- (FileType in the window: the treesitter hook highlights the rows it shows)
    if ft then
      vim.api.nvim_win_call(win, function()
        vim.bo[buf].filetype = ft
      end)
    end
  end

  local why = why_new or why_old
  local rows = { 1 } -- (an added or deleted file: all of it)
  if not file or why then
    rows = {}
  elseif deleted or not f.old then
    for r = 1, #body do
      line(buf, r, deleted and 'GlDiffDelete' or 'GlDiffAdd')
    end
  else
    -- (the old version's filetype: a renamed file's may differ)
    rows = mark(buf, old, new, vim.filetype.match({ filename = f.old, contents = old }) or ft)
  end
  shown[buf] = { rows = rows }

  local say = why or not f.old and 'new file' or deleted and 'deleted' or f.old ~= f.new and 'renamed from ' .. f.old
  local label = file and (' %s  %s%s%s'):format(sha, path, say and '  (' .. say .. ')' or '', extra or '') or ''
  vim.api.nvim_set_option_value('winbar', (label:gsub('%%', '%%%%')), { win = win, scope = 'local' })

  vim.api.nvim_win_call(win, function()
    local row = rows[1] or 1
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    vim.cmd('normal! zz')
    -- (removed lines over the first line: shown as filler over it)
    for _, m in ipairs(row == 1 and vim.api.nvim_buf_get_extmarks(buf, ns, 0, 0, { details = true }) or {}) do
      if m[4].virt_lines_above then
        vim.fn.winrestview({ topline = 1, topfill = #m[4].virt_lines })
      end
    end
  end)
end

-- To the next (dir 1) or previous (-1) change
function M.step(dir)
  local m = shown[vim.api.nvim_get_current_buf()]
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local to
  for _, r in ipairs(m and m.rows or {}) do
    if dir > 0 and r > row then
      to = to or r
    elseif dir < 0 and r < row then
      to = r
    end
  end
  if to then
    vim.api.nvim_win_set_cursor(0, { to, 0 })
  end
end

return M
