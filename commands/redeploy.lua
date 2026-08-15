local discordia = require('discordia')
local tools = require('discordia-slash').util.tools()
local pathjoin = require('pathjoin')

local M = {}

local data = tools.slashCommand('redeploy', 'Pull latest code from GitHub and restart the bot')
M.data = data

-- childprocess isn't available in this Luvit build, so we shell out with
-- plain os.execute instead. `nohup ... & disown` backgrounds start.sh and
-- detaches it from this process's session so it survives past this
-- process's exit (same goal as start.sh's own self-copy guard, one level
-- up). Output goes to redeploy.log next to start.sh since nohup can't
-- inherit this process's stdio the way a real spawn could.
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

  local repoRoot = pathjoin.pathJoin(module.dir, '..')
  local cmdStr = string.format(
    'cd %q && nohup bash start.sh >> redeploy.log 2>&1 & disown',
    repoRoot
  )

  local ok = os.execute(cmdStr)
  if not ok then
    print('redeploy: failed to spawn start.sh')
    ia:editReply({ content = 'Failed to spawn start.sh, check console.' })
    return
  end

  -- Give the shell a moment to actually launch the child before this
  -- process dies -- exiting in the same tick risks the child never
  -- getting off the ground.
  discordia.timer.setTimeout(1000, function()
    os.exit(0)
  end)
end

return M
