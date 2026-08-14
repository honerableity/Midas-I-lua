local discordia = require('discordia')
local tools = require('discordia-slash').util.tools()
local logger = require('logger')
local moderation = require('moderation')

local enums = discordia.enums

local M = {}

local ACTION_CHOICES = {
  tools.choice('ban', 'ban'),
  tools.choice('kick', 'kick'),
  tools.choice('mute', 'mute'),
  tools.choice('role', 'role'),
}

local data = tools.slashCommand('mod', 'Moderation commands')

data:addOption(
  tools.subCommand('ban', 'Ban a user')
    :addOption(tools.user('user', 'User to ban'):setRequired(true))
    :addOption(tools.string('duration', 'e.g. 10m, 2h, 3d, 1w. Leave empty for permanent'))
    :addOption(tools.string('reason', 'Reason'))
)

data:addOption(
  tools.subCommand('kick', 'Kick a user')
    :addOption(tools.user('user', 'User to kick'):setRequired(true))
    :addOption(tools.string('reason', 'Reason'))
)

data:addOption(
  tools.subCommand('unban', 'Unban a user')
    :addOption(tools.string('user', 'User ID to unban'):setRequired(true))
)

data:addOption(
  tools.subCommand('mute', 'Timeout (mute) a user')
    :addOption(tools.user('user', 'User to mute'):setRequired(true))
    :addOption(tools.string('duration', 'e.g. 10m, 2h, 3d (max 28d)'):setRequired(true))
    :addOption(tools.string('reason', 'Reason'))
)

data:addOption(
  tools.subCommand('vcmute', 'Voice server-mute a user')
    :addOption(tools.user('user', 'User to voice-mute'):setRequired(true))
    :addOption(tools.string('duration', 'e.g. 10m, 2h, 3d. Leave empty for indefinite'))
    :addOption(tools.string('reason', 'Reason'))
)

data:addOption(
  tools.subCommand('unmute', 'Remove an active timeout from a user')
    :addOption(tools.user('user', 'User to unmute'):setRequired(true))
    :addOption(tools.string('reason', 'Reason'))
)

data:addOption(
  tools.subCommand('unvcmute', 'Remove voice server-mute from a user')
    :addOption(tools.user('user', 'User to unmute'):setRequired(true))
    :addOption(tools.string('reason', 'Reason'))
)

data:addOption(
  tools.subCommand('warn', 'Warn a user (DMs them)')
    :addOption(tools.user('user', 'User to warn'):setRequired(true))
    :addOption(tools.string('reason', 'Reason'))
)

data:addOption(
  tools.subCommand('setwarn', 'Set an action that fires at a warn count threshold')
    :addOption(tools.integer('warncount', 'Warn count that triggers this'):setRequired(true):setMinValue(1))
    :addOption(tools.string('action', 'Action to take'):setRequired(true):setChoices(ACTION_CHOICES))
    :addOption(tools.string('duration', 'For mute action: e.g. 10m, 2h, 3d'))
    :addOption(tools.role('role', 'For role action: role to give'))
)

data:addOption(tools.subCommand('membercount', 'Show the server member count'))

data:addOption(
  tools.subCommand('honeypot', 'Set a channel that instant-bans anyone who types in it')
    :addOption(tools.channel('channel', 'Trap channel'):setRequired(true):addChannelType(enums.channelType.text))
)

M.data = data

