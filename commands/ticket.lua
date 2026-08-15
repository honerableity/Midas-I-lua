local uuid = require('resty.jit-uuid')
local logger = require('../utils/logger')
local products = require('../utils/products')
local verification = require('../utils/verification')
local ticketsUtil = require('../utils/tickets')

local MAX_SELECT_OPTIONS = 25

local CID = {
    PANEL_CATEGORY_SELECT = 'ticket_panel_category',
    ORDER_PRODUCT_SELECT = 'ticket_order_products',
    ORDER_CREATE_BTN = 'ticket_order_create',
    SERVICE_OPEN_MODAL_BTN = 'ticket_service_open_modal',
    SERVICE_MODAL = 'ticket_service_modal',
    CS_CREATE_BTN = 'ticket_cs_create',
    DONE_MODAL = 'ticket_done_modal'
}

local ticketsCommand = {}

local function requireAdmin(member)
    return member and member:hasPermission('administrator')
end

local function requireAdminReply(interaction)
    return interaction:reply({
        content = 'You need **Administrator** permission to do that.',
        flags = 64
    })
end

local function formatIDR(n)
    local formatted = tostring(math.floor(tonumber(n) or 0))
    local k
    while true do
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1.%2')
        if k == 0 then break end
    end
    return "Rp" .. formatted
end

local function parsePrice(priceStr)
    local digits = string.gsub(tostring(priceStr), "[^0-9]", "")
    return digits ~= "" and tonumber(digits) or 0
end

local function createTicketChannel(interaction, category, label)
    local guild = interaction.guild
    local overwrites = {}

    table.insert(overwrites, {
        id = guild.id,
        type = 0,
        deny = 1024
    })

    table.insert(overwrites, {
        id = interaction.member.id,
        type = 1,
        allow = 1024 + 2048 + 65536
    })

    table.insert(overwrites, {
        id = interaction.client.user.id,
        type = 1,
        allow = 1024 + 2048 + 16
    })

    for role in guild.roles:iter() do
        if role:hasPermission('administrator') then
            table.insert(overwrites, {
                id = role.id,
                type = 0,
                allow = 1024 + 2048 + 65536
            })
        end
    end

    local channelName = string.sub(category .. "-" .. interaction.member.user.username, 1, 90)
    local categories = ticketsUtil.getTicketCategories(guild.id)
    local parentId = categories and categories[category] or nil
    local parentValid = parentId and guild.channels:get(parentId) ~= nil

    local channel = guild:createChannel({
        name = channelName,
        type = 0,
        parent = parentValid and parentId or nil,
        permissionOverwrites = overwrites,
        topic = label .. " ticket for " .. interaction.member.user.tag
    })

    return channel
end

local function loadProductsMap(productIds)
    local map = {}
    for _, id in ipairs(productIds) do
        local p = products.getProduct(id)
        if p then map[id] = p end
    end
    return map
end

local function onOrderProductSelect(interaction)
    interaction:deferUpdate()

    local productIds = interaction.data.values
    local productsMap = loadProductsMap(productIds)

    local validIds = {}
    for _, id in ipairs(productIds) do
        if productsMap[id] then
            table.insert(validIds, id)
        end
    end

    if #validIds == 0 then
        return interaction:editReply({ content = 'Selected product(s) no longer exist. Try again.', components = {} })
    end

    local summaryLines = {}
    local total = 0
    for _, id in ipairs(validIds) do
        local p = productsMap[id]
        table.insert(summaryLines, "**" .. p.name .. "** — " .. p.price)
        total = total + parsePrice(p.price)
    end

    local token = uuid()
    ticketsUtil.saveOrderSelection(token, interaction.member.user.id, validIds)

    local createBtn = {
        type = 2,
        custom_id = CID.ORDER_CREATE_BTN .. "_" .. token,
        label = 'Create ticket',
        style = 3
    }

    return interaction:editReply({
        content = table.concat(summaryLines, "\n") .. "\n\n**Total: " .. formatIDR(total) .. "**",
        components = { { type = 1, components = { createBtn } } }
    })
end

