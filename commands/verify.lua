local discordia = require('discordia')
local tools = require('discordia-slash').util.tools()
local logger = require('logger')
local verification = require('verification')

local enums = discordia.enums

local M = {}

local data = tools.slashCommand('verify', 'Verify your Roblox account')

data:addOption(tools.subCommand('start', 'Start Roblox verification (DMs you a code)'))

data:addOption(
  tools.subCommand('setrole', 'Set the role given after verification')
    :addOption(tools.role('role', 'Role to assign on verify'):setRequired(true))
)

data:addOption(tools.subCommand('unverify', 'Remove your Roblox verification'))

data:addOption(
  tools.subCommand('profile', 'Look up a member\'s linked Roblox profile')
    :addOption(tools.user('user', 'Discord user to look up'):setRequired(true))
)

M.data = data

M.logSchema = {
  subcommands = {
    start = { label = 'Verify — Start', fields = { 'discordUser' } },
    setrole = { label = 'Verify — Set Role', fields = { 'discordUser', 'role' } },
    unverify = { label = 'Verify — Unverify', fields = { 'discordUser', 'robloxUsername' } },
    profile = { label = 'Verify — Profile Lookup', fields = { 'discordUser', 'targetUser' } },
    verifyComplete = { label = 'Verify — Completed', fields = { 'discordUser', 'robloxUsername' } },
  },
}

local PAGE_SIZE = 10
local profileStates = {}

local function paginateListField(embed, label, items, page, pageSize)
  local totalPages = math.max(1, math.ceil(#items / pageSize))
  local clampedPage = math.min(page, totalPages - 1)
  local start = clampedPage * pageSize
  local slice = {}
  for i = start + 1, math.min(start + pageSize, #items) do
    table.insert(slice, items[i])
  end
  local value = (#slice > 0) and table.concat(slice, '\n') or 'None'
  table.insert(embed.fields, {
    name = label .. ' (' .. #items .. ') — Page ' .. (clampedPage + 1) .. '/' .. totalPages,
    value = value,
  })
  return embed
end

local function buildProfileEmbed(state, details, record, targetUser)
  local embed = {
    title = 'Roblox Profile — ' .. details.username,
    color = 0x00b0f4,
    footer = { text = 'Discord: ' .. targetUser.username },
    fields = {},
  }

  if state.tab == 'overview' then
    local createdMs = discordia.Date.fromISO and nil or nil
    local accountAgeDays = nil
    local y, mo, d = details.created:match('(%d+)-(%d+)-(%d+)')
    if y then
      local createdEpoch = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d) })
      accountAgeDays = math.floor((os.time() - createdEpoch) / 86400)
    end

    table.insert(embed.fields, { name = 'Discord User', value = '<@' .. targetUser.id .. '>', inline = true })
    table.insert(embed.fields, { name = 'Roblox Username', value = details.username, inline = true })
    table.insert(embed.fields, { name = 'Display Name', value = details.displayName ~= '' and details.displayName or details.username, inline = true })
    table.insert(embed.fields, { name = 'Account Age', value = accountAgeDays == nil and 'Unknown' or (accountAgeDays .. ' days'), inline = true })
    table.insert(embed.fields, { name = 'Verified Badge', value = details.hasVerifiedBadge and 'Yes' or 'No', inline = true })
    table.insert(embed.fields, { name = 'Groups', value = tostring(#details.groups), inline = true })
    return embed
  end

  if state.tab == 'groups' then
    local items = {}
    for _, g in ipairs(details.groups) do
      table.insert(items, g.name .. ' — ' .. g.role)
    end
    return paginateListField(embed, 'Groups', items, state.page, PAGE_SIZE)
  end

  if state.tab == 'products' then
    return paginateListField(embed, 'Owned Products', {}, state.page, PAGE_SIZE)
  end

  table.insert(embed.fields, { name = 'Roblox ID', value = tostring(record.robloxId), inline = true })
  table.insert(embed.fields, { name = 'Verified At', value = '<t:' .. math.floor(record.verifiedAt / 1000) .. ':F>', inline = true })
  table.insert(embed.fields, { name = 'Verified Badge', value = details.hasVerifiedBadge and 'Yes' or 'No', inline = true })
  return embed
end

local function buildProfileComponents(state, details, disabled)
  disabled = disabled or false

  local specs = {
    { id = 'profile_tab_overview', type = 'button', label = 'Overview',
      style = state.tab == 'overview' and 'primary' or 'secondary', disabled = disabled },
    { id = 'profile_tab_groups', type = 'button', label = 'Groups',
      style = state.tab == 'groups' and 'primary' or 'secondary', disabled = disabled },
    { id = 'profile_tab_products', type = 'button', label = 'Products',
      style = state.tab == 'products' and 'primary' or 'secondary', disabled = disabled },
    { id = 'profile_tab_account', type = 'button', label = 'Account',
      style = state.tab == 'account' and 'primary' or 'secondary', disabled = disabled },
  }

  if state.tab == 'groups' or state.tab == 'products' then
    local items = state.tab == 'groups' and details.groups or {}
    local totalPages = math.max(1, math.ceil(#items / PAGE_SIZE))
    if totalPages > 1 then
      table.insert(specs, { id = 'profile_page_prev', type = 'button', label = '◀ Prev', style = 'secondary',
        disabled = disabled or state.page == 0, actionRow = 2 })
      table.insert(specs, { id = 'profile_page_next', type = 'button', label = 'Next ▶', style = 'secondary',
        disabled = disabled or state.page >= totalPages - 1, actionRow = 2 })
    end
  end

  return discordia.Components(specs)
end

local function runUnverify(modalIa)
  local record = verification.getVerifiedUser(modalIa.user.id)
  if not record then
    modalIa:reply({ content = 'You are already not verified!' }, true)
    return
  end

  local typed = modalIa.data.components[1].components[1].value:gsub('^%s+', ''):gsub('%s+$', '')

  if typed ~= record.robloxUsername then
    modalIa:reply({ content = 'Username didn\'t match. You typed `' .. typed .. '`, expected `' .. record.robloxUsername .. '`. Run `/verify unverify` again to retry.' }, true)
    return
  end

  local config = verification.getGuildConfig(modalIa.guildId)

  if config and config.verifiedRoleId and modalIa.guild then
    local ok, member = pcall(function() return modalIa.guild:getMember(modalIa.user.id) end)
    if ok and member then
      pcall(function() member:removeRole(config.verifiedRoleId) end)
    end
  end

  verification.removeVerifiedUser(modalIa.user.id)

  logger.logCommandActivity(modalIa.client, {
    guildId = modalIa.guildId, commandName = 'verify', member = { id = modalIa.user.id },
  }, {
    subcommand = 'unverify', success = true,
    fields = { discordUser = modalIa.user, robloxUsername = record.robloxUsername },
  })

  modalIa:reply({ content = 'You have been unverified. Your role and verification data have been removed.' }, true)
end

local function handleProfile(ia)
  ia:replyDeferred(false)

  local target = ia.data.parsed_options.user
  local record = verification.getVerifiedUser(target.id)

  if not record then
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'profile', success = false,
      fields = { discordUser = ia.user, targetUser = target },
      note = 'Target user is not verified.',
    })
    ia:editReply({ content = 'The user is not verified!' })
    return
  end

  local ok, details = pcall(verification.fetchRobloxProfileDetails, record.robloxId)
  if not ok then
    print('fetchRobloxProfileDetails failed: ' .. tostring(details))
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'profile', success = false,
      fields = { discordUser = ia.user, targetUser = target },
      note = 'Roblox API error while fetching profile details.',
    })
    ia:editReply({ content = 'Bot error while contacting Roblox. Try again later.' })
    return
  end

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'profile', success = true,
    fields = { discordUser = ia.user, targetUser = target },
  })

  local state = { tab = 'overview', page = 0 }

  local message = ia:editReply({
    embed = buildProfileEmbed(state, details, record, target),
    components = buildProfileComponents(state, details),
  })

  profileStates[message.id] = {
    state = state, details = details, record = record,
    targetUser = target, ownerId = ia.user.id, expiresAt = os.time() * 1000 + 5 * 60 * 1000,
  }
