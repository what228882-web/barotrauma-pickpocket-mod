--[[
    PickpocketServer.lua
    Server-side (authoritative) part of the pickpocket mechanic.
    All actual game logic - chance rolls, store stock changes, item spawning,
    reputation penalty and security aggro - lives here. The client only sends
    requests and receives the finished result over the network.
]]

if not SERVER then return end

-- sessions[client] = {
--     vendor      = Character (the vendor NPC),
--     store       = Location.StoreInfo,
--     location    = Location (to detect the outpost changing),
--     stolen      = { {item = Item}, ... }  -- items stolen during this session
--     attempts    = number  -- how many steal attempts were made this session
-- }
local sessions = {}

local function ResetSession(client)
    sessions[client] = nil
end

-- The chance ladder resets when the menu closes or the outpost changes (see
-- ResetSession). Outpost changes are also caught on roundStart/roundEnd below,
-- and every new request re-checks that the player is still at the same location.

local function ClearStolenItems(client)
    local session = sessions[client]
    if session == nil then return end
    for _, stolen in ipairs(session.stolen) do
        local item = stolen.item
        if item ~= nil and not item.Removed then
            Entity.Spawner.AddEntityToRemoveQueue(item)
        end
    end
    session.stolen = {}
end

local function SendToClient(netId, client, writeFunc)
    local message = Networking.Start(netId)
    if writeFunc ~= nil then
        writeFunc(message)
    end
    Networking.Send(message, client.Connection)
end

