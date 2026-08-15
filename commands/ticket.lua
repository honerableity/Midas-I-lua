local discordia = require('discordia')
local tools = require('discordia-slash').util.tools()
local logger = require('utils.logger')
local tickets = require('utils.tickets')
local products = require('utils.products')
local verification = require('utils.verification')
local uuid = require('utils.uuid')

local enums = discordia.enums
local M = {}

local MAX_SELECT_OPTIONS = 25

local CID = {
  PANEL_CATEGORY_SELECT = 'ticket_panel_category',
  ORDER_PRODUCT_SELECT = 'ticket_order_products',
  ORDER_CREATE_BTN = 'ticket_order_create',
  SERVICE_OPEN_MODAL_BTN = 'ticket_service_open_modal',
  SERVICE_MODAL = 'ticket_service_modal',
  CS_CREATE_BTN = 'ticket_cs_create',
  DONE_MODAL = 'ticket_done_modal',
}

local data = tools.slashCommand('ticket', 'Ticket system')

data:addOption(
  tools.subCommand('send', 'Send a ticket panel embed')
    :addOption(tools.channel('channel', 'Where to send the panel'):setRequired(true))
)

data:addOption(tools.subCommand('done', 'Mark the current ticket as done and post testimonial'))

data:addOption(
  tools.subCommand('settesti', 'Set the testimonial channel')
    :addOption(tools.channel('channel', 'Testimonial channel'):setRequired(true))
)

data:addOption(tools.subCommand('createcategory', 'Create the Order/Service/Customer Service ticket categories'))

data:addOption(
  tools.subCommand('close', 'Close and delete a ticket, DM the creator')
    :addOption(tools.channel('channel', 'Ticket channel to close (default: current channel)'):setRequired(false))
)

M.data = data

M.logSchema = {
  subcommands = {
    send = { label = 'Ticket — Panel Sent', fields = { 'discordUser', 'channel' } },
    done = { label = 'Ticket — Closed', fields = { 'discordUser', 'ticketChannel', 'total' } },
    settesti = { label = 'Ticket — Testimonial Channel Set', fields = { 'discordUser', 'channel' } },
    createcategory = { label = 'Ticket — Categories Created', fields = { 'discordUser' } },
    close = { label = 'Ticket — Deleted', fields = { 'discordUser', 'ticketChannel' } },
  },
}

local function requireAdmin(ia)
  return ia.member and ia.member:hasPermission(enums.permission.administrator)
end

local function requireAdminReply(ia)
  ia:reply({ content = 'You need **Administrator** permission to do that.' }, true)
end

