local discordia = require('discordia')
local dslash = require('discordia-slash')
local fs = require('fs')
local pathjoin = require('pathjoin')
local dotenv = require('dotenv')

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
    local deploy = require('deploy-command')
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
  if modCommand and modCommand.handleHoneypotMessage then
    local ok, err = pcall(modCommand.handleHoneypotMessage, message)
    if not ok then
      print('[mod] honeypot handler failed: ' .. tostring(err))
    end
  end

  local stickyCommand = commands['sticky']
  if stickyCommand and stickyCommand.handleActivity then
    local ok, err = pcall(stickyCommand.handleActivity, message)
    if not ok then
      print('[sticky] activity handler failed: ' .. tostring(err))
    end
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

local function routeVerifyComponent(ia)
  local id = ia.customId or (ia.data and ia.data.custom_id)
  if not id then return end
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
