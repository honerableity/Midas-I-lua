local discordia = require('discordia')
local tools = require('discordia-slash').util.tools()
local logger = require('logger')
local products = require('products')
local verification = require('verification')
local uuid = require('uuid')

local enums = discordia.enums
local M = {}

local STEP_TIMEOUT_MS = 15 * 60 * 1000
local MAX_SELECT_OPTIONS = 25

local data = tools.slashCommand('product', 'Manage shop products')

data:addOption(tools.subCommand('create', 'Create a new product listing'))

data:addOption(
  tools.subCommand('createtype', 'Create (or re-sync) a product type and its dedicated forum channel')
    :addOption(tools.string('nama', 'Nama jenis produk'):setRequired(true))
)

data:addOption(
  tools.subCommand('linktype', 'Link a product type to an already-existing forum channel')
    :addOption(tools.string('nama', 'Nama jenis produk'):setRequired(true))
    :addOption(tools.channel('channel', 'Existing forum channel to link'):setRequired(true))
)

data:addOption(
  tools.subCommand('sendpost', 'Post a product to its type\'s forum channel')
    :addOption(tools.string('product_uuid', 'ID produk (UUID)'):setRequired(true))
)

data:addOption(
  tools.subCommand('edit', 'Edit an existing product listing')
    :addOption(tools.string('product_uuid', 'ID produk (UUID)'):setRequired(true))
)

data:addOption(tools.subCommand('view', 'Browse all products by type'))

data:addOption(
  tools.subCommand('delete', 'Delete a product')
    :addOption(tools.string('product_uuid', 'ID produk (UUID)'):setRequired(true))
)

data:addOption(
  tools.subCommand('give', 'Give a product to a verified user')
    :addOption(tools.user('user', 'Target user'):setRequired(true))
    :addOption(tools.string('product_uuid', 'ID produk (UUID)'):setRequired(true))
)

data:addOption(
  tools.subCommand('revoke', 'Revoke a product from a user')
    :addOption(tools.user('user', 'Target user'):setRequired(true))
    :addOption(tools.string('product_uuid', 'ID produk (UUID)'):setRequired(true))
)

data:addOption(
  tools.subCommand('get', 'Get the file link of a product you own, sent to your DM')
    :addOption(tools.string('product_uuid', 'ID produk (UUID)'):setRequired(true):setAutocomplete(true))
)

M.data = data

M.logSchema = {
  subcommands = {
    create = { label = 'Product — Created', fields = { 'discordUser', 'productId', 'productName' } },
    createtype = { label = 'Product — Type Created', fields = { 'discordUser', 'typeName', 'forumChannel' } },
    linktype = { label = 'Product — Type Linked', fields = { 'discordUser', 'typeName', 'forumChannel' } },
    sendpost = { label = 'Product — Post Sent', fields = { 'discordUser', 'productId', 'forumChannel' } },
    edit = { label = 'Product — Edited', fields = { 'discordUser', 'productId', 'productName' } },
    view = { label = 'Product — Browsed', fields = { 'discordUser' } },
    delete = { label = 'Product — Deleted', fields = { 'discordUser', 'productId', 'productName' } },
    give = { label = 'Product — Given', fields = { 'discordUser', 'targetUser', 'productId', 'productName' } },
    revoke = { label = 'Product — Revoked', fields = { 'discordUser', 'targetUser', 'productId', 'productName' } },
    get = { label = 'Product — File Link Requested', fields = { 'discordUser', 'productId', 'productName' } },
  },
}

local function requireAdmin(ia)
  return ia.member and ia.member:hasPermission(enums.permission.administrator)
end