M.logSchema = {
  subcommands = {
    ban = { label = 'Mod — Ban', fields = { 'discordUser', 'duration', 'reason' } },
    kick = { label = 'Mod — Kick', fields = { 'discordUser', 'reason' } },
    unban = { label = 'Mod — Unban', fields = { 'discordUser' } },
    mute = { label = 'Mod — Mute', fields = { 'discordUser', 'duration', 'reason' } },
    vcmute = { label = 'Mod — VC Mute', fields = { 'discordUser', 'duration', 'reason' } },
    unmute = { label = 'Mod — Unmute', fields = { 'discordUser', 'reason' } },
    unvcmute = { label = 'Mod — VC Unmute', fields = { 'discordUser', 'reason' } },
    warn = { label = 'Mod — Warn', fields = { 'discordUser', 'reason', 'warnCount' } },
    setwarn = { label = 'Mod — Set Warn Rule', fields = { 'warnCount', 'action', 'duration', 'role' } },
    membercount = { label = 'Mod — Member Count', fields = { 'memberCount' } },
    honeypot = { label = 'Mod — Honeypot Set', fields = { 'channel' } },
    honeypotTrigger = { label = 'Mod — Honeypot Triggered', fields = { 'discordUser', 'channel' } },
  },
}

function M.execute(ia, cmd)
  if not ia.guildId then
    ia:reply({ content = 'This command only works inside a server.' }, true)
    return
  end

  if not (ia.member and ia.member:hasPermission(enums.permission.moderateMembers)) then
    ia:reply({ content = 'You need Moderate Members permission to do that.' }, true)
    return
  end

  local args, sub = tools.getSubCommand(cmd)
  ia:replyDeferred(true)

  local handlers = {
    ban = M.handleBan,
    kick = M.handleKick,
    unban = M.handleUnban,
    mute = M.handleMute,
    vcmute = M.handleVcMute,
    unmute = M.handleUnmute,
    unvcmute = M.handleUnvcMute,
    warn = M.handleWarn,
    setwarn = M.handleSetWarn,
    membercount = M.handleMemberCount,
    honeypot = M.handleHoneypot,
  }

  local handler = handlers[sub]
  if not handler then
    ia:reply({ content = 'Unknown subcommand.' })
    return
  end

  local ok, err = pcall(handler, ia, args)
  if not ok then
    print('[mod] ' .. sub .. ' failed: ' .. tostring(err))
    ia:reply({ content = 'Bot error occurred while running that command.' })
  end
end

function M.handleBan(ia, args)
  local user = args.user 
  local durationInput = args.duration
  local reason = args.reason or 'No reason provided'

  local durationMs = moderation.parseDuration(durationInput)
  if durationMs == false then
    ia:reply({ content = 'Invalid duration "' .. tostring(durationInput) .. '". Use formats like 10m, 2h, 3d, 1w, or leave empty for permanent.' })
    return
  end

  local member = (args.user.user and args.user) or nil
  local targetUser = (args.user.user and args.user.user) or args.user

  local guard = moderation.isProtectedTarget(ia.guild, member, targetUser)
  if guard.blocked then
    ia:reply({ content = 'Can\'t ban ' .. targetUser.username .. ' — protected (' .. guard.reason .. ').' })
    return
  end

  moderation.sendModDM(targetUser, {
    guildName = ia.guild.name,
    action = 'Banned',
    reason = reason,
    duration = durationMs == nil and 'permanent' or moderation.formatDuration(durationMs),
  })

  local ok, err = pcall(function()
    ia.guild:banUser(targetUser.id, reason .. ' (by ' .. ia.user.username .. ')')
  end)
  if not ok then
    ia:reply({ content = 'I can\'t ban ' .. targetUser.username .. ' — check role hierarchy / my permissions.' })
    return
  end

  moderation.clearExpiringActions(ia.guildId, targetUser.id, 'ban')
  if durationMs ~= nil then
    moderation.scheduleExpiringAction(ia.guildId, targetUser.id, 'ban', os.time() * 1000 + durationMs, ia.user.id)
  end

  local durationLabel = durationMs == nil and 'permanent' or moderation.formatDuration(durationMs)
  ia:reply({ content = 'Banned ' .. targetUser.username .. ' — ' .. durationLabel .. '. Reason: ' .. reason })

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'ban', success = true,
    fields = { discordUser = targetUser, duration = durationLabel, reason = reason },
  })
end