local function AlertSecurity(client, vendor)
    local thief = client.Character
    if thief == nil then return end

    local location = Pickpocket.GetCurrentLocation()
    if location ~= nil and location.Reputation ~= nil then
        location.Reputation.AddReputation(-Pickpocket.REPUTATION_PENALTY)
    end

    if vendor ~= nil and not vendor.Removed and not vendor.IsDead then
        local line = Pickpocket.CAUGHT_LINES[math.random(1, #Pickpocket.CAUGHT_LINES)]
        vendor.Speak(line, ChatMessageType.Default, 0)
    end

    -- Send every outpost security NPC after the thief.
    for _, character in pairs(Character.CharacterList) do
        if Pickpocket.IsSecurityNPC(character) then
            local ai = character.AIController
            if ai ~= nil and ai.AddCombatObjective ~= nil then
                ai.AddCombatObjective(AIObjectiveCombat.CombatMode.Offensive, thief, 0)
            end
        end
    end
end

-- caught = true when the session is closing because a steal attempt failed
-- (the player needs to be punished).
local function CloseSession(client, caught)
    local session = sessions[client]
    if session == nil then return end
    local vendor = session.vendor

    if caught then
        ClearStolenItems(client)
        SendToClient(Pickpocket.NET.Caught, client, nil)
        AlertSecurity(client, vendor)
    end

    ResetSession(client)
end

-- === Client asks to open the steal menu for a specific NPC ===
Networking.Receive(Pickpocket.NET.RequestOpen, function(message, client)
    local vendorId = message.ReadUInt16()
    if client == nil then return end

    local playerChar = client.Character
    if playerChar == nil or playerChar.Removed or playerChar.IsDead then return end

    local vendor = Entity.FindEntityByID(vendorId)
    if not Pickpocket.IsVendor(vendor) then return end

    if Vector2.Distance(playerChar.WorldPosition, vendor.WorldPosition) > Pickpocket.INTERACT_RANGE then
        return
    end

    local store = Pickpocket.GetStoreForVendor(vendor)
    if store == nil then return end

    -- New session with this vendor - the chance ladder resets.
    sessions[client] = {
        vendor = vendor,
        store = store,
        location = Pickpocket.GetCurrentLocation(),
        stolen = {},
        attempts = 0,
    }

    local stock = store.Stock
    local entries = {}
    for i = 1, stock.Count do
        local entry = stock[i]
        if entry.Quantity > 0 then
            table.insert(entries, entry)
        end
    end

    SendToClient(Pickpocket.NET.StoreData, client, function(msg)
        msg.WriteUInt16(#entries)
        for _, entry in ipairs(entries) do
            msg.WriteString(tostring(entry.ItemPrefabIdentifier))
            msg.WriteString(entry.ItemPrefab.Name)
            msg.WriteInt32(entry.Quantity)
        end
    end)
end)

-- === Client closed the menu on its own (not caught) ===
Networking.Receive(Pickpocket.NET.CloseMenu, function(message, client)
    if client == nil then return end
    CloseSession(client, false)
end)

-- === Client tries to steal a specific item by its prefab identifier ===
Networking.Receive(Pickpocket.NET.AttemptSteal, function(message, client)
    local identifier = message.ReadString()
    if client == nil then return end

    local session = sessions[client]
    if session == nil then return end

    local playerChar = client.Character
    if playerChar == nil or playerChar.Removed or playerChar.IsDead then
        ResetSession(client)
        return
    end

    local vendor = session.vendor
    if vendor == nil or vendor.Removed then
        ResetSession(client)
        return
    end

    -- Player walked too far away - close the menu, but don't punish (not a failed roll).
    if Vector2.Distance(playerChar.WorldPosition, vendor.WorldPosition) > Pickpocket.INTERACT_RANGE then
        CloseSession(client, false)
        return
    end

    -- Outpost changed (e.g. the sub left) - the ladder should have already reset.
    if Pickpocket.GetCurrentLocation() ~= session.location then
        ResetSession(client)
        return
    end

    local stock = session.store.Stock
    local targetEntry = nil
    for i = 1, stock.Count do
        local entry = stock[i]
        if entry.Quantity > 0 and tostring(entry.ItemPrefabIdentifier) == identifier then
            targetEntry = entry
            break
        end
    end

    -- Item is no longer in stock (someone else already stole/bought it) - don't waste an attempt.
    if targetEntry == nil then
        SendToClient(Pickpocket.NET.StealResult, client, function(msg)
            msg.WriteBoolean(false)
            msg.WriteString(identifier)
            msg.WriteBoolean(false) -- caught = false, just "no longer available"
        end)
        return
    end

    session.attempts = session.attempts + 1
    local chance = Pickpocket.GetChance(session.attempts)
    local roll = math.random(1, 100)
    local success = roll <= chance

    if success then
        -- Item temporarily disappears from the vendor's stock.
        targetEntry.Quantity = targetEntry.Quantity - 1

        Entity.Spawner.AddItemToSpawnQueue(targetEntry.ItemPrefab, playerChar.Inventory, nil, nil, function(item)
            if item ~= nil then
                table.insert(session.stolen, { item = item })
            end
        end)

        SendToClient(Pickpocket.NET.StealResult, client, function(msg)
            msg.WriteBoolean(true)
            msg.WriteString(identifier)
            msg.WriteBoolean(false)
        end)
    else
        SendToClient(Pickpocket.NET.StealResult, client, function(msg)
            msg.WriteBoolean(false)
            msg.WriteString(identifier)
            msg.WriteBoolean(true) -- caught = true
        end)

        CloseSession(client, true)
    end
end)

-- Outpost change (new leg of the journey / new round) - drop every active session.
Hook.Add("roundStart", "Pickpocket.RoundStart", function()
    sessions = {}
end)

Hook.Add("roundEnd", "Pickpocket.RoundEnd", function()
    sessions = {}
end)

-- Player died - their session is no longer relevant.
Hook.Add("characterDeath", "Pickpocket.CharacterDeath", function(character, affliction)
    for client, session in pairs(sessions) do
        if client.Character == character then
            ResetSession(client)
        end
    end
end)

-- Client disconnected - drop their session so it doesn't linger in the table.
Hook.Add("clientDisconnected", "Pickpocket.ClientDisconnected", function(client)
    ResetSession(client)
end)