local function trim(s)
  return (s or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function isFreeProduct(price)
  local normalized = trim(price):lower()
  return normalized == '0' or normalized == 'free'
end

local function isImageUrl(url)
  if not url or url == '' then return false end
  local clean = url:match('^([^?]*)') or url
  local ext = clean:lower():match('%.([%a]+)$')
  return ext == 'png' or ext == 'jpg' or ext == 'jpeg' or ext == 'gif' or ext == 'webp'
end

local sessions = {}
local viewStates = {}

local function newSession(guildId, userId)
  local key = guildId .. ':' .. userId
  local s = { guildId = guildId, userId = userId, expiresAt = os.time() * 1000 + STEP_TIMEOUT_MS }
  sessions[key] = s
  return key, s
end

local function getSession(guildId, userId)
  return sessions[guildId .. ':' .. userId]
end

local function clearSession(guildId, userId)
  sessions[guildId .. ':' .. userId] = nil
end

local function buildProductModal1(id, title, prefill)
  prefill = prefill or {}
  return discordia.Modal {
    id = id,
    title = title,
    { id = 'product_name', label = 'Nama produk', style = 'short', required = true, value = prefill.name },
    { id = 'product_description', label = 'Deskripsi', style = 'paragraph', required = true, value = prefill.description },
    { id = 'product_price', label = 'Harga', placeholder = 'cth: 25000 atau Rp25.000', style = 'short', required = true, value = prefill.price },
    { id = 'product_creator', label = 'Kreator (kosongkan jika kamu sendiri)', style = 'short', required = false, value = prefill.creator },
  }
end

local function buildProductModal2(id, title, prefill)
  prefill = prefill or {}
  return discordia.Modal {
    id = id,
    title = title,
    { id = 'product_file_link', label = 'Link file produk', placeholder = 'CDN Discord, catbox.moe, Drive, Mega.nz, dll', style = 'short', required = true, value = prefill.fileLink },
    { id = 'product_review_media', label = 'Video/Gambar Review Produk', placeholder = 'Link video atau gambar review', style = 'short', required = true, value = prefill.reviewMedia },
    { id = 'product_tutorial_link', label = 'Link Tutorial (opsional)', placeholder = 'Link tutorial cara pakai produk, boleh kosong', style = 'short', required = false, value = prefill.tutorialLink },
  }
end

local function typeSelectComponents(types, selectedTypeId, customId)
  local opts = {}
  for i = 1, math.min(#types, MAX_SELECT_OPTIONS) do
    local t = types[i]
    table.insert(opts, { label = t.name, value = t.id, default = (t.id == selectedTypeId) or nil })
  end
  return discordia.SelectMenu { id = customId, placeholder = 'Pilih jenis produk', options = opts }
end

local function handleCreateModal1Submit(cIa, session)
  local productName = trim(cIa.data.components[1].components[1].value)
  local productDescription = trim(cIa.data.components[2].components[1].value)
  local productPrice = trim(cIa.data.components[3].components[1].value)
  local productCreatorRaw = trim(cIa.data.components[4].components[1].value)

  session.name = productName
  session.description = productDescription
  session.price = productPrice
  session.creator = productCreatorRaw ~= '' and productCreatorRaw or cIa.user.username
  session.step = 'await_continue'

  local btn = discordia.Button { id = 'product_create_continue', label = 'Lanjutkan (2/2)', style = 'primary' }
  cIa:reply({ content = 'Langkah 1 tersimpan. Klik tombol di bawah buat lanjut ke langkah 2.', components = btn }, true)
end

local function handleEditModal1Submit(cIa, session)
  local productName = trim(cIa.data.components[1].components[1].value)
  local productDescription = trim(cIa.data.components[2].components[1].value)
  local productPrice = trim(cIa.data.components[3].components[1].value)
  local productCreatorRaw = trim(cIa.data.components[4].components[1].value)

  session.name = productName
  session.description = productDescription
  session.price = productPrice
  session.creator = productCreatorRaw ~= '' and productCreatorRaw or cIa.user.username
  session.step = 'await_continue'

  local btn = discordia.Button { id = 'product_edit_continue', label = 'Lanjutkan (2/2)', style = 'primary' }
  cIa:reply({ content = 'Langkah 1 tersimpan. Klik tombol di bawah buat lanjut ke langkah 2.', components = btn }, true)
end

local function showTypeSelect(cIa, session, mode)
  cIa:replyDeferred(true)

  local types = products.listProductTypes(session.guildId)
  if #types == 0 then
    clearSession(session.guildId, session.userId)
    cIa:editReply({ content = 'Belum ada jenis produk yang terdaftar. Minta admin jalankan `/product createtype` dulu.' })
    return
  end

  session.types = types
  session.step = 'await_type'

  if mode == 'edit' then
    local selectMenu = typeSelectComponents(types, session.product.typeId, 'product_edit_type_select')
    local keepBtn = discordia.Button { id = 'product_edit_keep_type', label = 'Simpan dengan jenis "' .. session.product.type .. '"', style = 'secondary' }
    cIa:editReply({
      content = 'Terakhir, pilih jenis produk (atau klik tombol untuk tetap pakai jenis saat ini):',
      components = { selectMenu, keepBtn },
    })
  else
    local selectMenu = typeSelectComponents(types, nil, 'product_create_type_select')
    cIa:editReply({ content = 'Terakhir, pilih jenis produk:', components = selectMenu })
  end
end

local function handleModal2Submit(cIa, session, mode)
  local productFileLink = trim(cIa.data.components[1].components[1].value)
  local productReviewMedia = trim(cIa.data.components[2].components[1].value)
  local productTutorialLink = trim(cIa.data.components[3].components[1].value)

  session.fileLink = productFileLink
  session.reviewMedia = productReviewMedia
  session.tutorialLink = productTutorialLink

  showTypeSelect(cIa, session, mode)
end

local function finalizeCreate(cIa, session, selectedType)
  local productId = uuid.generate_v4()

  local productData = {
    productId = productId,
    name = session.name,
    description = session.description,
    price = session.price,
    fileLink = session.fileLink,
    tutorialLink = session.tutorialLink,
    reviewMedia = session.reviewMedia,
    creator = session.creator,
    type = selectedType.name,
    typeId = selectedType.id,
    typeForumId = selectedType.forumChannelId or nil,
    createdBy = cIa.user.id,
    guildId = session.guildId,
    createdAt = os.time() * 1000,
  }

  local ok, err = pcall(products.saveProduct, session.guildId, productId, productData)
  clearSession(session.guildId, session.userId)

  if not ok then
    print('Failed to save product: ' .. tostring(err))
    logger.logCommandActivity(cIa.client, { guildId = session.guildId, commandName = 'product', member = { id = cIa.user.id } }, {
      subcommand = 'create', success = false,
      fields = { discordUser = cIa.user, productName = session.name },
      note = 'Database write failed.',
    })
    cIa:editReply({ content = 'Gagal menyimpan produk ke database. Coba lagi.', components = {} })
    return
  end

  logger.logCommandActivity(cIa.client, { guildId = session.guildId, commandName = 'product', member = { id = cIa.user.id } }, {
    subcommand = 'create', success = true,
    fields = { discordUser = cIa.user, productId = productId, productName = session.name },
  })

  local embed = {
    title = 'Produk Berhasil Dibuat',
    color = 0x57f287,
    fields = {
      { name = 'Nama Produk', value = session.name },
      { name = 'ID Produk', value = '`' .. productId .. '`' },
      { name = 'Jenis', value = selectedType.name, inline = true },
      { name = 'Harga', value = session.price, inline = true },
      { name = 'Kreator', value = session.creator, inline = true },
    },
  }

  cIa:editReply({ content = 'Produk berhasil dibuat!', embed = embed, components = {} })
end

local function finalizeEdit(cIa, session, selectedType)
  local product = session.product
  local productId = session.productId

  local updatedData = {}
  for k, v in pairs(product) do updatedData[k] = v end

  updatedData.productId = productId
  updatedData.name = session.name
  updatedData.description = session.description
  updatedData.price = session.price
  updatedData.fileLink = session.fileLink
  updatedData.tutorialLink = session.tutorialLink
  updatedData.reviewMedia = session.reviewMedia
  updatedData.creator = session.creator
  updatedData.type = selectedType.name
  updatedData.typeId = selectedType.id
  if selectedType.id == product.typeId then
    updatedData.typeForumId = product.typeForumId
  else
    updatedData.typeForumId = selectedType.forumChannelId or nil
  end
  updatedData.updatedAt = os.time() * 1000

  local ok, err = pcall(products.saveProduct, session.guildId, productId, updatedData)
  clearSession(session.guildId, session.userId)

  if not ok then
    print('Failed to save edited product: ' .. tostring(err))
    logger.logCommandActivity(cIa.client, { guildId = session.guildId, commandName = 'product', member = { id = cIa.user.id } }, {
      subcommand = 'edit', success = false,
      fields = { discordUser = cIa.user, productId = productId, productName = session.name },
      note = 'Database write failed.',
    })
    cIa:editReply({ content = 'Gagal menyimpan perubahan produk ke database. Coba lagi.', components = {} })
    return
  end

  logger.logCommandActivity(cIa.client, { guildId = session.guildId, commandName = 'product', member = { id = cIa.user.id } }, {
    subcommand = 'edit', success = true,
    fields = { discordUser = cIa.user, productId = productId, productName = session.name },
  })

  local embed = {
    title = 'Produk Berhasil Diedit',
    color = 0x57f287,
    fields = {
      { name = 'Nama Produk', value = session.name },
      { name = 'ID Produk', value = '`' .. productId .. '`' },
      { name = 'Jenis', value = selectedType.name, inline = true },
      { name = 'Harga', value = session.price, inline = true },
      { name = 'Kreator', value = session.creator, inline = true },
    },
  }

  local postNote = updatedData.forumThreadId and ' Jalankan `/product sendpost` untuk update post forum-nya juga.' or ''

  cIa:editReply({ content = 'Produk berhasil diedit!' .. postNote, embed = embed, components = {} })
end

local function handleTypeSelected(cIa, session, mode)
  local selectedTypeId
  if cIa.data.custom_id == 'product_edit_keep_type' then
    selectedTypeId = session.product.typeId
  else
    selectedTypeId = cIa.data.values[1]
  end

  local selectedType
  for _, t in ipairs(session.types) do
    if t.id == selectedTypeId then selectedType = t end
  end

  cIa:update({})

  if mode == 'edit' then
    finalizeEdit(cIa, session, selectedType)
  else
    finalizeCreate(cIa, session, selectedType)
  end
end

function M.handleComponent(cIa)
  local customId = cIa.data and cIa.data.custom_id
  if not customId then return end
  if not customId:match('^product_') then return end

  local guildId = cIa.guildId
  local userId = cIa.user.id
  local session = getSession(guildId, userId)

  if customId == 'product_create_modal_1' then
    if not session then return end
    handleCreateModal1Submit(cIa, session)
    return
  end

  if customId == 'product_create_continue' then
    if not session or session.step ~= 'await_continue' then return end
    local modal = buildProductModal2('product_create_modal_2', 'New Product (2/2)')
    cIa:modal(modal)
    return
  end

  if customId == 'product_create_modal_2' then
    if not session then return end
    handleModal2Submit(cIa, session, 'create')
    return
  end

  if customId == 'product_create_type_select' then
    if not session or session.step ~= 'await_type' then return end
    handleTypeSelected(cIa, session, 'create')
    return
  end

  if customId == 'product_edit_modal_1' then
    if not session then return end
    handleEditModal1Submit(cIa, session)
    return
  end

  if customId == 'product_edit_continue' then
    if not session or session.step ~= 'await_continue' then return end
    local modal = buildProductModal2('product_edit_modal_2', 'Edit Product (2/2)', session.product)
    cIa:modal(modal)
    return
  end

  if customId == 'product_edit_modal_2' then
    if not session then return end
    handleModal2Submit(cIa, session, 'edit')
    return
  end

  if customId == 'product_edit_type_select' or customId == 'product_edit_keep_type' then
    if not session or session.step ~= 'await_type' then return end
    handleTypeSelected(cIa, session, 'edit')
    return
  end

  if customId == 'product_delete_modal' then
    local productId = session and session.productId
    if not productId then return end

    cIa:replyDeferred(true)

    local product = products.getProduct(guildId, productId)
    if not product then
      clearSession(guildId, userId)
      logger.logCommandActivity(cIa.client, { guildId = guildId, commandName = 'product', member = { id = userId } }, {
        subcommand = 'delete', success = false,
        fields = { discordUser = cIa.user, productId = productId },
        note = 'Product UUID not found.',
      })
      cIa:editReply({ content = 'Produk dengan ID `' .. productId .. '` tidak ditemukan.' })
      return
    end

    local typed = trim(cIa.data.components[1].components[1].value)
    if typed ~= productId then
      cIa:editReply({ content = 'UUID tidak cocok. Kamu ketik `' .. typed .. '`, seharusnya `' .. productId .. '`. Jalankan `/product delete` lagi untuk mengulang.' })
      return
    end

    if product.forumThreadId and product.typeForumId then
      pcall(function() cIa.client._api:deleteChannel(product.forumThreadId) end)
    end

    local ok, err = pcall(products.deleteProduct, guildId, productId)
    clearSession(guildId, userId)

    if not ok then
      print('Failed to delete product: ' .. tostring(err))
      logger.logCommandActivity(cIa.client, { guildId = guildId, commandName = 'product', member = { id = userId } }, {
        subcommand = 'delete', success = false,
        fields = { discordUser = cIa.user, productId = productId, productName = product.name },
        note = 'Database delete failed.',
      })
      cIa:editReply({ content = 'Gagal menghapus produk dari database. Coba lagi.' })
      return
    end

    logger.logCommandActivity(cIa.client, { guildId = guildId, commandName = 'product', member = { id = userId } }, {
      subcommand = 'delete', success = true,
      fields = { discordUser = cIa.user, productId = productId, productName = product.name },
    })

    cIa:editReply({ content = 'Produk **' .. product.name .. '** (`' .. productId .. '`) berhasil dihapus.' })
    return
  end

  if customId:match('^product_view_') then
    local msgId = cIa.message and cIa.message.id
    local entry = msgId and viewStates[msgId]
    if not entry then return end

    if cIa.user.id ~= entry.ownerId then
      cIa:reply({ content = 'Only the person who ran this command can use these buttons.' }, true)
      return
    end

    local state = entry.state
    local types = entry.types

    if customId == 'product_view_type_prev' then
      state.typeIndex = ((state.typeIndex - 1 - 1) % #types) + 1
      state.productIndex = 1
    elseif customId == 'product_view_type_next' then
      state.typeIndex = (state.typeIndex % #types) + 1
      state.productIndex = 1
    elseif customId == 'product_view_product_prev' then
      state.productIndex = math.max(1, state.productIndex - 1)
    elseif customId == 'product_view_product_next' then
      local list = entry.getProductsForType(state.typeIndex)
      state.productIndex = math.min(#list, state.productIndex + 1)
    end

    cIa:update({ embed = entry.buildEmbed(), components = entry.buildComponents() })
    return
  end
end

local function handleCreate(ia)
  if not requireAdmin(ia) then
    ia:reply({ content = 'You need **Administrator** permission to do that.' }, true)
    return
  end

  newSession(ia.guildId, ia.user.id)
  local modal = buildProductModal1('product_create_modal_1', 'New Product (1/2)')
  ia:modal(modal)
end

local function handleEdit(ia, args)
  if not requireAdmin(ia) then
    ia:reply({ content = 'You need **Administrator** permission to do that.' }, true)
    return
  end

  local productId = trim(args.product_uuid)
  local product = products.getProduct(ia.guildId, productId)
  if not product then
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'edit', success = false,
      fields = { discordUser = ia.user, productId = productId },
      note = 'Product UUID not found.',
    })
    ia:reply({ content = 'Produk dengan ID `' .. productId .. '` tidak ditemukan.' }, true)
    return
  end

  local _, session = newSession(ia.guildId, ia.user.id)
  session.productId = productId
  session.product = product

  local modal = buildProductModal1('product_edit_modal_1', 'Edit Product (1/2)', product)
  ia:modal(modal)
end

local function handleCreateType(ia, args)
  if not requireAdmin(ia) then
    ia:reply({ content = 'You need **Administrator** permission to do that.' }, true)
    return
  end

  ia:replyDeferred(true)

  local typeName = trim(args.nama)
  if typeName == '' then
    ia:editReply({ content = 'Nama jenis tidak boleh kosong.' })
    return
  end

  local ok, result = pcall(products.createOrSyncProductTypeForum, ia.guild, ia.guildId, typeName)
  if not ok then
    print('createOrSyncProductTypeForum failed: ' .. tostring(result))
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'createtype', success = false,
      fields = { discordUser = ia.user, typeName = typeName },
      note = 'Forum channel creation/sync failed.',
    })
    ia:editReply({ content = 'Bot error saat membuat/menyinkronkan forum jenis produk. Cek permission Manage Channels bot.' })
    return
  end

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'createtype', success = true,
    fields = { discordUser = ia.user, typeName = typeName, forumChannel = result.forumChannel },
  })

  local verb = result.created and 'dibuat' or 'disinkronkan ulang'
  ia:editReply({ content = 'Jenis produk **' .. typeName .. '** ' .. verb .. '. Forum: <#' .. result.forumChannel.id .. '>' })