function M.handleKick(ia, args)
  local member = args.user
  if not (member and member.user) then
    ia:reply({ content = (member and member.username or 'That user') .. ' is not in this server.' })
    return
  end
  local targetUser = member.user
  local reason = args.reason or 'No reason provided'

  local guard = moderation.isProtectedTarget(ia.guild, member, targetUser)
  if guard.blocked then
    ia:reply({ content = 'Can\'t kick ' .. targetUser.username .. ' — protected (' .. guard.reason .. ').' })
    return
  end

  moderation.sendModDM(targetUser, { guildName = ia.guild.name, action = 'Kicked', reason = reason })

  local ok = pcall(function() member:kick(reason .. ' (by ' .. ia.user.username .. ')') end)
  if not ok then
    ia:reply({ content = 'I can\'t kick ' .. targetUser.username .. ' — check role hierarchy / my permissions.' })
    return
  end

  ia:reply({ content = 'Kicked ' .. targetUser.username .. '. Reason: ' .. reason })

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'kick', success = true,
    fields = { discordUser = targetUser, reason = reason },
  })
end

function M.handleUnban(ia, args)
  local userId = (args.user or ''):gsub('^%s+', ''):gsub('%s+$', '')
  local ban = select(1, pcall(function() return ia.guild:getBan(userId) end)) and ia.guild:getBan(userId) or nil
  if not ban then
    ia:reply({ content = 'That user ID is not banned.' })
    return
  end

  local ok = pcall(function() ia.guild:unbanUser(userId, 'Unbanned by ' .. ia.user.username) end)
  if not ok then
    ia:reply({ content = 'Failed to unban — check my permissions.' })
    return
  end
  moderation.clearExpiringActions(ia.guildId, userId, 'ban')

  moderation.sendModDM(ban.user, { guildName = ia.guild.name, action = 'Unbanned', reversal = true })

  ia:reply({ content = 'Unbanned ' .. ban.user.username .. '.' })

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'unban', success = true,
    fields = { discordUser = ban.user },
  })
end

local MAX_TIMEOUT_MS = 28 * 24 * 60 * 60 * 1000

function M.handleMute(ia, args)
  local member = args.user
  local durationInput = args.duration
  local reason = args.reason or 'No reason provided'

  local durationMs = moderation.parseDuration(durationInput)
  if not durationMs then 
    ia:reply({ content = 'Invalid duration "' .. tostring(durationInput) .. '". Use formats like 10m, 2h, 3d (max 28d). Mute cannot be permanent.' })
    return
  end

  if durationMs > MAX_TIMEOUT_MS then
    ia:reply({ content = 'Discord timeouts cap at 28 days. Use a shorter duration.' })
    return
  end

  if not (member and member.user) then
    ia:reply({ content = 'That user is not in this server.' })
    return
  end
  local targetUser = member.user

  local guard = moderation.isProtectedTarget(ia.guild, member, targetUser)
  if guard.blocked then
    ia:reply({ content = 'Can\'t mute ' .. targetUser.username .. ' — protected (' .. guard.reason .. ').' })
    return
  end

  local ok = pcall(function() member:timeoutFor(math.floor(durationMs / 1000)) end)
  if not ok then
    ia:reply({ content = 'I can\'t timeout ' .. targetUser.username .. ' — check role hierarchy / my permissions.' })
    return
  end

  moderation.sendModDM(targetUser, { guildName = ia.guild.name, action = 'Muted', reason = reason, duration = moderation.formatDuration(durationMs) })

  ia:reply({ content = 'Muted ' .. targetUser.username .. ' for ' .. moderation.formatDuration(durationMs) .. '. Reason: ' .. reason })

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'mute', success = true,
    fields = { discordUser = targetUser, duration = moderation.formatDuration(durationMs), reason = reason },
  })
end

