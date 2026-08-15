local http = require('coro-http')
local json = require('json')
local fs = require('fs')
local pathjoin = require('pathjoin')
local dotenv = require('dotenv')

local M = {}

-- dotenv.load() (called in main.lua) only stores values in dotenv's own
-- internal table, it does not export them as real OS env vars. Reading via
-- os.getenv() here would miss anything set through .env, so use dotenv.get()
-- instead, which checks its own table first then falls back to os.getenv().
local RTDB_URL = dotenv.get('RTDB_URL')
local RTDB_SECRET = dotenv.get('RTDB_SECRET')

if not RTDB_URL then
  error('Missing RTDB_URL in env. e.g. https://<project>-default-rtdb.<region>.firebasedatabase.app')
end
if not RTDB_SECRET then
  error('Missing RTDB_SECRET in env. Get from Firebase Console > Project Settings > Service Accounts > Database secrets.')
end

RTDB_URL = RTDB_URL:gsub('/+$', '')

-- `module.dir` is only populated by Luvit for the true entrypoint script,
-- not for files loaded via require() (this file included) — it resolves to
-- Lua's built-in module() function instead in that case, which has no .dir
-- field. Luvit apps are always run with CWD at the project root, so we build
-- the fallback path relative to CWD instead.
local FALLBACK_DIR = pathjoin.pathJoin('.', 'data', 'rtdb-fallback')
local offline = false

local function buildUrl(path, extraQuery)
  path = path:gsub('^/+', '')
  local url = RTDB_URL .. '/' .. path .. '.json?auth=' .. RTDB_SECRET
  if extraQuery then
    url = url .. '&' .. extraQuery
  end
  return url
end

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

  local ok, res, resBody = pcall(http.request, method, url, headers, payload)
  if not ok then
    return nil, nil, tostring(res)
  end

  if res.code >= 400 then
    return nil, res, resBody
  end

  local decoded = nil
  if resBody and resBody ~= '' and resBody ~= 'null' then
    local okDecode, parsed = pcall(json.decode, resBody)
    decoded = okDecode and parsed or resBody
  end

  return decoded, res
end

local function localPath(path)
  path = path:gsub('^/+', ''):gsub('/+$', '')
  if path == '' then path = '_root' end
  return pathjoin.pathJoin(FALLBACK_DIR, path .. '.json')
end

local function ensureDir(filePath)
  local dir = pathjoin.pathJoin(filePath, '..')
  local parts = {}
  for part in dir:gmatch('[^/]+') do table.insert(parts, part) end
  local cur = dir:sub(1, 1) == '/' and '/' or ''
  for _, part in ipairs(parts) do
    cur = cur == '' and part or (cur .. '/' .. part)
    if cur ~= '' and not fs.existsSync(cur) then
      pcall(fs.mkdirSync, cur)
    end
  end
end

local function localRead(path)
  local file = localPath(path)
  if not fs.existsSync(file) then return nil end
  local content = fs.readFileSync(file)
  if not content or content == '' then return nil end
  local ok, parsed = pcall(json.decode, content)
  return ok and parsed or nil
end

local function localWrite(path, value)
  local file = localPath(path)
  if value == nil then
    if fs.existsSync(file) then pcall(fs.unlinkSync, file) end
    return
  end
  ensureDir(file)
  fs.writeFileSync(file, json.encode(value))
end

local function deepMerge(base, patch)
  if type(patch) ~= 'table' then return patch end
  if type(base) ~= 'table' then base = {} end
  for k, v in pairs(patch) do
    if type(v) == 'table' and type(base[k]) == 'table' then
      base[k] = deepMerge(base[k], v)
    else
      base[k] = v
    end
  end
  return base
end

local function walkLocalFiles(dir, out)
  out = out or {}
  if not fs.existsSync(dir) then return out end
  local ok, entries = pcall(fs.readdirSync, dir)
  if not ok then return out end
  for _, name in ipairs(entries) do
    local full = pathjoin.pathJoin(dir, name)
    local stat = fs.statSync(full)
    if stat and stat.type == 'directory' then
      walkLocalFiles(full, out)
    elseif name:match('%.json$') then
      table.insert(out, full)
    end
  end
  return out
end