local function trim(s)
  return (s or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function formatIDR(n)
  local s = tostring(math.floor(n))
  local formatted = s:reverse():gsub('(%d%d%d)', '%1.'):reverse()
  formatted = formatted:gsub('^%.', '')
  return 'Rp' .. formatted
end

local function parsePrice(priceStr)
  local digits = tostring(priceStr):gsub('[^0-9]', '')
  return digits ~= '' and tonumber(digits) or 0
end

local orderSessions = {}

local function loadProductsMap(guildId, productIds)
  local map = {}
  for _, id in ipairs(productIds) do
    local p = products.getProduct(guildId, id)
    if p then map[id] = p end
  end
  return map
end

local function createTicketChannel(ia, category, label)
  local guild = ia.guild
  local botMember = guild.me

  local everyoneDeny = 1024

  local overwrites = {
    { id = guild.id, type = 0, allow = '0', deny = tostring(everyoneDeny) },
    { id = ia.user.id, type = 1, allow = tostring(1024 + 2048 + 65536), deny = '0' },
    { id = botMember.id, type = 1, allow = tostring(1024 + 2048 + 16), deny = '0' },
  }

  for _, role in pairs(guild.roles) do
    if role:hasPermission(enums.permission.administrator) then
      table.insert(overwrites, { id = role.id, type = 0, allow = tostring(1024 + 2048 + 65536), deny = '0' })
    end
  end

  local channelName = (category .. '-' .. ia.user.username):sub(1, 90)

  local categories = tickets.getTicketCategories(ia.guildId)
  local parentId = categories and categories[category]
  local parentValid = parentId and guild:getChannel(parentId) ~= nil

  local payload = {
    name = channelName,
    type = enums.channelType.text,
    parent_id = parentValid and parentId or nil,
    topic = label .. ' ticket for ' .. ia.user.username,
    permission_overwrites = overwrites,
  }

  local chData, err = guild.client._api:createGuildChannel(guild.id, payload)
  if not chData then
    error('[tickets] failed to create ticket channel: ' .. tostring(err))
  end

  return guild:getChannel(chData.id)
end

local function handleSend(ia, args)
  if not requireAdmin(ia) then return requireAdminReply(ia) end

  local targetChannel = args.channel

  local modal = discordia.Modal {
    id = 'ticket_send_modal',
    title = 'Ticket Panel',
    { id = 'panel_title', label = 'Title', style = 'short', required = true },
    { id = 'panel_description', label = 'Description', style = 'paragraph', required = true },
    { id = 'panel_color', label = 'Color (hex, e.g. #5865F2)', placeholder = '#5865F2', style = 'short', required = false },
  }

  ia:modal(modal)

  orderSessions['send_' .. ia.user.id] = { targetChannel = targetChannel, ia = ia }
end

local function handleSendModalSubmit(cIa)
  local session = orderSessions['send_' .. cIa.user.id]
  if not session then return end
  orderSessions['send_' .. cIa.user.id] = nil

  cIa:replyDeferred(true)

  local panelTitle = trim(cIa.data.components[1].components[1].value)
  local panelDesc = trim(cIa.data.components[2].components[1].value)
  local colorRaw = trim(cIa.data.components[3].components[1].value)

  local color = 0x5865f2
  if colorRaw ~= '' then
    local parsed = tonumber(colorRaw:gsub('#', ''), 16)
    if parsed then color = parsed end
  end

  local embed = { title = panelTitle, description = panelDesc, color = color }

  local select = discordia.SelectMenu {
    id = CID.PANEL_CATEGORY_SELECT,
    placeholder = 'Select a ticket category',
    options = {
      { label = 'Order', value = 'order', description = 'Buy a product' },
      { label = 'Service', value = 'service', description = 'Request a service' },
      { label = 'Customer Service', value = 'customerservice', description = 'Talk to an admin' },
    },
  }

  local sendOk, sendErr = pcall(function()
    session.targetChannel:send({ embed = embed, components = select })
  end)

  if not sendOk then
    print('Failed to send ticket panel: ' .. tostring(sendErr))
    cIa:editReply({ content = "Couldn't send the panel to <#" .. session.targetChannel.id .. '>.' })
    return
  end

  cIa:editReply({ content = 'Panel sent to <#' .. session.targetChannel.id .. '>.' })

  logger.logCommandActivity(cIa.client, { guildId = cIa.guildId, commandName = 'ticket', member = { id = cIa.user.id } }, {
    subcommand = 'send', success = true,
    fields = { discordUser = cIa.user, channel = session.targetChannel },
  })
end

local function handleSetTesti(ia, args)
  if not requireAdmin(ia) then return requireAdminReply(ia) end

  ia:replyDeferred(true)

  local channel = args.channel
  tickets.setTestiChannel(ia.guildId, channel.id)

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'settesti', success = true,
    fields = { discordUser = ia.user, channel = channel },
  })

  ia:editReply({ content = 'Testimonial channel set to <#' .. channel.id .. '>.' })
end

local function handleCreateCategory(ia)
  if not requireAdmin(ia) then return requireAdminReply(ia) end

  ia:replyDeferred(true)

  local guild = ia.guild
  local existing = tickets.getTicketCategories(ia.guildId) or {}

  local wanted = {
    { key = 'order', name = 'Order Tickets' },
    { key = 'service', name = 'Service Tickets' },
    { key = 'customerservice', name = 'Customer Service Tickets' },
  }

  local result = {}
  for k, v in pairs(existing) do result[k] = v end

  for _, w in ipairs(wanted) do
    local stillExists = result[w.key] and guild:getChannel(result[w.key]) ~= nil
    if not stillExists then
      local created = guild:createCategory(w.name)
      result[w.key] = created.id
    end
  end

  tickets.setTicketCategories(ia.guildId, result)

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'createcategory', success = true,
    fields = { discordUser = ia.user },
  })

  ia:editReply({
    content = 'Ticket categories ready:\nOrder: <#' .. result.order .. '>\nService: <#' .. result.service .. '>\nCustomer Service: <#' .. result.customerservice .. '>',
  })
end

