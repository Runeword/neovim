local vim = vim

-- What the language servers answer about the symbols at given positions, remembered so
-- hops land and the panel and pane update without waiting on a server: lua_ls, for one,
-- dozes off ~50 ms after its last request and then takes 100 ms (or a second) to
-- answer. Hops ask ahead of the next press (see refs.hop). The positions inside one word
-- share their answers, asked about at its start. Per word:
--   refs: the references, as { client, result } per client serving them, with `other`
--         set when a location besides the word itself came back (a hop lands there);
--         false when no attached server serves references
--   defs: the definitions, as { client, result } per client giving some (the pane
--         previews the first, the list marks them); false when no attached server
--         serves definitions
-- An answer holds while the text it was given about is unchanged: the asking buffer's,
-- that of the files it points into (`files`, their versions then) and, as an edit
-- anywhere can change what refers to what, every file buffer's (`epoch`). An answer
-- some server failed to give its part of is passed on, not remembered.
local M = {}

local memo = {} -- [buf] = { tick = changedtick, count = words, [row:col] = entry }
-- entry: { refs, defs, waiting = { [what] = the question out to the servers } }
local epoch = 0 -- bumped by each edit of a file buffer (see M.changed)
local inflight = {} -- [question] = true, for M.cancel
local MAX_WORDS = 500 -- a buffer's answers start afresh past this many words

local uri_bufs = {} -- [uri] = buf

-- The buffer of `uri`, if there is one (none is made for a file: a list can name
-- hundreds). That there's none is remembered until a buffer is made (M.buffer_added).
function M.uri_buf(uri)
  local buf = uri_bufs[uri]
  if buf == false or (buf and vim.api.nvim_buf_is_valid(buf)) then
    return buf or nil
  end
  local fname = vim.uri_to_fname(uri)
  buf = vim.fn.bufexists(fname) == 1 and vim.fn.bufnr(fname) or -1
  uri_bufs[uri] = buf > 0 and buf
  return uri_bufs[uri] or nil
end

-- A buffer was made: a file found without one may have it
function M.buffer_added()
  for uri, buf in pairs(uri_bufs) do
    if buf == false then
      uri_bufs[uri] = nil
    end
  end
end

-- The version of the text at `uri`: the file's modification time and size, or its
-- buffer's changedtick while that has changes not written (loading a file leaves it be)
local function version(uri)
  local buf = M.uri_buf(uri)
  if buf and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
    return 'b' .. vim.api.nvim_buf_get_changedtick(buf)
  end
  local stat = vim.uv.fs_stat(vim.uri_to_fname(uri))
  return stat and ('f%d.%d.%d'):format(stat.mtime.sec, stat.mtime.nsec, stat.size) or '-'
end

-- The versions of the files `answer` points into
local function files_of(answer)
  local files = {}
  for _, r in ipairs(answer) do
    for _, loc in ipairs(r.result) do
      local uri = loc.uri or loc.targetUri
      if uri and not files[uri] then
        files[uri] = version(uri)
      end
    end
  end
  return files
end

local CHECKED_MS = 1000 -- the files of an answer checked this recently are taken as unchanged

-- Whether `answer` (a table) still holds. (Edits bump the epoch at once; a file changed
-- on disk shows within CHECKED_MS.)
local function fresh(answer)
  if answer.epoch ~= epoch then
    return false
  end
  local now = vim.uv.now()
  if answer.checked and now - answer.checked < CHECKED_MS then
    return true
  end
  for uri, v in pairs(answer.files) do
    if version(uri) ~= v then
      return false
    end
  end
  answer.checked = now
  return true
end

local word = vim.regex([[\k\+$]])