end

local function handleLinkType(ia, args)
  if not requireAdmin(ia) then
    ia:reply({ content = 'You need **Administrator** permission to do that.' }, true)
    return
  end

  ia:replyDeferred(true)

  local typeName = trim(args.nama)
  if typeName == '' then
    ia:editReply({ content = 'Nama jenis tidak boleh kosong.' })
    return
  end

  local channel = args.channel
  if channel.type ~= enums.channelType.forum then
    ia:editReply({ content = '<#' .. channel.id .. '> bukan forum channel. Pilih forum channel yang sudah ada.' })
    return
  end

  local ok, result = pcall(products.linkExistingForumToType, ia.guild, ia.guildId, typeName, channel)
  if not ok then
    print('linkExistingForumToType failed: ' .. tostring(result))
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'linktype', success = false,
      fields = { discordUser = ia.user, typeName = typeName },
      note = 'Linking existing forum channel failed.',
    })
    ia:editReply({ content = 'Bot error saat menghubungkan jenis produk ke channel. Cek permission Manage Channels bot di channel tersebut.' })
    return
  end

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'linktype', success = true,
    fields = { discordUser = ia.user, typeName = typeName, forumChannel = result.forumChannel },
  })

  local note
  if result.wasExistingType then
    note = 'Jenis produk **' .. typeName .. '** sekarang terhubung ke <#' .. result.forumChannel.id .. '>. Forum lama (kalau berbeda) tidak dihapus.'
  else
    note = 'Jenis produk **' .. typeName .. '** dibuat dan dihubungkan ke <#' .. result.forumChannel.id .. '>.'
  end

  ia:editReply({ content = note })
