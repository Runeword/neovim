local vim = vim

-- What the language servers answer about the symbols at given positions, remembered per
-- buffer text, so hops land and the panel and pane update without waiting on a server:
-- lua_ls, for one, dozes off ~50 ms after its last request and then takes 100 ms (or a
-- second) to answer. Hops ask ahead of the next press (see refs.hop). Per position:
--   refs: the references, as { client, result } per client serving them, with `other`
--         set when a location besides the word itself came back (a hop lands there);
--         false when no attached server serves references
--   def:  the definition to preview (an item), or false when it's in the same file (a
--         jump away) or there is none
local M = {}

local memo = {} -- [buf] = { tick = changedtick, [row:col] = { refs, def, waiting } }

-- The memo entry for `pos` (0-indexed row, byte col) in `buf` as its text is now;
-- `create` makes a missing one
function M.at(buf, pos, create)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if not (memo[buf] and memo[buf].tick == tick) then
    memo[buf] = { tick = tick }
  end
  local key = pos[1] .. ':' .. pos[2]
  if create and not memo[buf][key] then
    memo[buf][key] = { waiting = {} }
  end
  return memo[buf][key]
end

-- Forget every answer: an edit elsewhere can change what refers to what
function M.forget()
  memo = {}
end

-- A hop lands on a word whose references are `refs`
function M.lands(refs)
  return refs and refs.other or false
end

-- Params for position `pos` of `buf`, in `client`'s encoding
local function position_params(client, buf, pos)
  local line = vim.api.nvim_buf_get_lines(buf, pos[1], pos[1] + 1, false)[1] or ''
  return {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = pos[1], character = vim.str_utfindex(line, client.offset_encoding, pos[2], false) },
  }
end

local fetch = {}

-- `refs` for `pos`, asking every attached client that serves references (vue_ls and
-- ts_ls share .vue files), the declaration included
function fetch.refs(buf, pos, done)
  local clients = vim.lsp.get_clients({ bufnr = buf, method = 'textDocument/references' })
  if #clients == 0 then
    return done(false)
  end
  local fname = vim.api.nvim_buf_get_name(buf)
  local refs, pending, failed = { other = false }, #clients, false
  for _, client in ipairs(clients) do
    local params = position_params(client, buf, pos)
    params.context = { includeDeclaration = true }
    local char = params.position.character
    local function answered(err, locations)
      failed = failed or err ~= nil
      refs[#refs + 1] = { client = client, result = locations or {} }
      for _, loc in ipairs(locations or {}) do
        local range = loc.range
        local itself = range.start.line == pos[1]
          and range.start.character <= char
          and char <= range['end'].character
          and vim.uri_to_fname(loc.uri) == fname
        refs.other = refs.other or not itself
      end
      pending = pending - 1
      if pending == 0 then
        -- (an error is no answer, unless another server's references made one)
        done((refs.other or not failed) and refs or nil)
      end
    end
    if not client:request('textDocument/references', params, answered, buf) then
      answered('not sent')
    end
  end
end

-- `def` for `pos`: the first definition a client gives, when it's in another file
function fetch.def(buf, pos, done)
  -- (a request no attached server can answer would raise an error notification)
  if #vim.lsp.get_clients({ bufnr = buf, method = 'textDocument/definition' }) == 0 then
    return done(false)
  end
  vim.lsp.buf_request_all(buf, 'textDocument/definition', function(client)
    return position_params(client, buf, pos)
  end, function(results)
    local failed = false
    for id, res in pairs(results) do
      failed = failed or res.err ~= nil
      local client = vim.lsp.get_client_by_id(id)
      local locs = res.result and (vim.islist(res.result) and res.result or { res.result }) or {}
      local it = client and locs[1] and vim.lsp.util.locations_to_items({ locs[1] }, client.offset_encoding)[1]
      if it then
        -- Same buffer = same file (buffers are matched by file, symlinks included)
        local def_buf = vim.uri_to_bufnr(locs[1].uri or locs[1].targetUri)
        return done(def_buf ~= buf and {
          filename = it.filename,
          buf = def_buf,
          pos = { it.lnum, it.col - 1 },
          end_pos = { it.end_lnum, it.end_col - 1 },
        })
      end
    end
    if not failed then
      done(false)
    else
      done(nil)
    end
  end)
end

local ASK_STALE_MS = 3000 -- a question left unanswered this long is asked again

-- Calls back with the `what` answer ('refs' or 'def') about `pos` in `buf`, async:
-- memoized, with one request shared by everyone asking meanwhile. nil means no answer
-- (an error), not memoized.
function M.ask(buf, pos, what, cb)
  local entry = M.at(buf, pos, true)
  if entry[what] ~= nil then
    return vim.schedule(function()
      cb(entry[what])
    end)
  end
  local waiting = entry.waiting[what]
  if waiting and vim.uv.now() - waiting.since < ASK_STALE_MS then
    waiting[#waiting + 1] = cb
    return
  end
  waiting = { cb, since = vim.uv.now() }
  entry.waiting[what] = waiting
  fetch[what](buf, pos, function(answer)
    entry[what] = answer
    if entry.waiting[what] == waiting then
      entry.waiting[what] = nil
    end
    vim.schedule(function()
      for _, f in ipairs(waiting) do
        f(answer)
      end
    end)
  end)
end

return M