local function handleClose(ia, args)
  if not requireAdmin(ia) then return requireAdminReply(ia) end

  ia:replyDeferred(true)

  local targetChannel = args.channel or ia.channel

  local ticket = tickets.getTicket(targetChannel.id)
  if not ticket then
    ia:editReply({ content = '<#' .. targetChannel.id .. '> is not a ticket channel.' })
    return
  end

  local creatorOk, creator = pcall(function() return ia.client:getUser(ticket.creatorId) end)
  local dmSent = false
  if creatorOk and creator then
    local dmOk = pcall(function()
      local channel = creator:getPrivateChannel()
      channel:send('Your ticket in **' .. ia.guild.name .. '** has been closed.')
    end)
    dmSent = dmOk
  end

  tickets.markTicketDeleted(targetChannel.id)

  local delOk, delErr = pcall(function() targetChannel:delete() end)
  if not delOk then
    print('Failed to delete ticket channel: ' .. tostring(delErr))
    ia:editReply({ content = "Couldn't delete <#" .. targetChannel.id .. '>. Check my permissions there.' })
    return
  end

  logger.logCommandActivity(ia.client, ia, {
    subcommand = 'close', success = true,
    fields = { discordUser = ia.user, ticketChannel = '<#' .. targetChannel.id .. '>' },
  })

  local note = dmSent and '' or ' (Could not DM the creator — DMs may be closed.)'
  ia:editReply({ content = 'Ticket closed and deleted.' .. note })
end

