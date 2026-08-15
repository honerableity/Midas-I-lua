local rtdb = require('utils.rtdb')
local discordia = require('discordia')
local enums = discordia.enums

local M = {}

function M.parseDuration(input)
  if not input or input == '' then return nil end
  local s = tostring(input):trim():lower()
  if s == 'permanent' or s == 'perm' or s == 'none' or s == '' then return nil end

  local amount, unit = s:match('^(%d+)%s*(%a+)$')
  if not amount then return false end 

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

  pcall(function() user:send({ embed = embed }) end)
end

function M.getWarnThresholds(guildId)
  local data = rtdb.get('guildConfig/' .. guildId .. '/warnThresholds')
  if not data then return {} end
  local list = {}
  for _, v in pairs(data) do table.insert(list, v) end
  return list
end

function M.addWarnThreshold(guildId, threshold)
  local existing = M.getWarnThresholds(guildId)

  local filtered = {}
  for _, t in ipairs(existing) do
    if t.count ~= threshold.count then table.insert(filtered, t) end
  end
  table.insert(filtered, threshold)
  table.sort(filtered, function(a, b) return a.count < b.count end)

  rtdb.set('guildConfig/' .. guildId .. '/warnThresholds', filtered)
  return filtered
end

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
function M.setHoneypotChannel(guildId, channelId)
  rtdb.update('guildConfig/' .. guildId, { honeypotChannelId = channelId })
end

function M.getHoneypotChannel(guildId)
  return rtdb.get('guildConfig/' .. guildId .. '/honeypotChannelId')
end

local function expiringKey(guildId, userId, type_)
  return guildId .. '_' .. userId .. '_' .. type_
end

function M.scheduleExpiringAction(guildId, userId, type_, expiresAtMs, moderatorId)
  if expiresAtMs == nil then return end 
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

function M.clearExpiringActions(guildId, userId, type_)
  local key = expiringKey(guildId, userId, type_)
  local ok = pcall(rtdb.delete, 'expiringActions/' .. key)
  return ok
end

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

local scanInProgress = false

function M.runExpiryScan(client)
  if scanInProgress then
    print('[moderation] runExpiryScan skipped: previous scan still in flight')
    return
  end
  scanInProgress = true

  coroutine.wrap(function()
    local ok, due = pcall(M.getDueExpiringActions, os.time() * 1000)
    if not ok then
      print('[moderation] runExpiryScan fetch failed: ' .. tostring(due))
      scanInProgress = false
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
          
          pcall(function() guild:unbanUser(action.userId, 'Temp-ban duration expired') end)
        elseif action.type == 'vcmute' then
          local member = guild:getMember(action.userId)
        
          if member and member.voiceChannel then
            pcall(function() member:unmute() end)
          end
        end

        M.deleteExpiringAction(action.id)
      end)

      if not ok2 then
        print('[moderation] failed to reverse expiring action ' .. tostring(action.id) .. ': ' .. tostring(err2))
       
      end
    end

    scanInProgress = false
  end)()
end

function M.startExpiryScanner(client, intervalMs)
  intervalMs = intervalMs or 60 * 1000
  M.runExpiryScan(client)
  local timer = require('timer')
  timer.setInterval(intervalMs, function() M.runExpiryScan(client) end)
end

return M
