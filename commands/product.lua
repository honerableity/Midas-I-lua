local uuid = require("uuid")
local logger = require("../utils/logger")
local products = require("../utils/products")
local verification = require("../utils/verification")

-- 15 minutes in milliseconds
local STEP_TIMEOUT_MS = 15 * 60 * 1000
local MAX_SELECT_OPTIONS = 25

-- Discord Channel Types
local CHANNEL_TYPE_GUILD_FORUM = 15

-- Discord Component & Style Enums
local BUTTON_STYLE_PRIMARY = 1
local BUTTON_STYLE_SECONDARY = 2
local BUTTON_STYLE_LINK = 5

local TEXT_INPUT_STYLE_SHORT = 1
local TEXT_INPUT_STYLE_PARAGRAPH = 2

-------------------------------------------------------------------------------
-- Helper Functions
-------------------------------------------------------------------------------

local function trim(str)
    if not str then return "" end
    return str:match("^%s*(.-)%s*$")
end

local function requireAdmin(interaction)
    if not interaction.member or not interaction.member.permissions then
        return false
    end
    -- Check for Administrator permission bit set
    return interaction.member.permissions:has("administrator")
end

-- Price is free-typed text ("25000", "Rp25.000", "0", "Free", ...).
local function isFreeProduct(price)
    local normalized = trim(tostring(price or "")):lower()
    return normalized == "0" or normalized == "free"
end

local function isDirectImageUrl(url)
    if not url then return false end
    return url:lower():match("%.(png|jpe?g|gif|webp)(%?.*)?$") ~= nil
end

-------------------------------------------------------------------------------
-- Command Module Definition
-------------------------------------------------------------------------------

local Command = {}

Command.data = {
    name = "product",
    description = "Manage shop products",
    options = {
        {
            type = 1,
            name = "create",
            description = "Create a new product listing",
        },
        {
            type = 1,
            name = "createtype",
            description = "Create (or re-sync) a product type and its dedicated forum channel",
            options = {
                {
                    type = 3,
                    name = "nama",
                    description = "Nama jenis produk",
                    required = true,
                }
            }
        },
        {
            type = 1,
            name = "linktype",
            description = "Link a product type to an already-existing forum channel",
            options = {
                {
                    type = 3,
                    name = "nama",
                    description = "Nama jenis produk",
                    required = true,
                },
                {
                    type = 7,
                    name = "channel",
                    description = "Existing forum channel to link",
                    required = true,
                    channel_types = { CHANNEL_TYPE_GUILD_FORUM }
                }
            }
        },
        {
            type = 1,
            name = "sendpost",
            description = "Post a product to its type's forum channel",
            options = {
                {
                    type = 3,
                    name = "product_uuid",
                    description = "ID produk (UUID)",
                    required = true,
                }
            }
        },
        {
            type = 1,
            name = "edit",
            description = "Edit an existing product listing",
            options = {
                {
                    type = 3,
                    name = "product_uuid",
                    description = "ID produk (UUID)",
                    required = true,
                }
            }
        },
        {
            type = 1,
            name = "view",
            description = "Browse all products by type",
        },
        {
            type = 1,
            name = "delete",
            description = "Delete a product",
            options = {
                {
                    type = 3,
                    name = "product_uuid",
                    description = "ID produk (UUID)",
                    required = true,
                }
            }
        },
        {
            type = 1,
            name = "give",
            description = "Give a product to a verified user",
            options = {
                {
                    type = 6,
                    name = "user",
                    description = "Target user",
                    required = true,
                },
                {
                    type = 3,
                    name = "product_uuid",
                    description = "ID produk (UUID)",
                    required = true,
                }
            }
        },
        {
            type = 1,
            name = "revoke",
            description = "Revoke a product from a user",
            options = {
                {
                    type = 6,
                    name = "user",
                    description = "Target user",
                    required = true,
                },
                {
                    type = 3,
                    name = "product_uuid",
                    description = "ID produk (UUID)",
                    required = true,
                }
            }
        },
        {
            type = 1,
            name = "get",
            description = "Get the file link of a product you own, sent to your DM",
            options = {
                {
                    type = 3,
                    name = "product_uuid",
                    description = "ID produk (UUID)",
                    required = true,
                    autocomplete = true,
                }
            }
        }
    }
}

Command.logSchema = {
    subcommands = {
        create = { label = "Product — Created", fields = { "discordUser", "productId", "productName" } },
        createtype = { label = "Product — Type Created", fields = { "discordUser", "typeName", "forumChannel" } },
        linktype = { label = "Product — Type Linked", fields = { "discordUser", "typeName", "forumChannel" } },
        sendpost = { label = "Product — Post Sent", fields = { "discordUser", "productId", "forumChannel" } },
        edit = { label = "Product — Edited", fields = { "discordUser", "productId", "productName" } },
        view = { label = "Product — Browsed", fields = { "discordUser" } },
        delete = { label = "Product — Deleted", fields = { "discordUser", "productId", "productName" } },
        give = { label = "Product — Given", fields = { "discordUser", "targetUser", "productId", "productName" } },
        revoke = { label = "Product — Revoked", fields = { "discordUser", "targetUser", "productId", "productName" } },
        get = { label = "Product — File Link Requested", fields = { "discordUser", "productId", "productName" } },
    }
}

-------------------------------------------------------------------------------
-- Subcommand Handlers
-------------------------------------------------------------------------------