local function fileToRtdbPath(file)
  local rel = file:sub(#FALLBACK_DIR + 2)
  rel = rel:gsub('%.json$', '')
  if rel == '_root' then rel = '' end
  return rel
end

local function wipeLocal()
  local files = walkLocalFiles(FALLBACK_DIR)
  for _, file in ipairs(files) do
    pcall(fs.unlinkSync, file)
  end

  local function removeEmptyDirs(dir)
    local ok, entries = pcall(fs.readdirSync, dir)
    if not ok then return end
    for _, name in ipairs(entries) do
      local full = pathjoin.pathJoin(dir, name)
      local stat = fs.statSync(full)
      if stat and stat.type == 'directory' then
        removeEmptyDirs(full)
      end
    end
    ok, entries = pcall(fs.readdirSync, dir)
    if ok and #entries == 0 and dir ~= FALLBACK_DIR then
      pcall(fs.rmdirSync, dir)
    end
  end
  removeEmptyDirs(FALLBACK_DIR)
end

local function resync()
  print('[rtdb] back online, resyncing local fallback data')
  local files = walkLocalFiles(FALLBACK_DIR)
  local failed = false

  for _, file in ipairs(files) do
    local rtdbPath = fileToRtdbPath(file)
    local content = fs.readFileSync(file)
    local ok, localValue = pcall(json.decode, content)
    if ok then
      local remote, res, errBody = doRequest('GET', rtdbPath)
      if res == nil then
        failed = true
        break
      end
      local merged = deepMerge(remote, localValue)
      local _, putRes, putErr = doRequest('PUT', rtdbPath, merged)
      if putRes == nil or putRes.code >= 400 then
        print('[rtdb] resync failed for ' .. rtdbPath .. ': ' .. tostring(putErr))
        failed = true
        break
      end
    end
  end

  if not failed then
    wipeLocal()
    print('[rtdb] resync complete, local fallback cleared')
  else
    print('[rtdb] resync incomplete, will retry on next successful connection')
  end
end

local function tryRequest(method, path, body, extraQuery, extraHeaders)
  local data, res, errBody = doRequest(method, path, body, extraQuery, extraHeaders)
  if res == nil then
    offline = true
    return nil, nil, errBody, true
  end

  if offline then
    offline = false
    local ok, err = pcall(resync)
    if not ok then
      print('[rtdb] resync error: ' .. tostring(err))
    end
  end

  return data, res, errBody, false
end

function M.get(path)
  local data, res, errBody, failed = tryRequest('GET', path)
  if failed then
    return localRead(path)
  end
  if res.code >= 400 then
    error('[rtdb] GET ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return data
end

function M.set(path, value)
  local data, res, errBody, failed = tryRequest('PUT', path, value)
  if failed then
    localWrite(path, value)
    return value
  end
  if res.code >= 400 then
    error('[rtdb] PUT ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return data
end

function M.update(path, patch)
  local data, res, errBody, failed = tryRequest('PATCH', path, patch)
  if failed then
    local current = localRead(path)
    local merged = deepMerge(current, patch)
    localWrite(path, merged)
    return patch
  end
  if res.code >= 400 then
    error('[rtdb] PATCH ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return data
end

function M.push(path, value)
  local data, res, errBody, failed = tryRequest('POST', path, value)
  if failed then
    local key = 'local_' .. tostring(os.time()) .. '_' .. tostring(math.random(100000, 999999))
    local current = localRead(path) or {}
    current[key] = value
    localWrite(path, current)
    return key
  end
  if res.code >= 400 then
    error('[rtdb] POST ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return data and data.name or nil
end

function M.delete(path)
  local data, res, errBody, failed = tryRequest('DELETE', path)
  if failed then
    localWrite(path, nil)
    return true
  end
  if res.code >= 400 then
    error('[rtdb] DELETE ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return true
end

function M.increment(path, amount)
  amount = amount or 1
  local parent, key = path:match('^(.*)/([^/]+)$')
  if not parent then
    parent, key = '', path
  end

  local patch = {}
  patch[key] = { [".sv"] = { increment = amount } }
  local data, res, errBody, failed = tryRequest('PATCH', parent, patch)
  if failed then
    local current = localRead(parent) or {}
    current[key] = (type(current[key]) == 'number' and current[key] or 0) + amount
    localWrite(parent, current)
    return current
  end
  if res.code >= 400 then
    error('[rtdb] PATCH ' .. parent .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return data
end

function M.getWithEtag(path)
  local data, res, errBody = doRequest('GET', path, nil, nil, { { 'X-Firebase-ETag', 'true' } })
  if res == nil then
    offline = true
    error('[rtdb] GET(etag) ' .. path .. ' failed: RTDB unreachable, no local fallback for etag reads')
  end
  if res.code >= 400 then
    error('[rtdb] GET(etag) ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  if offline then
    offline = false
    pcall(resync)
  end
  local etag = nil
  for _, h in ipairs(res.headers or {}) do
    if h[1]:lower() == 'etag' then etag = h[2] end
  end
  return data, etag
end

function M.conditionalSet(path, value, etag)
  local data, res, errBody = doRequest('PUT', path, value, nil, { { 'if-match', etag } })
  if res == nil then
    offline = true
    error('[rtdb] conditionalSet ' .. path .. ' failed: RTDB unreachable, no local fallback for conditional writes')
  end
  if res.code == 412 then
    local currentEtag = nil
    for _, h in ipairs(res.headers or {}) do
      if h[1]:lower() == 'etag' then currentEtag = h[2] end
    end
    return false, data, currentEtag
  end
  if res.code >= 400 then
    error('[rtdb] conditionalSet ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  if offline then
    offline = false
    pcall(resync)
  end
  return true, data
end

function M.queryEqualTo(path, orderByKey, value)
  local orderByParam = 'orderBy=' .. json.encode(orderByKey)
  local equalToParam = 'equalTo=' .. json.encode(value)
  local data, res, errBody = doRequest('GET', path, nil, orderByParam .. '&' .. equalToParam)
  if res == nil then
    offline = true
    error('[rtdb] query ' .. path .. ' failed: RTDB unreachable, no local fallback for queries')
  end
  if res.code >= 400 then
    error('[rtdb] query ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  if offline then
    offline = false
    pcall(resync)
  end
  return data
end

function M.queryEndAt(path, orderByKey, endAtValue)
  local orderByParam = 'orderBy=' .. json.encode(orderByKey)
  local endAtParam = 'endAt=' .. json.encode(endAtValue)
  local data, res, errBody = doRequest('GET', path, nil, orderByParam .. '&' .. endAtParam)
  if res == nil then
    offline = true
    error('[rtdb] query ' .. path .. ' failed: RTDB unreachable, no local fallback for queries')
  end
  if res.code >= 400 then
    error('[rtdb] query ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  if offline then
    offline = false
    pcall(resync)
  end
  return data
end

return M