local function onOrderCreateButton(interaction)
    interaction:deferUpdate()

    local token = string.gsub(interaction.data.custom_id, "^" .. CID.ORDER_CREATE_BTN .. "_", "")
    local selection = ticketsUtil.getOrderSelection(token)

    if not selection or selection.userId ~= interaction.member.user.id then
        return interaction:editReply({ content = 'This selection has expired. Please start over from the ticket panel.', components = {} })
    end

    local productIds = selection.productIds
    local gotLock = ticketsUtil.claimTicketCreateLock(interaction.member.user.id, 'order')

    if gotLock then
        local existing = ticketsUtil.findOpenTicket(interaction.guild.id, interaction.member.user.id, 'order')
        if existing then
            ticketsUtil.releaseTicketCreateLock(interaction.member.user.id, 'order')
            return interaction:editReply({ content = "You already have an open order ticket: <#" .. existing.channelId .. ">", components = {} })
        end
    end

    local productsMap = loadProductsMap(productIds)
    local lineItems = {}
    local total = 0

    for _, id in ipairs(productIds) do
        local p = productsMap[id]
        if p then
            local priceNum = parsePrice(p.price)
            table.insert(lineItems, { productId = id, name = p.name, price = p.price, lineTotal = priceNum })
            total = total + priceNum
        end
    end

    local channel = createTicketChannel(interaction, 'order', 'Order')

    if not gotLock then
        pcall(function() channel:delete() end)
        return interaction:editReply({
            content = 'Looks like that got clicked twice -- your ticket was already created, check your channel list.',
            components = {}
        })
    end

    ticketsUtil.createTicket({
        guildId = interaction.guild.id,
        channelId = channel.id,
        category = 'order',
        creatorId = interaction.member.user.id,
        products = lineItems,
        total = total
    })

    ticketsUtil.releaseTicketCreateLock(interaction.member.user.id, 'order')

    local summaryLines = {}
    for _, li in ipairs(lineItems) do
        table.insert(summaryLines, "**" .. li.name .. "** — " .. formatIDR(li.lineTotal))
    end

    local embed = {
        title = 'New Order Ticket',
        color = 0x57f287,
        description = table.concat(summaryLines, "\n"),
        fields = { { name = 'Total', value = formatIDR(total) } },
        footer = { text = "Requested by " .. interaction.member.user.tag }
    }

    channel:send({ content = "<@" .. interaction.member.user.id .. ">", embed = embed })

    logger.logCommandActivity(interaction, {
        subcommand = 'send',
        success = true,
        fields = { discordUser = interaction.member.user },
        note = "Order ticket created: " .. channel.id .. ", total " .. total
    })

    return interaction:editReply({
        content = "Ticket created: <#" .. channel.id .. ">",
        components = {}
    })
end

local function onServiceOpenModalButton(interaction)
    local modal = {
        custom_id = CID.SERVICE_MODAL,
        title = 'Service Request',
        components = {
            {
                type = 1,
                components = {
                    {
                        type = 4,
                        custom_id = 'service_answer',
                        label = 'What type of service do you want?',
                        style = 2,
                        required = true
                    }
                }
            }
        }
    }
    return interaction:showModal(modal)
end

local function onServiceModalSubmit(interaction)
    interaction:deferReply({ flags = 64 })

    local gotLock = ticketsUtil.claimTicketCreateLock(interaction.member.user.id, 'service')

    if gotLock then
        local existing = ticketsUtil.findOpenTicket(interaction.guild.id, interaction.member.user.id, 'service')
        if existing then
            ticketsUtil.releaseTicketCreateLock(interaction.member.user.id, 'service')
            return interaction:editReply({ content = "You already have an open service ticket: <#" .. existing.channelId .. ">" })
        end
    end

    local answer = interaction.data.components[1].components[1].value
    answer = string.gsub(answer, "^%s*(.-)%s*$", "%1")

    local channel = createTicketChannel(interaction, 'service', 'Service')

    if not gotLock then
        pcall(function() channel:delete() end)
        return interaction:editReply({ content = 'Looks like that got submitted twice -- your ticket was already created, check your channel list.' })
    end

    ticketsUtil.createTicket({
        guildId = interaction.guild.id,
        channelId = channel.id,
        category = 'service',
        creatorId = interaction.member.user.id,
        serviceAnswer = answer
    })

    ticketsUtil.releaseTicketCreateLock(interaction.member.user.id, 'service')

    local embed = {
        title = 'New Service Ticket',
        color = 0x5865f2,
        fields = { { name = 'Requested service', value = string.sub(answer, 1, 1024) } },
        footer = { text = "Requested by " .. interaction.member.user.tag }
    }

    channel:send({ content = "<@" .. interaction.member.user.id .. ">", embed = embed })

    return interaction:editReply({ content = "Ticket created: <#" .. channel.id .. ">" })
