local discordia = require('discordia')
local tools = require('discordia-slash').util.tools()
local rtdb = require('utils.rtdb')

local enums = discordia.enums
local M = {}

local data = tools.slashCommand('sticky', 'Manage sticky message per channel')

data:addOption(
  tools.subCommand('stick', 'Stick a message: pin content to bottom, delete original')
    :addOption(tools.string('messageid', 'Message ID to stick'):setRequired(true))
)

data:addOption(
  tools.subCommand('unstick', 'Remove sticky message from this channel')
)

M.data = data

-- In-memory cache: channelId -> record. Skip rtdb read on every message.
local cache = {}
-- Per-channel state machine: 'idle' | 'pending' | 'reposting'
local state = {}
-- Debounce timers per channel
local timers = {}

local DEBOUNCE_MS = 1200 -- coalesce burst of messages into one repost

local function stickyPath(channelId)
  return 'sticky/' .. channelId
end

local function safeDeleteMessage(channel, messageId)
  if not messageId then return true end
  local ok = pcall(function()
    local msg = channel.messages:get(messageId)
    if msg then
      msg:delete()
    else
      channel:getMessage(messageId):delete()
    end
  end)
  return ok -- false if already gone/no perm; not fatal
end

-- Core repost logic. Deletes old sticky msg, sends new one, updates cache + rtdb.
local function doRepost(channel)
  local channelId = channel.id
  local record = cache[channelId]
  if not record then return end

  state[channelId] = 'reposting'

  safeDeleteMessage(channel, record.stickyMessageId)

  local sendOk, newMsg = pcall(function()
    return channel:send({
      content = record.content ~= '' and record.content or nil,
      embed = record.embed,
    })
  end)

  if not sendOk or not newMsg then
    print('[sticky] send failed in ' .. channelId .. ': ' .. tostring(newMsg))
    state[channelId] = 'idle'
    return
  end

  record.stickyMessageId = newMsg.id
  cache[channelId] = record
  state[channelId] = 'idle'

  -- Fire-and-forget persist; UI-facing repost already done, don't block on it.
  local setOk, setErr = pcall(rtdb.set, stickyPath(channelId), record)
  if not setOk then
    print('[sticky] rtdb.set failed for ' .. channelId .. ': ' .. tostring(setErr))
  end
end

-- Debounced trigger: many messages in quick succession collapse to one repost.
local function scheduleRepost(channel)
  local channelId = channel.id

  if timers[channelId] then
    timers[channelId]:stop()
    timers[channelId] = nil
  end

  timers[channelId] = discordia.timer.setTimeout(DEBOUNCE_MS, function()
    timers[channelId] = nil
    if state[channelId] == 'reposting' then return end -- already mid-flight, next activity reschedules
    doRepost(channel)
  end)
end

-- Called from main.lua's messageCreate handler.
function M.handleActivity(message)
  if message.author and message.author.bot then return end
  if not message.guildId then return end

  local channel = message.channel
  local channelId = channel.id

  local record = cache[channelId]
  if record == nil then
    -- cold cache: load once, then cache holds authority (avoid rtdb hit every message)
    local ok, fetched = pcall(rtdb.get, stickyPath(channelId))
    if not ok then
      print('[sticky] rtdb.get failed in ' .. channelId .. ': ' .. tostring(fetched))
      return
    end
    record = fetched or false -- false = confirmed "no sticky", skip future lookups
    cache[channelId] = record
  end

  if not record or not record.stickyMessageId then return end
  if message.id == record.stickyMessageId then return end

  scheduleRepost(channel)
end

function M.execute(ia, cmd, args)
  if not ia.guildId then
    ia:reply({ content = 'This command only works inside a server.' }, true)
    return
  end

  if not (ia.member and ia.member:hasPermission(enums.permission.manageMessages)) then
    ia:reply({ content = 'You need Manage Messages permission to do that.' }, true)
    return
  end

  local subArgs, sub = tools.getSubCommand(cmd)
  local channel = ia.channel
  local channelId = channel.id

  ia:replyDeferred(true)

  if sub == 'stick' then
    local messageId = subArgs.messageid

    local getOk, srcMessage = pcall(function() return channel:getMessage(messageId) end)
    if not getOk or not srcMessage then
      ia:editReply({ content = 'Could not find that message ID in this channel.' })
      return
    end

    local content = srcMessage.content
    local embeds = srcMessage.embeds
    local newEmbed = embeds and embeds[1] or nil

    local delOk = pcall(function() srcMessage:delete() end)
    if not delOk then
      ia:editReply({ content = 'Found the message but could not delete it. Check my Manage Messages permission.' })
      return
    end

    -- kill any pending debounce so it doesn't race this manual repost
    if timers[channelId] then
      timers[channelId]:stop()
      timers[channelId] = nil
    end

    local existing = cache[channelId]
    if existing == nil then
      local ok, fetched = pcall(rtdb.get, stickyPath(channelId))
      existing = ok and fetched or nil
    end
    if existing and existing.stickyMessageId then
      safeDeleteMessage(channel, existing.stickyMessageId)
    end

    state[channelId] = 'reposting'
    local sendOk, newMsg = pcall(function()
      return channel:send({
        content = content ~= '' and content or nil,
        embed = newEmbed,
      })
    end)
    state[channelId] = 'idle'

    if not sendOk or not newMsg then
      cache[channelId] = false
      ia:editReply({ content = 'Original deleted, but failed to post the sticky message.' })
      return
    end

    local record = {
      content = content,
      embed = newEmbed,
      stickyMessageId = newMsg.id,
      setBy = ia.user.id,
      setAt = os.time(),
    }
    cache[channelId] = record

    local setOk, setErr = pcall(rtdb.set, stickyPath(channelId), record)
    if not setOk then
      print('[sticky] rtdb.set failed for ' .. channelId .. ': ' .. tostring(setErr))
    end

    ia:editReply({ content = 'Stuck message to this channel.' })
    return
  end

  if sub == 'unstick' then
    local existing = cache[channelId]
    if existing == nil then
      local ok, fetched = pcall(rtdb.get, stickyPath(channelId))
      existing = ok and fetched or nil
    end

    if not existing or not existing.stickyMessageId then
      ia:editReply({ content = 'No sticky message set in this channel.' })
      return
    end

    if timers[channelId] then
      timers[channelId]:stop()
      timers[channelId] = nil
    end

    safeDeleteMessage(channel, existing.stickyMessageId)

    cache[channelId] = false
    state[channelId] = 'idle'

    local delOk, delErr = pcall(rtdb.delete, stickyPath(channelId))
    if not delOk then
      print('[sticky] rtdb.delete failed for ' .. channelId .. ': ' .. tostring(delErr))
    end

    ia:editReply({ content = 'Removed sticky message from this channel.' })
    return
  end
end

return M