local function onPanelCategorySelect(cIa)
  local category = cIa.data.values[1]

  if category == 'order' then
    cIa:replyDeferred(true)

    local existing = tickets.findOpenTicket(cIa.guildId, cIa.user.id, 'order')
    if existing then
      cIa:editReply({ content = 'You already have an open order ticket: <#' .. existing.channelId .. '>' })
      return
    end

    local types = products.listProductTypes(cIa.guildId)
    if #types == 0 then
      cIa:editReply({ content = 'No products are available right now.' })
      return
    end

    local allProducts = {}
    for _, t in ipairs(types) do
      for _, p in ipairs(products.listProductsByType(cIa.guildId, t.id)) do
        table.insert(allProducts, p)
      end
    end

    if #allProducts == 0 then
      cIa:editReply({ content = 'No products are available right now.' })
      return
    end

    local verifiedUser = verification.getVerifiedUser(cIa.user.id)
    local owned = {}
    if verifiedUser and type(verifiedUser.ownedProducts) == 'table' then
      for _, id in ipairs(verifiedUser.ownedProducts) do owned[id] = true end
    end

    local purchasable = {}
    for _, p in ipairs(allProducts) do
      if not owned[p.id] then table.insert(purchasable, p) end
    end

    if #purchasable == 0 then
      cIa:editReply({ content = 'You already own every available product.' })
      return
    end

    local options = {}
    for i = 1, math.min(#purchasable, MAX_SELECT_OPTIONS) do
      local p = purchasable[i]
      table.insert(options, {
        label = p.name:sub(1, 100),
        description = (p.type .. ' — ' .. p.price):sub(1, 100),
        value = p.id,
      })
    end

    local select = discordia.SelectMenu {
      id = CID.ORDER_PRODUCT_SELECT,
      placeholder = 'Select product(s) to buy',
      minValues = 1,
      maxValues = #options,
      options = options,
    }

    cIa:editReply({
      content = 'Pick the product(s) you want to buy (already-owned products are hidden):',
      components = select,
    })
    return
  end

  if category == 'service' then
    cIa:replyDeferred(true)

    local existing = tickets.findOpenTicket(cIa.guildId, cIa.user.id, 'service')
    if existing then
      cIa:editReply({ content = 'You already have an open service ticket: <#' .. existing.channelId .. '>' })
      return
    end

    local btn = discordia.Button { id = CID.SERVICE_OPEN_MODAL_BTN, label = 'Fill service request', style = 'primary' }
    cIa:editReply({ content = 'Click below to describe the service you need:', components = btn })
    return
  end

  if category == 'customerservice' then
    cIa:replyDeferred(true)

    local existing = tickets.findOpenTicket(cIa.guildId, cIa.user.id, 'customerservice')
    if existing then
      cIa:editReply({ content = 'You already have an open customer service ticket: <#' .. existing.channelId .. '>' })
      return
    end

    local btn = discordia.Button { id = CID.CS_CREATE_BTN, label = 'Create ticket', style = 'primary' }
    cIa:editReply({ content = 'Click below to open a customer service ticket:', components = btn })
    return
  end
end

local function onOrderProductSelect(cIa)
  cIa:update({})

  local productIds = cIa.data.values
  local productsMap = loadProductsMap(cIa.guildId, productIds)

  local validIds = {}
  for _, id in ipairs(productIds) do
    if productsMap[id] then table.insert(validIds, id) end
  end

  if #validIds == 0 then
    cIa:editReply({ content = 'Selected product(s) no longer exist. Try again.', components = {} })
    return
  end

  local summaryLines = {}
  local total = 0
  for _, id in ipairs(validIds) do
    local p = productsMap[id]
    table.insert(summaryLines, '**' .. p.name .. '** — ' .. p.price)
    total = total + parsePrice(p.price)
  end

  local token = uuid.generate_v4()
  tickets.saveOrderSelection(token, cIa.user.id, validIds)

  local createBtn = discordia.Button { id = CID.ORDER_CREATE_BTN .. '_' .. token, label = 'Create ticket', style = 'success' }

  cIa:editReply({
    content = table.concat(summaryLines, '\n') .. '\n\n**Total: ' .. formatIDR(total) .. '**',
    components = createBtn,
  })
end

local function onOrderCreateButton(cIa)
  cIa:update({})

  local token = cIa.data.custom_id:gsub('^' .. CID.ORDER_CREATE_BTN .. '_', '')
  local selection = tickets.getOrderSelection(token)

  if not selection or selection.userId ~= cIa.user.id then
    cIa:editReply({ content = 'This selection has expired. Please start over from the ticket panel.', components = {} })
    return
  end

  local productIds = selection.productIds

  local gotLock = tickets.claimTicketCreateLock(cIa.user.id, 'order')

  if gotLock then
    local existing = tickets.findOpenTicket(cIa.guildId, cIa.user.id, 'order')
    if existing then
      tickets.releaseTicketCreateLock(cIa.user.id, 'order')
      cIa:editReply({ content = 'You already have an open order ticket: <#' .. existing.channelId .. '>', components = {} })
      return
    end
  end

  local productsMap = loadProductsMap(cIa.guildId, productIds)
  local lineItems = {}
  local total = 0
  for _, id in ipairs(productIds) do
    local p = productsMap[id]
    if p then
      local lineTotal = parsePrice(p.price)
      table.insert(lineItems, { productId = id, name = p.name, price = p.price, lineTotal = lineTotal })
      total = total + lineTotal
    end
  end

  local channel = createTicketChannel(cIa, 'order', 'Order')

  if not gotLock then
    pcall(function() channel:delete() end)
    cIa:editReply({
      content = "Looks like that got clicked twice -- your ticket was already created, check your channel list.",
      components = {},
    })
    return
  end

  tickets.createTicket({
    guildId = cIa.guildId,
    channelId = channel.id,
    category = 'order',
    creatorId = cIa.user.id,
    products = lineItems,
    total = total,
  })

  tickets.releaseTicketCreateLock(cIa.user.id, 'order')

  local summaryLines = {}
  for _, li in ipairs(lineItems) do
    table.insert(summaryLines, '**' .. li.name .. '** — ' .. formatIDR(li.lineTotal))
  end

  local embed = {
    title = 'New Order Ticket',
    color = 0x57f287,
    description = table.concat(summaryLines, '\n'),
    fields = { { name = 'Total', value = formatIDR(total) } },
    footer = { text = 'Requested by ' .. cIa.user.username },
  }

  channel:send({ content = '<@' .. cIa.user.id .. '>', embed = embed })

  logger.logCommandActivity(cIa.client, { guildId = cIa.guildId, commandName = 'ticket', member = { id = cIa.user.id } }, {
    subcommand = 'send', success = true,
    fields = { discordUser = cIa.user },
    note = 'Order ticket created: ' .. channel.id .. ', total ' .. tostring(total),
  })

  cIa:editReply({ content = 'Ticket created: <#' .. channel.id .. '>', components = {} })
end

local function onServiceOpenModalButton(cIa)
  local modal = discordia.Modal {
    id = CID.SERVICE_MODAL,
    title = 'Service Request',
    { id = 'service_answer', label = 'What type of service do you want?', style = 'paragraph', required = true },
  }
  cIa:modal(modal)
end

local function onServiceModalSubmit(cIa)
  cIa:replyDeferred(true)

  local gotLock = tickets.claimTicketCreateLock(cIa.user.id, 'service')

  if gotLock then
    local existing = tickets.findOpenTicket(cIa.guildId, cIa.user.id, 'service')
    if existing then
      tickets.releaseTicketCreateLock(cIa.user.id, 'service')
      cIa:editReply({ content = 'You already have an open service ticket: <#' .. existing.channelId .. '>' })
      return
    end
  end

  local answer = trim(cIa.data.components[1].components[1].value)

  local channel = createTicketChannel(cIa, 'service', 'Service')

  if not gotLock then
    pcall(function() channel:delete() end)
    cIa:editReply({ content = "Looks like that got submitted twice -- your ticket was already created, check your channel list." })
    return
  end

  tickets.createTicket({
    guildId = cIa.guildId,
    channelId = channel.id,
    category = 'service',
    creatorId = cIa.user.id,
    serviceAnswer = answer,
  })

  tickets.releaseTicketCreateLock(cIa.user.id, 'service')

  local embed = {
    title = 'New Service Ticket',
    color = 0x5865f2,
    fields = { { name = 'Requested service', value = answer:sub(1, 1024) } },
    footer = { text = 'Requested by ' .. cIa.user.username },
  }

  channel:send({ content = '<@' .. cIa.user.id .. '>', embed = embed })

  cIa:editReply({ content = 'Ticket created: <#' .. channel.id .. '>' })
end

local function onCsCreateButton(cIa)
  cIa:update({})

  local gotLock = tickets.claimTicketCreateLock(cIa.user.id, 'customerservice')

  if gotLock then
    local existing = tickets.findOpenTicket(cIa.guildId, cIa.user.id, 'customerservice')
    if existing then
      tickets.releaseTicketCreateLock(cIa.user.id, 'customerservice')
      cIa:editReply({ content = 'You already have an open customer service ticket: <#' .. existing.channelId .. '>', components = {} })
      return
    end
  end

  local channel = createTicketChannel(cIa, 'customerservice', 'Customer Service')

  if not gotLock then
    pcall(function() channel:delete() end)
    cIa:editReply({
      content = "Looks like that got clicked twice -- your ticket was already created, check your channel list.",
      components = {},
    })
    return
  end

  tickets.createTicket({
    guildId = cIa.guildId,
    channelId = channel.id,
    category = 'customerservice',
    creatorId = cIa.user.id,
  })

  tickets.releaseTicketCreateLock(cIa.user.id, 'customerservice')

  channel:send({ content = '<@' .. cIa.user.id .. '> Please wait for an admin to answer your ticket.' })

  cIa:editReply({ content = 'Ticket created: <#' .. channel.id .. '>', components = {} })
end

local function handleDone(ia)
  if not requireAdmin(ia) then return requireAdminReply(ia) end

  local channelId = ia.channelId

  local ticket = tickets.getTicket(channelId)
  if not ticket then
    ia:reply({ content = 'This is not a ticket channel.' }, true)
    return
  end
  if ticket.status == 'done' then
    ia:reply({ content = 'This ticket is already marked done.' }, true)
    return
  end
  if ticket.status == 'deleted' then
    ia:reply({ content = 'This ticket has already been closed.' }, true)
    return
  end

  local testiChannelId = tickets.getTestiChannel(ia.guildId)
  if not testiChannelId then
    ia:reply({ content = 'No testimonial channel set. Run `/ticket settesti` first.' }, true)
    return
  end

  local modal = discordia.Modal {
    id = CID.DONE_MODAL .. '_' .. channelId,
    title = 'Testimonial Image',
    { id = 'testi_image_url', label = 'Image URL', style = 'short', required = true },
  }

  ia:modal(modal)

  orderSessions['done_' .. ia.user.id] = { channelId = channelId, ticket = ticket, ia = ia }
end

local function handleDoneModalSubmit(cIa)
  local channelId = cIa.data.custom_id:gsub('^' .. CID.DONE_MODAL .. '_', '')
  local session = orderSessions['done_' .. cIa.user.id]
  if not session or session.channelId ~= channelId then return end
  orderSessions['done_' .. cIa.user.id] = nil

  cIa:replyDeferred(true)

  local ticket = session.ticket
  local imageUrl = trim(cIa.data.components[1].components[1].value)

  local testiChannelId = tickets.getTestiChannel(cIa.guildId)
  local testiOk, testiChannel = pcall(function() return cIa.client:getChannel(testiChannelId) end)
  if not testiOk or not testiChannel then
    cIa:editReply({ content = 'Testimonial channel no longer exists. Run `/ticket settesti` again.' })
    return
  end

  local productList
  if type(ticket.products) == 'table' and #ticket.products > 0 then
    local names = {}
    for _, p in ipairs(ticket.products) do table.insert(names, p.name) end
    productList = table.concat(names, ', ')
  else
    productList = ticket.category == 'service' and 'Service' or 'Customer Service'
  end

  local totalPrice = ticket.total and formatIDR(ticket.total) or 'N/A'
  local ticketNumber = tickets.nextTicketNumber(cIa.guildId)

  local testiEmbed = {
    color = 0x57f287,
    description = 'TERIMAKASIH SUDAH MEMBELI PRODUK: ' .. productList .. ' DENGAN TOTAL HARGA: ' .. totalPrice .. ' | ' .. imageUrl,
    image = { url = imageUrl },
    footer = { text = 'Testimonial number ' .. tostring(ticketNumber) },
  }

  testiChannel:send({ embed = testiEmbed })

  local deliveryFailures = {}
  if type(ticket.products) == 'table' and #ticket.products > 0 then
    local creatorOk, creator = pcall(function() return cIa.client:getUser(ticket.creatorId) end)

    for _, item in ipairs(ticket.products) do
      local giveOk, giveErr = pcall(products.giveProductToUser, cIa.guildId, item.productId, ticket.creatorId)
      if not giveOk then
        print('Failed to grant product ' .. item.productId .. ' to ' .. ticket.creatorId .. ': ' .. tostring(giveErr))
        table.insert(deliveryFailures, item.name)
      end

      local product = products.getProduct(cIa.guildId, item.productId)
      if creatorOk and creator and product and product.fileLink then
        local dmOk = pcall(function()
          local channel = creator:getPrivateChannel()
          channel:send(products.buildProductDeliveryDM(product))
        end)
        if not dmOk then
          table.insert(deliveryFailures, item.name .. ' (DM failed)')
        end
      end
    end
  end

  tickets.closeTicket(channelId, { ticketNumber = ticketNumber })

  logger.logCommandActivity(cIa.client, { guildId = cIa.guildId, commandName = 'ticket', member = { id = cIa.user.id } }, {
    subcommand = 'done', success = true,
    fields = { discordUser = cIa.user, ticketChannel = '<#' .. channelId .. '>', total = totalPrice },
  })

  local deliveryNote = #deliveryFailures > 0
    and ("\nCouldn't fully deliver: " .. table.concat(deliveryFailures, ', ') .. '. Check manually.')
    or ''

  cIa:editReply({ content = 'Ticket marked done, testimonial posted.' .. deliveryNote })
end

function M.handleComponent(cIa)
  local customId = cIa.data and cIa.data.custom_id
  if not customId then return end
  if not customId:match('^ticket_') then return end

  if customId == 'ticket_send_modal' then return handleSendModalSubmit(cIa) end
  if customId == CID.PANEL_CATEGORY_SELECT then return onPanelCategorySelect(cIa) end
  if customId == CID.ORDER_PRODUCT_SELECT then return onOrderProductSelect(cIa) end
  if customId:match('^' .. CID.ORDER_CREATE_BTN .. '_') then return onOrderCreateButton(cIa) end
  if customId == CID.SERVICE_OPEN_MODAL_BTN then return onServiceOpenModalButton(cIa) end
  if customId == CID.SERVICE_MODAL then return onServiceModalSubmit(cIa) end
  if customId == CID.CS_CREATE_BTN then return onCsCreateButton(cIa) end
  if customId:match('^' .. CID.DONE_MODAL .. '_') then return handleDoneModalSubmit(cIa) end
end

function M.execute(ia, cmd, args)
  if not ia.guildId then
    ia:reply({ content = 'This command only works inside a server.' }, true)
    return
  end

  local subArgs, sub = tools.getSubCommand(cmd)

  if sub == 'send' then return handleSend(ia, subArgs) end
  if sub == 'done' then return handleDone(ia) end
  if sub == 'settesti' then return handleSetTesti(ia, subArgs) end
  if sub == 'createcategory' then return handleCreateCategory(ia) end
  if sub == 'close' then return handleClose(ia, subArgs) end
end

return M
