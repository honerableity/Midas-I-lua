local rtdb = require('utils.rtdb')

local M = {}

local CREATE_LOCK_MS = 15 * 1000
local SELECTION_TTL_MS = 15 * 60 * 1000

function M.getGuildConfig(guildId)
  return rtdb.get('guildConfig/' .. guildId) or {}
end

function M.setTestiChannel(guildId, channelId)
  rtdb.update('guildConfig/' .. guildId, { testiChannelId = channelId })
end

function M.getTestiChannel(guildId)
  local cfg = M.getGuildConfig(guildId)
  return cfg.testiChannelId
end

function M.setTicketCategories(guildId, categoryIds)
  rtdb.update('guildConfig/' .. guildId, { ticketCategories = categoryIds })
end

function M.getTicketCategories(guildId)
  local cfg = M.getGuildConfig(guildId)
  return cfg.ticketCategories
end

function M.nextTicketNumber(guildId)
  local path = 'guildConfig/' .. guildId
  local cfg = rtdb.get(path) or {}
  local current = cfg.testiCounter or 0
  local next_ = current + 1
  rtdb.update(path, { testiCounter = next_ })
  return next_
end

function M.createTicket(data)
  local payload = {}
  for k, v in pairs(data) do payload[k] = v end
  payload.status = 'open'
  payload.createdAt = os.time() * 1000
  rtdb.set('tickets/' .. data.channelId, payload)
end

function M.claimTicketCreateLock(userId, category)
  local path = 'ticketCreateLocks/' .. userId .. '_' .. category
  local existing = rtdb.get(path)
  local now = os.time() * 1000
  if existing and (now - (existing.lockedAt or 0)) < CREATE_LOCK_MS then
    return false
  end
  rtdb.set(path, { lockedAt = now })
  return true
end

function M.releaseTicketCreateLock(userId, category)
  pcall(function() rtdb.delete('ticketCreateLocks/' .. userId .. '_' .. category) end)
end

function M.saveOrderSelection(token, userId, productIds)
  rtdb.set('orderSelections/' .. token, {
    userId = userId,
    productIds = productIds,
    createdAt = os.time() * 1000,
  })
end

function M.getOrderSelection(token)
  local data = rtdb.get('orderSelections/' .. token)
  if not data then return nil end
  if (os.time() * 1000 - (data.createdAt or 0)) > SELECTION_TTL_MS then return nil end
  return data
end

function M.getTicket(channelId)
  local data = rtdb.get('tickets/' .. channelId)
  if not data then return nil end
  data.id = channelId
  return data
end

function M.findOpenTicket(guildId, creatorId, category)
  local all = rtdb.get('tickets')
  if not all then return nil end
  for id, data in pairs(all) do
    if data.creatorId == creatorId and data.status == 'open' and data.guildId == guildId and data.category == category then
      data.id = id
      return data
    end
  end
  return nil
end

function M.closeTicket(channelId, extra)
  local payload = { status = 'done', closedAt = os.time() * 1000 }
  if extra then
    for k, v in pairs(extra) do payload[k] = v end
  end
  rtdb.update('tickets/' .. channelId, payload)
end

function M.markTicketDeleted(channelId)
  rtdb.update('tickets/' .. channelId, { status = 'deleted', deletedAt = os.time() * 1000 })
end

return M
