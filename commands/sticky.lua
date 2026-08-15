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

local function safeDeleteMessage(channel, messageId)
  if not messageId then return end
  local ok, err = pcall(function()
    local msg = channel.messages:get(messageId)
    if not msg then
      msg = channel:getMessage(messageId)
    end
    if msg then msg:delete() end
  end)
  if not ok then
    print('[sticky] safeDeleteMessage failed for ' .. tostring(messageId) .. ' in ' .. tostring(channel.id) .. ': ' .. tostring(err))
  end
  return ok
end

local function repostSticky(channel, record)
  local sendOk, newMsg = pcall(function()
    return channel:send({
      content = record.content ~= '' and record.content or nil,
      embed = record.embed,
    })
  end)
  if not sendOk then
    print('[sticky] send failed in ' .. tostring(channel.id) .. ': ' .. tostring(newMsg))
    return nil
  end
  if not newMsg then
    print('[sticky] send returned nil message in ' .. tostring(channel.id))
    return nil
  end

  record.stickyMessageId = newMsg.id
  local setOk, setErr = pcall(rtdb.set, stickyPath(channel.id), record)
  if not setOk then
    print('[sticky] rtdb.set failed for ' .. tostring(channel.id) .. ': ' .. tostring(setErr))
  end
  return newMsg
end

-- Called from main.lua's messageCreate handler. Bumps the sticky back to the
-- bottom of the channel whenever a newer message comes in, so it always
-- stays the last message. The new message itself is left alone.
function M.handleActivity(message)
  if message.author and message.author.bot then return end
  if not message.guildId then return end

  local channel = message.channel

  local getRecOk, record = pcall(rtdb.get, stickyPath(channel.id))
  if not getRecOk then
    print('[sticky] rtdb.get failed in ' .. tostring(channel.id) .. ': ' .. tostring(record))
    return
  end
  if not record or not record.stickyMessageId then return end
  if message.id == record.stickyMessageId then return end

  safeDeleteMessage(channel, record.stickyMessageId)

  local repostOk, repostErr = pcall(repostSticky, channel, record)
  if not repostOk then
    print('[sticky] repostSticky threw in ' .. tostring(channel.id) .. ': ' .. tostring(repostErr))
  end
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

    -- Delete the original message.
    local delOk = pcall(function() srcMessage:delete() end)
    if not delOk then
      ia:editReply({ content = 'Found the message but could not delete it. Check my Manage Messages permission.' })
      return
    end

    -- Remove any existing sticky in this channel first (one per channel).
    local existing = rtdb.get(stickyPath(channel.id))
    if existing and existing.stickyMessageId then
      safeDeleteMessage(channel, existing.stickyMessageId)
    end

    local newMsg = repostSticky(channel, {
      content = content,
      embed = embeds and embeds[1] or nil,
      setBy = ia.user.id,
      setAt = os.time(),
    })
    if not newMsg then
      ia:editReply({ content = 'Original deleted, but failed to post the sticky message.' })
      return
    end

    ia:editReply({ content = 'Stuck message to this channel.' })
    return
  end

  if sub == 'unstick' then
    local existing = rtdb.get(stickyPath(channel.id))
    if not existing or not existing.stickyMessageId then
      ia:editReply({ content = 'No sticky message set in this channel.' })
      return
    end

    safeDeleteMessage(channel, existing.stickyMessageId)

    rtdb.delete(stickyPath(channel.id))

    ia:editReply({ content = 'Removed sticky message from this channel.' })
    return
  end
end

return M
