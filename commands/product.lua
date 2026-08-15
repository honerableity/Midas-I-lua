local discordia = require('discordia')
local permissions = discordia.enums.permission
local channelType = discordia.enums.channelType
local buttonStyle = discordia.enums.buttonStyle
local textInputStyle = discordia.enums.textInputStyle

local uuid = require('uuid')
local logger = require('../utils/logger')
local products = require('../utils/products')
local verification = require('../utils/verification')

local STEP_TIMEOUT_MS = 15 * 60 * 1000
local MAX_SELECT_OPTIONS = 25

local function requireAdmin(interaction)
    local member = interaction.member
    if not member then return false end
    return member:hasPermission(permissions.administrator)
end

local function isFreeProduct(price)
    local normalized = string.lower(string.match(tostring(price or ''), '^%s*(.-)%s*$'))
    return normalized == '0' or normalized == 'free'
end

local function autocompleteGetProductUuid(interaction)
    local focused = string.lower(interaction.options.focused.value or '')
    local userId = interaction.user.id

    local verifiedRecord = verification.getVerifiedUser(userId)
    local ownedIds = verifiedRecord and verifiedRecord.ownedProducts

    if type(ownedIds) ~= 'table' or #ownedIds == 0 then
        return interaction:respond({})
    end

    local owned = products.getProductsByIds(ownedIds)
    local filtered = {}

    for _, p in ipairs(owned) do
        if p.name and string.find(string.lower(p.name), focused, 1, true) then
            table.insert(filtered, {
                name = string.sub(p.name, 1, 100),
                value = p.id
            })
            if #filtered >= 25 then break end
        end
    end

    return interaction:respond(filtered)
end