local function handleCreate(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({
            content = "You need **Administrator** permission to do that.",
            ephemeral = true
        })
    end

    local modal1 = {
        custom_id = "product_create_modal_1",
        title = "New Product (1/2)",
        components = {
            {
                type = 1,
                components = {
                    {
                        type = 4,
                        custom_id = "product_name",
                        label = "Nama produk",
                        style = TEXT_INPUT_STYLE_SHORT,
                        required = true
                    }
                }
            },
            {
                type = 1,
                components = {
                    {
                        type = 4,
                        custom_id = "product_description",
                        label = "Deskripsi",
                        style = TEXT_INPUT_STYLE_PARAGRAPH,
                        required = true
                    }
                }
            },
            {
                type = 1,
                components = {
                    {
                        type = 4,
                        custom_id = "product_price",
                        label = "Harga",
                        placeholder = "cth: 25000 atau Rp25.000",
                        style = TEXT_INPUT_STYLE_SHORT,
                        required = true
                    }
                }
            },
            {
                type = 1,
                components = {
                    {
                        type = 4,
                        custom_id = "product_creator",
                        label = "Kreator (kosongkan jika kamu sendiri)",
                        style = TEXT_INPUT_STYLE_SHORT,
                        required = false
                    }
                }
            }
        }
    }

    interaction:showModal(modal1)

    local success1, modal1Submit = pcall(function()
        return interaction:awaitModalSubmit({
            time = STEP_TIMEOUT_MS,
            filter = function(i)
                return i.custom_id == "product_create_modal_1" and i.user.id == interaction.user.id
            end
        })
    end)

    if not success1 or not modal1Submit then return end

    local productName = trim(modal1Submit:getInputValue("product_name"))
    local productDescription = trim(modal1Submit:getInputValue("product_description"))
    local productPrice = trim(modal1Submit:getInputValue("product_price"))
    local productCreatorRaw = trim(modal1Submit:getInputValue("product_creator"))
    local productCreator = #productCreatorRaw > 0 and productCreatorRaw or interaction.user.username

    modal1Submit:reply({
        content = "Langkah 1 tersimpan. Klik tombol di bawah buat lanjut ke langkah 2.",
        components = {
            {
                type = 1,
                components = {
                    {
                        type = 2,
                        custom_id = "product_create_continue",
                        label = "Lanjutkan (2/2)",
                        style = BUTTON_STYLE_PRIMARY
                    }
                }
            }
        },
        ephemeral = true
    })

    local successBtn, btnInteraction = pcall(function()
        return modal1Submit.channel:awaitComponent({
            time = STEP_TIMEOUT_MS,
            filter = function(i)
                return i.custom_id == "product_create_continue" and i.user.id == interaction.user.id
            end
        })
    end)

    if not successBtn or not btnInteraction then
        pcall(function()
            modal1Submit:editReply({ content = "Waktu habis. Jalankan `/product create` lagi.", components = {} })
        end)
        return
    end

    local modal2 = {
        custom_id = "product_create_modal_2",
        title = "New Product (2/2)",
        components = {
            {
                type = 1,
                components = {
                    {
                        type = 4,
                        custom_id = "product_file_link",
                        label = "Link file produk",
                        placeholder = "CDN Discord, catbox.moe, Drive, Mega.nz, dll",
                        style = TEXT_INPUT_STYLE_SHORT,
                        required = true
                    }
                }
            },
            {
                type = 1,
                components = {
                    {
                        type = 4,
                        custom_id = "product_review_media",
                        label = "Video/Gambar Review Produk",
                        placeholder = "Link video atau gambar review",
                        style = TEXT_INPUT_STYLE_SHORT,
                        required = true
                    }
                }
            },
            {
                type = 1,
                components = {
                    {
                        type = 4,
                        custom_id = "product_tutorial_link",
                        label = "Link Tutorial (opsional)",
                        placeholder = "Link tutorial cara pakai produk, boleh kosong",
                        style = TEXT_INPUT_STYLE_SHORT,
                        required = false
                    }
                }
            }
        }
    }

    btnInteraction:showModal(modal2)

    local success2, modal2Submit = pcall(function()
        return btnInteraction:awaitModalSubmit({
            time = STEP_TIMEOUT_MS,
            filter = function(i)
                return i.custom_id == "product_create_modal_2" and i.user.id == interaction.user.id
            end
        })
    end)

    if not success2 or not modal2Submit then return end

    local productFileLink = trim(modal2Submit:getInputValue("product_file_link"))
    local productReviewMedia = trim(modal2Submit:getInputValue("product_review_media"))
    local productTutorialLink = trim(modal2Submit:getInputValue("product_tutorial_link"))

    modal2Submit:deferReply({ ephemeral = true })

    local types = products.listProductTypes(interaction.guild_id)
    if #types == 0 then
        return modal2Submit:editReply({
            content = "Belum ada jenis produk yang terdaftar. Minta admin jalankan `/product createtype` dulu, baru ulangi `/product create`."
        })
    end

    local options = {}
    for i = 1, math.min(#types, MAX_SELECT_OPTIONS) do
        table.insert(options, { label = types[i].name, value = types[i].id })
    end

    modal2Submit:editReply({
        content = "Terakhir, pilih jenis produk:",
        components = {
            {
                type = 1,
                components = {
                    {
                        type = 3,
                        custom_id = "product_create_type_select",
                        placeholder = "Pilih jenis produk",
                        options = options
                    }
                }
            }
        }
    })

    local successSelect, typeSelectInteraction = pcall(function()
        return modal2Submit.channel:awaitComponent({
            time = STEP_TIMEOUT_MS,
            filter = function(i)
                return i.custom_id == "product_create_type_select" and i.user.id == interaction.user.id
            end
        })
    end)

    if not successSelect or not typeSelectInteraction then
        pcall(function()
            modal2Submit:editReply({ content = "Waktu habis memilih jenis. Jalankan `/product create` lagi.", components = {} })
        end)
        return
    end

    local selectedTypeId = typeSelectInteraction.values[1]
    local selectedType
    for _, t in ipairs(types) do
        if t.id == selectedTypeId then
            selectedType = t
            break
        end
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
        guildId = interaction.guild_id,
        createdAt = os.time() * 1000
    }

    local saveOk = pcall(function()
        products.saveProduct(productId, productData)
    end)

    if not saveOk then
        logger.logCommandActivity(interaction, {
            subcommand = "create",
            success = false,
            fields = { discordUser = interaction.user, productName = productName },
            note = "Firestore write failed."
        })
        return modal2Submit:editReply({ content = "Gagal menyimpan produk ke database. Coba lagi.", components = {} })
    end

    logger.logCommandActivity(interaction, {
        subcommand = "create",
        success = true,
        fields = { discordUser = interaction.user, productId = productId, productName = productName }
    })

    local embed = {
        title = "Produk Berhasil Dibuat",
        color = 0x57f287,
        fields = {
            { name = "Nama Produk", value = productName },
            { name = "ID Produk", value = "`" .. productId .. "`" },
            { name = "Jenis", value = selectedType.name, inline = true },
            { name = "Harga", value = productPrice, inline = true },
            { name = "Kreator", value = productCreator, inline = true }
        }
    }

    return modal2Submit:editReply({ content = "Produk berhasil dibuat!", embeds = { embed }, components = {} })
end

local function handleCreateType(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({ content = "You need **Administrator** permission to do that.", ephemeral = true })
    end

    interaction:deferReply({ ephemeral = true })

    local typeName = trim(interaction:getOption("nama"))
    if #typeName == 0 then
        return interaction:editReply({ content = "Nama jenis tidak boleh kosong." })
    end

    local ok, result = pcall(function()
        return products.createOrSyncProductTypeForum(interaction.guild, interaction.guild_id, typeName)
    end)

    if not ok or not result then
        logger.logCommandActivity(interaction, {
            subcommand = "createtype",
            success = false,
            fields = { discordUser = interaction.user, typeName = typeName },
            note = "Forum channel creation/sync failed."
        })
        return interaction:editReply({ content = "Bot error saat membuat/menyinkronkan forum jenis produk. Cek permission Manage Channels bot." })
    end

    logger.logCommandActivity(interaction, {
        subcommand = "createtype",
        success = true,
        fields = { discordUser = interaction.user, typeName = typeName, forumChannel = result.forumChannel }
    })

    local verb = result.created and "dibuat" or "disinkronkan ulang"
    return interaction:editReply({
        content = string.format("Jenis produk **%s** %s. Forum: %s", typeName, verb, tostring(result.forumChannel))
    })
end

local function handleLinkType(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({ content = "You need **Administrator** permission to do that.", ephemeral = true })
    end

    interaction:deferReply({ ephemeral = true })

    local typeName = trim(interaction:getOption("nama"))
    if #typeName == 0 then
        return interaction:editReply({ content = "Nama jenis tidak boleh kosong." })
    end

    local channel = interaction:getOption("channel")
    if channel.type ~= CHANNEL_TYPE_GUILD_FORUM then
        return interaction:editReply({ content = tostring(channel) .. " bukan forum channel. Pilih forum channel yang sudah ada." })
    end

    local ok, result = pcall(function()
        return products.linkExistingForumToType(interaction.guild, interaction.guild_id, typeName, channel)
    end)

    if not ok or not result then
        logger.logCommandActivity(interaction, {
            subcommand = "linktype",
            success = false,
            fields = { discordUser = interaction.user, typeName = typeName },
            note = "Linking existing forum channel failed."
        })
        return interaction:editReply({ content = "Bot error saat menghubungkan jenis produk ke channel. Cek permission Manage Channels bot di channel tersebut." })
    end

    logger.logCommandActivity(interaction, {
        subcommand = "linktype",
        success = true,
        fields = { discordUser = interaction.user, typeName = typeName, forumChannel = result.forumChannel }
    })

    local note = result.wasExistingType
        and string.format("Jenis produk **%s** sekarang terhubung ke %s. Forum lama (kalau berbeda) tidak dihapus.", typeName, tostring(result.forumChannel))
        or string.format("Jenis produk **%s** dibuat dan dihubungkan ke %s.", typeName, tostring(result.forumChannel))

    return interaction:editReply({ content = note })
end

local function handleSendPost(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({ content = "You need **Administrator** permission to do that.", ephemeral = true })
    end

    interaction:deferReply({ ephemeral = true })

    local productId = trim(interaction:getOption("product_uuid"))
    local product = products.getProduct(productId)

    if not product then
        logger.logCommandActivity(interaction, {
            subcommand = "sendpost",
            success = false,
            fields = { discordUser = interaction.user, productId = productId },
            note = "Product UUID not found."
        })
        return interaction:editReply({ content = string.format("Produk dengan ID `%s` tidak ditemukan.", productId) })
    end

    if not product.typeForumId then
        logger.logCommandActivity(interaction, {
            subcommand = "sendpost",
            success = false,
            fields = { discordUser = interaction.user, productId = productId },
            note = "Product has no associated forum."
        })
        return interaction:editReply({ content = string.format("Produk ini belum punya forum jenis yang valid. Jalankan `/product createtype` untuk jenis **%s** dulu.", product.type) })
    end

    local forumChannel = interaction.guild:getChannel(product.typeForumId)
    if not forumChannel or forumChannel.type ~= CHANNEL_TYPE_GUILD_FORUM then
        logger.logCommandActivity(interaction, {
            subcommand = "sendpost",
            success = false,
            fields = { discordUser = interaction.user, productId = productId },
            note = "Forum channel missing."
        })
        return interaction:editReply({ content = "Forum untuk jenis produk ini sudah tidak ada. Jalankan `/product createtype` lagi untuk membuatnya ulang." })
    end

    local isFree = isFreeProduct(product.price)
    local embed = {
        title = product.name,
        color = 0x00b0f4,
        fields = {
            { name = "Harga", value = isFree and "GRATIS" or product.price, inline = true },
            { name = "Jenis", value = product.type, inline = true },
            { name = "Kreator", value = product.creator, inline = true },
        }
    }

    if not isFree then
        table.insert(embed.fields, { name = "Link File", value = product.fileLink })
    end

    if isDirectImageUrl(product.reviewMedia) then
        embed.image = { url = product.reviewMedia }
    else
        table.insert(embed.fields, { name = "Video/Gambar Review", value = product.reviewMedia })
    end

    local components = {}
    if isFree then
        local btnOk, downloadButton = pcall(function()
            return {
                type = 1,
                components = {
                    {
                        type = 2,
                        label = "Download",
                        style = BUTTON_STYLE_LINK,
                        url = product.fileLink
                    }
                }
            }
        end)
        if btnOk then
            table.insert(components, downloadButton)
        else
            table.insert(embed.fields, { name = "Link File", value = product.fileLink })
        end
    end

    local postContent = (isFree and product.tutorialLink and #product.tutorialLink > 0)
        and string.format("%s\n\nTutorial: %s", product.description, product.tutorialLink)
        or product.description

    local existingThread = nil
    if product.forumThreadId then
        existingThread = forumChannel:getThread(product.forumThreadId)
    end

    local thread = nil
    local wasUpdate = false

    if existingThread then
        local updateOk = pcall(function()
            if existingThread.name ~= product.name then
                existingThread:setName(product.name)
            end
            local starterMessage = existingThread:getStarterMessage()
            if not starterMessage then error("No starter message") end
            starterMessage:edit({ content = postContent, embeds = { embed }, components = components })
            thread = existingThread
            wasUpdate = true
        end)
        if not updateOk then existingThread = nil end
    end

    if not existingThread then
        local createOk, newThread = pcall(function()
            return forumChannel:createThread({
                name = product.name,
                message = {
                    content = postContent,
                    embeds = { embed },
                    components = components
                }
            })
        end)

        if not createOk or not newThread then
            logger.logCommandActivity(interaction, {
                subcommand = "sendpost",
                success = false,
                fields = { discordUser = interaction.user, productId = productId },
                note = "Bot error while creating forum post."
            })
            return interaction:editReply({ content = "Bot error saat membuat post di forum. Cek permission bot di channel forum tersebut." })
        end
        thread = newThread
    end

    logger.logCommandActivity(interaction, {
        subcommand = "sendpost",
        success = true,
        fields = { discordUser = interaction.user, productId = productId, forumChannel = forumChannel },
        note = wasUpdate and "Updated existing post in place." or "Created new post."
    })

    if not wasUpdate then
        pcall(function()
            product.forumThreadId = thread.id
            products.saveProduct(productId, product)
        end)
    end

    local verb = wasUpdate and "diperbarui" or "diposting"
    return interaction:editReply({ content = string.format("Produk **%s** berhasil %s: %s", product.name, verb, tostring(thread)) })
end

local function handleEdit(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({ content = "You need **Administrator** permission to do that.", ephemeral = true })
    end

    local productId = trim(interaction:getOption("product_uuid"))
    local product = products.getProduct(productId)

    if not product then
        logger.logCommandActivity(interaction, {
            subcommand = "edit",
            success = false,
            fields = { discordUser = interaction.user, productId = productId },
            note = "Product UUID not found."
        })
        return interaction:reply({ content = string.format("Produk dengan ID `%s` tidak ditemukan.", productId), ephemeral = true })
    end

    local modal1 = {
        custom_id = "product_edit_modal_1",
        title = "Edit Product (1/2)",
        components = {
            { type = 1, components = { { type = 4, custom_id = "product_name", label = "Nama produk", style = TEXT_INPUT_STYLE_SHORT, value = product.name, required = true } } },
            { type = 1, components = { { type = 4, custom_id = "product_description", label = "Deskripsi", style = TEXT_INPUT_STYLE_PARAGRAPH, value = product.description, required = true } } },
            { type = 1, components = { { type = 4, custom_id = "product_price", label = "Harga", placeholder = "cth: 25000 atau Rp25.000", style = TEXT_INPUT_STYLE_SHORT, value = product.price, required = true } } },
            { type = 1, components = { { type = 4, custom_id = "product_creator", label = "Kreator (kosongkan jika kamu sendiri)", style = TEXT_INPUT_STYLE_SHORT, value = product.creator or "", required = false } } },
        }
    }

    interaction:showModal(modal1)

    local success1, modal1Submit = pcall(function()
        return interaction:awaitModalSubmit({
            time = STEP_TIMEOUT_MS,
            filter = function(i) return i.custom_id == "product_edit_modal_1" and i.user.id == interaction.user.id end
        })
    end)

    if not success1 or not modal1Submit then return end

    local productName = trim(modal1Submit:getInputValue("product_name"))
    local productDescription = trim(modal1Submit:getInputValue("product_description"))
    local productPrice = trim(modal1Submit:getInputValue("product_price"))
    local productCreatorRaw = trim(modal1Submit:getInputValue("product_creator"))
    local productCreator = #productCreatorRaw > 0 and productCreatorRaw or interaction.user.username

    modal1Submit:reply({
        content = "Langkah 1 tersimpan. Klik tombol di bawah buat lanjut ke langkah 2.",
        components = {
            { type = 1, components = { { type = 2, custom_id = "product_edit_continue", label = "Lanjutkan (2/2)", style = BUTTON_STYLE_PRIMARY } } }
        },
        ephemeral = true
    })

    local successBtn, btnInteraction = pcall(function()
        return modal1Submit.channel:awaitComponent({
            time = STEP_TIMEOUT_MS,
            filter = function(i) return i.custom_id == "product_edit_continue" and i.user.id == interaction.user.id end
        })
    end)

    if not successBtn or not btnInteraction then
        pcall(function() modal1Submit:editReply({ content = string.format("Waktu habis. Jalankan `/product edit %s` lagi.", productId), components = {} }) end)
        return
    end

    local modal2 = {
        custom_id = "product_edit_modal_2",
        title = "Edit Product (2/2)",
        components = {
            { type = 1, components = { { type = 4, custom_id = "product_file_link", label = "Link file produk", style = TEXT_INPUT_STYLE_SHORT, value = product.fileLink, required = true } } },
            { type = 1, components = { { type = 4, custom_id = "product_review_media", label = "Video/Gambar Review Produk", style = TEXT_INPUT_STYLE_SHORT, value = product.reviewMedia or "", required = true } } },
            { type = 1, components = { { type = 4, custom_id = "product_tutorial_link", label = "Link Tutorial (opsional)", style = TEXT_INPUT_STYLE_SHORT, value = product.tutorialLink or "", required = false } } },
        }
    }

    btnInteraction:showModal(modal2)

    local success2, modal2Submit = pcall(function()
        return btnInteraction:awaitModalSubmit({
            time = STEP_TIMEOUT_MS,
            filter = function(i) return i.custom_id == "product_edit_modal_2" and i.user.id == interaction.user.id end
        })
    end)

    if not success2 or not modal2Submit then return end

    local productFileLink = trim(modal2Submit:getInputValue("product_file_link"))
    local productReviewMedia = trim(modal2Submit:getInputValue("product_review_media"))
    local productTutorialLink = trim(modal2Submit:getInputValue("product_tutorial_link"))

    modal2Submit:deferReply({ ephemeral = true })

    local types = products.listProductTypes(interaction.guild_id)
    if #types == 0 then
        return modal2Submit:editReply({ content = "Belum ada jenis produk yang terdaftar. Minta admin jalankan `/product createtype` dulu." })
    end

    local selectOptions = {}
    for i = 1, math.min(#types, MAX_SELECT_OPTIONS) do
        table.insert(selectOptions, {
            label = types[i].name,
            value = types[i].id,
            default = (types[i].id == product.typeId)
        })
    end

    modal2Submit:editReply({
        content = "Terakhir, pilih jenis produk (atau klik tombol untuk tetap pakai jenis saat ini):",
        components = {
            { type = 1, components = { { type = 3, custom_id = "product_edit_type_select", placeholder = "Pilih jenis produk", options = selectOptions } } },
            { type = 1, components = { { type = 2, custom_id = "product_edit_keep_type", label = string.format('Simpan dengan jenis "%s"', product.type), style = BUTTON_STYLE_SECONDARY } } }
        }
    })

    local selectedTypeId = nil
    local ackInteraction = nil

    local successType, compInteraction = pcall(function()
        return modal2Submit.channel:awaitComponent({
            time = STEP_TIMEOUT_MS,
            filter = function(i)
                return (i.custom_id == "product_edit_type_select" or i.custom_id == "product_edit_keep_type") and i.user.id == interaction.user.id
            end
        })
    end)

    if not successType or not compInteraction then
        pcall(function() modal2Submit:editReply({ content = string.format("Waktu habis memilih jenis. Jalankan `/product edit %s` lagi.", productId), components = {} }) end)
        return
    end

    ackInteraction = compInteraction
    selectedTypeId = (compInteraction.custom_id == "product_edit_keep_type") and product.typeId or compInteraction.values[1]

    local selectedType
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
        updatedAt = os.time() * 1000
    }

    local saveOk = pcall(function() products.saveProduct(productId, updatedData) end)

    if not saveOk then
        logger.logCommandActivity(interaction, {
            subcommand = "edit",
            success = false,
            fields = { discordUser = interaction.user, productId = productId, productName = productName },
            note = "Firestore write failed."
        })
        return modal2Submit:editReply({ content = "Gagal menyimpan perubahan produk ke database. Coba lagi.", components = {} })
    end

    logger.logCommandActivity(interaction, {
        subcommand = "edit",
        success = true,
        fields = { discordUser = interaction.user, productId = productId, productName = productName }
    })

    local embed = {
        title = "Produk Berhasil Diedit",
        color = 0x57f287,
        fields = {
            { name = "Nama Produk", value = productName },
            { name = "ID Produk", value = "`" .. productId .. "`" },
            { name = "Jenis", value = selectedType.name, inline = true },
            { name = "Harga", value = productPrice, inline = true },
            { name = "Kreator", value = productCreator, inline = true },
        }
    }

    local postNote = updatedData.forumThreadId and " Jalankan `/product sendpost` untuk update post forum-nya juga." or ""
    return modal2Submit:editReply({ content = "Produk berhasil diedit!" .. postNote, embeds = { embed }, components = {} })
end

local function handleView(interaction)
    interaction:deferReply()

    local types = products.listProductTypes(interaction.guild_id)
    table.sort(types, function(a, b) return a.name:lower() < b.name:lower() end)

    if #types == 0 then
        return interaction:editReply({ content = "Belum ada jenis produk yang terdaftar." })
    end

    logger.logCommandActivity(interaction, {
        subcommand = "view",
        success = true,
        fields = { discordUser = interaction.user }
    })

    local productsByTypeCache = {}
    local function getProductsForType(typeIndex)
        local typeObj = types[typeIndex]
        if not productsByTypeCache[typeObj.id] then
            local prods = products.listProductsByType(interaction.guild_id, typeObj.id)
            table.sort(prods, function(a, b) return a.name:lower() < b.name:lower() end)
            productsByTypeCache[typeObj.id] = prods
        end
        return productsByTypeCache[typeObj.id]
    end

    local state = { typeIndex = 1, productIndex = 1 }

    local function buildEmbed()
        local typeObj = types[state.typeIndex]
        local prods = getProductsForType(state.typeIndex)

        if #prods == 0 then
            return {
                title = typeObj.name,
                description = "Belum ada produk di jenis ini.",
                color = 0x00b0f4,
                footer = { text = string.format("Jenis %d/%d — %s", state.typeIndex, #types, typeObj.name) }
            }
        end

        local p = prods[state.productIndex]
        local embed = {
            title = p.name,
            description = p.description,
            color = 0x00b0f4,
            fields = {
                { name = "Harga", value = p.price, inline = true },
                { name = "Jenis", value = p.type, inline = true },
                { name = "Kreator", value = p.creator, inline = true },
                { name = "ID Produk", value = "`" .. p.productId .. "`" }
            },
            footer = {
                text = string.format("Jenis %d/%d — %s · Produk %d/%d", state.typeIndex, #types, typeObj.name, state.productIndex, #prods)
            }
        }

        if isDirectImageUrl(p.reviewMedia) then
            embed.image = { url = p.reviewMedia }
        elseif p.reviewMedia and #p.reviewMedia > 0 then
            table.insert(embed.fields, { name = "Video/Gambar Review", value = p.reviewMedia })
        end

        return embed
    end

    local function buildComponents(disabled)
        disabled = disabled or false
        local prods = getProductsForType(state.typeIndex)

        return {
            {
                type = 1,
                components = {
                    { type = 2, custom_id = "product_view_type_prev", label = "◀◀ Jenis", style = BUTTON_STYLE_SECONDARY, disabled = disabled or (#types <= 1) },
                    { type = 2, custom_id = "product_view_product_prev", label = "◀ Produk", style = BUTTON_STYLE_SECONDARY, disabled = disabled or (#prods <= 1 or state.productIndex == 1) },
                    { type = 2, custom_id = "product_view_product_next", label = "Produk ▶", style = BUTTON_STYLE_SECONDARY, disabled = disabled or (#prods <= 1 or state.productIndex >= #prods) },
                    { type = 2, custom_id = "product_view_type_next", label = "Jenis ▶▶", style = BUTTON_STYLE_SECONDARY, disabled = disabled or (#types <= 1) },
                }
            }
        }
    end

    local message = interaction:editReply({ embeds = { buildEmbed() }, components = buildComponents() })
    local collector = message:createComponentCollector({ time = 10 * 60 * 1000 })

    collector:on("collect", function(btnInteraction)
        if btnInteraction.user.id ~= interaction.user.id then
            return btnInteraction:reply({ content = "Only the person who ran this command can use these buttons.", ephemeral = true })
        end

        if btnInteraction.custom_id == "product_view_type_prev" then
            state.typeIndex = ((state.typeIndex - 2 + #types) % #types) + 1
            state.productIndex = 1
        elseif btnInteraction.custom_id == "product_view_type_next" then
            state.typeIndex = (state.typeIndex % #types) + 1
            state.productIndex = 1
        elseif btnInteraction.custom_id == "product_view_product_prev" then
            state.productIndex = math.max(1, state.productIndex - 1)
        elseif btnInteraction.custom_id == "product_view_product_next" then
            local prods = getProductsForType(state.typeIndex)
            state.productIndex = math.min(#prods, state.productIndex + 1)
        end

        btnInteraction:update({ embeds = { buildEmbed() }, components = buildComponents() })
    end)

    collector:on("end", function()
        pcall(function()
            interaction:editReply({ components = buildComponents(true) })
        end)
    end)
end

local function handleDelete(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({ content = "You need **Administrator** permission to do that.", ephemeral = true })
    end

    local productId = trim(interaction:getOption("product_uuid"))

    local modal = {
        custom_id = "product_delete_modal",
        title = "Confirm Delete",
        components = {
            {
                type = 1,
                components = {
                    {
                        type = 4,
                        custom_id = "confirm_uuid",
                        label = "Ketik ulang UUID produk untuk konfirmasi",
                        placeholder = productId,
                        style = TEXT_INPUT_STYLE_SHORT,
                        required = true
                    }
                }
            }
        }
    }

    interaction:showModal(modal)

    local successModal, modalSubmit = pcall(function()
        return interaction:awaitModalSubmit({
            time = 2 * 60 * 1000,
            filter = function(i) return i.custom_id == "product_delete_modal" and i.user.id == interaction.user.id end
        })
    end)

    if not successModal or not modalSubmit then return end

    modalSubmit:deferReply({ ephemeral = true })

    local product = products.getProduct(productId)
    if not product then
        logger.logCommandActivity(interaction, {
            subcommand = "delete",
            success = false,
            fields = { discordUser = interaction.user, productId = productId },
            note = "Product UUID not found."
        })
        return modalSubmit:editReply({ content = string.format("Produk dengan ID `%s` tidak ditemukan.", productId) })
    end

    local typed = trim(modalSubmit:getInputValue("confirm_uuid"))
    if typed ~= productId then
        return modalSubmit:editReply({
            content = string.format("UUID tidak cocok. Kamu ketik `%s`, seharusnya `%s`. Jalankan `/product delete` lagi untuk mengulang.", typed, productId)
        })
    end

    if product.forumThreadId and product.typeForumId then
        pcall(function()
            local forumChannel = interaction.guild:getChannel(product.typeForumId)
            if forumChannel then
                local thread = forumChannel:getThread(product.forumThreadId)
                if thread then thread:delete() end
            end
        end)
    end

    local deleteOk = pcall(function() products.deleteProduct(productId) end)
    if not deleteOk then
        logger.logCommandActivity(interaction, {
            subcommand = "delete",
            success = false,
            fields = { discordUser = interaction.user, productId = productId, productName = product.name },
            note = "Firestore delete failed."
        })
        return modalSubmit:editReply({ content = "Gagal menghapus produk dari database. Coba lagi." })
    end

    logger.logCommandActivity(interaction, {
        subcommand = "delete",
        success = true,
        fields = { discordUser = interaction.user, productId = productId, productName = product.name }
    })

    return modalSubmit:editReply({ content = string.format("Produk **%s** (`%s`) berhasil dihapus.", product.name, productId) })
end

local function handleGive(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({ content = "You need **Administrator** permission to do that.", ephemeral = true })
    end

    interaction:deferReply({ ephemeral = true })

    local targetUser = interaction:getOption("user")
    local productId = trim(interaction:getOption("product_uuid"))

    local verifiedRecord = verification.getVerifiedUser(targetUser.id)
    if not verifiedRecord then
        logger.logCommandActivity(interaction, {
            subcommand = "give",
            success = false,
            fields = { discordUser = interaction.user, targetUser = targetUser, productId = productId },
            note = "Target user is not verified."
        })
        return interaction:editReply({ content = string.format("%s belum verifikasi. Suruh mereka jalankan `/verify start` dulu.", tostring(targetUser)) })
    end

    local product = products.getProduct(productId)
    if not product then
        logger.logCommandActivity(interaction, {
            subcommand = "give",
            success = false,
            fields = { discordUser = interaction.user, targetUser = targetUser, productId = productId },
            note = "Product UUID not found."
        })
        return interaction:editReply({ content = string.format("Produk dengan ID `%s` tidak ditemukan.", productId) })
    end

    if products.userOwnsProduct(product, targetUser.id) then
        logger.logCommandActivity(interaction, {
            subcommand = "give",
            success = false,
            fields = { discordUser = interaction.user, targetUser = targetUser, productId = productId, productName = product.name },
            note = "Target user already owns this product."
        })
        return interaction:editReply({ content = string.format("%s sudah punya produk **%s**.", tostring(targetUser), product.name) })
    end

    local giveOk = pcall(function() products.giveProductToUser(productId, targetUser.id) end)
    if not giveOk then
        logger.logCommandActivity(interaction, {
            subcommand = "give",
            success = false,
            fields = { discordUser = interaction.user, targetUser = targetUser, productId = productId, productName = product.name },
            note = "Firestore write failed."
        })
        return interaction:editReply({ content = "Gagal memberikan produk ke database. Coba lagi." })
    end

    logger.logCommandActivity(interaction, {
        subcommand = "give",
        success = true,
        fields = { discordUser = interaction.user, targetUser = targetUser, productId = productId, productName = product.name }
    })

    return interaction:editReply({ content = string.format("Produk **%s** berhasil diberikan ke %s.", product.name, tostring(targetUser)) })
end

local function handleRevoke(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({ content = "You need **Administrator** permission to do that.", ephemeral = true })
    end

    interaction:deferReply({ ephemeral = true })

    local targetUser = interaction:getOption("user")
    local productId = trim(interaction:getOption("product_uuid"))

    local product = products.getProduct(productId)
    if not product then
        logger.logCommandActivity(interaction, {
            subcommand = "revoke",
            success = false,
            fields = { discordUser = interaction.user, targetUser = targetUser, productId = productId },
            note = "Product UUID not found."
        })
        return interaction:editReply({ content = string.format("Produk dengan ID `%s` tidak ditemukan.", productId) })
    end

    if not products.userOwnsProduct(product, targetUser.id) then
        logger.logCommandActivity(interaction, {
            subcommand = "revoke",
            success = false,
            fields = { discordUser = interaction.user, targetUser = targetUser, productId = productId, productName = product.name },
            note = "Target user does not own this product."
        })
        return interaction:editReply({ content = string.format("%s belum punya produk **%s**.", tostring(targetUser), product.name) })
    end

    local revokeOk = pcall(function() products.revokeProductFromUser(productId, targetUser.id) end)
    if not revokeOk then
        logger.logCommandActivity(interaction, {
            subcommand = "revoke",
            success = false,
            fields = { discordUser = interaction.user, targetUser = targetUser, productId = productId, productName = product.name },
            note = "Firestore write failed."
        })
        return interaction:editReply({ content = "Gagal mencabut produk dari database. Coba lagi." })
    end

    logger.logCommandActivity(interaction, {
        subcommand = "revoke",
        success = true,
        fields = { discordUser = interaction.user, targetUser = targetUser, productId = productId, productName = product.name }
    })

    return interaction:editReply({ content = string.format("Produk **%s** berhasil dicabut dari %s.", product.name, tostring(targetUser)) })
end

local function handleGet(interaction)
    interaction:deferReply({ ephemeral = true })

    local productId = trim(interaction:getOption("product_uuid"))

    local verifiedRecord = verification.getVerifiedUser(interaction.user.id)
    if not verifiedRecord then
        logger.logCommandActivity(interaction, {
            subcommand = "get",
            success = false,
            fields = { discordUser = interaction.user, productId = productId },
            note = "Requesting user is not verified."
        })
        return interaction:editReply({ content = "You are required to verified to use this command!" })
    end

    local product = products.getProduct(productId)
    if not product then
        logger.logCommandActivity(interaction, {
            subcommand = "get",
            success = false,
            fields = { discordUser = interaction.user, productId = productId },
            note = "Product UUID not found."
        })
        return interaction:editReply({ content = string.format("Produk dengan ID `%s` tidak ditemukan.", productId) })
    end

    if not products.userOwnsProduct(product, interaction.user.id) then
        logger.logCommandActivity(interaction, {
            subcommand = "get",
            success = false,
            fields = { discordUser = interaction.user, productId = productId, productName = product.name },
            note = "Requesting user does not own this product."
        })
        return interaction:editReply({ content = "You didnt owned the product!" })
    end

    local dmOk = pcall(function()
        local dmChannel = interaction.user:createDM()
        dmChannel:send(products.buildProductDeliveryDM(product))
    end)

    if not dmOk then
        logger.logCommandActivity(interaction, {
            subcommand = "get",
            success = false,
            fields = { discordUser = interaction.user, productId = productId, productName = product.name },
            note = "Could not DM the user (DMs likely closed)."
        })
        return interaction:editReply({ content = "Could not DM you the file link. Please enable DMs from server members and try again." })
    end

    logger.logCommandActivity(interaction, {
        subcommand = "get",
        success = true,
        fields = { discordUser = interaction.user, productId = productId, productName = product.name }
    })

    return interaction:editReply({ content = "Sent! Check your DMs 📬" })
end

-------------------------------------------------------------------------------
-- Autocomplete & Main Command Execution
-------------------------------------------------------------------------------

function Command.autocomplete(interaction)
    local sub = interaction:getSubcommand()
    if sub ~= "get" then return interaction:respond({}) end

    local focused = interaction:getFocusedOption().value:lower()
    local verifiedRecord = verification.getVerifiedUser(interaction.user.id)
    local ownedIds = verifiedRecord and verifiedRecord.ownedProducts or nil

    if not ownedIds or type(ownedIds) ~= "table" or #ownedIds == 0 then
        return interaction:respond({})
    end

    local owned = products.getProductsByIds(ownedIds)
    local filtered = {}

    for _, p in ipairs(owned) do
        if p.name and p.name:lower():find(focused, 1, true) then
            table.insert(filtered, {
                name = p.name:sub(1, 100),
                value = p.id
            })
            if #filtered >= 25 then break end
        end
    end

    return interaction:respond(filtered)
end

function Command.execute(interaction)
    if not interaction.guild_id then
        return interaction:reply({ content = "This command only works inside a server.", ephemeral = true })
    end

    local sub = interaction:getSubcommand()

    if sub == "create" then return handleCreate(interaction) end
    if sub == "createtype" then return handleCreateType(interaction) end
    if sub == "linktype" then return handleLinkType(interaction) end
    if sub == "sendpost" then return handleSendPost(interaction) end
    if sub == "edit" then return handleEdit(interaction) end
    if sub == "view" then return handleView(interaction) end
    if sub == "delete" then return handleDelete(interaction) end
    if sub == "give" then return handleGive(interaction) end
    if sub == "revoke" then return handleRevoke(interaction) end
    if sub == "get" then return handleGet(interaction) end
end

return Command
