local discordia = require('discordia')
local dslash = require('discordia-slash')
local fs = require('fs')
local pathjoin = require('pathjoin')
local dotenv = require('dotenv')

-- Luvit's require() only resolves bare deps/ modules (like 'coro-http') when
-- called directly from the entrypoint file. Files under commands/ and utils/
-- are nested too deep to find deps/ on their own, so we require the modules
-- utils/rtdb.lua needs here (from main.lua, the entrypoint) and prime
-- package.loaded so those same require('coro-http') / require('json') calls
-- inside utils/rtdb.lua resolve from cache instead of failing.
package.loaded['coro-http'] = require('coro-http')
package.loaded['json'] = require('json')
package.loaded['fs'] = fs
package.loaded['pathjoin'] = pathjoin
package.loaded['discordia'] = discordia
package.loaded['discordia-slash'] = dslash
package.loaded['dotenv'] = dotenv

local ok, err = dotenv.load()
if not ok then
  print('Failed to load .env: ' .. tostring(err))
  os.exit(1)
end

local DISCORD_TOKEN = dotenv.get('DISCORD_TOKEN')

if not DISCORD_TOKEN or DISCORD_TOKEN == '' then
  print('Missing DISCORD_TOKEN in .env')
  os.exit(1)
end

local client = discordia.Client({
  gatewayIntents = discordia.enums.gatewayIntent.guilds
    + discordia.enums.gatewayIntent.guildMembers
    + discordia.enums.gatewayIntent.guildMessages
    + discordia.enums.gatewayIntent.messageContent,
}):useApplicationCommands()

-- Use a local table for commands; do NOT attach to Discordia client object.
local commands = {}

local commandsDir = pathjoin.pathJoin(module.dir, 'commands')
local commandFiles = fs.readdirSync(commandsDir)
for _, file in ipairs(commandFiles) do
  if file:match('%.lua$') then
    local cmd = require(pathjoin.pathJoin(commandsDir, file))
    if not (cmd and cmd.data and cmd.data.name) then
      print('Skipped loading ' .. file .. ': missing "data.name" export.')
    else
      commands[cmd.data.name] = cmd
    end
  end
end

local function deployCommands()
  print('Deploying slash commands...')
  local ok, err = pcall(function()
    local deploy = require(pathjoin.pathJoin(module.dir, 'deploy-commands'))
    deploy.run(client)
  end)
  if not ok then
    print('Auto-deploy failed: ' .. tostring(err))
    print('Bot will still start, but slash commands may be out of date. Run deploy-commands.lua manually.')
  end
end

client:once('ready', function()
  print('Logged in as ' .. client.user.username)

  deployCommands()

  local moderation = require(pathjoin.pathJoin(module.dir, 'utils', 'moderation'))
  moderation.startExpiryScanner(client)
end)

client:on('messageCreate', function(message)
  local modCommand = commands['mod']
  if not (modCommand and modCommand.handleHoneypotMessage) then return end

  local ok, err = pcall(modCommand.handleHoneypotMessage, message)
  if not ok then
    print('[mod] honeypot handler failed: ' .. tostring(err))
  end
end)

client:on('slashCommandAutocomplete', function(ia, cmd, focused_option, args)
  local command = commands[cmd.name]
  if not (command and command.autocomplete) then return end

  local ok, err = pcall(command.autocomplete, ia, cmd, focused_option, args)
  if not ok then
    print('Error in /' .. cmd.name .. ' autocomplete: ' .. tostring(err))
  end
end)

local function replyBotError(ia)
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
  local command = commands[cmd.name]
  if not command then return end

  local ok, err = pcall(command.execute, ia, cmd, args)
  if not ok then
    print('Error in /' .. cmd.name .. ': ' .. tostring(err))
    replyBotError(ia)
  end
end)

local function routeTicketComponent(ia)
  -- componentInteraction/modalSubmit may expose custom id as ia.customId or ia.data.custom_id;
  -- check both.
  local customId = ia.customId or (ia.data and ia.data.custom_id)
  if not (customId and customId:match('^ticket_')) then return end

  local ticketCommand = commands['ticket']
  if not (ticketCommand and ticketCommand.handleComponent) then return end

  local ok, err = pcall(ticketCommand.handleComponent, ia)
  if not ok then
    print('Error in ticket component handler: ' .. tostring(err))
    replyBotError(ia)
  end
end

-- Removed erroneous top-level ia references that ran at module load time.

local function routeVerifyComponent(ia)
  local id = ia.customId or (ia.data and ia.data.custom_id)
  if not id then return end

  -- Allow verification-related component IDs to pass to the verify handler.
  if not (id == 'verify_button' or id == 'verify_modal' or id == 'unverify_modal' or id:match('^profile_')) then
    return
  end

  local verifyCommand = commands['verify']
  if not (verifyCommand and verifyCommand.handleComponent) then return end

  local ok, err = pcall(verifyCommand.handleComponent, ia)
  if not ok then
    print('Error in verify component handler: ' .. tostring(err))
    replyBotError(ia)
  end
end

client:on('componentInteraction', routeTicketComponent)
client:on('modalSubmit', routeTicketComponent)
client:on('componentInteraction', routeVerifyComponent)
client:on('modalSubmit', routeVerifyComponent)

client:on('error', function(err)
  print('Unhandled error: ' .. tostring(err))
end)

client:run('Bot ' .. DISCORD_TOKEN)