end

local function handleSendPost(ia, args)
  if not requireAdmin(ia) then
    ia:reply({ content = 'You need **Administrator** permission to do that.' }, true)
    return
  end

  ia:replyDeferred(true)

  local productId = trim(args.product_uuid)
  local product = products.getProduct(ia.guildId, productId)
  if not product then
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'sendpost', success = false,
      fields = { discordUser = ia.user, productId = productId },
      note = 'Product UUID not found.',
    })
    ia:editReply({ content = 'Produk dengan ID `' .. productId .. '` tidak ditemukan. Kalau produk ini baru dihapus, post forum-nya seharusnya sudah ikut terhapus lewat `/product delete`.' })
    return
  end

  if not product.typeForumId then
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'sendpost', success = false,
      fields = { discordUser = ia.user, productId = productId },
      note = 'Product has no associated forum (type forum missing).',
    })
    ia:editReply({ content = 'Produk ini belum punya forum jenis yang valid. Jalankan `/product createtype` untuk jenis **' .. product.type .. '** dulu.' })
    return
  end

  local forumOk, forumChannel = pcall(function() return ia.guild:getChannel(product.typeForumId) end)
  if not forumOk or not forumChannel or forumChannel.type ~= enums.channelType.forum then
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'sendpost', success = false,
      fields = { discordUser = ia.user, productId = productId },
      note = 'Forum channel missing or no longer a forum channel.',
    })
    ia:editReply({ content = 'Forum untuk jenis produk ini sudah tidak ada. Jalankan `/product createtype` lagi untuk membuatnya ulang.' })
    return
  end

  local isFree = isFreeProduct(product.price)

  local embed = {
    title = product.name,
    color = 0x00b0f4,
    fields = {
      { name = 'Harga', value = isFree and 'GRATIS' or product.price, inline = true },
      { name = 'Jenis', value = product.type, inline = true },
      { name = 'Kreator', value = product.creator, inline = true },
    },
  }

  if not isFree then
    table.insert(embed.fields, { name = 'Link File', value = product.fileLink })
  end

  if isImageUrl(product.reviewMedia) then
    embed.image = { url = product.reviewMedia }
  else
    table.insert(embed.fields, { name = 'Video/Gambar Review', value = product.reviewMedia })
  end

  local downloadComponents = nil
  if isFree then
    local btnOk, btn = pcall(function() return discordia.Button { label = 'Download', url = product.fileLink } end)
    if btnOk then
      downloadComponents = btn
    else
      table.insert(embed.fields, { name = 'Link File', value = product.fileLink })
    end
  end

  local postContent = product.description
  if isFree and product.tutorialLink and product.tutorialLink ~= '' then
    postContent = product.description .. '\n\nTutorial: ' .. product.tutorialLink
  end

  local existingThread = nil
  if product.forumThreadId then
    local tOk, t = pcall(function() return ia.client:getChannel(product.forumThreadId) end)
    if tOk and t then existingThread = t end
  end

  local thread
  local wasUpdate = false

  if existingThread then
    local editOk, editErr = pcall(function()
      if existingThread.name ~= product.name then
        ia.client._api:modifyChannel(existingThread.id, { name = product.name })
      end
      local starterOk, starter = ia.client._api:getChannelMessage(existingThread.id, existingThread.id)
      if not starterOk or not starter then
        error('Starter message missing, cannot edit in place.')
      end
      ia.client._api:editMessage(existingThread.id, existingThread.id, {
        content = postContent,
        embeds = { embed },
        components = downloadComponents and downloadComponents:raw() or {},
      })
    end)
    if editOk then
      thread = existingThread
      wasUpdate = true
    else
      print('Failed to edit existing forum post in place, falling back to new thread: ' .. tostring(editErr))
      existingThread = nil
    end
  end

  if not existingThread then
    local createOk, resp, err = pcall(function()
      return ia.client._api:request('POST', 'channels/' .. forumChannel.id .. '/threads', {
        name = product.name,
        message = {
          content = postContent,
          embeds = { embed },
          components = downloadComponents and downloadComponents:raw() or {},
        },
      })
    end)
    if not createOk or not resp then
      print('Forum post creation failed: ' .. tostring(resp))
      logger.logCommandActivity(ia.client, ia, {
        subcommand = 'sendpost', success = false,
        fields = { discordUser = ia.user, productId = productId },
        note = 'Bot error while creating forum post.',
      })
      ia:editReply({ content = 'Bot error saat membuat post di forum. Cek permission bot di channel forum tersebut.' })
      return
    end
    thread = resp
  end

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'sendpost', success = true,
    fields = { discordUser = ia.user, productId = productId, forumChannel = forumChannel },
    note = wasUpdate and 'Updated existing post in place.' or 'Created new post.',
  })

  if not wasUpdate then
    local saveOk, saveErr = pcall(function()
      local merged = {}
      for k, v in pairs(product) do merged[k] = v end
      merged.forumThreadId = thread.id
      products.saveProduct(ia.guildId, productId, merged)
    end)
    if not saveOk then
      print('Failed to save forumThreadId onto product (post itself succeeded): ' .. tostring(saveErr))
    end
  end

  local verb = wasUpdate and 'diperbarui' or 'diposting'
  ia:editReply({ content = 'Produk **' .. product.name .. '** berhasil ' .. verb .. ': <#' .. thread.id .. '>' })