function M.handleVcMute(ia, args)
  local member = args.user
  local durationInput = args.duration
  local reason = args.reason or 'No reason provided'

  local durationMs = moderation.parseDuration(durationInput)
  if durationMs == false then
    ia:reply({ content = 'Invalid duration "' .. tostring(durationInput) .. '". Use formats like 10m, 2h, 3d, or leave empty for indefinite.' })
    return
  end

  if not (member and member.user) then
    ia:reply({ content = 'That user is not in this server.' })
    return
  end
  local targetUser = member.user

  if not member.voiceChannel then
    ia:reply({ content = targetUser.username .. ' is not currently in a voice channel.' })
    return
  end

  local guard = moderation.isProtectedTarget(ia.guild, member, targetUser)
  if guard.blocked then
    ia:reply({ content = 'Can\'t voice-mute ' .. targetUser.username .. ' — protected (' .. guard.reason .. ').' })
    return
  end

  local ok = pcall(function() member:mute() end)
  if not ok then
    ia:reply({ content = 'I can\'t voice-mute ' .. targetUser.username .. ' — check role hierarchy / my permissions.' })
    return
  end

  moderation.clearExpiringActions(ia.guildId, targetUser.id, 'vcmute')
  if durationMs ~= nil then
    moderation.scheduleExpiringAction(ia.guildId, targetUser.id, 'vcmute', os.time() * 1000 + durationMs, ia.user.id)
  end

  local durationLabel = durationMs == nil and 'indefinite' or moderation.formatDuration(durationMs)
  moderation.sendModDM(targetUser, { guildName = ia.guild.name, action = 'Voice-muted', reason = reason, duration = durationLabel })

  ia:reply({ content = 'Voice-muted ' .. targetUser.username .. ' — ' .. durationLabel .. '. Reason: ' .. reason })

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'vcmute', success = true,
    fields = { discordUser = targetUser, duration = durationLabel, reason = reason },
  })
end

function M.handleUnmute(ia, args)
  local member = args.user
  local reason = args.reason or 'No reason provided'

  if not (member and member.user) then
    ia:reply({ content = 'That user is not in this server.' })
    return
  end
  local targetUser = member.user

  if not member.timedOut then 
    ia:reply({ content = targetUser.username .. ' is not currently muted.' })
    return
  end

  local ok = pcall(function() member:removeTimeout() end) 
  if not ok then
    ia:reply({ content = 'I can\'t unmute ' .. targetUser.username .. ' — check role hierarchy / my permissions.' })
    return
  end

  moderation.sendModDM(targetUser, { guildName = ia.guild.name, action = 'Unmuted', reason = reason, reversal = true })

  ia:reply({ content = 'Unmuted ' .. targetUser.username .. '. Reason: ' .. reason })

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'unmute', success = true,
    fields = { discordUser = targetUser, reason = reason },
  })
end

function M.handleUnvcMute(ia, args)
  local member = args.user
  local reason = args.reason or 'No reason provided'

  if not (member and member.user) then
    ia:reply({ content = 'That user is not in this server.' })
    return
  end
  local targetUser = member.user

  if not member.muted then 
    ia:reply({ content = targetUser.username .. ' is not currently voice-muted.' })
    return
  end

  local ok = pcall(function() member:unmute() end)
  if not ok then
    ia:reply({ content = 'I can\'t unmute ' .. targetUser.username .. ' — check role hierarchy / my permissions.' })
    return
  end
  moderation.clearExpiringActions(ia.guildId, targetUser.id, 'vcmute')

  moderation.sendModDM(targetUser, { guildName = ia.guild.name, action = 'Voice-unmuted', reason = reason, reversal = true })

  ia:reply({ content = 'Voice-unmuted ' .. targetUser.username .. '. Reason: ' .. reason })

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'unvcmute', success = true,
    fields = { discordUser = targetUser, reason = reason },
  })
end

