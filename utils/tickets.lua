local db = require('../utils/firebase')

local tickets = {}

local CREATE_LOCK_MS = 15 * 1000
local SELECTION_TTL_MS = 15 * 60 * 1000

local function getTimeMs()
    return os.time() * 1000
end

local function getGuildConfig(guildId)
    local doc = db.collection('guildConfig'):doc(guildId):get()
    return (doc and doc.exists) and doc:data() or {}
end

function tickets.setTestiChannel(guildId, channelId)
    db.collection('guildConfig'):doc(guildId):set({
        testiChannelId = channelId
    }, { merge = true })
end

function tickets.getTestiChannel(guildId)
    local cfg = getGuildConfig(guildId)
    return cfg.testiChannelId or nil
end

function tickets.setTicketCategories(guildId, categoryIds)
    db.collection('guildConfig'):doc(guildId):set({
        ticketCategories = categoryIds
    }, { merge = true })
end

function tickets.getTicketCategories(guildId)
    local cfg = getGuildConfig(guildId)
    return cfg.ticketCategories or nil
end

function tickets.nextTicketNumber(guildId)
    local ref = db.collection('guildConfig'):doc(guildId)
    
    return db.runTransaction(function(tx)
        local doc = tx:get(ref)
        local current = (doc and doc.exists and doc:data().testiCounter) or 0
        local nextNum = current + 1
        
        tx:set(ref, { testiCounter = nextNum }, { merge = true })
        return nextNum
    end)
end

function tickets.createTicket(data)
    data.status = 'open'
    data.createdAt = getTimeMs()

    db.collection('tickets'):doc(data.channelId):set(data)
end

function tickets.claimTicketCreateLock(userId, category)
    local docId = string.format("%s_%s", tostring(userId), tostring(category))
    local ref = db.collection('ticketCreateLocks'):doc(docId)

    return db.runTransaction(function(tx)
        local doc = tx:get(ref)
        local now = getTimeMs()
        
        if doc and doc.exists then
            local lockedAt = doc:data().lockedAt or 0
            if (now - lockedAt) < CREATE_LOCK_MS then
                return false
            end
        end

        tx:set(ref, { lockedAt = now })
        return true
    end)
end

function tickets.releaseTicketCreateLock(userId, category)
    local docId = string.format("%s_%s", tostring(userId), tostring(category))
    pcall(function()
        db.collection('ticketCreateLocks'):doc(docId):delete()
    end)
end

function tickets.saveOrderSelection(token, userId, productIds)
    db.collection('orderSelections'):doc(token):set({
        userId = userId,
        productIds = productIds,
        createdAt = getTimeMs(),
    })
end

function tickets.getOrderSelection(token)
    local doc = db.collection('orderSelections'):doc(token):get()
    if not doc or not doc.exists then return nil end

    local data = doc:data()
    if (getTimeMs() - (data.createdAt or 0)) > SELECTION_TTL_MS then
        return nil
    end

    return data
end

function tickets.getTicket(channelId)
    local doc = db.collection('tickets'):doc(channelId):get()
    if not doc or not doc.exists then return nil end

    local data = doc:data()
    data.id = doc.id
    return data
end

function tickets.findOpenTicket(guildId, creatorId, category)
    local snap = db.collection('tickets')
        :where('creatorId', '==', creatorId)
        :where('status', '==', 'open')
        :get()

    if not snap or not snap.docs then return nil end

    for _, doc in ipairs(snap.docs) do
        local data = doc:data()
        if data.guildId == guildId and data.category == category then
            data.id = doc.id
            return data
        end
    end

    return nil
end

function tickets.closeTicket(channelId, extra)
    extra = extra or {}
    extra.status = 'done'
    extra.closedAt = getTimeMs()

    db.collection('tickets'):doc(channelId):set(extra, { merge = true })
end

function tickets.markTicketDeleted(channelId)
    db.collection('tickets'):doc(channelId):set({
        status = 'deleted',
        deletedAt = getTimeMs()
    }, { merge = true })
end

return tickets