end

function M.handleComponent(cIa)
  local customId = cIa.data and cIa.data.custom_id
  if not customId then return end

  if customId == 'unverify_modal' then
    runUnverify(cIa)
    return
  end

  if customId:match('^profile_') then
    local msgId = cIa.message and cIa.message.id
    local entry = msgId and profileStates[msgId]
    if not entry then return end

    if cIa.user.id ~= entry.ownerId then
      cIa:reply({ content = 'Only the person who ran this command can use these buttons.' }, true)
      return
    end

    if customId:match('^profile_tab_') then
      entry.state.tab = customId:gsub('^profile_tab_', '')
      entry.state.page = 0
    elseif customId == 'profile_page_prev' then
      entry.state.page = math.max(0, entry.state.page - 1)
    elseif customId == 'profile_page_next' then
      entry.state.page = entry.state.page + 1
    end

    cIa:update({
      embed = buildProfileEmbed(entry.state, entry.details, entry.record, entry.targetUser),
      components = buildProfileComponents(entry.state, entry.details),
    })
    return
  end

  if customId == 'verify_button' then
    local modal = discordia.Modal {
      id = 'verify_modal',
      title = 'Roblox Verification',
      { id = 'roblox_username', label = 'Your Roblox Username', style = 'short', required = true },
    }
    cIa:modal(modal)
    return
  end

  if customId == 'verify_modal' then
    local username = cIa.data.components[1].components[1].value:gsub('^%s+', ''):gsub('%s+$', '')

    cIa:replyDeferred(true)

    local session = verification.getSession(cIa.user.id)
    if not session or os.time() * 1000 > session.expiresAt then
      cIa:editReply('Your verification code expired. Run `/verify start` again.')
      return
    end

    local ok, profile = pcall(verification.fetchRobloxDescription, username)
    if not ok then
      cIa:editReply('Bot error while contacting Roblox. Try again later.')
      return
    end

    if profile.notFound then
      cIa:editReply('That Roblox username was not found. Check spelling and try again.')
      return
    end

    if not verification.descriptionContainsCode(profile.description, session.code) then
      cIa:editReply('Code not found in your Roblox profile description yet. Make sure `' .. session.code .. '` is pasted in your About section, then click Verify! again.')
      return
    end

    local guild = cIa.guild
    if not guild then
      cIa:editReply('Bot error: could not resolve server.')
      return
    end
    local member = guild:getMember(cIa.user.id)
    local cfg = verification.getGuildConfig(guild.id)

    if not cfg or not cfg.verifiedRoleId then
      cIa:editReply('Bot error: verified role is no longer configured.')
      return
    end

    local roleOk, roleErr = pcall(function() member:addRole(cfg.verifiedRoleId) end)
    if not roleOk then
      print('Role assign failed: ' .. tostring(roleErr))
      cIa:editReply('Bot error: could not assign role. Check my role position/permissions.')
      return
    end

    local saveOk, saveErr = pcall(function()
      verification.saveVerifiedUser(cIa.user.id, {
        robloxId = profile.robloxId,
        robloxUsername = profile.robloxUsername,
        guildId = guild.id,
      })
    end)
    if not saveOk then
      print('saveVerifiedUser failed (role already assigned): ' .. tostring(saveErr))
    end

    verification.clearSession(cIa.user.id)

    logger.logCommandActivity(cIa.client, {
      guildId = guild.id, commandName = 'verify', member = { id = cIa.user.id },
    }, {
      subcommand = 'verifyComplete', success = true,
      fields = { discordUser = cIa.user, robloxUsername = profile.robloxUsername },
    })

    cIa:editReply('Verified! You\'re linked as **' .. profile.robloxUsername .. '**. Role assigned.')
    return
  end
