local rtdb = require('rtdb')
local discordia = require('discordia')

local enums = discordia.enums
local M = {}

local PERM_VIEW_CHANNEL = 1024
local PERM_READ_HISTORY = 65536
local PERM_SEND_MESSAGES = 2048
local PERM_SEND_IN_THREADS = 274877906944
local PERM_CREATE_PUBLIC_THREADS = 34359738368
local PERM_CREATE_PRIVATE_THREADS = 68719476736
local PERM_MANAGE_CHANNELS = 16

function M.slugifyChannelName(name)
  local s = name:lower():gsub('^%s+', ''):gsub('%s+$', '')
  s = s:gsub('[^a-z0-9]+', '-')
  s = s:gsub('^%-+', ''):gsub('%-+$', '')
  if #s > 90 then s = s:sub(1, 90) end
  if s == '' then s = 'produk' end
  return s
end

function M.getGuildProductConfig(guildId)
  local data = rtdb.get('guildConfig/' .. guildId)
  if not data then return nil end
  return { productCategoryId = data.productCategoryId }
end

function M.saveProductCategory(guildId, categoryId)
  rtdb.update('guildConfig/' .. guildId, { productCategoryId = categoryId })
end

function M.resolveProductCategory(guild, guildId)
  local config = M.getGuildProductConfig(guildId)

  if config and config.productCategoryId then
    local ok, existing = pcall(function() return guild:getChannel(config.productCategoryId) end)
    if ok and existing then return existing end
  end

  local category, err = guild:createCategory('Bot Products')
  if not category then
    error('[products] failed to create category: ' .. tostring(err))
  end

  M.saveProductCategory(guildId, category.id)
  return category
end

function M.listProductTypes(guildId)
  local data = rtdb.get('productTypes/' .. guildId)
  local out = {}
  if not data then return out end
  for id, v in pairs(data) do
    v.id = id
    table.insert(out, v)
  end
  return out
end

function M.getProductTypeByName(guildId, name)
  for _, t in ipairs(M.listProductTypes(guildId)) do
    if t.name == name then return t end
  end
  return nil
end

function M.getProductTypeById(guildId, typeId)
  local data = rtdb.get('productTypes/' .. guildId .. '/' .. typeId)
  if not data then return nil end
  data.id = typeId
  return data
end

local function buildForumPermissionOverwrites(guild)
  return {
    {
      id = guild.id,
      type = 0,
      allow = tostring(PERM_VIEW_CHANNEL + PERM_READ_HISTORY),
      deny = tostring(PERM_SEND_MESSAGES + PERM_SEND_IN_THREADS + PERM_CREATE_PUBLIC_THREADS + PERM_CREATE_PRIVATE_THREADS),
    },
    {
      id = guild.client.user.id,
      type = 1,
      allow = tostring(PERM_VIEW_CHANNEL + PERM_SEND_MESSAGES + PERM_SEND_IN_THREADS + PERM_CREATE_PUBLIC_THREADS + PERM_MANAGE_CHANNELS),
      deny = '0',
    },
  }
end

local function applyForumOverwrites(client, channelId, overwrites)
  for _, ow in ipairs(overwrites) do
    local _, err = client._api:editChannelPermissions(channelId, ow.id, {
      type = ow.type,
      allow = ow.allow,
      deny = ow.deny,
    })
    if err then
      error('[products] failed to set overwrite ' .. tostring(ow.id) .. ': ' .. tostring(err))
    end
  end
end

function M.createOrSyncProductTypeForum(guild, guildId, typeName)
  local existingType = M.getProductTypeByName(guildId, typeName)
  local category = M.resolveProductCategory(guild, guildId)
  local overwrites = buildForumPermissionOverwrites(guild)

  if existingType and existingType.forumChannelId then
    local ok, existingChannel = pcall(function() return guild:getChannel(existingType.forumChannelId) end)
    if ok and existingChannel then
      applyForumOverwrites(guild.client, existingType.forumChannelId, overwrites)
      return { productType = existingType, forumChannel = existingChannel, created = false }
    end
  end

  local payload = {
    name = M.slugifyChannelName(typeName),
    type = enums.channelType.forum,
    parent_id = category.id,
    topic = 'Produk kategori: ' .. typeName,
    permission_overwrites = overwrites,
  }
  local data, err = guild.client._api:createGuildChannel(guild.id, payload)
  if not data then
    error('[products] failed to create forum channel: ' .. tostring(err))
  end

  local typeDoc
  if existingType then
    rtdb.update('productTypes/' .. guildId .. '/' .. existingType.id, { forumChannelId = data.id })
    typeDoc = existingType
    typeDoc.forumChannelId = data.id
  else
    local typeId = rtdb.push('productTypes/' .. guildId, {
      name = typeName,
      forumChannelId = data.id,
      createdAt = os.time() * 1000,
    })
    typeDoc = { id = typeId, name = typeName, forumChannelId = data.id, createdAt = os.time() * 1000 }
  end

  return { productType = typeDoc, forumChannel = data, created = true }
