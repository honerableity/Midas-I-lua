local rtdb = require('rtdb')
local discordia = require('discordia')

local M = {}
function M.loadCommandDescriptors(client)
  local descriptors = {}
  for name, cmd in pairs(client.commands) do
    table.insert(descriptors, {
      name = name,
      channelName = name .. '-logs',
      logSchema = cmd.logSchema,
    })
  end
  return descriptors
end

function M.getLogConfig(guildId)
  local data = rtdb.get('guildConfig/' .. guildId)
  if not data then return nil end
  return {
    logCategoryId = data.logCategoryId,
    logChannels = data.logChannels or {},
  }
end

function M.saveLogCategory(guildId, categoryId)
  rtdb.update('guildConfig/' .. guildId, { logCategoryId = categoryId })
end

function M.saveLogChannel(guildId, commandName, channelId)
  rtdb.update('guildConfig/' .. guildId .. '/logChannels', { [commandName] = channelId })
end

function M.resolveLogCategory(guild, categoryOption)
  if categoryOption then
    return categoryOption
  end

  local category = guild:createCategory('Bot Logs')

  local everyoneOverwrite = category:getPermissionOverwriteFor(guild.defaultRole)
  everyoneOverwrite:setDeniedPermissions(discordia.enums.permission.readMessages)

  local botMember = guild.me
  if botMember then
    local botOverwrite = category:getPermissionOverwriteFor(botMember)
    botOverwrite:setAllowedPermissions(
      discordia.enums.permission.readMessages
      + discordia.enums.permission.sendMessages
      + discordia.enums.permission.manageChannels
    )
  end

  return category
end

function M.syncLogChannels(client, guild, guildId, categoryId)
  local descriptors = M.loadCommandDescriptors(client)
  local config = M.getLogConfig(guildId)
  local existingChannels = (config and config.logChannels) or {}

  local created, skippedNoSchema, alreadyExists = {}, {}, {}

  for _, desc in ipairs(descriptors) do
    local existingId = existingChannels[desc.name]
    local stillValid = existingId and guild:getChannel(existingId) ~= nil

    if stillValid then
      table.insert(alreadyExists, desc.channelName)
    elseif not desc.logSchema then
      print('[logger] Skipping channel creation for "' .. desc.name .. '" -- no logSchema exported.')
      table.insert(skippedNoSchema, desc.name)
    else
      local channel = guild:createTextChannel(desc.channelName)
      pcall(function() channel:setCategory(categoryId) end)
      pcall(function() channel:setTopic('Activity log for /' .. desc.name) end)

      M.saveLogChannel(guildId, desc.name, channel.id)
      table.insert(created, desc.channelName)
    end
  end

  return { created = created, alreadyExists = alreadyExists, skippedNoSchema = skippedNoSchema }
end

local function formatFieldValue(value)
  if value == nil then return 'N/A' end
  if type(value) == 'table' and value.id then
    if value.username ~= nil then
      return '<@' .. value.id .. '>' 
    elseif value.hoisted ~= nil or value.mentionable ~= nil then
      return '<@&' .. value.id .. '>'
    elseif value.topic ~= nil or value.bitrate ~= nil then
      return '<#' .. value.id .. '>'
    end
    return tostring(value)
  end
  return tostring(value)
end
function M.logCommandActivity(client, ia, opts)
  local ok, err = pcall(function()
    if not ia.guildId then return end

    local config = M.getLogConfig(ia.guildId)
    local channelId = config and config.logChannels and config.logChannels[ia.commandName]
    if not channelId then return end 

    local channel = client:getChannel(channelId)
    if not channel then return end 

    local cmd = client.commands[ia.commandName]
    local schemaEntry = cmd and cmd.logSchema and cmd.logSchema.subcommands and cmd.logSchema.subcommands[opts.subcommand]
    local label = (schemaEntry and schemaEntry.label) or opts.subcommand or ia.commandName

    local fields = {
      { name = 'Status', value = opts.success and 'Success' or 'Failed', inline = true },
      { name = 'Run By', value = '<@' .. ia.member.id .. '>', inline = true },
    }

    for key, value in pairs(opts.fields or {}) do
      
      if key ~= 'discordUser' then
        table.insert(fields, { name = key, value = formatFieldValue(value), inline = true })
      end
    end

    if opts.note then
      local noteStr = tostring(opts.note)
      if #noteStr > 1024 then noteStr = noteStr:sub(1, 1024) end
      table.insert(fields, { name = 'Note', value = noteStr })
    end

    channel:send({
      embed = {
        title = label,
        color = opts.success and 0x57f287 or 0xed4245,
        fields = fields,
        timestamp = os.date('!%Y-%m-%dT%H:%M:%S.000Z'),
      },
    })
  end)

  if not ok then
    print('[logger] logCommandActivity failed: ' .. tostring(err))
  end
end

return M