end

local function buildViewEmbed(state, types, getProductsForType)
  local type_ = types[state.typeIndex]
  local list = getProductsForType(state.typeIndex)

  local embed = {
    color = 0x00b0f4,
    footer = { text = 'Jenis ' .. state.typeIndex .. '/' .. #types .. ' — ' .. type_.name },
    fields = {},
  }

  if #list == 0 then
    embed.title = type_.name
    embed.description = 'Belum ada produk di jenis ini.'
    return embed
  end

  local product = list[state.productIndex]

  embed.title = product.name
  embed.description = product.description
  embed.fields = {
    { name = 'Harga', value = product.price, inline = true },
    { name = 'Jenis', value = product.type, inline = true },
    { name = 'Kreator', value = product.creator, inline = true },
    { name = 'ID Produk', value = '`' .. product.productId .. '`' },
  }

  if isImageUrl(product.reviewMedia) then
    embed.image = { url = product.reviewMedia }
  elseif product.reviewMedia and product.reviewMedia ~= '' then
    table.insert(embed.fields, { name = 'Video/Gambar Review', value = product.reviewMedia })
  end

  embed.footer = { text = 'Jenis ' .. state.typeIndex .. '/' .. #types .. ' — ' .. type_.name .. ' · Produk ' .. state.productIndex .. '/' .. #list }

  return embed
end

local function buildViewComponents(state, types, getProductsForType, disabled)
  local list = getProductsForType(state.typeIndex)

  local specs = {
    { id = 'product_view_type_prev', type = 'button', label = '◀◀ Jenis', style = 'secondary', disabled = disabled or #types <= 1 },
    { id = 'product_view_product_prev', type = 'button', label = '◀ Produk', style = 'secondary', disabled = disabled or #list <= 1 or state.productIndex == 1 },
    { id = 'product_view_product_next', type = 'button', label = 'Produk ▶', style = 'secondary', disabled = disabled or #list <= 1 or state.productIndex >= #list },
    { id = 'product_view_type_next', type = 'button', label = 'Jenis ▶▶', style = 'secondary', disabled = disabled or #types <= 1 },
  }

  return discordia.Components(specs)
end

local function handleView(ia)
  ia:replyDeferred(false)

  local types = products.listProductTypes(ia.guildId)
  table.sort(types, function(a, b) return a.name < b.name end)

  if #types == 0 then
    ia:editReply({ content = 'Belum ada jenis produk yang terdaftar.' })
    return
  end

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'view', success = true,
    fields = { discordUser = ia.user },
  })

  local cache = {}
  local function getProductsForType(typeIndex)
    local type_ = types[typeIndex]
    if not cache[type_.id] then
      local list = products.listProductsByType(ia.guildId, type_.id)
      table.sort(list, function(a, b) return a.name < b.name end)
      cache[type_.id] = list
    end
    return cache[type_.id]
  end

  local state = { typeIndex = 1, productIndex = 1 }

  local message = ia:editReply({
    embed = buildViewEmbed(state, types, getProductsForType),
    components = buildViewComponents(state, types, getProductsForType),
  })

  viewStates[message.id] = {
    state = state,
    types = types,
    getProductsForType = getProductsForType,
    ownerId = ia.user.id,
    buildEmbed = function() return buildViewEmbed(state, types, getProductsForType) end,
    buildComponents = function() return buildViewComponents(state, types, getProductsForType) end,
  }

  discordia.timer.setTimeout(10 * 60 * 1000, function()
    local entry = viewStates[message.id]
    if not entry then return end
    viewStates[message.id] = nil
    pcall(function()
      ia:editReply({ components = buildViewComponents(state, types, getProductsForType, true) })
    end)
  end)
end

local function handleDelete(ia, args)
  if not requireAdmin(ia) then
    ia:reply({ content = 'You need **Administrator** permission to do that.' }, true)
    return
  end

  local productId = trim(args.product_uuid)

  local _, session = newSession(ia.guildId, ia.user.id)
  session.productId = productId

  local modal = discordia.Modal {
    id = 'product_delete_modal',
    title = 'Confirm Delete',
    { id = 'confirm_uuid', label = 'Ketik ulang UUID produk untuk konfirmasi', placeholder = productId, style = 'short', required = true },
  }

  ia:modal(modal)
end

local function handleGive(ia, args)
  if not requireAdmin(ia) then
    ia:reply({ content = 'You need **Administrator** permission to do that.' }, true)
    return
  end

  ia:replyDeferred(true)

  local targetUser = args.user
  local productId = trim(args.product_uuid)

  local verifiedRecord = verification.getVerifiedUser(targetUser.id)
  if not verifiedRecord then
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'give', success = false,
      fields = { discordUser = ia.user, targetUser = targetUser, productId = productId },
      note = 'Target user is not verified.',
    })
    ia:editReply({ content = '<@' .. targetUser.id .. '> belum verifikasi. Suruh mereka jalankan `/verify start` dulu.' })
    return
  end

  local product = products.getProduct(ia.guildId, productId)
  if not product then
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'give', success = false,
      fields = { discordUser = ia.user, targetUser = targetUser, productId = productId },
      note = 'Product UUID not found.',
    })
    ia:editReply({ content = 'Produk dengan ID `' .. productId .. '` tidak ditemukan.' })
    return
  end

  if products.userOwnsProduct(product, targetUser.id) then
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'give', success = false,
      fields = { discordUser = ia.user, targetUser = targetUser, productId = productId, productName = product.name },
      note = 'Target user already owns this product.',
    })
    ia:editReply({ content = '<@' .. targetUser.id .. '> sudah punya produk **' .. product.name .. '**.' })
    return
  end

  local ok, err = pcall(products.giveProductToUser, ia.guildId, productId, targetUser.id)
  if not ok then
    print('Failed to give product: ' .. tostring(err))
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'give', success = false,
      fields = { discordUser = ia.user, targetUser = targetUser, productId = productId, productName = product.name },
      note = 'Database write failed.',
    })
    ia:editReply({ content = 'Gagal memberikan produk ke database. Coba lagi.' })
    return
  end

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'give', success = true,
    fields = { discordUser = ia.user, targetUser = targetUser, productId = productId, productName = product.name },
  })

  ia:editReply({ content = 'Produk **' .. product.name .. '** berhasil diberikan ke <@' .. targetUser.id .. '>.' })