end

function M.linkExistingForumToType(guild, guildId, typeName, forumChannel)
  local existingType = M.getProductTypeByName(guildId, typeName)
  local overwrites = buildForumPermissionOverwrites(guild)

  applyForumOverwrites(guild.client, forumChannel.id, overwrites)

  local typeDoc
  if existingType then
    rtdb.update('productTypes/' .. guildId .. '/' .. existingType.id, { forumChannelId = forumChannel.id })
    typeDoc = existingType
    typeDoc.forumChannelId = forumChannel.id
  else
    local typeId = rtdb.push('productTypes/' .. guildId, {
      name = typeName,
      forumChannelId = forumChannel.id,
      createdAt = os.time() * 1000,
    })
    typeDoc = { id = typeId, name = typeName, forumChannelId = forumChannel.id, createdAt = os.time() * 1000 }
  end

  return { productType = typeDoc, forumChannel = forumChannel, wasExistingType = existingType ~= nil }
end

function M.getProduct(guildId, productId)
  local data = rtdb.get('products/' .. guildId .. '/' .. productId)
  if not data then return nil end
  data.id = productId
  return data
end

function M.listProductsByType(guildId, typeId)
  local all = rtdb.get('products/' .. guildId)
  local out = {}
  if not all then return out end
  for id, v in pairs(all) do
    if v.typeId == typeId then
      v.id = id
      table.insert(out, v)
    end
  end
  return out
end

function M.saveProduct(guildId, productId, data)
  rtdb.set('products/' .. guildId .. '/' .. productId, data)
end

function M.deleteProduct(guildId, productId)
  rtdb.delete('products/' .. guildId .. '/' .. productId)
end

function M.userOwnsProduct(product, discordId)
  if type(product.owners) ~= 'table' then return false end
  for _, id in ipairs(product.owners) do
    if id == discordId then return true end
  end
  return false
end

local function arrayAdd(arr, value)
  arr = arr or {}
  for _, v in ipairs(arr) do
    if v == value then return arr end
  end
  table.insert(arr, value)
  return arr
end

local function arrayRemove(arr, value)
  local out = {}
  if not arr then return out end
  for _, v in ipairs(arr) do
    if v ~= value then table.insert(out, v) end
  end
  return out
end

function M.giveProductToUser(guildId, productId, discordId)
  local product = M.getProduct(guildId, productId)
  if not product then error('[products] product not found: ' .. productId) end
  product.owners = arrayAdd(product.owners, discordId)
  rtdb.update('products/' .. guildId .. '/' .. productId, { owners = product.owners })

  local user = rtdb.get('verifiedUsers/' .. discordId) or {}
  user.ownedProducts = arrayAdd(user.ownedProducts, productId)
  rtdb.update('verifiedUsers/' .. discordId, { ownedProducts = user.ownedProducts })
end

function M.revokeProductFromUser(guildId, productId, discordId)
  local product = M.getProduct(guildId, productId)
  if not product then error('[products] product not found: ' .. productId) end
  product.owners = arrayRemove(product.owners, discordId)
  rtdb.update('products/' .. guildId .. '/' .. productId, { owners = product.owners })

  local user = rtdb.get('verifiedUsers/' .. discordId) or {}
  user.ownedProducts = arrayRemove(user.ownedProducts, productId)
  rtdb.update('verifiedUsers/' .. discordId, { ownedProducts = user.ownedProducts })
end

function M.getProductsByIds(guildId, productIds)
  local out = {}
  if not productIds or #productIds == 0 then return out end
  for _, id in ipairs(productIds) do
    local p = M.getProduct(guildId, id)
    if p then table.insert(out, p) end
  end
  return out
end

function M.buildProductDeliveryDM(product)
  local embed = {
    title = product.name,
    color = 0x00b0f4,
    description = 'Here is your product, click the button below to download the file.',
    fields = {},
  }

  local components = nil
  local buttonOk, button = pcall(function()
    return discordia.Button { label = 'Download', url = product.fileLink }
  end)

  if product.tutorialLink then
    table.insert(embed.fields, { name = 'Tutorial', value = product.tutorialLink })
  end

  if buttonOk then
    components = button
  else
    table.insert(embed.fields, { name = 'Link File', value = product.fileLink })
  end

  return { embed = embed, components = components }
end

return M