-- `pos` (0-indexed row, byte col) in `buf` moved to the start of the word it's in, if any
function M.word_start(buf, pos)
  local line = vim.api.nvim_buf_get_lines(buf, pos[1], pos[1] + 1, false)[1] or ''
  if pos[2] >= #line then
    return pos
  end
  local stop = pos[2] + #vim.fn.strcharpart(line:sub(pos[2] + 1), 0, 1) -- (the character there included)
  local start = word:match_line(buf, pos[1], 0, stop)
  return start and { pos[1], start } or pos
end

-- The memo entry for the word at `pos` in `buf` as its text is now, its answers that no
-- longer hold dropped; `create` makes a missing one. Also returns the word's start.
function M.at(buf, pos, create)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil, pos
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local m = memo[buf]
  if not (m and m.tick == tick) then
    m = { tick = tick, count = 0 }
    memo[buf] = m
  end
  pos = M.word_start(buf, pos)
  local key = pos[1] .. ':' .. pos[2]
  local entry = m[key]
  if entry then
    for _, what in ipairs({ 'refs', 'defs' }) do
      if entry[what] and not fresh(entry[what]) then
        entry[what] = nil
      end
    end
  elseif create then
    if m.count >= MAX_WORDS then
      m = { tick = tick, count = 0 }
      memo[buf] = m
    end
    entry = { waiting = {} }
    m[key] = entry
    m.count = m.count + 1
  end
  return entry, pos
end

-- The `what` answer about the word at `pos` in `buf`, if known
function M.known(buf, pos, what)
  local entry = M.at(buf, pos)
  if entry then
    return entry[what]
  end
end

-- Forget the answers about `buf` (a server attached or left: it answers otherwise), or
-- every answer (files may have changed out of sight)
function M.forget(buf)
  if buf then
    memo[buf] = nil
  else
    memo = {}
    epoch = epoch + 1
  end
end

-- A file buffer was edited: what refers to what may have changed anywhere
function M.changed()
  epoch = epoch + 1
end

-- The current epoch (see M.changed): the panel keys what it shows with it
function M.epoch()
  return epoch
end

-- Servers loading the project: [client id] = { begun = whether it reported progress yet },
-- false once done (see M.warm_up)
local warming = {}
local WARMUP_MS = 5000
local WARMUP_MAX_MS = 60000 -- (a progress that never ends ends the loading anyway)