end

local function handleRevoke(ia, args)
  if not requireAdmin(ia) then
    ia:reply({ content = 'You need **Administrator** permission to do that.' }, true)
    return
  end

  ia:replyDeferred(true)

  local targetUser = args.user
  local productId = trim(args.product_uuid)

  local product = products.getProduct(ia.guildId, productId)
  if not product then
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'revoke', success = false,
      fields = { discordUser = ia.user, targetUser = targetUser, productId = productId },
      note = 'Product UUID not found.',
    })
    ia:editReply({ content = 'Produk dengan ID `' .. productId .. '` tidak ditemukan.' })
    return
  end

  if not products.userOwnsProduct(product, targetUser.id) then
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'revoke', success = false,
      fields = { discordUser = ia.user, targetUser = targetUser, productId = productId, productName = product.name },
      note = 'Target user does not own this product.',
    })
    ia:editReply({ content = '<@' .. targetUser.id .. '> belum punya produk **' .. product.name .. '**.' })
    return
  end

  local ok, err = pcall(products.revokeProductFromUser, ia.guildId, productId, targetUser.id)
  if not ok then
    print('Failed to revoke product: ' .. tostring(err))
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'revoke', success = false,
      fields = { discordUser = ia.user, targetUser = targetUser, productId = productId, productName = product.name },
      note = 'Database write failed.',
    })
    ia:editReply({ content = 'Gagal mencabut produk dari database. Coba lagi.' })
    return
  end

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'revoke', success = true,
    fields = { discordUser = ia.user, targetUser = targetUser, productId = productId, productName = product.name },
  })

  ia:editReply({ content = 'Produk **' .. product.name .. '** berhasil dicabut dari <@' .. targetUser.id .. '>.' })