end

local function onCsCreateButton(interaction)
    interaction:deferUpdate()

    local gotLock = ticketsUtil.claimTicketCreateLock(interaction.member.user.id, 'customerservice')

    if gotLock then
        local existing = ticketsUtil.findOpenTicket(interaction.guild.id, interaction.member.user.id, 'customerservice')
        if existing then
            ticketsUtil.releaseTicketCreateLock(interaction.member.user.id, 'customerservice')
            return interaction:editReply({ content = "You already have an open customer service ticket: <#" .. existing.channelId .. ">", components = {} })
        end
    end

    local channel = createTicketChannel(interaction, 'customerservice', 'Customer Service')

    if not gotLock then
        pcall(function() channel:delete() end)
        return interaction:editReply({
            content = 'Looks like that got clicked twice -- your ticket was already created, check your channel list.',
            components = {}
        })
    end

    ticketsUtil.createTicket({
        guildId = interaction.guild.id,
        channelId = channel.id,
        category = 'customerservice',
        creatorId = interaction.member.user.id
    })

    ticketsUtil.releaseTicketCreateLock(interaction.member.user.id, 'customerservice')

    channel:send({
        content = "<@" .. interaction.member.user.id .. "> Please wait for an admin to answer your ticket."
    })

    return interaction:editReply({ content = "Ticket created: <#" .. channel.id .. ">", components = {} })
end

