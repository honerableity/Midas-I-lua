local fs = require('fs')
local pathjoin = require('pathjoin')
local dotenv = require('dotenv')

local ok, err = dotenv.load()
if not ok then
  error('Failed to load .env: ' .. tostring(err))
end

local M = {}

function M.run(client)
  local required = { 'DISCORD_TOKEN', 'CLIENT_ID', 'GUILD_ID' }
  local missing = {}
  for _, key in ipairs(required) do
    if not dotenv.get(key) then
      table.insert(missing, key)
    end
  end
  if #missing > 0 then
    error('Missing env var(s): ' .. table.concat(missing, ', ') .. '. Copy .env.example to .env and fill them in.')
  end

  -- module.dir only resolves correctly for the true entrypoint (main.lua);
  -- this file is loaded via require() from main.lua, so module.dir here
  -- resolves to Lua's legacy module() function instead (no .dir field).
  -- Luvit apps always run with CWD at the project root, so build the path
  -- relative to CWD instead.
  local commandsDir = pathjoin.pathJoin('.', 'commands')
  local commandFiles = fs.readdirSync(commandsDir)

  local commands = {}
  for _, file in ipairs(commandFiles) do
    if file:match('%.lua$') then
      -- require() needs a dotted module name, not a filesystem path with
      -- a .lua extension — pathjoin.pathJoin(commandsDir, file) produced
      -- something like './commands/mod.lua', which require() can't resolve.
      local modName = 'commands.' .. file:gsub('%.lua$', '')
      local cmd = require(modName)
      if not (cmd and cmd.data) then
        print('Skipped ' .. file .. ': no "data" export found.')
      else
        table.insert(commands, cmd.data)
      end
    end
  end

  if #commands == 0 then
    error('No valid commands found in ./commands. Nothing to deploy.')
  end

  local names = {}
  for _, c in ipairs(commands) do
    table.insert(names, c.name)
  end
  print('Deploying ' .. #commands .. ' command(s): ' .. table.concat(names, ', '))

  local ok, result = pcall(function()
    return client._api:bulkOverwriteGuildApplicationCommands(
      dotenv.get('CLIENT_ID'),
      dotenv.get('GUILD_ID'),
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
