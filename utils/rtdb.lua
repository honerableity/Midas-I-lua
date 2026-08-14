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

RTDB_URL = RTDB_URL:gsub('/+$', '')
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

function M.get(path)
  local data, res, errBody = doRequest('GET', path)
  if not data and res and res.code >= 400 then
    error('[rtdb] GET ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return data
end

function M.set(path, value)
  local data, res, errBody = doRequest('PUT', path, value)
  if res.code >= 400 then
    error('[rtdb] PUT ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return data
end
function M.update(path, patch)
  local data, res, errBody = doRequest('PATCH', path, patch)
  if res.code >= 400 then
    error('[rtdb] PATCH ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return data
end
function M.push(path, value)
  local data, res, errBody = doRequest('POST', path, value)
  if res.code >= 400 then
    error('[rtdb] POST ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return data and data.name or nil
end

function M.delete(path)
  local _, res, errBody = doRequest('DELETE', path)
  if res.code >= 400 then
    error('[rtdb] DELETE ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return true
end

function M.increment(path, amount)
  amount = amount or 1
  local patch = {}
  local parent, key = path:match('^(.*)/([^/]+)$')
  if not parent then
    parent, key = '', path
  end
  patch[key] = { [".sv"] = { increment = amount } }
  return M.update(parent, patch)
end
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
function M.conditionalSet(path, value, etag)
  local data, res, errBody = doRequest('PUT', path, value, nil, { { 'if-match', etag } })
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
  return true, data
end

function M.queryEqualTo(path, orderByKey, value)
  local orderByParam = 'orderBy=' .. json.encode(orderByKey)
  local equalToParam = 'equalTo=' .. json.encode(value)
  local data, res, errBody = doRequest('GET', path, nil, orderByParam .. '&' .. equalToParam)
  if res.code >= 400 then
    error('[rtdb] query ' .. path .. ' failed (' .. res.code .. '): ' .. tostring(errBody))
  end
  return data
end

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