-- Server `id` attached. While it loads the project its answers can lack what it hasn't
-- read yet (ts_ls's do, until its "Initializing JS/TS language features" ends): a first
-- progress it reports within WARMUP_MS of attaching is taken for that, its answers then
-- passed on, not remembered; when it ends, those it gave before it began are dropped
-- too (see init.lua). One reporting none by then (lua_ls) answers in full from the start.
function M.warm_up(id)
  if warming[id] == nil then
    warming[id] = { begun = false }
    vim.defer_fn(function()
      if warming[id] and not warming[id].begun then
        warming[id] = false
      end
    end, WARMUP_MS)
    vim.defer_fn(function()
      warming[id] = warming[id] and false
    end, WARMUP_MAX_MS)
  end
end

-- Server `id` reported progress (`kind`: 'begin', 'report', 'end'): whether that ends its
-- loading (its answers so far are to be asked again)
function M.progress(id, kind)
  local w = warming[id]
  if w and kind == 'begin' then
    w.begun = true
  elseif w and kind == 'end' then
    warming[id] = false
    return true
  end
  return false
end

-- A hop lands on a word whose references are `refs`
function M.lands(refs)
  return refs and refs.other or false
end

-- A digest of `answer`, the same for the same locations in the same texts
function M.sig(answer)
  if type(answer) ~= 'table' then
    return tostring(answer)
  end
  if not answer.sig then
    local parts, versions = {}, {}
    for _, r in ipairs(answer) do
      for _, loc in ipairs(r.result) do
        local uri, range = loc.uri or loc.targetUri, loc.range or loc.targetSelectionRange
        parts[#parts + 1] = ('%s:%d:%d:%d:%d'):format(
          uri,
          range.start.line,
          range.start.character,
          range['end'].line,
          range['end'].character
        )
      end
    end
    for uri, v in pairs(answer.files or {}) do
      versions[#versions + 1] = uri .. '=' .. v
    end
    table.sort(parts)
    table.sort(versions)
    answer.sig = vim.fn.sha256(table.concat(parts, '\n') .. '\n' .. table.concat(versions, '\n'))
  end
  return answer.sig
end

-- Params for position `pos` of `buf`, in `client`'s encoding
local function position_params(client, buf, pos)
  local line = vim.api.nvim_buf_get_lines(buf, pos[1], pos[1] + 1, false)[1] or ''
  return {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = pos[1], character = vim.str_utfindex(line, client.offset_encoding, pos[2], false) },
  }
end

local FETCH_TIMEOUT_MS = 5000 -- the replies in this long go on without a server still silent

-- Ask each client attached to `buf` that serves `method` about `pos`, in its encoding,
-- `context` added to the params. Calls back with their replies ({ client, err, result,
-- char: the position's character for it }) and how many clients were asked, once each
-- replied; or, after FETCH_TIMEOUT_MS, with those in if one is still silent while others
-- replied (a server that stops never answers, and would hold them back). A lone server
-- is waited for. nil replies when no client serves it. `q.cancel` cancels what's pending.
local function request_all(buf, method, pos, context, q, done)
  local clients = vim.lsp.get_clients({ bufnr = buf, method = method })
  if #clients == 0 then
    return done(nil)
  end
  local replies, pending, left, over = {}, {}, #clients, false
  local function finish()
    if not over then
      over, q.cancel = true, nil
      done(replies, #clients)
    end
  end
  local function reply(r)
    replies[#replies + 1] = r
    left = left - 1
    if left == 0 then
      finish()
    end
  end
  for _, client in ipairs(clients) do
    local params = position_params(client, buf, pos)
    params.context = context
    local answered = false
    local ok, id = client:request(method, params, function(err, result)
      answered, pending[client] = true, nil
      reply({ client = client, err = err, result = result, char = params.position.character })
    end, buf)
    if ok and not answered then -- (unless it replied at once)
      pending[client] = id
    elseif not ok then
      reply({ client = client, err = { message = 'not sent' } })
    end
  end
  q.cancel = not over
      and function()
        over = true
        for client, id in pairs(pending) do
          pcall(client.cancel_request, client, id)
        end
      end
    or nil
  vim.defer_fn(function()
    if not over and #replies > 0 then
      finish()
    end
  end, FETCH_TIMEOUT_MS)
end

-- Errors after which asking again can get an answer: a request cancelled (-32800), the
-- content modified meanwhile (-32801), a server cancelling (-32802)
local TRANSIENT = { [-32800] = true, [-32801] = true, [-32802] = true }

-- How the `count` clients asked did, from their `replies`: nil when each answered,
-- 'partial' when only some did (or one still loading the project did, see M.warm_up),
-- else 'transient' when asking again can do better (a transient error, a server left
-- silent), 'error' when not (an answer of nothing, as gopls gives on a keyword)
local function status_of(replies, count)
  local ok, transient, loading = 0, #replies < count, false
  for _, r in ipairs(replies) do
    if r.err then
      transient = transient or TRANSIENT[r.err.code] or false
    else
      ok = ok + 1
      loading = loading or (warming[r.client.id] and warming[r.client.id].begun) or false
    end
  end
  if ok == count and not loading then
    return nil
  elseif ok == count then
    return 'partial'
  elseif ok > 0 then
    return 'partial'
  end
  return transient and 'transient' or 'error'
end

local fetch = {}

-- `refs` for `pos`, asking every attached client that serves references (vue_ls and
-- ts_ls share .vue files), the declaration included
function fetch.refs(buf, pos, q, done)
  local fname = vim.uri_to_fname(vim.uri_from_bufnr(buf))
  request_all(buf, 'textDocument/references', pos, { includeDeclaration = true }, q, function(replies, count)
    if not replies then
      return done(false)
    end
    local refs = { other = false }
    for _, r in ipairs(replies) do
      if not r.err then
        local locations = r.result or {}
        refs[#refs + 1] = { client = r.client, result = locations }
        for _, loc in ipairs(locations) do
          local range = loc.range
          local itself = range.start.line == pos[1]
            and range.start.character <= r.char
            and r.char <= range['end'].character
            and vim.uri_to_fname(loc.uri) == fname
          refs.other = refs.other or not itself
        end
      end
    end
    done(refs, status_of(replies, count))
  end)
end

-- `defs` for `pos`, asking every attached client that serves definitions
function fetch.defs(buf, pos, q, done)
  request_all(buf, 'textDocument/definition', pos, nil, q, function(replies, count)
    if not replies then
      return done(false)
    end
    local defs = {}
    for _, r in ipairs(replies) do
      local locs = not r.err and r.result and (vim.islist(r.result) and r.result or { r.result }) or {}
      if #locs > 0 then
        defs[#defs + 1] = { client = r.client, result = locs }
      end
    end
    done(defs, status_of(replies, count))
  end)
end

local ASK_STALE_MS = 10000 -- a question left unanswered this long is asked again
local RETRIES, RETRY_MS = 2, 150 -- a question failing for a transient reason is asked again

-- Calls back with the `what` answer ('refs' or 'defs') about the word at `pos` in `buf`,
-- async: memoized, with one question out to the servers shared by everyone asking
-- meanwhile. When the servers failed to answer it, it calls back with nil if asking
-- again may do (callers keep what they show), else with an answer of nothing. `tag`
-- names the asker for M.cancel.
function M.ask(buf, pos, what, cb, tag)
  local entry
  entry, pos = M.at(buf, pos, true)
  if not entry then
    return -- (the buffer is gone)
  end
  if entry[what] ~= nil then
    local answer = entry[what]
    return vim.schedule(function()
      cb(answer)
    end)
  end
  local q = entry.waiting[what]
  if q and vim.uv.now() - q.since < ASK_STALE_MS then
    q[#q + 1] = { cb = cb, tag = tag }
    return
  end
  q = { { cb = cb, tag = tag }, since = vim.uv.now(), entry = entry, what = what, tries = 0 }
  q.key = buf .. ':' .. pos[1] .. ':' .. pos[2]
  entry.waiting[what] = q
  inflight[q] = true
  local function send()
    local asked = epoch
    fetch[what](buf, pos, q, function(answer, status)
      if q.cancelled then
        return
      elseif status == 'transient' and q.tries < RETRIES then
        q.tries = q.tries + 1
        return vim.defer_fn(function()
          if not q.cancelled and vim.api.nvim_buf_is_valid(buf) then
            send()
          end
        end, RETRY_MS)
      end
      inflight[q] = nil
      if entry.waiting[what] == q then
        entry.waiting[what] = nil
      end
      if answer then
        answer.epoch, answer.files = asked, files_of(answer)
      end
      if status == nil then
        entry[what] = answer
      elseif status == 'transient' then
        answer = nil
      end
      vim.schedule(function()
        for _, waiter in ipairs(q) do
          waiter.cb(answer)
        end
      end)
    end)
  end
  send()
end

-- Drop the waiters tagged `tag`, but those asking about the words in `keep` (a set of
-- "buf:row:col"), and cancel the questions left with none
function M.cancel(tag, keep)
  for q in pairs(inflight) do
    if not (keep and keep[q.key]) then
      for i = #q, 1, -1 do
        if q[i].tag == tag then
          table.remove(q, i)
        end
      end
      if #q == 0 then
        q.cancelled, inflight[q] = true, nil
        if q.entry.waiting[q.what] == q then
          q.entry.waiting[q.what] = nil
        end
        if q.cancel then
          q.cancel()
        end
      end
    end
  end
end

return M
