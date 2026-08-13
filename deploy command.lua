-- Midas-I deploy-commands.lua
-- Luau port of deploy-commands.js
-- Exports run(client) so main.lua can call in-process (Luvit has no
-- direct child_process/execFileSync equiv -- see main.lua deployCommands()).

local fs = require('fs')
local pathjoin = require('pathjoin')

local M = {}

function M.run(client)
  -- deploy-commands.js: required = ['DISCORD_TOKEN', 'CLIENT_ID', 'GUILD_ID']
  local required = { 'DISCORD_TOKEN', 'CLIENT_ID', 'GUILD_ID' }
  local missing = {}
  for _, key in ipairs(required) do
    if not os.getenv(key) then
      table.insert(missing, key)
    end
  end
  if #missing > 0 then
    error('Missing env var(s): ' .. table.concat(missing, ', ') .. '. Copy .env.example to .env and fill them in.')
  end

  -- deploy-commands.js: fs.readdirSync(commandsDir).filter(f => f.endsWith('.js'))
  local commandsDir = pathjoin.pathJoin(module.dir, 'commands')
  local commandFiles = fs.readdirSync(commandsDir)

  local commands = {}
  for _, file in ipairs(commandFiles) do
    if file:match('%.lua$') then
      -- deploy-commands.js: const cmd = require(path.join(commandsDir, file))
      local cmd = require(pathjoin.pathJoin(commandsDir, file))
      if not (cmd and cmd.data) then
        print('Skipped ' .. file .. ': no "data" export found.')
      else
        -- deploy-commands.js: cmd.data.toJSON() -- discord.js SlashCommandBuilder
        -- has toJSON(); discordia-slash CommandConstructor has no toJSON,
        -- table itself IS the payload shape, so use cmd.data directly.
        table.insert(commands, cmd.data)
      end
    end
  end

  if #commands == 0 then
    error('No valid commands found in ./commands. Nothing to deploy.')
  end

  -- deploy-commands.js: const rest = new REST().setToken(...); rest.put(
  --   Routes.applicationGuildCommands(CLIENT_ID, GUILD_ID), { body: commands })
  -- discordia-slash equiv: API:bulkOverwriteGuildApplicationCommands
  local names = {}
  for _, c in ipairs(commands) do
    table.insert(names, c.name)
  end
  print('Deploying ' .. #commands .. ' command(s): ' .. table.concat(names, ', '))

  local ok, result = pcall(function()
    return client._api:bulkOverwriteGuildApplicationCommands(
      os.getenv('CLIENT_ID'),
      os.getenv('GUILD_ID'),
      commands
    )
  end)

  if ok then
    print('Slash commands registered successfully. Discord confirmed ' .. #result .. ' command(s) live.')
  else
    print('Slash command deploy FAILED: ' .. tostring(result))
    error(result)
  end
end

return M
