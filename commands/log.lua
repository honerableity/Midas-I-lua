local discordia = require('discordia')
local tools = require('discordia-slash').util.tools()
local logger = require('utils.logger')

local enums = discordia.enums
local M = {}

local data = tools.slashCommand('log', 'Configure bot activity logging')

data:addOption(
  tools.subCommand('setcategory', 'Set (or create) the category logs go into, and generate log channels')
    :addOption(tools.channel('category', 'Existing category to use. Leave empty to create an owner-only category.'):setRequired(false))
)

data:addOption(
  tools.subCommand('update', 'Scan commands/ and create log channels for any commands missing one')
)

M.data = data

local function buildSummaryMessage(category, summary)
  local lines = { 'Log category: <#' .. category.id .. '>' }

  if #summary.created > 0 then
    table.insert(lines, 'Created: ' .. table.concat(summary.created, ', '))
  else
    table.insert(lines, 'Created: none')
  end

  if #summary.alreadyExists > 0 then
    table.insert(lines, 'Already existed: ' .. table.concat(summary.alreadyExists, ', '))
  else
    table.insert(lines, 'Already existed: none')
  end

  if #summary.skippedNoSchema > 0 then
    table.insert(lines, 'Skipped (no logSchema defined yet): ' .. table.concat(summary.skippedNoSchema, ', '))
  end

  return table.concat(lines, '\n')
end

function M.execute(ia, cmd, args)
  if not ia.guildId then
    ia:reply({ content = 'This command only works inside a server.' }, true)
    return
  end

  if not (ia.member and ia.member:hasPermission(enums.permission.manageGuild)) then
    ia:reply({ content = 'You need Manage Server permission to do that.' }, true)
    return
  end

  local subArgs, sub = tools.getSubCommand(cmd)

  ia:replyDeferred(true)

  if sub == 'setcategory' then
    local categoryOption = subArgs.category

    local catOk, category = pcall(logger.resolveLogCategory, ia.guild, categoryOption)
    if not catOk then
      print('resolveLogCategory failed: ' .. tostring(category))
      ia:editReply({ content = 'Bot error while creating the log category. Check my Manage Channels permission.' })
      return
    end

    logger.saveLogCategory(ia.guildId, category.id)

    local syncOk, summary = pcall(logger.syncLogChannels, ia.client, ia.guild, ia.guildId, category.id)
    if not syncOk then
      print('syncLogChannels failed: ' .. tostring(summary))
      ia:editReply({ content = 'Log category set to <#' .. category.id .. '>, but channel creation failed partway through. Run `/log update` to retry.' })
      return
    end

    ia:editReply({ content = buildSummaryMessage(category, summary) })
    return
  end

  local config = logger.getLogConfig(ia.guildId)
  if not config or not config.logCategoryId then
    ia:editReply({ content = 'No log category set yet. Run `/log setcategory` first.' })
    return
  end

  local catOk, category = pcall(function() return ia.guild:getChannel(config.logCategoryId) end)
  if not catOk or not category then
    ia:editReply({ content = 'The configured log category no longer exists (deleted?). Run `/log setcategory` again to set a new one.' })
    return
  end

  local syncOk, summary = pcall(logger.syncLogChannels, ia.client, ia.guild, ia.guildId, category.id)
  if not syncOk then
    print('syncLogChannels failed: ' .. tostring(summary))
    ia:editReply({ content = 'Bot error while creating log channels. Check my Manage Channels permission.' })
    return
  end

  ia:editReply({ content = buildSummaryMessage(category, summary) })
end

return M