end

function M.execute(ia, cmd)
  if not ia.guildId then
    ia:reply({ content = 'This command only works inside a server.' }, true)
    return
  end

  local args, sub = tools.getSubCommand(cmd)

  if sub == 'unverify' then
    local modal = discordia.Modal {
      id = 'unverify_modal',
      title = 'Confirm Unverify',
      { id = 'roblox_username', label = 'Type your Roblox username to confirm', placeholder = 'Your exact Roblox username', style = 'short', required = true },
    }
    ia:modal(modal)
    return
  end

  if sub == 'profile' then
    handleProfile(ia)
    return
  end

  ia:replyDeferred(true)

  if sub == 'setrole' then
    if not (ia.member and ia.member:hasPermission(enums.permission.manageRoles)) then
      ia:editReply({ content = 'You need Manage Roles permission to do that.' })
      return
    end
    local role = args.role
    verification.setGuildRole(ia.guildId, role.id)
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'setrole', success = true,
      fields = { discordUser = ia.user, role = role },
    })
    ia:editReply({ content = 'Verified role set to <@&' .. role.id .. '>.' })
    return
  end

  local config = verification.getGuildConfig(ia.guildId)
  if not config or not config.verifiedRoleId then
    ia:editReply({ content = 'Verify role isn\'t set up yet. Ask an admin to run `/verify setrole` first.' })
    return
  end

  local existing = verification.getSession(ia.user.id)
  if existing then
    ia:editReply({ content = 'You already have an active verification code. Check your DMs, or wait <t:' .. math.floor(existing.expiresAt / 1000) .. ':R> for it to expire before starting over.' })
    return
  end

  ia:editReply({ content = 'Check your DMs! 📬' })

  local session = verification.createSession(ia.user.id)

  local embed = {
    title = 'Roblox Verification',
    description = 'Copy this code and paste it anywhere in your Roblox profile **About/Description**:\n\n```' .. session.code .. '```\nThis code expires <t:' .. math.floor(session.expiresAt / 1000) .. ':R>.\n\nOnce it\'s on your profile, click **Verify!** below.',
    color = 0x00b0f4,
  }

  local button = discordia.Button { id = 'verify_button', label = 'Verify!', style = 'success' }

  local dmOk, channel = pcall(function() return ia.user:getPrivateChannel() end)
  if not dmOk or not channel then
    ia:send({ content = 'Could not DM you. Please enable DMs from server members and run `/verify start` again.', ephemeral = true })
    return
  end

  local sendOk = pcall(function() channel:sendComponents({ embed = embed }, button) end)
  if not sendOk then
    ia:send({ content = 'Could not DM you. Please enable DMs from server members and run `/verify start` again.', ephemeral = true })
    return
  end

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'start', success = true,
    fields = { discordUser = ia.user },
  })
end

return M
