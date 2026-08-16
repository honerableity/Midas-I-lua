local dotenv = require('dotenv')
local ok, err = dotenv.load()
if not ok then
  error('Failed to load .env: ' .. tostring(err))
end
local M = {}
function M.run(client, loadedCommands)
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
  -- Commands are already loaded by main.lua's own require() loop at
  -- startup (before the client connects). Re-require()ing them a second
  -- time from inside client:once('ready', ...) proved unreliable — same
  -- absolute paths that resolve fine in a standalone script fail here,
  -- for reasons tied to how require() interacts with Discordia's event
  -- loop that we couldn't fully pin down. Reusing main.lua's already-
  -- loaded table sidesteps the problem instead of chasing it further.
  local commands = {}
  for _, cmd in pairs(loadedCommands) do
    if cmd.data then
      table.insert(commands, cmd.data)
    end
  end
  if #commands == 0 then
    error('No valid commands found. Nothing to deploy.')
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
