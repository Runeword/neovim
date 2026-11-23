local vim = vim

-- The git side of gl's stage, unstage and discard lists (see gl), as the shell's ga, gru and grd
-- pick (~/terminal's __git_pick_files and git-hunk-pick): a file's hunks as git diff gives them
-- without context (--unified=0, the work tree's change or the index's), the patch of those
-- picked, and the op applied to what's picked: whole files by git add, git restore --staged or
-- git restore, hunks by git apply, to the index or the work tree.
local M = {}

-- What each op drills and applies: the index's change (git diff --cached) or the work tree's;
-- taken out (reverse) or put in; to the index (git apply --cached) or the work tree; the command
-- for whole files, after git; whether its list has the files git doesn't track; what it did
M.OPS = {
  stage = { untracked = true, index = true, whole = { 'add', '--' }, did = 'staged' },
  unstage = { cached = true, reverse = true, index = true, whole = { 'restore', '--staged', '--' }, did = 'unstaged' },
  discard = { reverse = true, whole = { 'restore', '--' }, did = 'discarded' },
}

-- git diff's output whatever git's config says, as git-hunk-pick has it: an external diff or a
-- textconv driver shows text that isn't the file's, and colours, other prefixes, context or
-- hunks merged across lines (diff.interHunkContext) break the parse
local FLAGS = {
  '--no-ext-diff',
  '--no-textconv',
  '--no-color',
  '--src-prefix=a/',
  '--dst-prefix=b/',
  '--unified=0',
  '--inter-hunk-context=0',
}

-- git in the repository at root, its pathspecs paths (not globs: foo[1].txt isn't foo1.txt),
-- stdin its input: its output, else nil and why
function M.git(root, args, stdin)
  local cmd = { 'git', '--literal-pathspecs' }
  vim.list_extend(cmd, args)
  local r = vim.system(cmd, { cwd = root, stdin = stdin }):wait()
  if r.code ~= 0 then
    local err = vim.trim(r.stderr or '')
    return nil, err ~= '' and err or 'git ' .. table.concat(args, ' ') .. ' failed'
  end
  return r.stdout or ''
end

-- One file's diff without context, as { head, hunks }: head its diff --git, --- and +++ lines
-- (the paths quoted as git quotes them; no mode or index line: a patch of some hunks changes
-- lines alone); each hunk { a, b, c, d } as its @@ line has them (from line a, b lines, to line
-- c, d lines; with a count of 0, the line it comes after), its @@ line, the lines it removes
-- (old) and adds (new) without their - or +, the "\ No newline at end of file" after the last of
-- either (old_eof, new_eof), and raw, its text as git wrote it. A binary file's diff has no
-- hunks, nor a combined one (an unmerged file's, @@@).
function M.parse(out)
  local d, h, side, raw = { head = {}, hunks = {} }, nil, nil, {}
  local lines = vim.split(out, '\n', { plain = true })
  if lines[#lines] == '' then
    lines[#lines] = nil
  end
  for _, l in ipairs(lines) do
    local a, b, c, n = l:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')
    if a then
      h = { a = tonumber(a), b = tonumber(b) or 1, c = tonumber(c), d = tonumber(n) or 1, line = l }
      h.old, h.new, side = {}, {}, nil
      raw[#d.hunks + 1] = { l }
      d.hunks[#d.hunks + 1] = h
    elseif h then
      table.insert(raw[#d.hunks], l)
      local first = l:sub(1, 1)
      if first == '-' then
        h.old[#h.old + 1], side = l:sub(2), 'old'
      elseif first == '+' then
        h.new[#h.new + 1], side = l:sub(2), 'new'
      elseif first == '\\' and side then
        h[side .. '_eof'] = l
      end
    elseif l:find('^diff %-%-git ') or l:find('^%-%-%- ') or l:find('^%+%+%+ ') then
      d.head[#d.head + 1] = l
    end
  end
  for i, x in ipairs(d.hunks) do
    x.raw = table.concat(raw[i], '\n')
  end
  return d
end

-- The file's change as the op drills it (see parse): the index's (cached), else the work tree's
function M.diff(root, op, path)
  local args = { '--no-optional-locks', 'diff' }
  if M.OPS[op].cached then
    args[#args + 1] = '--cached'
  end
  vim.list_extend(args, FLAGS)
  vim.list_extend(args, { '--', path })
  local out, err = M.git(root, args)
  if not out then
    return nil, err
  end
  return M.parse(out)
end

-- The hunks picked as git wrote them (their @@ lines too: a hunk moved since is another one), or
-- nil if the diff has no longer as many
function M.raw(d, picked)
  local t = {}
  for _, i in ipairs(picked) do
    if not d.hunks[i] then
      return nil
    end
    t[#t + 1] = d.hunks[i].raw
  end
  return table.concat(t, '\n')
end

-- The patch of the hunks picked (their indices, in order) for git apply --unidiff-zero; reverse,
-- each turned around (the lines it removes added back, those it adds removed), for an op that
-- takes the change out. With no context to find a hunk by, git apply puts it where the new side
-- of its @@ line says, in the file as the hunks before it have left it, and one that only adds
-- lines goes there as it is. A hunk skipped before it would move it by the lines that one adds or
-- removes, so its new side is where the hunks picked before it leave its start (git add -p and
-- gitsigns count it the same way); git diff's own, the place after all of them, isn't.
function M.patch(d, picked, reverse)
  local out, shift = vim.list_extend({}, d.head), 0
  for _, i in ipairs(picked) do
    local h = d.hunks[i]
    local start, count, adds = h.a, h.b, h.d
    local old, new, old_eof, new_eof = h.old, h.new, h.old_eof, h.new_eof
    if reverse then
      start, count, adds = h.c, h.d, h.b
      old, new, old_eof, new_eof = new, old, new_eof, old_eof
    end
    out[#out + 1] = ('@@ -%d,%d +%d,%d @@'):format(start, count, start + shift + (count == 0 and 1 or 0), adds)
    for _, l in ipairs(old) do
      out[#out + 1] = '-' .. l
    end
    if old_eof then
      out[#out + 1] = old_eof
    end
    for _, l in ipairs(new) do
      out[#out + 1] = '+' .. l
    end
    if new_eof then
      out[#out + 1] = new_eof
    end
    shift = shift + adds - count
  end
  return table.concat(out, '\n') .. '\n'
end

-- Applies the op to the files picked whole (their paths, at once), then to the hunks picked of
-- the others, a file at a time ({ path, picked, raw }): its hunks diffed again, and applied only
-- if those picked are still as they were (raw), as the shell's digest checks them. Stops at the
-- first git refuses, as the shell's && does, and returns why.
function M.apply(root, op, whole, parts)
  local o = M.OPS[op]
  if #whole > 0 then
    local ok, err = M.git(root, vim.list_extend(vim.list_extend({}, o.whole), whole))
    if not ok then
      return err
    end
  end
  for _, p in ipairs(parts) do
    local d, err = M.diff(root, op, p.path)
    if not d then
      return err
    elseif M.raw(d, p.picked) ~= p.raw then
      return p.path .. ' changed since its hunks were picked: pick them again'
    end
    local args = { 'apply', '--unidiff-zero', '--whitespace=nowarn', '-' }
    if o.index then
      table.insert(args, 2, '--cached')
    end
    local ok, aerr = M.git(root, args, M.patch(d, p.picked, o.reverse))
    if not ok then
      return aerr
    end
  end
end

-- The line in the file of a hunk (its new side's): its first line added, or, one that only
-- removes lines, the line they were under (over the first line: 1), as gl.diff marks them
function M.line(h)
  return h.d > 0 and h.c or math.max(h.c, 1)
end

-- The line of the lines b that line n of the text a is, by their diff (in a change, its first):
-- the index's line of a hunk (unstage's), in the file as it is, its own changes after the staged
function M.translate(a, b, n)
  local shift = 0
  for _, h in ipairs(vim.text.diff(a, table.concat(b, '\n') .. '\n', { result_type = 'indices' })) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if ca > 0 and n >= sa and n < sa + ca then
      return math.max(sb, 1)
    elseif n < sa or ca == 0 and n == sa then
      break
    end
    shift = shift + cb - ca
  end
  return n + shift
end

return M
