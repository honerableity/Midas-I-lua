-- Midas-I utils/verification.lua
-- Luau port of utils/verification.js
-- DB: Firestore -> Firebase Realtime Database (see utils/rtdb.lua + chat
-- decision log: separate parallel DB, not shared with Node bot).
-- Node's crypto.randomInt -> openssl.random (luvit built-in, confirmed via
-- luvit/luvit tests/test-crypto.lua: `pcall(require,'openssl')` is the
-- stdlib's own guard pattern, so it's bundled, not an external dep).
-- Falls back to math.random if the openssl module isn't present in this
-- build -- flagged loudly rather than silently degrading security.

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

-- ---------- unbiased random index, mirrors crypto.randomInt(0, max) ----------
local function randomInt(maxExclusive)
  if hasOpenssl then
    -- openssl.random(n) -> n cryptographically random bytes (string).
    -- Rejection-sample a single byte to avoid modulo bias, same goal as
    -- Node's crypto.randomInt (which is itself bias-free internally).
    while true do
      local byte = string.byte(openssl.random(1))
      local limit = 256 - (256 % maxExclusive)
      if byte < limit then
        return byte % maxExclusive
      end
    end
  end
  -- Fallback: math.random is not cryptographically secure. Acceptable here
  -- only as a degraded fallback -- see WARNING above.
  return math.random(0, maxExclusive - 1)
end

-- ---------- code generation ----------
-- Node: picks CODE_LENGTH unique words from the pool, no repeats in one code.
function M.genCode()
  local picked = {}
  local pool = {}
  for i, w in ipairs(words) do pool[i] = w end

  for _ = 1, CODE_LENGTH do
    local idx = randomInt(#pool) + 1 -- Lua tables are 1-indexed
    table.insert(picked, pool[idx])
    table.remove(pool, idx) -- no repeat word in same code
  end
  return table.concat(picked, '-')
end

-- ---------- verification sessions ----------
-- Node path: verifications/{discordId} (Firestore doc)
-- RTDB path: verifications/{discordId} (flat node, same shape)
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
    M.clearSession(discordId) -- lazy cleanup of stale nodes
    return nil
  end
  return data
end

function M.clearSession(discordId)
  rtdb.delete('verifications/' .. discordId)
end

-- ---------- guild config ----------
-- Node path: guildConfig/{guildId} (Firestore doc)
function M.getGuildConfig(guildId)
  return rtdb.get('guildConfig/' .. guildId)
end

-- Node: set(x, {merge:true}) -> RTDB PATCH, same merge semantics.
function M.setGuildRole(guildId, roleId)
  rtdb.update('guildConfig/' .. guildId, { verifiedRoleId = roleId })
end

-- ---------- verified users ----------
-- Persist Discord <-> Roblox link. Called at the moment role assign succeeds.
-- PATCH (merge) so re-verifying overwrites cleanly instead of erroring on
-- an existing node, matching Node's { merge: true }.
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

-- ---------- Roblox API calls ----------
-- Node used global fetch (Node 18+). Lua equiv: coro-http, must run inside
-- a coroutine -- discordia's event handlers and slash command callbacks
-- already run in one, same precondition as utils/rtdb.lua.

-- Fetches Roblox user id from username, then their profile description (blurb).
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

-- Full profile pull for /verify profile: account info + groups.
-- robloxId already known (from verifiedUsers record) so this skips the
-- username lookup step that fetchRobloxDescription needs.
-- Note: badges.roblox.com is intentionally not called here -- Roblox removed
-- unauthenticated access to that endpoint (4 May '26 API change), so it 401s
-- for every request without a logged-in .ROBLOSECURITY cookie. Not worth
-- standing up a Roblox account session just for a badge count.
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

-- ---------- code matching ----------
-- Node: strips zero-width chars (\u200B-\u200D, \uFEFF) via JS \u escapes.
-- Lua patterns have no \u{} syntax -- these are UTF-8 byte sequences here:
--   U+200B..U+200D -> \226\128\139 .. \226\128\141
--   U+FEFF         -> \239\187\191
-- Verified against the UTF-8 encoding of each codepoint.
function M.normalize(str)
  local s = str:lower()
  s = s:gsub('\226\128[\139\140\141]', '') -- U+200B, U+200C, U+200D
  s = s:gsub('\239\187\191', '') -- U+FEFF
  s = s:gsub('[%s%-]+', '') -- collapse spaces/dashes so "pearl - opal" still matches "pearl-opal"
  return s
end

function M.descriptionContainsCode(description, code)
  return M.normalize(description):find(M.normalize(code), 1, true) ~= nil
end

return M
