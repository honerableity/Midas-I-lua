local rtdb = require("../utils/rtdb")
local logger = require("../utils/logger")

local CHANNEL_TYPE_GUILD_TEXT = 0

local function requireAdmin(interaction)
    if not interaction.member or not interaction.member.permissions then
        return false
    end
    return interaction.member.permissions:has("administrator")
end

local Command = {}

Command.data = {
    name = "log",
    description = "Configure activity logging channel for the server",
    options = {
        {
            type = 1,
            name = "set",
            description = "Set the channel for bot activity logs",
            options = {
                {
                    type = 7,
                    name = "channel",
                    description = "Select a text channel for activity logs",
                    required = true,
                    channel_types = { CHANNEL_TYPE_GUILD_TEXT }
                }
            }
        },
        {
            type = 1,
            name = "disable",
            description = "Disable activity logging for this server"
        },
        {
            type = 1,
            name = "view",
            description = "View current logging channel configuration"
        }
    }
}

Command.logSchema = {
    subcommands = {
        set = { label = "Log — Channel Set", fields = { "discordUser", "targetChannel" } },
        disable = { label = "Log — Channel Disabled", fields = { "discordUser" } },
        view = { label = "Log — Settings Viewed", fields = { "discordUser" } }
    }
}

local function handleSet(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({
            content = "You need **Administrator** permission to do that.",
            ephemeral = true
        })
    end

    interaction:deferReply({ ephemeral = true })

    local channel = interaction:getOption("channel")
    if not channel or channel.type ~= CHANNEL_TYPE_GUILD_TEXT then
        return interaction:editReply({ content = "Please select a valid server text channel." })
    end

    local path = string.format("guilds/%s/config/logChannelId", interaction.guild_id)
    
    local ok = pcall(function()
        rtdb.set(path, channel.id)
    end)

    if not ok then
        logger.logCommandActivity(interaction, {
            subcommand = "set",
            success = false,
            fields = { discordUser = interaction.user, targetChannel = channel },
            note = "Failed to write logChannelId to RTDB."
        })
        return interaction:editReply({ content = "Gagal menyimpan konfigurasi log channel ke database. Coba lagi." })
    end

    logger.logCommandActivity(interaction, {
        subcommand = "set",
        success = true,
        fields = { discordUser = interaction.user, targetChannel = channel }
    })

    return interaction:editReply({
        content = string.format("Activity log channel successfully set to %s!", tostring(channel))
    })
end

local function handleDisable(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({
            content = "You need **Administrator** permission to do that.",
            ephemeral = true
        })
    end

    interaction:deferReply({ ephemeral = true })

    local path = string.format("guilds/%s/config/logChannelId", interaction.guild_id)

    local ok = pcall(function()
        rtdb.delete(path)
    end)

    if not ok then
        logger.logCommandActivity(interaction, {
            subcommand = "disable",
            success = false,
            fields = { discordUser = interaction.user },
            note = "Failed to remove logChannelId from RTDB."
        })
        return interaction:editReply({ content = "Gagal menghapus konfigurasi log channel dari database. Coba lagi." })
    end

    logger.logCommandActivity(interaction, {
        subcommand = "disable",
        success = true,
        fields = { discordUser = interaction.user }
    })

    return interaction:editReply({ content = "Activity logging has been disabled for this server." })
end

local function handleView(interaction)
    if not requireAdmin(interaction) then
        return interaction:reply({
            content = "You need **Administrator** permission to do that.",
            ephemeral = true
        })
    end

    interaction:deferReply({ ephemeral = true })

    local path = string.format("guilds/%s/config/logChannelId", interaction.guild_id)

    local ok, channelId = pcall(function()
        return rtdb.get(path)
    end)

    if not ok or not channelId or channelId == "" then
        return interaction:editReply({ content = "Activity logging is currently **not configured** for this server." })
    end

    logger.logCommandActivity(interaction, {
        subcommand = "view",
        success = true,
        fields = { discordUser = interaction.user }
    })

    return interaction:editReply({
        content = string.format("Current activity log channel is set to <#%s> (`%s`).", channelId, channelId)
    })
end

function Command.execute(interaction)
    if not interaction.guild_id then
        return interaction:reply({ content = "This command only works inside a server.", ephemeral = true })
    end

    local sub = interaction:getSubcommand()

    if sub == "set" then return handleSet(interaction) end
    if sub == "disable" then return handleDisable(interaction) end
    if sub == "view" then return handleView(interaction) end
end

return Command