local function handleCreate(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({
            content = 'You need **Administrator** permission to do that.',
            ephemeral = true
        })
    end

    local modal1 = {
        title = 'New Product (1/2)',
        custom_id = 'product_create_modal_1',
        components = {
            { type = 1, components = { { type = 4, custom_id = 'product_name', label = 'Nama produk', style = textInputStyle.short, required = true } } },
            { type = 1, components = { { type = 4, custom_id = 'product_description', label = 'Deskripsi', style = textInputStyle.paragraph, required = true } } },
            { type = 1, components = { { type = 4, custom_id = 'product_price', label = 'Harga', placeholder = 'cth: 25000 atau Rp25.000', style = textInputStyle.short, required = true } } },
            { type = 1, components = { { type = 4, custom_id = 'product_creator', label = 'Kreator (kosongkan jika kamu sendiri)', style = textInputStyle.short, required = false } } },
        }
    }

    interaction:showModal(modal1)

    local success1, modal1Submit = pcall(function()
        return interaction:awaitModalSubmit({
            filter = function(i) return i.custom_id == 'product_create_modal_1' and i.user.id == interaction.user.id end,
            timeout = STEP_TIMEOUT_MS
        })
    end)

    if not success1 or not modal1Submit then return end

    local productName = string.match(modal1Submit.fields.product_name or '', '^%s*(.-)%s*$')
    local productDescription = string.match(modal1Submit.fields.product_description or '', '^%s*(.-)%s*$')
    local productPrice = string.match(modal1Submit.fields.product_price or '', '^%s*(.-)%s*$')
    local productCreatorRaw = string.match(modal1Submit.fields.product_creator or '', '^%s*(.-)%s*$')
    local productCreator = (productCreatorRaw ~= '') and productCreatorRaw or interaction.user.username

    local continueRow = {
        type = 1,
        components = {
            { type = 2, custom_id = 'product_create_continue', label = 'Lanjutkan (2/2)', style = buttonStyle.primary }
        }
    }

    modal1Submit:reply({
        content = 'Langkah 1 tersimpan. Klik tombol di bawah buat lanjut ke langkah 2.',
        components = { continueRow },
        ephemeral = true
    })

    local successBtn, btnInteraction = pcall(function()
        return modal1Submit.channel:awaitComponent({
            filter = function(i) return i.custom_id == 'product_create_continue' and i.user.id == interaction.user.id end,
            timeout = STEP_TIMEOUT_MS
        })
    end)

    if not successBtn or not btnInteraction then
        pcall(function() modal1Submit:editReply({ content = 'Waktu habis. Jalankan `/product create` lagi.', components = {} }) end)
        return
    end

    local modal2 = {
        title = 'New Product (2/2)',
        custom_id = 'product_create_modal_2',
        components = {
            { type = 1, components = { { type = 4, custom_id = 'product_file_link', label = 'Link file produk', placeholder = 'CDN Discord, catbox.moe, Drive, Mega.nz, dll', style = textInputStyle.short, required = true } } },
            { type = 1, components = { { type = 4, custom_id = 'product_review_media', label = 'Video/Gambar Review Produk', placeholder = 'Link video atau gambar review', style = textInputStyle.short, required = true } } },
            { type = 1, components = { { type = 4, custom_id = 'product_tutorial_link', label = 'Link Tutorial (opsional)', placeholder = 'Link tutorial cara pakai produk, boleh kosong', style = textInputStyle.short, required = false } } },
        }
    }

    btnInteraction:showModal(modal2)

    local success2, modal2Submit = pcall(function()
        return btnInteraction:awaitModalSubmit({
            filter = function(i) return i.custom_id == 'product_create_modal_2' and i.user.id == interaction.user.id end,
            timeout = STEP_TIMEOUT_MS
        })
    end)

    if not success2 or not modal2Submit then return end

    local productFileLink = string.match(modal2Submit.fields.product_file_link or '', '^%s*(.-)%s*$')
    local productReviewMedia = string.match(modal2Submit.fields.product_review_media or '', '^%s*(.-)%s*$')
    local productTutorialLink = string.match(modal2Submit.fields.product_tutorial_link or '', '^%s*(.-)%s*$')

    modal2Submit:deferReply({ ephemeral = true })

    local types = products.listProductTypes(interaction.guild.id)
    if #types == 0 then
        return modal2Submit:editReply({ content = 'Belum ada jenis produk yang terdaftar. Minta admin jalankan `/product createtype` dulu, baru ulangi `/product create`.' })
    end

    local selectOptions = {}
    for i = 1, math.min(#types, MAX_SELECT_OPTIONS) do
        table.insert(selectOptions, { label = types[i].name, value = types[i].id })
    end

    local selectRow = {
        type = 1,
        components = {
            { type = 3, custom_id = 'product_create_type_select', placeholder = 'Pilih jenis produk', options = selectOptions }
        }
    }

    modal2Submit:editReply({
        content = 'Terakhir, pilih jenis produk:',
        components = { selectRow }
    })

    local successSelect, typeSelectInteraction = pcall(function()
        return modal2Submit.channel:awaitComponent({
            filter = function(i) return i.custom_id == 'product_create_type_select' and i.user.id == interaction.user.id end,
            timeout = STEP_TIMEOUT_MS
        })
    end)

    if not successSelect or not typeSelectInteraction then
        pcall(function() modal2Submit:editReply({ content = 'Waktu habis memilih jenis. Jalankan `/product create` lagi.', components = {} }) end)
        return
    end

    local selectedTypeId = typeSelectInteraction.values[1]
    local selectedType = nil
    for _, t in ipairs(types) do
        if t.id == selectedTypeId then selectedType = t break end
    end

    pcall(function() typeSelectInteraction:deferUpdate() end)

    local productId = uuid.new()
    local productData = {
        productId = productId,
        name = productName,
        description = productDescription,
        price = productPrice,
        fileLink = productFileLink,
        tutorialLink = productTutorialLink,
        reviewMedia = productReviewMedia,
        creator = productCreator,
        type = selectedType.name,
        typeId = selectedType.id,
        typeForumId = selectedType.forumChannelId or nil,
        createdBy = interaction.user.id,
        guildId = interaction.guild.id,
        createdAt = os.time() * 1000,
    }

    local saveOk = pcall(function() products.saveProduct(productId, productData) end)
    if not saveOk then
        logger.logCommandActivity(interaction, {
            subcommand = 'create',
            success = false,
            fields = { discordUser = interaction.user, productName = productName },
            note = 'Firestore write failed.'
        })
        return modal2Submit:editReply({ content = 'Gagal menyimpan produk ke database. Coba lagi.', components = {} })
    end

    logger.logCommandActivity(interaction, {
        subcommand = 'create',
        success = true,
        fields = { discordUser = interaction.user, productId = productId, productName = productName }
    })

    local embed = {
        title = 'Produk Berhasil Dibuat',
        color = 0x57f287,
        fields = {
            { name = 'Nama Produk', value = productName },
            { name = 'ID Produk', value = '`' .. productId .. '`' },
            { name = 'Jenis', value = selectedType.name, inline = true },
            { name = 'Harga', value = productPrice, inline = true },
            { name = 'Kreator', value = productCreator, inline = true },
        }
    }

    return modal2Submit:editReply({ content = 'Produk berhasil dibuat!', embeds = { embed }, components = {} })
end

local function handleEdit(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({ content = 'You need **Administrator** permission to do that.', ephemeral = true })
    end

    local productId = string.match(interaction.options.product_uuid or '', '^%s*(.-)%s*$')
    local product = products.getProduct(productId)

    if not product then
        logger.logCommandActivity(interaction, {
            subcommand = 'edit',
            success = false,
            fields = { discordUser = interaction.user, productId = productId },
            note = 'Product UUID not found.'
        })
        return interaction:reply({ content = string.format('Produk dengan ID `%s` tidak ditemukan.', productId), ephemeral = true })
    end

    local modal1 = {
        title = 'Edit Product (1/2)',
        custom_id = 'product_edit_modal_1',
        components = {
            { type = 1, components = { { type = 4, custom_id = 'product_name', label = 'Nama produk', style = textInputStyle.short, value = product.name, required = true } } },
            { type = 1, components = { { type = 4, custom_id = 'product_description', label = 'Deskripsi', style = textInputStyle.paragraph, value = product.description, required = true } } },
            { type = 1, components = { { type = 4, custom_id = 'product_price', label = 'Harga', placeholder = 'cth: 25000 atau Rp25.000', style = textInputStyle.short, value = product.price, required = true } } },
            { type = 1, components = { { type = 4, custom_id = 'product_creator', label = 'Kreator (kosongkan jika kamu sendiri)', style = textInputStyle.short, value = product.creator or '', required = false } } },
        }
    }

    interaction:showModal(modal1)

    local success1, modal1Submit = pcall(function()
        return interaction:awaitModalSubmit({
            filter = function(i) return i.custom_id == 'product_edit_modal_1' and i.user.id == interaction.user.id end,
            timeout = STEP_TIMEOUT_MS
        })
    end)

    if not success1 or not modal1Submit then return end

    local productName = string.match(modal1Submit.fields.product_name or '', '^%s*(.-)%s*$')
    local productDescription = string.match(modal1Submit.fields.product_description or '', '^%s*(.-)%s*$')
    local productPrice = string.match(modal1Submit.fields.product_price or '', '^%s*(.-)%s*$')
    local productCreatorRaw = string.match(modal1Submit.fields.product_creator or '', '^%s*(.-)%s*$')
    local productCreator = (productCreatorRaw ~= '') and productCreatorRaw or interaction.user.username

    local continueRow = {
        type = 1,
        components = { { type = 2, custom_id = 'product_edit_continue', label = 'Lanjutkan (2/2)', style = buttonStyle.primary } }
    }

    modal1Submit:reply({ content = 'Langkah 1 tersimpan. Klik tombol di bawah buat lanjut ke langkah 2.', components = { continueRow }, ephemeral = true })

    local successBtn, btnInteraction = pcall(function()
        return modal1Submit.channel:awaitComponent({
            filter = function(i) return i.custom_id == 'product_edit_continue' and i.user.id == interaction.user.id end,
            timeout = STEP_TIMEOUT_MS
        })
    end)

    if not successBtn or not btnInteraction then
        pcall(function() modal1Submit:editReply({ content = string.format('Waktu habis. Jalankan `/product edit %s` lagi.', productId), components = {} }) end)
        return
    end

    local modal2 = {
        title = 'Edit Product (2/2)',
        custom_id = 'product_edit_modal_2',
        components = {
            { type = 1, components = { { type = 4, custom_id = 'product_file_link', label = 'Link file produk', placeholder = 'CDN Discord, catbox.moe, Drive, Mega.nz, dll', style = textInputStyle.short, value = product.fileLink, required = true } } },
            { type = 1, components = { { type = 4, custom_id = 'product_review_media', label = 'Video/Gambar Review Produk', placeholder = 'Link video atau gambar review', style = textInputStyle.short, value = product.reviewMedia or '', required = true } } },
            { type = 1, components = { { type = 4, custom_id = 'product_tutorial_link', label = 'Link Tutorial (opsional)', placeholder = 'Link tutorial cara pakai produk, boleh kosong', style = textInputStyle.short, value = product.tutorialLink or '', required = false } } },
        }
    }

    btnInteraction:showModal(modal2)

    local success2, modal2Submit = pcall(function()
        return btnInteraction:awaitModalSubmit({
            filter = function(i) return i.custom_id == 'product_edit_modal_2' and i.user.id == interaction.user.id end,
            timeout = STEP_TIMEOUT_MS
        })
    end)

    if not success2 or not modal2Submit then return end

    local productFileLink = string.match(modal2Submit.fields.product_file_link or '', '^%s*(.-)%s*$')
    local productReviewMedia = string.match(modal2Submit.fields.product_review_media or '', '^%s*(.-)%s*$')
    local productTutorialLink = string.match(modal2Submit.fields.product_tutorial_link or '', '^%s*(.-)%s*$')

    modal2Submit:deferReply({ ephemeral = true })

    local types = products.listProductTypes(interaction.guild.id)
    if #types == 0 then
        return modal2Submit:editReply({ content = 'Belum ada jenis produk yang terdaftar. Minta admin jalankan `/product createtype` dulu.' })
    end

    local selectOptions = {}
    for i = 1, math.min(#types, MAX_SELECT_OPTIONS) do
        table.insert(selectOptions, {
            label = types[i].name,
            value = types[i].id,
            default = (types[i].id == product.typeId)
        })
    end

    local selectRow = {
        type = 1,
        components = { { type = 3, custom_id = 'product_edit_type_select', placeholder = 'Pilih jenis produk', options = selectOptions } }
    }
    local keepTypeRow = {
        type = 1,
        components = { { type = 2, custom_id = 'product_edit_keep_type', label = string.format('Simpan dengan jenis "%s"', product.type), style = buttonStyle.secondary } }
    }

    modal2Submit:editReply({
        content = 'Terakhir, pilih jenis produk (atau klik tombol untuk tetap pakai jenis saat ini):',
        components = { selectRow, keepTypeRow }
    })

    local selectedTypeId = nil
    local ackInteraction = nil

    local successComp, componentInteraction = pcall(function()
        return modal2Submit.channel:awaitComponent({
            filter = function(i)
                return (i.custom_id == 'product_edit_type_select' or i.custom_id == 'product_edit_keep_type') and i.user.id == interaction.user.id
            end,
            timeout = STEP_TIMEOUT_MS
        })
    end)

    if not successComp or not componentInteraction then
        pcall(function() modal2Submit:editReply({ content = string.format('Waktu habis memilih jenis. Jalankan `/product edit %s` lagi.', productId), components = {} }) end)
        return
    end

    ackInteraction = componentInteraction
    selectedTypeId = (componentInteraction.custom_id == 'product_edit_keep_type') and product.typeId or componentInteraction.values[1]

    local selectedType = nil
    for _, t in ipairs(types) do
        if t.id == selectedTypeId then selectedType = t break end
    end

    pcall(function() ackInteraction:deferUpdate() end)

    local updatedData = {
        productId = productId,
        name = productName,
        description = productDescription,
        price = productPrice,
        fileLink = productFileLink,
        tutorialLink = productTutorialLink,
        reviewMedia = productReviewMedia,
        creator = productCreator,
        type = selectedType.name,
        typeId = selectedType.id,
        typeForumId = (selectedType.id == product.typeId) and product.typeForumId or (selectedType.forumChannelId or nil),
        forumThreadId = product.forumThreadId,
        createdBy = product.createdBy,
        createdAt = product.createdAt,
        updatedAt = os.time() * 1000,
    }

    local saveOk = pcall(function() products.saveProduct(productId, updatedData) end)
    if not saveOk then
        logger.logCommandActivity(interaction, {
            subcommand = 'edit',
            success = false,
            fields = { discordUser = interaction.user, productId = productId, productName = productName },
            note = 'Firestore write failed.'
        })
        return modal2Submit:editReply({ content = 'Gagal menyimpan perubahan produk ke database. Coba lagi.', components = {} })
    end

    logger.logCommandActivity(interaction, {
        subcommand = 'edit',
        success = true,
        fields = { discordUser = interaction.user, productId = productId, productName = productName }
    })

    local embed = {
        title = 'Produk Berhasil Diedit',
        color = 0x57f287,
        fields = {
            { name = 'Nama Produk', value = productName },
            { name = 'ID Produk', value = '`' .. productId .. '`' },
            { name = 'Jenis', value = selectedType.name, inline = true },
            { name = 'Harga', value = productPrice, inline = true },
            { name = 'Kreator', value = productCreator, inline = true },
        }
    }

    local postNote = updatedData.forumThreadId and ' Jalankan `/product sendpost` untuk update post forum-nya juga.' or ''
    return modal2Submit:editReply({ content = 'Produk berhasil diedit!' .. postNote, embeds = { embed }, components = {} })
end

local function handleCreateType(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({ content = 'You need **Administrator** permission to do that.', ephemeral = true })
    end

    interaction:deferReply({ ephemeral = true })

    local typeName = string.match(interaction.options.nama or '', '^%s*(.-)%s*$')
    if typeName == '' then
        return interaction:editReply({ content = 'Nama jenis tidak boleh kosong.' })
    end

    local success, result = pcall(function()
        return products.createOrSyncProductTypeForum(interaction.guild, interaction.guild.id, typeName)
    end)

    if not success or not result then
        logger.logCommandActivity(interaction, {
            subcommand = 'createtype',
            success = false,
            fields = { discordUser = interaction.user, typeName = typeName },
            note = 'Forum channel creation/sync failed.'
        })
        return interaction:editReply({ content = 'Bot error saat membuat/menyinkronkan forum jenis produk. Cek permission Manage Channels bot.' })
    end

    logger.logCommandActivity(interaction, {
        subcommand = 'createtype',
        success = true,
        fields = { discordUser = interaction.user, typeName = typeName, forumChannel = result.forumChannel }
    })

    local verb = result.created and 'dibuat' or 'disinkronkan ulang'
    return interaction:editReply({
        content = string.format('Jenis produk **%s** %s. Forum: %s', typeName, verb, tostring(result.forumChannel))
    })
end

local function handleLinkType(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({ content = 'You need **Administrator** permission to do that.', ephemeral = true })
    end

    interaction:deferReply({ ephemeral = true })

    local typeName = string.match(interaction.options.nama or '', '^%s*(.-)%s*$')
    if typeName == '' then
        return interaction:editReply({ content = 'Nama jenis tidak boleh kosong.' })
    end

    local channel = interaction.options.channel
    if channel.type ~= channelType.guildForum then
        return interaction:editReply({ content = string.format('%s bukan forum channel. Pilih forum channel yang sudah ada.', tostring(channel)) })
    end

    local success, result = pcall(function()
        return products.linkExistingForumToType(interaction.guild, interaction.guild.id, typeName, channel)
    end)

    if not success or not result then
        logger.logCommandActivity(interaction, {
            subcommand = 'linktype',
            success = false,
            fields = { discordUser = interaction.user, typeName = typeName },
            note = 'Linking existing forum channel failed.'
        })
        return interaction:editReply({ content = 'Bot error saat menghubungkan jenis produk ke channel. Cek permission Manage Channels bot di channel tersebut.' })
    end

    logger.logCommandActivity(interaction, {
        subcommand = 'linktype',
        success = true,
        fields = { discordUser = interaction.user, typeName = typeName, forumChannel = result.forumChannel }
    })

    local note = result.wasExistingType
        and string.format('Jenis produk **%s** sekarang terhubung ke %s. Forum lama (kalau berbeda) tidak dihapus.', typeName, tostring(result.forumChannel))
        or string.format('Jenis produk **%s** dibuat dan dihubungkan ke %s.', typeName, tostring(result.forumChannel))

    return interaction:editReply({ content = note })
end

local function handleSendPost(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({ content = 'You need **Administrator** permission to do that.', ephemeral = true })
    end

    interaction:deferReply({ ephemeral = true })

    local productId = string.match(interaction.options.product_uuid or '', '^%s*(.-)%s*$')
    local product = products.getProduct(productId)

    if not product then
        logger.logCommandActivity(interaction, {
            subcommand = 'sendpost',
            success = false,
            fields = { discordUser = interaction.user, productId = productId },
            note = 'Product UUID not found.'
        })
        return interaction:editReply({ content = string.format('Produk dengan ID `%s` tidak ditemukan. Kalau produk ini baru dihapus, post forum-nya seharusnya sudah ikut terhapus lewat `/product delete`.', productId) })
    end

    if not product.typeForumId then
        logger.logCommandActivity(interaction, {
            subcommand = 'sendpost',
            success = false,
            fields = { discordUser = interaction.user, productId = productId },
            note = 'Product has no associated forum.'
        })
        return interaction:editReply({ content = string.format('Produk ini belum punya forum jenis yang valid. Jalankan `/product createtype` untuk jenis **%s** dulu.', product.type) })
    end

    local forumChannel = interaction.guild:getChannel(product.typeForumId)
    if not forumChannel or forumChannel.type ~= channelType.guildForum then
        logger.logCommandActivity(interaction, {
            subcommand = 'sendpost',
            success = false,
            fields = { discordUser = interaction.user, productId = productId },
            note = 'Forum channel missing.'
        })
        return interaction:editReply({ content = 'Forum untuk jenis produk ini sudah tidak ada. Jalankan `/product createtype` lagi untuk membuatnya ulang.' })
    end

    local isFree = isFreeProduct(product.price)
    local embed = {
        title = product.name,
        color = 0x00b0f4,
        fields = {
            { name = 'Harga', value = isFree and 'GRATIS' or product.price, inline = true },
            { name = 'Jenis', value = product.type, inline = true },
            { name = 'Kreator', value = product.creator, inline = true },
        }
    }

    if not isFree then
        table.insert(embed.fields, { name = 'Link File', value = product.fileLink })
    end

    local isImageUrl = string.match(product.reviewMedia or '', '%.(png|jpe?g|gif|webp)(%?.*)?$') ~= nil
    if isImageUrl then
        embed.image = { url = product.reviewMedia }
    else
        table.insert(embed.fields, { name = 'Video/Gambar Review', value = product.reviewMedia })
    end

    local downloadRow = nil
    if isFree then
        local validUrl = string.match(product.fileLink or '', '^https?://')
        if validUrl then
            downloadRow = {
                type = 1,
                components = { { type = 2, label = 'Download', style = buttonStyle.link, url = product.fileLink } }
            }
        else
            table.insert(embed.fields, { name = 'Link File', value = product.fileLink })
        end
    end

    local postContent = (isFree and product.tutorialLink and product.tutorialLink ~= '')
        and string.format('%s\n\nTutorial: %s', product.description, product.tutorialLink)
        or product.description

    local existingThread = nil
    if product.forumThreadId then
        existingThread = forumChannel:getThread(product.forumThreadId)
    end

    local thread = nil
    local wasUpdate = false

    if existingThread then
        local editOk = pcall(function()
            if existingThread.name ~= product.name then existingThread:setName(product.name) end
            local starterMessage = existingThread:getStarterMessage()
            if not starterMessage then error('No starter message') end

            starterMessage:edit({
                content = postContent,
                embeds = { embed },
                components = downloadRow and { downloadRow } or {}
            })
            thread = existingThread
            wasUpdate = true
        end)

        if not editOk then existingThread = nil end
    end

    if not existingThread then
        local createOk, err = pcall(function()
            thread = forumChannel:createThread({
                name = product.name,
                message = {
                    content = postContent,
                    embeds = { embed },
                    components = downloadRow and { downloadRow } or {}
                }
            })
        end)

        if not createOk or not thread then
            logger.logCommandActivity(interaction, {
                subcommand = 'sendpost',
                success = false,
                fields = { discordUser = interaction.user, productId = productId },
                note = 'Bot error while creating forum post.'
            })
            return interaction:editReply({ content = 'Bot error saat membuat post di forum. Cek permission bot di channel forum tersebut.' })
        end
    end

    logger.logCommandActivity(interaction, {
        subcommand = 'sendpost',
        success = true,
        fields = { discordUser = interaction.user, productId = productId, forumChannel = forumChannel },
        note = wasUpdate and 'Updated existing post in place.' or 'Created new post.'
    })

    if not wasUpdate then
        product.forumThreadId = thread.id
        pcall(function() products.saveProduct(productId, product) end)
    end

    local verb = wasUpdate and 'diperbarui' or 'diposting'
    return interaction:editReply({ content = string.format('Produk **%s** berhasil %s: %s', product.name, verb, tostring(thread)) })
end

local function handleView(interaction)
    interaction:deferReply()

    local types = products.listProductTypes(interaction.guild.id)
    table.sort(types, function(a, b) return a.name < b.name end)

    if #types == 0 then
        return interaction:editReply({ content = 'Belum ada jenis produk yang terdaftar.' })
    end

    logger.logCommandActivity(interaction, {
        subcommand = 'view',
        success = true,
        fields = { discordUser = interaction.user }
    })

    local productsCache = {}

    local function getProductsForType(typeIndex)
        local t = types[typeIndex]
        if not productsCache[t.id] then
            local pList = products.listProductsByType(interaction.guild.id, t.id)
            table.sort(pList, function(a, b) return a.name < b.name end)
            productsCache[t.id] = pList
        end
        return productsCache[t.id]
    end

    local state = { typeIndex = 1, productIndex = 1 }

    local function buildEmbed()
        local typeObj = types[state.typeIndex]
        local pList = getProductsForType(state.typeIndex)

        local embed = {
            color = 0x00b0f4,
            footer = { text = string.format('Jenis %d/%d — %s', state.typeIndex, #types, typeObj.name) }
        }

        if #pList == 0 then
            embed.title = typeObj.name
            embed.description = 'Belum ada produk di jenis ini.'
            return embed
        end

        local product = pList[state.productIndex]
        embed.title = product.name
        embed.description = product.description
        embed.fields = {
            { name = 'Harga', value = product.price, inline = true },
            { name = 'Jenis', value = product.type, inline = true },
            { name = 'Kreator', value = product.creator, inline = true },
            { name = 'ID Produk', value = '`' .. product.productId .. '`' },
        }

        local isImageUrl = string.match(product.reviewMedia or '', '%.(png|jpe?g|gif|webp)(%?.*)?$') ~= nil
        if isImageUrl then
            embed.image = { url = product.reviewMedia }
        elseif product.reviewMedia and product.reviewMedia ~= '' then
            table.insert(embed.fields, { name = 'Video/Gambar Review', value = product.reviewMedia })
        end

        embed.footer = { text = string.format('Jenis %d/%d — %s · Produk %d/%d', state.typeIndex, #types, typeObj.name, state.productIndex, #pList) }
        return embed
    end

    local function buildComponents(disabled)
        local pList = getProductsForType(state.typeIndex)
        return {
            {
                type = 1,
                components = {
                    { type = 2, custom_id = 'product_view_type_prev', label = '◀◀ Jenis', style = buttonStyle.secondary, disabled = disabled or #types <= 1 },
                    { type = 2, custom_id = 'product_view_product_prev', label = '◀ Produk', style = buttonStyle.secondary, disabled = disabled or #pList <= 1 or state.productIndex == 1 },
                    { type = 2, custom_id = 'product_view_product_next', label = 'Produk ▶', style = buttonStyle.secondary, disabled = disabled or #pList <= 1 or state.productIndex >= #pList },
                    { type = 2, custom_id = 'product_view_type_next', label = 'Jenis ▶▶', style = buttonStyle.secondary, disabled = disabled or #types <= 1 },
                }
            }
        }
    end

    local message = interaction:editReply({ embeds = { buildEmbed() }, components = buildComponents(false) })

    local collector = message:createComponentCollector({ timeout = 10 * 60 * 1000 })

    collector:on('collect', function(btnInteraction)
        if btnInteraction.user.id ~= interaction.user.id then
            return btnInteraction:reply({ content = 'Only the person who ran this command can use these buttons.', ephemeral = true })
        end

        local id = btnInteraction.custom_id
        if id == 'product_view_type_prev' then
            state.typeIndex = (state.typeIndex - 2 + #types) % #types + 1
            state.productIndex = 1
        elseif id == 'product_view_type_next' then
            state.typeIndex = state.typeIndex % #types + 1
            state.productIndex = 1
        elseif id == 'product_view_product_prev' then
            state.productIndex = math.max(1, state.productIndex - 1)
        elseif id == 'product_view_product_next' then
            local pList = getProductsForType(state.typeIndex)
            state.productIndex = math.min(#pList, state.productIndex + 1)
        end

        btnInteraction:update({ embeds = { buildEmbed() }, components = buildComponents(false) })
    end)

    collector:on('end', function()
        pcall(function() interaction:editReply({ components = buildComponents(true) }) end)
    end)
end

local function handleDelete(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({ content = 'You need **Administrator** permission to do that.', ephemeral = true })
    end

    local productId = string.match(interaction.options.product_uuid or '', '^%s*(.-)%s*$')

    local modal = {
        title = 'Confirm Delete',
        custom_id = 'product_delete_modal',
        components = {
            { type = 1, components = { { type = 4, custom_id = 'confirm_uuid', label = 'Ketik ulang UUID produk untuk konfirmasi', placeholder = productId, style = textInputStyle.short, required = true } } }
        }
    }

    interaction:showModal(modal)

    local success, modalSubmit = pcall(function()
        return interaction:awaitModalSubmit({
            filter = function(i) return i.custom_id == 'product_delete_modal' and i.user.id == interaction.user.id end,
            timeout = 2 * 60 * 1000
        })
    end)

    if not success or not modalSubmit then return end

    modalSubmit:deferReply({ ephemeral = true })

    local product = products.getProduct(productId)
    if not product then
        logger.logCommandActivity(interaction, {
            subcommand = 'delete',
            success = false,
            fields = { discordUser = interaction.user, productId = productId },
            note = 'Product UUID not found.'
        })
        return modalSubmit:editReply({ content = string.format('Produk dengan ID `%s` tidak ditemukan.', productId) })
    end

    local typed = string.match(modalSubmit.fields.confirm_uuid or '', '^%s*(.-)%s*$')
    if typed ~= productId then
        return modalSubmit:editReply({ content = string.format('UUID tidak cocok. Kamu ketik `%s`, seharusnya `%s`. Jalankan `/product delete` lagi untuk mengulang.', typed, productId) })
    end

    if product.forumThreadId and product.typeForumId then
        pcall(function()
            local forum = interaction.guild:getChannel(product.typeForumId)
            if forum then
                local thread = forum:getThread(product.forumThreadId)
                if thread then thread:delete() end
            end
        end)
    end

    local deleteOk = pcall(function() products.deleteProduct(productId) end)
    if not deleteOk then
        logger.logCommandActivity(interaction, {
            subcommand = 'delete',
            success = false,
            fields = { discordUser = interaction.user, productId = productId, productName = product.name },
            note = 'Firestore delete failed.'
        })
        return modalSubmit:editReply({ content = 'Gagal menghapus produk dari database. Coba lagi.' })
    end

    logger.logCommandActivity(interaction, {
        subcommand = 'delete',
        success = true,
        fields = { discordUser = interaction.user, productId = productId, productName = product.name }
    })

    return modalSubmit:editReply({ content = string.format('Produk **%s** (`%s`) berhasil dihapus.', product.name, productId) })
end

local function handleGive(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({ content = 'You need **Administrator** permission to do that.', ephemeral = true })
    end

    interaction:deferReply({ ephemeral = true })

    local targetUser = interaction.options.user
    local productId = string.match(interaction.options.product_uuid or '', '^%s*(.-)%s*$')

    local verifiedRecord = verification.getVerifiedUser(targetUser.id)
    if not verifiedRecord then
        logger.logCommandActivity(interaction, {
            subcommand = 'give',
            success = false,
            fields = { discordUser = interaction.user, targetUser = targetUser, productId = productId },
            note = 'Target user is not verified.'
        })
        return interaction:editReply({ content = string.format('%s belum verifikasi. Suruh mereka jalankan `/verify start` dulu.', tostring(targetUser)) })
    end

    local product = products.getProduct(productId)
    if not product then
        logger.logCommandActivity(interaction, {
            subcommand = 'give',
            success = false,
            fields = { discordUser = interaction.user, targetUser = targetUser, productId = productId },
            note = 'Product UUID not found.'
        })
        return interaction:editReply({ content = string.format('Produk dengan ID `%s` tidak ditemukan.', productId) })
    end

    if products.userOwnsProduct(product, targetUser.id) then
        logger.logCommandActivity(interaction, {
            subcommand = 'give',
            success = false,
            fields = { discordUser = interaction.user, targetUser = targetUser, productId = productId, productName = product.name },
            note = 'Target user already owns this product.'
        })
        return interaction:editReply({ content = string.format('%s sudah punya produk **%s**.', tostring(targetUser), product.name) })
    end

    local giveOk = pcall(function() products.giveProductToUser(productId, targetUser.id) end)
    if not giveOk then
        logger.logCommandActivity(interaction, {
            subcommand = 'give',
            success = false,
            fields = { discordUser = interaction.user, targetUser = targetUser, productId = productId, productName = product.name },
            note = 'Firestore write failed.'
        })
        return interaction:editReply({ content = 'Gagal memberikan produk ke database. Coba lagi.' })
    end

    logger.logCommandActivity(interaction, {
        subcommand = 'give',
        success = true,
        fields = { discordUser = interaction.user, targetUser = targetUser, productId = productId, productName = product.name }
    })

    return interaction:editReply({ content = string.format('Produk **%s** berhasil diberikan ke %s.', product.name, tostring(targetUser)) })
end

local function handleRevoke(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({ content = 'You need **Administrator** permission to do that.', ephemeral = true })
    end

    interaction:deferReply({ ephemeral = true })

    local targetUser = interaction.options.user
    local productId = string.match(interaction.options.product_uuid or '', '^%s*(.-)%s*$')

    local product = products.getProduct(productId)
    if not product then
        logger.logCommandActivity(interaction, {
            subcommand = 'revoke',
            success = false,
            fields = { discordUser = interaction.user, targetUser = targetUser, productId = productId },
            note = 'Product UUID not found.'
        })
        return interaction:editReply({ content = string.format('Produk dengan ID `%s` tidak ditemukan.', productId) })
    end

    if not products.userOwnsProduct(product, targetUser.id) then
        logger.logCommandActivity(interaction, {
            subcommand = 'revoke',
            success = false,
            fields = { discordUser = interaction.user, targetUser = targetUser, productId = productId, productName = product.name },
            note = 'Target user does not own this product.'
        })
        return interaction:editReply({ content = string.format('%s belum punya produk **%s**.', tostring(targetUser), product.name) })
    end

    local revokeOk = pcall(function() products.revokeProductFromUser(productId, targetUser.id) end)
    if not revokeOk then
        logger.logCommandActivity(interaction, {
            subcommand = 'revoke',
            success = false,
            fields = { discordUser = interaction.user, targetUser = targetUser, productId = productId, productName = product.name },
            note = 'Firestore write failed.'
        })
        return interaction:editReply({ content = 'Gagal mencabut produk dari database. Coba lagi.' })
    end

    logger.logCommandActivity(interaction, {
        subcommand = 'revoke',
        success = true,
        fields = { discordUser = interaction.user, targetUser = targetUser, productId = productId, productName = product.name }
    })

    return interaction:editReply({ content = string.format('Produk **%s** berhasil dicabut dari %s.', product.name, tostring(targetUser)) })
end

local function handleGet(interaction)
    interaction:deferReply({ ephemeral = true })

    local productId = string.match(interaction.options.product_uuid or '', '^%s*(.-)%s*$')

    local verifiedRecord = verification.getVerifiedUser(interaction.user.id)
    if not verifiedRecord then
        logger.logCommandActivity(interaction, {
            subcommand = 'get',
            success = false,
            fields = { discordUser = interaction.user, productId = productId },
            note = 'Requesting user is not verified.'
        })
        return interaction:editReply({ content = 'You are required to verified to use this command!' })
    end

    local product = products.getProduct(productId)
    if not product then
        logger.logCommandActivity(interaction, {
            subcommand = 'get',
            success = false,
            fields = { discordUser = interaction.user, productId = productId },
            note = 'Product UUID not found.'
        })
        return interaction:editReply({ content = string.format('Produk dengan ID `%s` tidak ditemukan.', productId) })
    end

    if not products.userOwnsProduct(product, interaction.user.id) then
        logger.logCommandActivity(interaction, {
            subcommand = 'get',
            success = false,
            fields = { discordUser = interaction.user, productId = productId, productName = product.name },
            note = 'Requesting user does not own this product.'
        })
        return interaction:editReply({ content = 'You didnt owned the product!' })
    end

    local sendOk = pcall(function()
        interaction.user:send(products.buildProductDeliveryDM(product))
    end)

    if not sendOk then
        logger.logCommandActivity(interaction, {
            subcommand = 'get',
            success = false,
            fields = { discordUser = interaction.user, productId = productId, productName = product.name },
            note = 'Could not DM the user.'
        })
        return interaction:editReply({ content = 'Could not DM you the file link. Please enable DMs from server members and try again.' })
    end

    logger.logCommandActivity(interaction, {
        subcommand = 'get',
        success = true,
        fields = { discordUser = interaction.user, productId = productId, productName = product.name }
    })

    return interaction:editReply({ content = 'Sent! Check your DMs 📬' })
end

return {
    name = 'product',
    description = 'Manage shop products',
    
    execute = function(interaction)
        if not interaction.guild then
            return interaction:reply({ content = 'This command only works inside a server.', ephemeral = true })
        end

        local sub = interaction.options.subcommand

        if sub == 'create' then return handleCreate(interaction)
        elseif sub == 'createtype' then return handleCreateType(interaction)
        elseif sub == 'linktype' then return handleLinkType(interaction)
        elseif sub == 'sendpost' then return handleSendPost(interaction)
        elseif sub == 'edit' then return handleEdit(interaction)
        elseif sub == 'view' then return handleView(interaction)
        elseif sub == 'delete' then return handleDelete(interaction)
        elseif sub == 'give' then return handleGive(interaction)
        elseif sub == 'revoke' then return handleRevoke(interaction)
        elseif sub == 'get' then return handleGet(interaction)
        end
    end,

    autocomplete = function(interaction)
        local sub = interaction.options.subcommand
        if sub == 'get' then
            return autocompleteGetProductUuid(interaction)
        end
        return interaction:respond({})
    end
}
