local discordia = require('discordia')
local tools = require('discordia-slash').util.tools()
local childprocess = require('childprocess')
local pathjoin = require('pathjoin')

local M = {}

local data = tools.slashCommand('redeploy', 'Pull latest code from GitHub and restart the bot')
M.data = data

-- Spawns a fresh start.sh (which does the git pull + self-copy guard
-- itself) as a detached process, then kills this one. Detached so the
-- child survives past this process's exit instead of dying with it --
-- same reasoning as start.sh's own self-copy guard, just one level up.
-- stdio inherits the current terminal so the new run's output still
-- shows in the wispbyte console instead of going to a silent orphan.
function M.execute(ia, cmd, args)
  if not ia.guildId then
    ia:reply({ content = 'This command only works inside a server.' }, true)
    return
  end

  if ia.guild.ownerId ~= ia.user.id then
    ia:reply({ content = 'Only the server owner can run this.' }, true)
    return
  end

  ia:reply({ content = 'Pulling latest code and restarting...' }, true)

  local startScript = pathjoin.pathJoin(module.dir, '..', 'start.sh')

  local ok, err = pcall(function()
    local child = childprocess.spawn('bash', { startScript }, {
      detached = true,
      stdio = { 0, 1, 2 },
    })
    child:unref()
  end)

  if not ok then
    print('redeploy: failed to spawn start.sh: ' .. tostring(err))
    ia:editReply({ content = 'Failed to spawn start.sh, check console: ' .. tostring(err) })
    return
  end

  -- Give the spawn call a moment to actually land before this process
  -- dies -- exiting in the same tick risks the child never launching.
  discordia.timer.setTimeout(1000, function()
    os.exit(0)
  end)
end

return M
