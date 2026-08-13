-- Midas-I main.lua
-- Luau port of index.js. Libs: discordia, discordia-interactions,
-- discordia-components, discordia-slash, discordia-modals.
-- Node equiv: index.js (client boot, command loader, interaction router)

local discordia = require('discordia')
local dslash = require('discordia-slash')
local fs = require('fs')       -- luvit fs, async by default, use Sync variants
local pathjoin = require('pathjoin')

local DISCORD_TOKEN = os.getenv('DISCORD_TOKEN')
if not DISCORD_TOKEN then
  print('Missing DISCORD_TOKEN in env. Copy .env.example to .env and fill it in.')
  os.exit(1)
end

-- index.js: intents Guilds, GuildMembers, GuildMessages, MessageContent
local client = discordia.Client({
  gatewayIntents = discordia.enums.gatewayIntent.guilds
    + discordia.enums.gatewayIntent.guildMembers
    + discordia.enums.gatewayIntent.guildMessages
    + discordia.enums.gatewayIntent.messageContent,
}):useApplicationCommands()  -- required by discordia-slash for interactions

-- index.js: client.commands = new Collection() -- plain table keyed by
-- command name, discordia has no Collection ctor for this use case
client.commands = {}

-- index.js: fs.readdirSync(commandsDir).filter(f => f.endsWith('.js'))
local commandsDir = pathjoin.pathJoin(module.dir, 'commands')
local commandFiles = fs.readdirSync(commandsDir)
for _, file in ipairs(commandFiles) do
  if file:match('%.lua$') then
    -- index.js: const cmd = require(path.join(commandsDir, file))
    local cmd = require(pathjoin.pathJoin(commandsDir, file))
    if not (cmd and cmd.data and cmd.data.name) then
      print('Skipped loading ' .. file .. ': missing "data.name" export.')
    else
      client.commands[cmd.data.name] = cmd
    end
  end
end

-- index.js: deployCommands() -- always redeploy on boot, no hash-check
-- (Discloud .commands-hash bug -- see index.js comment, same reasoning here)
local function deployCommands()
  print('Deploying slash commands...')
  local ok, err = pcall(function()
    -- deploy-commands.lua equiv must exist; run in-process here instead of
    -- execFileSync since Luvit has no direct child_process node equiv --
    -- require + call a run() export instead of spawning a subprocess
    local deploy = require(pathjoin.pathJoin(module.dir, 'deploy-commands'))
    deploy.run(client)
  end)
  if not ok then
    print('Auto-deploy failed: ' .. tostring(err))
    print('Bot will still start, but slash commands may be out of date. Run deploy-commands.lua manually.')
  end
end

-- index.js: client.once('clientReady', ...) -- clientReady is discord.js's
-- renamed-from-ready event (v14.21+, non-deprecated). discordia's own event
-- name is unrelated and still called "ready" -- NOT the deprecated djs one,
-- different library, no renaming here.
client:once('ready', function()
  print('Logged in as ' .. client.user.username)

  deployCommands()

  -- index.js: startExpiryScanner(client) -- reverses temp-ban/temp-vcmute
  -- past expiry, runs once immediately then every 60s
  local moderation = require(pathjoin.pathJoin(module.dir, 'utils', 'moderation'))
  moderation.startExpiryScanner(client)
end)

-- index.js: client.on('messageCreate', ...) -- honeypot channel watch,
-- separate from interaction router below, fires every message
client:on('messageCreate', function(message)
  local modCommand = client.commands['mod']
  if not (modCommand and modCommand.handleHoneypotMessage) then return end

  local ok, err = pcall(modCommand.handleHoneypotMessage, message)
  if not ok then
    print('[mod] honeypot handler failed: ' .. tostring(err))
  end
end)

-- index.js: client.on('interactionCreate', ...) -- discordia-slash exposes
-- separate events per interaction type instead of one dispatcher; wire each.

-- index.js isAutocomplete() branch
client:on('slashCommandAutocomplete', function(ia, cmd, focused_option, args)
  local command = client.commands[cmd.name]
  if not (command and command.autocomplete) then return end

  local ok, err = pcall(command.autocomplete, ia, cmd, focused_option, args)
  if not ok then
    print('Error in /' .. cmd.name .. ' autocomplete: ' .. tostring(err))
    -- index.js: can't reply to autocomplete on error, let it time out
  end
end)

-- index.js isChatInputCommand() branch
local function replyBotError(ia)
  -- index.js: interaction.replied || interaction.deferred branch --
  -- discordia-interactions tracks this on ia.acknowledged
  local ok, err
  if ia.acknowledged then
    ok, err = pcall(function() ia:send({ content = 'Bot error occurred.', ephemeral = true }) end)
  else
    ok, err = pcall(function() ia:reply({ content = 'Bot error occurred.', ephemeral = true }) end)
  end
  if not ok then
    print('Could not send error reply (interaction likely expired): ' .. tostring(err))
  end
end

client:on('slashCommand', function(ia, cmd, args)
  local command = client.commands[cmd.name]
  if not command then return end

  local ok, err = pcall(command.execute, ia, cmd, args)
  if not ok then
    print('Error in /' .. cmd.name .. ': ' .. tostring(err))
    replyBotError(ia)
  end
end)

-- index.js: global component router, customId prefix "ticket_" ->
-- ticket.js handleComponent(). discordia-components fires on raw
-- interactionCreate for buttons/selects; discordia-modals for modal submit.
-- Wire both to the same routing logic as index.js.
local function routeTicketComponent(ia)
  if not (ia.customId and ia.customId:match('^ticket_')) then return end

  local ticketCommand = client.commands['ticket']
  if not (ticketCommand and ticketCommand.handleComponent) then return end

  local ok, err = pcall(ticketCommand.handleComponent, ia)
  if not ok then
    print('Error in ticket component handler: ' .. tostring(err))
    replyBotError(ia)
  end
end

-- buttons + string selects (discordia-components)
client:on('componentInteraction', routeTicketComponent)
-- modal submits (discordia-modals)
client:on('modalSubmit', routeTicketComponent)

client:on('error', function(err)
  -- index.js: process.on('unhandledRejection', ...) -- Luvit has no direct
  -- unhandledRejection equiv, discordia's own error event is closest catch-all
  print('Unhandled error: ' .. tostring(err))
end)

client:run('Bot ' .. DISCORD_TOKEN)