end

local function handleGet(ia, args)
  ia:replyDeferred(true)

  local productId = trim(args.product_uuid)

  local verifiedRecord = verification.getVerifiedUser(ia.user.id)
  if not verifiedRecord then
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'get', success = false,
      fields = { discordUser = ia.user, productId = productId },
      note = 'Requesting user is not verified.',
    })
    ia:editReply({ content = 'You are required to verified to use this command!' })
    return
  end

  local product = products.getProduct(ia.guildId, productId)
  if not product then
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'get', success = false,
      fields = { discordUser = ia.user, productId = productId },
      note = 'Product UUID not found.',
    })
    ia:editReply({ content = 'Produk dengan ID `' .. productId .. '` tidak ditemukan.' })
    return
  end

  if not products.userOwnsProduct(product, ia.user.id) then
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'get', success = false,
      fields = { discordUser = ia.user, productId = productId, productName = product.name },
      note = 'Requesting user does not own this product.',
    })
    ia:editReply({ content = 'You didnt owned the product!' })
    return
  end

  local dmOk, channel = pcall(function() return ia.user:getPrivateChannel() end)
  local sendOk = false
  if dmOk and channel then
    sendOk = pcall(function() channel:send(products.buildProductDeliveryDM(product)) end)
  end

  if not sendOk then
    logger.logCommandActivity(ia.client, ia, {
      subcommand = 'get', success = false,
      fields = { discordUser = ia.user, productId = productId, productName = product.name },
      note = 'Could not DM the user (DMs likely closed).',
    })
    ia:editReply({ content = 'Could not DM you the file link. Please enable DMs from server members and try again.' })
    return
  end

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'get', success = true,
    fields = { discordUser = ia.user, productId = productId, productName = product.name },
  })

  ia:editReply({ content = 'Sent! Check your DMs 📬' })