local function onPanelCategorySelect(interaction)
    local category = interaction.data.values[1]

    if category == 'order' then
        interaction:deferReply({ flags = 64 })

        local existing = ticketsUtil.findOpenTicket(interaction.guild.id, interaction.member.user.id, 'order')
        if existing then
            return interaction:editReply({ content = "You already have an open order ticket: <#" .. existing.channelId .. ">" })
        end

        local types = products.listProductTypes(interaction.guild.id)
        if not types or #types == 0 then
            return interaction:editReply({ content = 'No products are available right now.' })
        end

        local allProducts = {}
        for _, t in ipairs(types) do
            local prods = products.listProductsByType(interaction.guild.id, t.id)
            if prods then
                for _, p in ipairs(prods) do table.insert(allProducts, p) end
            end
        end

        if #allProducts == 0 then
            return interaction:editReply({ content = 'No products are available right now.' })
        end

        local verifiedUser = verification.getVerifiedUser(interaction.member.user.id)
        local owned = {}
        if verifiedUser and verifiedUser.ownedProducts then
            for _, pid in ipairs(verifiedUser.ownedProducts) do owned[pid] = true end
        end

        local purchasable = {}
        for _, p in ipairs(allProducts) do
            if not owned[p.id] then table.insert(purchasable, p) end
        end

        if #purchasable == 0 then
            return interaction:editReply({ content = 'You already own every available product.' })
        end

        local options = {}
        for i = 1, math.min(#purchasable, MAX_SELECT_OPTIONS) do
            local p = purchasable[i]
            table.insert(options, {
                label = string.sub(p.name, 1, 100),
                description = string.sub(p.type .. " — " .. p.price, 1, 100),
                value = p.id
            })
        end

        local selectMenu = {
            type = 3,
            custom_id = CID.ORDER_PRODUCT_SELECT,
            placeholder = 'Select product(s) to buy',
            min_values = 1,
            max_values = #options,
            options = options
        }

        return interaction:editReply({
            content = 'Pick the product(s) you want to buy (already-owned products are hidden):',
            components = { { type = 1, components = { selectMenu } } }
        })
    end

    if category == 'service' then
        interaction:deferReply({ flags = 64 })

        local existing = ticketsUtil.findOpenTicket(interaction.guild.id, interaction.member.user.id, 'service')
        if existing then
            return interaction:editReply({ content = "You already have an open service ticket: <#" .. existing.channelId .. ">" })
        end

        local btn = {
            type = 2,
            custom_id = CID.SERVICE_OPEN_MODAL_BTN,
            label = 'Fill service request',
            style = 1
        }

        return interaction:editReply({
            content = 'Click below to describe the service you need:',
            components = { { type = 1, components = { btn } } }
        })
    end

    if category == 'customerservice' then
        interaction:deferReply({ flags = 64 })

        local existing = ticketsUtil.findOpenTicket(interaction.guild.id, interaction.member.user.id, 'customerservice')
        if existing then
            return interaction:editReply({ content = "You already have an open customer service ticket: <#" .. existing.channelId .. ">" })
        end

        local btn = {
            type = 2,
            custom_id = CID.CS_CREATE_BTN,
            label = 'Create ticket',
            style = 1
        }

        return interaction:editReply({
            content = 'Click below to open a customer service ticket:',
            components = { { type = 1, components = { btn } } }
        })
    end
end

local function handleSend(interaction)
    if not requireAdmin(interaction.member) then return requireAdminReply(interaction) end

    local targetChannelId = interaction.data.options[1].options[1].value
    local targetChannel = interaction.guild.channels:get(targetChannelId)

    local modal = {
        custom_id = 'ticket_send_modal',
        title = 'Ticket Panel',
        components = {
            { type = 1, components = { { type = 4, custom_id = 'panel_title', label = 'Title', style = 1, required = true } } },
            { type = 1, components = { { type = 4, custom_id = 'panel_description', label = 'Description', style = 2, required = true } } },
            { type = 1, components = { { type = 4, custom_id = 'panel_color', label = 'Color (hex, e.g. #5865F2)', placeholder = '#5865F2', style = 1, required = false } } }
        }
    }

    interaction:showModal(modal)

    local success, modalSubmit = interaction.client:await('modalSubmit', function(i)
        return i.data.custom_id == 'ticket_send_modal' and i.member.user.id == interaction.member.user.id
    end, 15 * 60 * 1000)

    if not success or not modalSubmit then return end

    local fields = modalSubmit.data.components
    local panelTitle = fields[1].components[1].value
    local panelDesc = fields[2].components[1].value
    local colorRaw = fields[3].components[1].value

    modalSubmit:deferReply({ flags = 64 })

    local color = 0x5865f2
    if colorRaw and colorRaw ~= "" then
        local cleanHex = string.gsub(colorRaw, "#", "")
        local parsed = tonumber(cleanHex, 16)
        if parsed then color = parsed end
    end

    local embed = {
        title = panelTitle,
        description = panelDesc,
        color = color
    }

    local categorySelect = {
        type = 3,
        custom_id = CID.PANEL_CATEGORY_SELECT,
        placeholder = 'Select a ticket category',
        options = {
            { label = 'Order', value = 'order', description = 'Buy a product' },
            { label = 'Service', value = 'service', description = 'Request a service' },
            { label = 'Customer Service', value = 'customerservice', description = 'Talk to an admin' }
        }
    }

    local sentSuccess, err = pcall(function()
        targetChannel:send({ embed = embed, components = { { type = 1, components = { categorySelect } } } })
    end)

    if not sentSuccess then
        return modalSubmit:editReply({ content = "Couldn't send the panel to <#" .. targetChannelId .. ">." })
    end

    modalSubmit:editReply({ content = "Panel sent to <#" .. targetChannelId .. ">." })

    logger.logCommandActivity(interaction, {
        subcommand = 'send',
        success = true,
        fields = { discordUser = interaction.member.user, channel = targetChannel }
    })
end

local function handleSetTesti(interaction)
    if not requireAdmin(interaction.member) then return requireAdminReply(interaction) end

    interaction:deferReply({ flags = 64 })

    local channelId = interaction.data.options[1].options[1].value
    ticketsUtil.setTestiChannel(interaction.guild.id, channelId)

    logger.logCommandActivity(interaction, {
        subcommand = 'settesti',
        success = true,
        fields = { discordUser = interaction.member.user, channel = channelId }
    })

    return interaction:editReply({ content = "Testimonial channel set to <#" .. channelId .. ">." })
end

local function handleCreateCategory(interaction)
    if not requireAdmin(interaction.member) then return requireAdminReply(interaction) end

    interaction:deferReply({ flags = 64 })

    local guild = interaction.guild
    local existing = ticketsUtil.getTicketCategories(guild.id) or {}

    local wanted = {
        order = 'Order Tickets',
        service = 'Service Tickets',
        customerservice = 'Customer Service Tickets'
    }

    local result = {}
    for k, v in pairs(existing) do result[k] = v end

    for key, name in pairs(wanted) do
        local stillExists = result[key] and guild.channels:get(result[key]) ~= nil
        if not stillExists then
            local created = guild:createChannel({
                name = name,
                type = 4
            })
            result[key] = created.id
        end
    end

    ticketsUtil.setTicketCategories(guild.id, result)

    logger.logCommandActivity(interaction, {
        subcommand = 'createcategory',
        success = true,
        fields = { discordUser = interaction.member.user }
    })

    return interaction:editReply({
        content = "Ticket categories ready:\nOrder: <#" .. tostring(result.order) .. ">\nService: <#" .. tostring(result.service) .. ">\nCustomer Service: <#" .. tostring(result.customerservice) .. ">"
    })
end

local function handleClose(interaction)
    if not requireAdmin(interaction.member) then return requireAdminReply(interaction) end

    interaction:deferReply({ flags = 64 })

    local targetChannelId = (interaction.data.options and interaction.data.options[1].options and interaction.data.options[1].options[1]) and interaction.data.options[1].options[1].value or interaction.channel.id
    local targetChannel = interaction.guild.channels:get(targetChannelId)

    local ticket = ticketsUtil.getTicket(targetChannelId)
    if not ticket then
        return interaction:editReply({ content = "<#" .. targetChannelId .. "> is not a ticket channel." })
    end

    local creator = interaction.client:getUser(ticket.creatorId)
    local dmSent = false
    if creator then
        local successDM = pcall(function()
            creator:send("Your ticket in **" .. interaction.guild.name .. "** has been closed.")
        end)
        if successDM then dmSent = true end
    end

    ticketsUtil.markTicketDeleted(targetChannelId)

    local delSuccess = pcall(function()
        targetChannel:delete()
    end)

    if not delSuccess then
        return interaction:editReply({ content = "Couldn't delete <#" .. targetChannelId .. ">. Check my permissions there." })
    end

    logger.logCommandActivity(interaction, {
        subcommand = 'close',
        success = true,
        fields = { discordUser = interaction.member.user, ticketChannel = "<#" .. targetChannelId .. ">" }
    })

    return interaction:editReply({
        content = "Ticket closed and deleted." .. (dmSent and "" or " (Could not DM the creator — DMs may be closed.)")
    })
end

local function handleDone(interaction)
    if not requireAdmin(interaction.member) then return requireAdminReply(interaction) end

    local channelId = interaction.channel.id

    local ticket = ticketsUtil.getTicket(channelId)
    if not ticket then
        return interaction:reply({ content = 'This is not a ticket channel.', flags = 64 })
    end
    if ticket.status == 'done' then
        return interaction:reply({ content = 'This ticket is already marked done.', flags = 64 })
    end
    if ticket.status == 'deleted' then
        return interaction:reply({ content = 'This ticket has already been closed.', flags = 64 })
    end

    local testiChannelId = ticketsUtil.getTestiChannel(interaction.guild.id)
    if not testiChannelId then
        return interaction:reply({
            content = 'No testimonial channel set. Run `/ticket settesti` first.',
            flags = 64
        })
    end

    local modal = {
        custom_id = CID.DONE_MODAL .. "_" .. channelId,
        title = 'Testimonial Image',
        components = {
            {
                type = 1,
                components = {
                    {
                        type = 4,
                        custom_id = 'testi_image_url',
                        label = 'Image URL',
                        style = 1,
                        required = true
                    }
                }
            }
        }
    }

    interaction:showModal(modal)

    local success, modalSubmit = interaction.client:await('modalSubmit', function(i)
        return i.data.custom_id == (CID.DONE_MODAL .. "_" .. channelId) and i.member.user.id == interaction.member.user.id
    end, 15 * 60 * 1000)

    if not success or not modalSubmit then return end

    modalSubmit:deferReply({ flags = 64 })

    local imageUrl = modalSubmit.data.components[1].components[1].value
    imageUrl = string.gsub(imageUrl, "^%s*(.-)%s*$", "%1")

    local testiChannel = interaction.guild.channels:get(testiChannelId)
    if not testiChannel then
        return modalSubmit:editReply({ content = 'Testimonial channel no longer exists. Run `/ticket settesti` again.' })
    end

    local productNames = {}
    if type(ticket.products) == 'table' and #ticket.products > 0 then
        for _, p in ipairs(ticket.products) do table.insert(productNames, p.name) end
    end

    local productList = #productNames > 0 and table.concat(productNames, ", ") or (ticket.category == 'service' and 'Service' or 'Customer Service')
    local totalPrice = ticket.total and formatIDR(ticket.total) or 'N/A'
    local ticketNumber = ticketsUtil.nextTicketNumber(interaction.guild.id)

    local testiEmbed = {
        color = 0x57f287,
        description = "TERIMAKASIH SUDAH MEMBELI PRODUK: " .. productList .. " DENGAN TOTAL HARGA: " .. totalPrice .. " | " .. imageUrl,
        image = { url = imageUrl },
        footer = { text = "Testimonial number " .. tostring(ticketNumber) }
    }

    testiChannel:send({ embed = testiEmbed })

    local deliveryFailures = {}
    if type(ticket.products) == 'table' and #ticket.products > 0 then
        local creator = interaction.client:getUser(ticket.creatorId)

        for _, item in ipairs(ticket.products) do
            local gSuccess = pcall(function()
                products.giveProductToUser(item.productId, ticket.creatorId)
            end)
            if not gSuccess then
                table.insert(deliveryFailures, item.name)
            end

            local product = products.getProduct(item.productId)
            if creator and product and product.fileLink then
                local dmOk = pcall(function()
                    creator:send(products.buildProductDeliveryDM(product))
                end)
                if not dmOk then
                    table.insert(deliveryFailures, item.name .. " (DM failed)")
                end
            end
        end
    end

    ticketsUtil.closeTicket(channelId, { ticketNumber = ticketNumber })

    logger.logCommandActivity(interaction, {
        subcommand = 'done',
        success = true,
        fields = { discordUser = interaction.member.user, ticketChannel = "<#" .. channelId .. ">", total = totalPrice }
    })

    local deliveryNote = #deliveryFailures > 0 and ("\nCouldn't fully deliver: " .. table.concat(deliveryFailures, ", ") .. ". Check manually.") or ""

    return modalSubmit:editReply({ content = "Ticket marked done, testimonial posted." .. deliveryNote })
end

function ticketsCommand.execute(interaction)
    if not interaction.guild then
        return interaction:reply({ content = 'This command only works inside a server.', flags = 64 })
    end

    local sub = interaction.data.options[1].name

    if sub == 'send' then return handleSend(interaction) end
    if sub == 'done' then return handleDone(interaction) end
    if sub == 'settesti' then return handleSetTesti(interaction) end
    if sub == 'createcategory' then return handleCreateCategory(interaction) end
    if sub == 'close' then return handleClose(interaction) end
end

function ticketsCommand.handleComponent(interaction)
    local id = interaction.data.custom_id

    if id == CID.PANEL_CATEGORY_SELECT then return onPanelCategorySelect(interaction) end
    if id == CID.ORDER_PRODUCT_SELECT then return onOrderProductSelect(interaction) end
    if string.find(id, "^" .. CID.ORDER_CREATE_BTN .. "_") then return onOrderCreateButton(interaction) end
    if id == CID.SERVICE_OPEN_MODAL_BTN then return onServiceOpenModalButton(interaction) end
    if id == CID.SERVICE_MODAL then return onServiceModalSubmit(interaction) end
    if id == CID.CS_CREATE_BTN then return onCsCreateButton(interaction) end
end

return ticketsCommand