function M.handleWarn(ia, args)
  local member = args.user
  local targetUser = (member and member.user) or member
  local reason = args.reason or 'No reason provided'

  local guard = moderation.isProtectedTarget(ia.guild, member, targetUser)
  if guard.blocked then
    ia:reply({ content = 'Can\'t warn ' .. targetUser.username .. ' — protected (' .. guard.reason .. ').' })
    return
  end

  local data2 = moderation.addWarn(ia.guildId, targetUser.id, ia.user.id, reason)
  local count = (data2 and data2.count) or 0

  -- DM the user -- best effort, don't fail the command if DMs are closed.
  pcall(function()
    targetUser:send({
      embed = {
        title = 'You received a warning',
        description = 'Server: **' .. ia.guild.name .. '**\nReason: ' .. reason .. '\nTotal warns: ' .. count,
        color = 0xffaa00,
      },
    })
  end)

  local thresholds = moderation.getWarnThresholds(ia.guildId)
  local matched = nil
  for _, t in ipairs(thresholds) do
    if t.count == count then matched = t; break end
  end

  local actionNote = ''
  if matched then
    local ok, result = pcall(M.applyThresholdAction, ia, targetUser, matched)
    if ok then
      actionNote = result
    else
      print('[mod] threshold action failed: ' .. tostring(result))
      actionNote = 'Threshold action failed — check bot permissions.'
    end
  end

  ia:reply({ content = 'Warned ' .. targetUser.username .. '. Total warns: ' .. count .. '.' .. (actionNote ~= '' and ('\n' .. actionNote) or '') })

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'warn', success = true,
    fields = { discordUser = targetUser, reason = reason, warnCount = count },
  })
end

function M.applyThresholdAction(ia, user, threshold)
  local member = ia.guild:getMember(user.id)

  local guard = moderation.isProtectedTarget(ia.guild, member, user)
  if guard.blocked then
    return 'Reached ' .. threshold.count .. ' warns but target is protected (' .. guard.reason .. ') — auto-action skipped.'
  end

  if threshold.action == 'ban' then
    moderation.sendModDM(user, { guildName = ia.guild.name, action = 'Banned', reason = 'Reached ' .. threshold.count .. ' warns', duration = 'permanent' })
    local ok = pcall(function() ia.guild:banUser(user.id, 'Auto-ban at ' .. threshold.count .. ' warns') end)
    if not ok then return 'Reached ' .. threshold.count .. ' warns but I can\'t ban (permissions).' end
    return 'Auto-banned for reaching ' .. threshold.count .. ' warns.'
  end

  if threshold.action == 'kick' then
    if not member then return 'Reached ' .. threshold.count .. ' warns but user already left.' end
    moderation.sendModDM(user, { guildName = ia.guild.name, action = 'Kicked', reason = 'Reached ' .. threshold.count .. ' warns' })
    local ok = pcall(function() member:kick('Auto-kick at ' .. threshold.count .. ' warns') end)
    if not ok then return 'Reached ' .. threshold.count .. ' warns but I can\'t kick (permissions).' end
    return 'Auto-kicked for reaching ' .. threshold.count .. ' warns.'
  end

  if threshold.action == 'mute' then
    if not member then return 'Reached ' .. threshold.count .. ' warns but user is not in server.' end
    local durationMs = moderation.parseDuration(threshold.duration)
    if not durationMs or durationMs == false then durationMs = 10 * 60 * 1000 end 
    local ok = pcall(function() member:timeoutFor(math.floor(durationMs / 1000)) end)
    if not ok then return 'Reached ' .. threshold.count .. ' warns but I can\'t mute (permissions).' end
    moderation.sendModDM(user, { guildName = ia.guild.name, action = 'Muted', reason = 'Reached ' .. threshold.count .. ' warns', duration = moderation.formatDuration(durationMs) })
    return 'Auto-muted for ' .. moderation.formatDuration(durationMs) .. ' for reaching ' .. threshold.count .. ' warns.'
  end

  if threshold.action == 'role' then
    if not member then return 'Reached ' .. threshold.count .. ' warns but user is not in server.' end
    if not threshold.roleId then return 'Reached ' .. threshold.count .. ' warns but no role configured.' end
    local ok = pcall(function() member:addRole(threshold.roleId) end) 
    if not ok then return 'Reached ' .. threshold.count .. ' warns but I can\'t assign the role (permissions).' end
    return 'Auto-assigned role for reaching ' .. threshold.count .. ' warns.'
  end

  return ''
