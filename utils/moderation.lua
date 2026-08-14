-- Midas-I utils/moderation.lua
-- Luau port of utils/moderation.js
-- DB: Firestore -> Firebase Realtime Database (see utils/rtdb.lua + chat
-- decision log: separate parallel DB, not shared with Node bot).

local rtdb = require('rtdb')
local discordia = require('discordia')
local enums = discordia.enums

local M = {}

-- ---------- duration parsing ----------
-- Node: parseDuration() -- accepts "10m","2h","3d","1w", "permanent"/"none"/""
-- -> nil (permanent). Returns ms, or nil for permanent.
-- Node distinguishes null (permanent) vs undefined (invalid) as two falsy
-- values -- Lua has only nil, so invalid returns false as a sentinel instead.
function M.parseDuration(input)
  if not input or input == '' then return nil end
  local s = tostring(input):trim():lower()
  if s == 'permanent' or s == 'perm' or s == 'none' or s == '' then return nil end

  local amount, unit = s:match('^(%d+)%s*(%a+)$')
  if not amount then return false end -- false = invalid (Node's `undefined`)

  local validUnits = {
    m = true, min = true, mins = true, minute = true, minutes = true,
    h = true, hr = true, hrs = true, hour = true, hours = true,
    d = true, day = true, days = true,
    w = true, week = true, weeks = true,
  }
  if not validUnits[unit] then return false end

  amount = tonumber(amount)
  local first = unit:sub(1, 1)
  if first == 'm' then return amount * 60 * 1000 end
  if first == 'h' then return amount * 60 * 60 * 1000 end
  if first == 'd' then return amount * 24 * 60 * 60 * 1000 end
  if first == 'w' then return amount * 7 * 24 * 60 * 60 * 1000 end
  return false
end

function M.formatDuration(ms)
  if ms == nil then return 'permanent' end
  local mins = math.floor(ms / 60000 + 0.5)
  if mins < 60 then return mins .. 'm' end
  local hours = math.floor(mins / 60 + 0.5)
  if hours < 24 then return hours .. 'h' end
  local days = math.floor(hours / 24 + 0.5)
  if days < 7 then return days .. 'd' end
  local weeks = math.floor(days / 7 + 0.5)
  return weeks .. 'w'
end

-- ---------- protected target guard ----------
-- Node: isProtectedTarget(guild, member, user) -- member is a fetched
-- GuildMember (nil if target isn't in guild, e.g. unban-by-id), user is
-- base User, fallback for bot check when member is nil.
function M.isProtectedTarget(guild, member, user)
  local targetUser = (member and member.user) or user
  if targetUser and targetUser.id == guild.ownerId then
    return { blocked = true, reason = 'server owner' }
  end
  if targetUser and targetUser.bot then
    return { blocked = true, reason = 'bot account' }
  end
  if member and member:hasPermission(enums.permission.manageGuild) then
    return { blocked = true, reason = 'has Manage Server permission' }
  end
  return { blocked = false }
end

-- ---------- mod action DM ----------
-- Node: sendModDM() -- best-effort, never throws, caller doesn't need pcall.
-- No moderator name/tag included by design (privacy).
function M.sendModDM(user, opts)
  local embed = {
    title = opts.reversal and ('Action reversed: ' .. opts.action) or ('Moderation action: ' .. opts.action),
    color = opts.reversal and 0x57f287 or 0xed4245,
    fields = { { name = 'Server', value = opts.guildName } },
  }
  if opts.reason then
    table.insert(embed.fields, { name = 'Reason', value = opts.reason })
  end
  if opts.duration ~= nil then
    table.insert(embed.fields, { name = 'Duration', value = opts.duration })
  end

  -- User:send() -- confirmed real, shortcut for getPrivateChannel():send()
  -- (SinisterRectus/Discordia libs/containers/User.lua). Best-effort, never
  -- throws to caller -- matches Node's .catch(() => {}) behavior.
  pcall(function() user:send({ embed = embed }) end)
end

-- ---------- guild mod config (setwarn thresholds) ----------
-- Node path: guildConfig/{guildId}.warnThresholds (Firestore doc field)
-- RTDB path: guildConfig/{guildId}/warnThresholds
function M.getWarnThresholds(guildId)
  local data = rtdb.get('guildConfig/' .. guildId .. '/warnThresholds')
  if not data then return {} end
  -- RTDB returns array-like tables as Lua tables w/ integer keys already
  -- when source was a JSON array; guard against sparse/dict shape too.
  local list = {}
  for _, v in pairs(data) do table.insert(list, v) end
  return list
end

function M.addWarnThreshold(guildId, threshold)
  local existing = M.getWarnThresholds(guildId)

  -- Node: filter out same-count rule, push new one, sort by count.
  local filtered = {}
  for _, t in ipairs(existing) do
    if t.count ~= threshold.count then table.insert(filtered, t) end
  end
  table.insert(filtered, threshold)
  table.sort(filtered, function(a, b) return a.count < b.count end)

  rtdb.set('guildConfig/' .. guildId .. '/warnThresholds', filtered)
  return filtered
end

-- ---------- warns ----------
-- Node: warns/{guildId}_{userId} doc = { guildId, userId, count, history:[] }
-- RTDB: warns/{guildId}_{userId} node. history is push()'d sub-nodes instead
-- of an array (RTDB has no arrayUnion; array-of-objects is an anti-pattern
-- for RTDB per Firebase's own structuring guidance) -- see chat decision log.
local function warnPath(guildId, userId)
  return 'warns/' .. guildId .. '_' .. userId
end

function M.addWarn(guildId, userId, moderatorId, reason)
  local path = warnPath(guildId, userId)
  local entry = {
    moderatorId = moderatorId,
    reason = reason or 'No reason provided',
    timestamp = os.time() * 1000,
  }

  rtdb.update(path, { guildId = guildId, userId = userId })
  rtdb.increment(path .. '/count', 1)
  rtdb.push(path .. '/history', entry)

  local data = rtdb.get(path)
  return data
end

function M.getWarnCount(guildId, userId)
  local count = rtdb.get(warnPath(guildId, userId) .. '/count')
  return count or 0
end

function M.resetWarns(guildId, userId)
  local path = warnPath(guildId, userId)
  rtdb.set(path, { guildId = guildId, userId = userId, count = 0, history = nil })
end

-- ---------- honeypot config ----------
function M.setHoneypotChannel(guildId, channelId)
  rtdb.update('guildConfig/' .. guildId, { honeypotChannelId = channelId })
end

function M.getHoneypotChannel(guildId)
  return rtdb.get('guildConfig/' .. guildId .. '/honeypotChannelId')
end

-- ---------- expiring actions (temp-ban, vcmute) ----------
-- Node: expiringActions/{autoId} doc, queried with 3x .where() AND filter.
-- RTDB: composite key expiringActions/{guildId}_{userId}_{type} -- O(1)
-- direct get/set/delete, no multi-field query needed for the clear case.
-- Due-scan (single field, expiresAt) still works fine via orderBy on this
-- same flat node regardless of key shape -- see chat decision log.
local function expiringKey(guildId, userId, type_)
  return guildId .. '_' .. userId .. '_' .. type_
end

function M.scheduleExpiringAction(guildId, userId, type_, expiresAtMs, moderatorId)
  if expiresAtMs == nil then return end -- permanent, nothing to schedule
  local key = expiringKey(guildId, userId, type_)
  rtdb.set('expiringActions/' .. key, {
    guildId = guildId,
    userId = userId,
    type = type_,
    expiresAt = expiresAtMs,
    moderatorId = moderatorId,
    createdAt = os.time() * 1000,
  })
end

-- Node: clearExpiringActions() -- removed the manual/re-ban timer for a
-- user+type. Composite key makes this a single direct delete, no scan.
function M.clearExpiringActions(guildId, userId, type_)
  local key = expiringKey(guildId, userId, type_)
  local ok = pcall(rtdb.delete, 'expiringActions/' .. key)
  return ok
end

-- Node: getDueExpiringActions() -- .where('expiresAt','<=',nowMs)
-- RTDB: orderBy=expiresAt&endAt=nowMs (needs .indexOn:["expiresAt"] rule
-- set on expiringActions in Firebase console -- flagged separately).
function M.getDueExpiringActions(nowMs)
  local data = rtdb.queryEndAt('expiringActions', 'expiresAt', nowMs)
  local due = {}
  if data then
    for key, action in pairs(data) do
      action.id = key
      table.insert(due, action)
    end
  end
  return due
end

function M.deleteExpiringAction(docId)
  pcall(rtdb.delete, 'expiringActions/' .. docId)
end

-- Scans due expiring actions and reverses them (unban / voice-unmute).
-- Called on boot and on an interval. Self-contained -- only needs the client.
function M.runExpiryScan(client)
  local ok, due = pcall(M.getDueExpiringActions, os.time() * 1000)
  if not ok then
    print('[moderation] runExpiryScan fetch failed: ' .. tostring(due))
    return
  end

  for _, action in ipairs(due) do
    local ok2, err2 = pcall(function()
      local guild = client:getGuild(action.guildId)
      if not guild then
        M.deleteExpiringAction(action.id)
        return
      end

      if action.type == 'ban' then
        -- Guild:unbanUser(id, reason) -- confirmed real method, Member:unban()
        -- is a thin delegate to this same call (SinisterRectus/Discordia
        -- libs/containers/Member.lua). userId string works via Resolver.
        pcall(function() guild:unbanUser(action.userId, 'Temp-ban duration expired') end)
      elseif action.type == 'vcmute' then
        local member = guild:getMember(action.userId)
        -- Member:mute()/Member:unmute() -- confirmed real methods, no
        -- boolean-arg setMute() exists in discordia (that's a djs-ism).
        -- See SinisterRectus/Discordia libs/containers/Member.lua.
        if member and member.voiceChannel then
          pcall(function() member:unmute() end)
        end
      end

      M.deleteExpiringAction(action.id)
    end)

    if not ok2 then
      print('[moderation] failed to reverse expiring action ' .. tostring(action.id) .. ': ' .. tostring(err2))
      -- Leave the node in place so it retries next scan pass instead of
      -- silently dropping a stuck ban/mute.
    end
  end
end

function M.startExpiryScanner(client, intervalMs)
  intervalMs = intervalMs or 60 * 1000
  M.runExpiryScan(client) -- run once immediately on boot to catch anything missed while offline
  local timer = require('timer')
  timer.setInterval(intervalMs, function() M.runExpiryScan(client) end)
end

return M
