-- Midas-I utils/logger.lua
-- Luau port of utils/logger.js
-- DB: Firestore -> RTDB (see utils/rtdb.lua)
-- Node's loadCommandDescriptors() does fs.readdirSync(commandsDir) fresh each
-- call to reflect files added without a restart. Lua has no hot-reload of
-- required modules anyway (require() caches), so this reads from the
-- already-loaded client.commands table instead -- same descriptor shape,
-- simpler, and always in sync with what's actually running.

local rtdb = require('rtdb')
local discordia = require('discordia')

local M = {}

-- Node: loadCommandDescriptors() -- reads commands/*.js + cmd.logSchema.
-- Lua: reads client.commands (populated once at boot in main.lua).
function M.loadCommandDescriptors(client)
  local descriptors = {}
  for name, cmd in pairs(client.commands) do
    table.insert(descriptors, {
      name = name,
      channelName = name .. '-logs',
      logSchema = cmd.logSchema, -- nil if command hasn't opted in yet
    })
  end
  return descriptors
end

-- Node: guildConfig/{guildId}.logCategoryId / .logChannels (Firestore doc)
-- RTDB: guildConfig/{guildId}/logCategoryId, /logChannels
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
  -- Node merges a nested { logChannels: { [commandName]: channelId } } patch
  -- so sibling commands' channel entries survive. RTDB PATCH on the specific
  -- nested path does the same without touching other logChannels keys.
  rtdb.update('guildConfig/' .. guildId .. '/logChannels', { [commandName] = channelId })
end

-- Node: guild.channels.create({ type: GuildCategory, permissionOverwrites: [...] })
-- discordia has no inline permissionOverwrites-on-create; create then set
-- overwrites via getPermissionOverwriteFor()/setDeniedPermissions() --
-- confirmed API, see SinisterRectus/Discordia libs/containers/PermissionOverwrite.lua
function M.resolveLogCategory(guild, categoryOption)
  if categoryOption then
    return categoryOption
  end

  local category = guild:createCategory('Bot Logs')

  local everyoneOverwrite = category:getPermissionOverwriteFor(guild.defaultRole)
  everyoneOverwrite:setDeniedPermissions(discordia.enums.permission.viewChannel)

  local botMember = guild.me
  if botMember then
    local botOverwrite = category:getPermissionOverwriteFor(botMember)
    botOverwrite:setAllowedPermissions(
      discordia.enums.permission.viewChannel
      + discordia.enums.permission.sendMessages
      + discordia.enums.permission.manageChannels
    )
  end

  return category
end

-- Node: syncLogChannels() -- scans commands, creates {command}-logs channel
-- under the log category for any command missing one on record.
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
      -- discordia createTextChannel has no parent/topic in ctor args --
      -- set them as a follow-up call each. setCategory (NOT setParent --
      -- that's a djs-ism) confirmed real via SinisterRectus/Discordia
      -- wiki/GuildChannel.
      local channel = guild:createTextChannel(desc.channelName)
      pcall(function() channel:setCategory(categoryId) end)
      pcall(function() channel:setTopic('Activity log for /' .. desc.name) end)

      M.saveLogChannel(guildId, desc.name, channel.id)
      table.insert(created, desc.channelName)
    end
  end

  return { created = created, alreadyExists = alreadyExists, skippedNoSchema = skippedNoSchema }
end

-- Node: formatFieldValue() -- Discord.js User/Member/Role/Channel all have
-- toString() that yields mention syntax. discordia containers implement
-- __tostring via the same ClassName:hash pattern by default, BUT mention
-- syntax specifically needs tostring(obj) to be overridden per-class --
-- confirmed discordia does NOT auto-produce <@id> from tostring() the way
-- djs does. Must build mention strings manually here instead.
local function formatFieldValue(value)
  if value == nil then return 'N/A' end
  if type(value) == 'table' and value.id then
    -- Distinguish by presence of characteristic fields rather than a
    -- discordia class-check helper (keeps this util decoupled from needing
    -- isInstance + every possible class required in this file).
    if value.username ~= nil then
      return '<@' .. value.id .. '>' -- User or Member
    elseif value.hoisted ~= nil or value.mentionable ~= nil then
      return '<@&' .. value.id .. '>' -- Role
    elseif value.topic ~= nil or value.bitrate ~= nil then
      return '<#' .. value.id .. '>' -- Channel
    end
    return tostring(value)
  end
  return tostring(value)
end

-- Node: logCommandActivity(interaction, {...}) -- silent no-op if logging
-- isn't configured; never throws to the caller.
-- ia here is a discordia-slash CommandInteraction (or the honeypot's
-- constructed fake-interaction table, matching Node's fakeInteraction usage).
function M.logCommandActivity(client, ia, opts)
  local ok, err = pcall(function()
    if not ia.guildId then return end

    local config = M.getLogConfig(ia.guildId)
    local channelId = config and config.logChannels and config.logChannels[ia.commandName]
    if not channelId then return end -- logging not set up for this command

    local channel = client:getChannel(channelId)
    if not channel then return end -- deleted manually, nothing to log to

    local cmd = client.commands[ia.commandName]
    local schemaEntry = cmd and cmd.logSchema and cmd.logSchema.subcommands and cmd.logSchema.subcommands[opts.subcommand]
    local label = (schemaEntry and schemaEntry.label) or opts.subcommand or ia.commandName

    local fields = {
      { name = 'Status', value = opts.success and '✅ Success' or '❌ Failed', inline = true },
      { name = 'Run By', value = '<@' .. ia.member.id .. '>', inline = true },
    }

    for key, value in pairs(opts.fields or {}) do
      -- discordUser is redundant with "Run By" above -- same skip as Node.
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
    -- Logging must never break the command it's logging -- same reasoning
    -- as the error-reply try/catch in main.lua.
    print('[logger] logCommandActivity failed: ' .. tostring(err))
  end
end

return M