end

function M.handleSetWarn(ia, args)
  local warncount = args.warncount
  local action = args.action
  local durationInput = args.duration
  local role = args.role 

  if action == 'mute' then
    local durationMs = moderation.parseDuration(durationInput)
    if not durationMs or durationMs == false then
      ia:reply({ content = 'Action "mute" needs a valid duration, e.g. 10m, 2h, 3d.' })
      return
    end
  end

  if action == 'role' and not role then
    ia:reply({ content = 'Action "role" needs a role option.' })
    return
  end

  local threshold = {
    count = warncount,
    action = action,
    duration = (action == 'mute') and durationInput or nil,
    roleId = (action == 'role') and role.id or nil,
  }

  moderation.addWarnThreshold(ia.guildId, threshold)

  local desc
  if action == 'mute' then
    desc = 'mute for ' .. durationInput
  elseif action == 'role' then
    desc = 'give role ' .. role.name
  else
    desc = action
  end

  ia:reply({ content = 'Set: at ' .. warncount .. ' warns -> ' .. desc .. '.' })

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'setwarn', success = true,
    fields = { warnCount = warncount, action = action, duration = durationInput, role = role and role.name },
  })
end

function M.handleMemberCount(ia)
  local guild = ia.guild
  local total = guild.totalMemberCount
  local humans, bots = 0, 0
  for member in guild.members:iter() do
    if member.bot then bots = bots + 1 else humans = humans + 1 end
  end

  ia:reply({ content = '**' .. guild.name .. '** has **' .. total .. '** members (' .. humans .. ' humans, ' .. bots .. ' bots, of cached members).' })

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'membercount', success = true,
    fields = { memberCount = total },
  })
end

function M.handleHoneypot(ia, args)
  local channel = args.channel

  moderation.setHoneypotChannel(ia.guildId, channel.id)

  ia:reply({ content = 'Honeypot set to <#' .. channel.id .. '>. Anyone who sends a message there gets banned (7 days) and their messages purged server-wide.' })

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'honeypot', success = true,
    fields = { channel = channel.name },
  })
end

function M.handleHoneypotMessage(message)
  if not message.guild or message.author.bot then return end

  local honeypotId = moderation.getHoneypotChannel(message.guild.id)
  if not honeypotId or message.channel.id ~= honeypotId then return end

  local guild = message.guild
  local userId = message.author.id

  local member = guild:getMember(userId)
  local guard = moderation.isProtectedTarget(guild, member, message.author)
  if guard.blocked then
    print('[mod] honeypot triggered by ' .. message.author.username .. ' but target is protected (' .. guard.reason .. ') — ignoring entirely.')
    return
  end

  pcall(function() message:delete() end)

  for channel in guild.textChannels:iter() do
    local ok, recent = pcall(function() return channel:getMessages(100) end)
    if ok and recent then
      for msg in recent:iter() do
        if msg.author and msg.author.id == userId then
          pcall(function() msg:delete() end)
        end
      end
    end
  end

  moderation.sendModDM(message.author, {
    guildName = guild.name,
    action = 'Banned',
    reason = 'Honeypot channel triggered',
    duration = moderation.formatDuration(7 * 24 * 60 * 60 * 1000),
  })

  local ok = pcall(function() guild:banUser(userId, 'Honeypot channel triggered', 7) end)
  if not ok then
    print('[mod] honeypot triggered by ' .. message.author.username .. ' but ban failed (permissions).')
    return
  end

  moderation.scheduleExpiringAction(guild.id, userId, 'ban', os.time() * 1000 + 7 * 24 * 60 * 60 * 1000, guild.client.user.id)

  local fakeInteraction = {
    guildId = guild.id,
    commandName = 'mod',
    member = { id = guild.client.user.id },
  }
  pcall(function()
    logger.logCommandActivity(guild.client, fakeInteraction, {
      subcommand = 'honeypotTrigger', success = true,
      fields = { discordUser = message.author, channel = message.channel.name },
    })
  end)
end

return M