end

function M.autocomplete(ia, cmd, focused_option, args)
  local _, sub = tools.getSubCommand(cmd)
  if sub ~= 'get' then
    ia:autocomplete({})
    return
  end

  local focused = tostring(focused_option and focused_option.value or ''):lower()

  local verifiedRecord = verification.getVerifiedUser(ia.user.id)
  local ownedIds = verifiedRecord and verifiedRecord.ownedProducts
  if type(ownedIds) ~= 'table' or #ownedIds == 0 then
    ia:autocomplete({})
    return
  end

  local owned = products.getProductsByIds(ia.guildId, ownedIds)

  local choices = {}
  for _, p in ipairs(owned) do
    if #choices >= 25 then break end
    if p.name and p.name:lower():find(focused, 1, true) then
      table.insert(choices, tools.choice(p.name:sub(1, 100), p.id))
    end
  end

  ia:autocomplete(choices)
end

function M.execute(ia, cmd, args)
  if not ia.guildId then
    ia:reply({ content = 'This command only works inside a server.' }, true)
    return
  end

  local subArgs, sub = tools.getSubCommand(cmd)

  if sub == 'create' then return handleCreate(ia) end
  if sub == 'createtype' then return handleCreateType(ia, subArgs) end
  if sub == 'linktype' then return handleLinkType(ia, subArgs) end
  if sub == 'sendpost' then return handleSendPost(ia, subArgs) end
  if sub == 'edit' then return handleEdit(ia, subArgs) end
  if sub == 'view' then return handleView(ia) end
  if sub == 'delete' then return handleDelete(ia, subArgs) end
  if sub == 'give' then return handleGive(ia, subArgs) end
  if sub == 'revoke' then return handleRevoke(ia, subArgs) end
  if sub == 'get' then return handleGet(ia, subArgs) end
end

return M
