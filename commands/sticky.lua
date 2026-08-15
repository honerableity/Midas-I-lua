local discordia = require('discordia')
local timer = require('timer')
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

-- Coalesce bursts into one repost. Discord allows ~5 messages/5s per channel and
-- each repost costs a send + a delete, so don't go much below this.
local DEBOUNCE_MS = 3000

local cache = {}  -- channelId -> record | false (false = confirmed "no sticky")
local gen = {}    -- channelId -> debounce generation; bumping it invalidates pending waits
local busy = {}   -- channelId -> true while a repost is in flight
local dirty = {}  -- channelId -> activity arrived while we were reposting

local function stickyPath(channelId)
  return 'sticky/' .. channelId
end

-- Delete by ID without fetching first. Tolerant of 404 / missing perms.
local function safeDeleteMessage(channel, messageId)
  if not messageId then return true end

  local cached = channel.messages:get(messageId)
  if cached then
    local ok, res = pcall(function() return cached:delete() end)
    return ok and res ~= false
  end

  local ok, res = pcall(function()
    return channel.client._api:deleteMessage(channel.id, messageId)
  end)
  return ok and res ~= nil
end

-- Firebase returns Lua arrays as string-keyed maps; Discord rejects that shape.
local function toList(t)
  if type(t) ~= 'table' then return nil end
  local list, i = {}, 1
  while true do
    local v = t[i] or t[tostring(i)]
    if v == nil then break end
    list[i], i = v, i + 1
  end
  return list[1] and list or nil
end

local function normalizeEmbed(embed)
  if type(embed) ~= 'table' then return nil end
  embed.fields = toList(embed.fields)
  return embed
end

local function buildPayload(record)
  local content = record.content
  if content == '' then content = nil end
  local embed = normalizeEmbed(record.embed)
  if not content and not embed then return nil end
  return { content = content, embed = embed }
end

-- Send the replacement first, then delete the old one, so the channel is never
-- left without a sticky. Loops if new activity landed mid-flight.
local function doRepost(channel)
  local channelId = channel.id
  if busy[channelId] then
    dirty[channelId] = true
    return
  end
  busy[channelId] = true

  repeat
    dirty[channelId] = nil

    local record = cache[channelId]
    if not record or not record.stickyMessageId then break end

    -- already the newest message in the channel
    if channel.lastMessageId == record.stickyMessageId then break end

    local payload = buildPayload(record)
    if not payload then
      print('[sticky] record in ' .. channelId .. ' has no content or embed, dropping')
      cache[channelId] = false
      pcall(rtdb.delete, stickyPath(channelId))
      break
    end

    local oldId = record.stickyMessageId
    local sendOk, newMsg = pcall(function() return channel:send(payload) end)
    if not sendOk or not newMsg then
      print('[sticky] send failed in ' .. channelId .. ': ' .. tostring(newMsg))
      break
    end

    record.stickyMessageId = newMsg.id
    cache[channelId] = record
    safeDeleteMessage(channel, oldId)

    local setOk, setErr = pcall(rtdb.set, stickyPath(channelId), record)
    if not setOk then
      print('[sticky] rtdb.set failed for ' .. channelId .. ': ' .. tostring(setErr))
    end
  until not dirty[channelId]

  busy[channelId] = false
end

-- Generation-counter debounce: no timer handles to track or close, and the whole
-- wait happens inside a coroutine so Discordia's HTTP calls can yield.
local function scheduleRepost(channel)
  local channelId = channel.id
  local myGen = (gen[channelId] or 0) + 1
  gen[channelId] = myGen

  coroutine.wrap(function()
    timer.sleep(DEBOUNCE_MS)
    if gen[channelId] ~= myGen then return end -- superseded by newer activity
    doRepost(channel)
  end)()
end

-- Called from main.lua's messageCreate handler.
function M.handleActivity(message)
  local author = message.author
  if not author or author.bot then return end
  if not message.guild then return end

  local channel = message.channel
  local channelId = channel.id

  local record = cache[channelId]
  if record == nil then
    -- cold cache: load once, then the cache is authoritative
    local ok, fetched = pcall(rtdb.get, stickyPath(channelId))
    if not ok then
      print('[sticky] rtdb.get failed in ' .. channelId .. ': ' .. tostring(fetched))
      return
    end
    record = fetched or false
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

  -- invalidate any pending debounce so it can't race this command
  gen[channelId] = (gen[channelId] or 0) + 1

  local function loadExisting()
    local existing = cache[channelId]
    if existing == nil then
      local ok, fetched = pcall(rtdb.get, stickyPath(channelId))
      existing = ok and fetched or nil
    end
    return existing or nil
  end

  if sub == 'stick' then
    local messageId = subArgs and subArgs.messageid
    if not messageId then
      ia:editReply({ content = 'Missing message ID.' })
      return
    end

    local getOk, srcMessage = pcall(function() return channel:getMessage(messageId) end)
    if not getOk or not srcMessage then
      ia:editReply({ content = 'Could not find that message ID in this channel.' })
      return
    end

    local content = srcMessage.content
    local embed = normalizeEmbed(srcMessage.embed)
    if (not content or content == '') and not embed then
      ia:editReply({ content = 'That message has nothing I can repost.' })
      return
    end

    local existing = loadExisting()

    busy[channelId] = true
    local sendOk, newMsg = pcall(function()
      return channel:send({
        content = content ~= '' and content or nil,
        embed = embed,
      })
    end)

    if not sendOk or not newMsg then
      busy[channelId] = false
      ia:editReply({ content = 'Failed to post the sticky message. Your original is untouched.' })
      return
    end

    -- new sticky is live: now safe to clean up the old sticky and the original
    if existing and existing.stickyMessageId then
      safeDeleteMessage(channel, existing.stickyMessageId)
    end
    local removedOriginal = safeDeleteMessage(channel, srcMessage.id)

    local record = {
      content = content,
      embed = embed,
      stickyMessageId = newMsg.id,
      setBy = ia.user.id,
      setAt = os.time(),
    }
    cache[channelId] = record
    busy[channelId] = false

    local setOk, setErr = pcall(rtdb.set, stickyPath(channelId), record)
    if not setOk then
      print('[sticky] rtdb.set failed for ' .. channelId .. ': ' .. tostring(setErr))
    end

    if removedOriginal then
      ia:editReply({ content = 'Stuck message to this channel.' })
    else
      ia:editReply({ content = 'Sticky is live, but I could not delete the original. Check my Manage Messages permission.' })
    end
    return
  end

  if sub == 'unstick' then
    local existing = loadExisting()

    if not existing or not existing.stickyMessageId then
      cache[channelId] = false
      ia:editReply({ content = 'No sticky message set in this channel.' })
      return
    end

    safeDeleteMessage(channel, existing.stickyMessageId)

    cache[channelId] = false
    dirty[channelId] = nil

    local delOk, delErr = pcall(rtdb.delete, stickyPath(channelId))
    if not delOk then
      print('[sticky] rtdb.delete failed for ' .. channelId .. ': ' .. tostring(delErr))
    end

    ia:editReply({ content = 'Removed sticky message from this channel.' })
    return
  end

  ia:editReply({ content = 'Unknown subcommand.' })
end

return M
