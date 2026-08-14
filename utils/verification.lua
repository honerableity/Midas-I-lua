local rtdb = require('rtdb')
local http = require('coro-http')
local json = require('json')
local words = require('words')

local hasOpenssl, openssl = pcall(require, 'openssl')
if not hasOpenssl then
  print('[verification] WARNING: openssl module not found, falling back to '
    .. 'math.random for code generation (weaker than crypto.randomInt).')
end

local M = {}

local CODE_LENGTH = 5
M.EXPIRY_MS = 15 * 60 * 1000 -- 15 min
local function randomInt(maxExclusive)
  if hasOpenssl then
    while true do
      local byte = string.byte(openssl.random(1))
      local limit = 256 - (256 % maxExclusive)
      if byte < limit then
        return byte % maxExclusive
      end
    end
  end
  return math.random(0, maxExclusive - 1)
end

function M.genCode()
  local picked = {}
  local pool = {}
  for i, w in ipairs(words) do pool[i] = w end

  for _ = 1, CODE_LENGTH do
    local idx = randomInt(#pool) + 1
    table.insert(picked, pool[idx])
    table.remove(pool, idx) 
  end
  return table.concat(picked, '-')
end

function M.createSession(discordId)
  local code = M.genCode()
  local expiresAt = os.time() * 1000 + M.EXPIRY_MS
  rtdb.set('verifications/' .. discordId, {
    code = code,
    expiresAt = expiresAt,
    createdAt = os.time() * 1000,
  })
  return { code = code, expiresAt = expiresAt }
end

function M.getSession(discordId)
  local data = rtdb.get('verifications/' .. discordId)
  if not data then return nil end
  if os.time() * 1000 > data.expiresAt then
    M.clearSession(discordId) 
    return nil
  end
  return data
end

function M.clearSession(discordId)
  rtdb.delete('verifications/' .. discordId)
end

function M.getGuildConfig(guildId)
  return rtdb.get('guildConfig/' .. guildId)
end

function M.setGuildRole(guildId, roleId)
  rtdb.update('guildConfig/' .. guildId, { verifiedRoleId = roleId })
end

function M.saveVerifiedUser(discordId, opts)
  rtdb.update('verifiedUsers/' .. discordId, {
    robloxId = opts.robloxId,
    robloxUsername = opts.robloxUsername,
    verifiedAt = os.time() * 1000,
    guildId = opts.guildId,
  })
end

function M.getVerifiedUser(discordId)
  return rtdb.get('verifiedUsers/' .. discordId)
end

function M.removeVerifiedUser(discordId)
  rtdb.delete('verifiedUsers/' .. discordId)
end

function M.fetchRobloxDescription(username)
  local userReqBody = json.encode({ usernames = { username }, excludeBannedUsers = false })
  local userHeaders = { { 'Content-Type', 'application/json' } }
  local userRes, userResBody = http.request(
    'POST', 'https://users.roblox.com/v1/usernames/users', userHeaders, userReqBody
  )
  if userRes.code >= 400 then
    error('Roblox user lookup failed: ' .. userRes.code)
  end
  local userData = json.decode(userResBody)
  if not userData.data or #userData.data == 0 then
    return { notFound = true }
  end

  local robloxId = userData.data[1].id

  local profileRes, profileResBody = http.request(
    'GET', 'https://users.roblox.com/v1/users/' .. robloxId, {}
  )
  if profileRes.code >= 400 then
    error('Roblox profile fetch failed: ' .. profileRes.code)
  end
  local profileData = json.decode(profileResBody)

  return {
    notFound = false,
    robloxId = robloxId,
    robloxUsername = profileData.name,
    description = profileData.description or '',
  }
end

function M.fetchRobloxProfileDetails(robloxId)
  local userRes, userResBody = http.request(
    'GET', 'https://users.roblox.com/v1/users/' .. robloxId, {}
  )
  if userRes.code >= 400 then
    error('Roblox user fetch failed: ' .. userRes.code)
  end
  local user = json.decode(userResBody)

  local groupsRes, groupsResBody = http.request(
    'GET', 'https://groups.roblox.com/v1/users/' .. robloxId .. '/groups/roles', {}
  )
  if groupsRes.code >= 400 then
    error('Roblox groups fetch failed: ' .. groupsRes.code)
  end
  local groupsData = json.decode(groupsResBody)

  local groups = {}
  if groupsData.data then
    for _, g in ipairs(groupsData.data) do
      table.insert(groups, { name = g.group.name, role = g.role.name })
    end
  end

  return {
    username = user.name,
    displayName = user.displayName,
    created = user.created, -- ISO string
    hasVerifiedBadge = user.hasVerifiedBadge,
    groups = groups,
  }
end

function M.normalize(str)
  local s = str:lower()
  s = s:gsub('\226\128[\139\140\141]', '')
  s = s:gsub('\239\187\191', '') 
  s = s:gsub('[%s%-]+', '')
  return s
end

function M.descriptionContainsCode(description, code)
  return M.normalize(description):find(M.normalize(code), 1, true) ~= nil
end

return M
