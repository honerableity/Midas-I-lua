-- Midas-I utils/rtdb.lua
-- Firebase Realtime Database REST wrapper.
-- Node equiv: utils/firebase.js (but Firestore -> RTDB, different product,
-- no official Lua SDK exists for either -- see chat decision log).
--
-- Env required:
--   RTDB_URL    e.g. https://markotop-sdk-default-rtdb.asia-southeast1.firebasedatabase.app
--   RTDB_SECRET Legacy database secret, Firebase Console > Project Settings >
--               Service Accounts > Database secrets (see auth docs:
--               https://firebase.google.com/docs/database/rest/auth)

local http = require('coro-http')
local json = require('json')

local M = {}

local RTDB_URL = os.getenv('RTDB_URL')
local RTDB_SECRET = os.getenv('RTDB_SECRET')

if not RTDB_URL then
  error('Missing RTDB_URL in env. e.g. https://<project>-default-rtdb.<region>.firebasedatabase.app')
end
if not RTDB_SECRET then
  error('Missing RTDB_SECRET in env. Get from Firebase Console > Project Settings > Service Accounts > Database secrets.')
end

-- Strip trailing slash so path-joining below never double-slashes.
RTDB_URL = RTDB_URL:gsub('/+$', '')

-- Build "{RTDB_URL}/{path}.json?auth=...&extra_query" -- every RTDB REST
-- call needs the trailing ".json", per REST API spec (any URL + .json is
-- a valid REST endpoint).
local function buildUrl(path, extraQuery)
  path = path:gsub('^/+', '') -- strip leading slash, avoid //path.json
  local url = RTDB_URL .. '/' .. path .. '.json?auth=' .. RTDB_SECRET
  if extraQuery then
    url = url .. '&' .. extraQuery
  end
  return url
end

-- Shared request runner. Must run inside a coroutine (discordia's event
-- handlers already do -- see coro-http docs, request() yields until done).
-- Returns decoded body (table/number/string/nil) + raw response object.
local function doRequest(method, path, body, extraQuery, extraHeaders)
  local url = buildUrl(path, extraQuery)
  local headers = { { 'Content-Type', 'application/json' } }
  if extraHeaders then
    for _, h in ipairs(extraHeaders) do table.insert(headers, h) end
  end

  local payload = nil
  if body ~= nil then
    payload = json.encode(body)
  end

  local res, resBody = http.request(method, url, headers, payload)

  if res.code >= 400 then
    return nil, res, resBody
  end

  local decoded = nil
  if resBody and resBody ~= '' and resBody ~= 'null' then
    local ok, parsed = pcall(json.decode, resBody)
    decoded = ok and parsed or resBody
  end

  return decoded, res
end

-- ---------- basic CRUD ----------

-- GET {path}.json -- returns decoded value or nil if path empty/missing.
function M.get(path)
  local data, res, errBody = doRequest('GET', path)
  if not data and res and res.code >= 400 then
    error('[rtdb] GET ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return data
end

-- PUT {path}.json -- overwrites everything at path. Node equiv: doc.set()
function M.set(path, value)
  local data, res, errBody = doRequest('PUT', path, value)
  if res.code >= 400 then
    error('[rtdb] PUT ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return data
end

-- PATCH {path}.json -- merges only given keys. Node equiv: doc.set(x, {merge:true})
function M.update(path, patch)
  local data, res, errBody = doRequest('PATCH', path, patch)
  if res.code >= 400 then
    error('[rtdb] PATCH ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return data
end

-- POST {path}.json -- auto-generates a pushId key, returns { name = "-NxYz..." }.
-- Node equiv: collection.add(). Returns just the new key string.
function M.push(path, value)
  local data, res, errBody = doRequest('POST', path, value)
  if res.code >= 400 then
    error('[rtdb] POST ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return data and data.name or nil
end

-- DELETE {path}.json -- Node equiv: doc.delete()
function M.delete(path)
  local _, res, errBody = doRequest('DELETE', path)
  if res.code >= 400 then
    error('[rtdb] DELETE ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return true
end

-- ---------- atomic server-side increment ----------
-- Uses the {".sv":{"increment":N}} sentinel -- runs atomically on Firebase's
-- server, no read-modify-write race, no transaction/ETag dance needed.
-- Node equiv: FieldValue.increment(N) (Firestore). RTDB web-SDK equiv:
-- ServerValue.increment(N) -- REST payload form confirmed via official docs.
function M.increment(path, amount)
  amount = amount or 1
  local patch = {}
  -- path itself is the field to increment; wrap as a single-key PATCH at
  -- its parent so RTDB applies the sentinel to exactly that field.
  local parent, key = path:match('^(.*)/([^/]+)$')
  if not parent then
    -- top-level key, no parent segment
    parent, key = '', path
  end
  patch[key] = { [".sv"] = { increment = amount } }
  return M.update(parent, patch)
end

-- ---------- ETag conditional writes ----------
-- For read-then-write races that aren't a pure increment (e.g. list
-- mutation). Node equiv: Firestore transactions.
-- Usage:
--   local value, etag = rtdb.getWithEtag(path)
--   local ok, newValueOrEtag = rtdb.conditionalSet(path, newValue, etag)
--   if not ok then -- retry: newValueOrEtag is the current value+etag, redo the merge

function M.getWithEtag(path)
  local data, res, errBody = doRequest('GET', path, nil, nil, { { 'X-Firebase-ETag', 'true' } })
  if res.code >= 400 then
    error('[rtdb] GET(etag) ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  local etag = nil
  for _, h in ipairs(res.headers or {}) do
    if h[1]:lower() == 'etag' then etag = h[2] end
  end
  return data, etag
end

-- Returns true, newValue on success.
-- Returns false, currentValue, currentEtag on 412 conflict -- caller must
-- recompute against currentValue and retry with currentEtag.
function M.conditionalSet(path, value, etag)
  local data, res, errBody = doRequest('PUT', path, value, nil, { { 'if-match', etag } })
  if res.code == 412 then
    -- 412 body IS the current value; response also carries the new ETag header
    local currentEtag = nil
    for _, h in ipairs(res.headers or {}) do
      if h[1]:lower() == 'etag' then currentEtag = h[2] end
    end
    return false, data, currentEtag
  end
  if res.code >= 400 then
    error('[rtdb] conditionalSet ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return true, data
end

-- ---------- simple queries ----------
-- RTDB REST query params: orderBy (JSON-quoted string), equalTo, startAt,
-- endAt, limitToFirst/Last. Weaker than Firestore .where() -- single sort
-- key only, results returned as a table keyed by pushId, not an array.
-- Node equiv: db.collection(x).where(field, op, value).get()

-- orderBy a child key, equalTo a value. Returns decoded table (or nil if empty).
function M.queryEqualTo(path, orderByKey, value)
  local orderByParam = 'orderBy=' .. json.encode(orderByKey)
  local equalToParam = 'equalTo=' .. json.encode(value)
  local data, res, errBody = doRequest('GET', path, nil, orderByParam .. '&' .. equalToParam)
  if res.code >= 400 then
    error('[rtdb] query ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return data
end

-- orderBy a child key, results with value <= endAtValue.
-- Node equiv: .where('expiresAt', '<=', nowMs) -- see utils/moderation.lua
function M.queryEndAt(path, orderByKey, endAtValue)
  local orderByParam = 'orderBy=' .. json.encode(orderByKey)
  local endAtParam = 'endAt=' .. json.encode(endAtValue)
  local data, res, errBody = doRequest('GET', path, nil, orderByParam .. '&' .. endAtParam)
  if res.code >= 400 then
    error('[rtdb] query ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return data
end

return M
