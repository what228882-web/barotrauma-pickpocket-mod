--[[
    PickpocketShared.lua
    Shared constants and helpers used by both the client and the server side.
    Runs on both.
]]

Pickpocket = Pickpocket or {}

-- Custom network message identifiers (Networking.Start / Networking.Receive)
Pickpocket.NET = {
    RequestOpen  = "Pickpocket_RequestOpen",  -- client -> server: open the steal menu for an NPC
    StoreData    = "Pickpocket_StoreData",    -- server -> client: the vendor's stock list
    CloseMenu    = "Pickpocket_CloseMenu",    -- client -> server: player closed the menu
    AttemptSteal = "Pickpocket_AttemptSteal", -- client -> server: attempt to steal one item
    StealResult  = "Pickpocket_StealResult",  -- server -> client: result of a steal attempt
    Caught       = "Pickpocket_Caught",       -- server -> client: player got caught, force-close menu
    Banned       = "Pickpocket_Banned",       -- server -> client: no longer allowed to steal from this vendor (already got caught)
}

-- Success chance for the 1st, 2nd, ... attempt within a single session (percent).
-- Anything past the length of CHANCES falls back to MIN_CHANCE (8th attempt onward).
Pickpocket.CHANCES = { 90, 70, 50, 30, 10, 5, 2 }
Pickpocket.MIN_CHANCE = 1

-- Maximum distance (world units) to show the prompt and allow stealing.
Pickpocket.INTERACT_RANGE = 200

-- Reputation penalty applied to the current location when caught.
Pickpocket.REPUTATION_PENALTY = 5

-- Job identifiers treated as "outpost security" NPCs.
Pickpocket.SECURITY_JOB_IDS = { "securityofficer" }

-- Lines the vendor shouts after catching the player red-handed.
Pickpocket.CAUGHT_LINES = {
    "Thief! Guards!",
    "Stop him, he stole from me!",
    "Security, over here, thief!",
}

-- Returns the success chance (0-100) for the attempt with the given 1-based index.
function Pickpocket.GetChance(attemptIndex)
    local chance = Pickpocket.CHANCES[attemptIndex]
    if chance == nil then
        return Pickpocket.MIN_CHANCE
    end
    return chance
end

-- Checks whether the character is an active outpost vendor NPC (has a "Store" tab).
function Pickpocket.IsVendor(character)
    if character == nil or character.Removed then
        return false
    end
    local ok, interactionType = pcall(function() return character.CampaignInteractionType end)
    if not ok or interactionType == nil then
        return false
    end
    -- Compare against the enum's string representation instead of
    -- CampaignMode.InteractionType.Store - the CampaignMode class isn't
    -- always reachable as a bare global table in Lua, but tostring() on
    -- the enum value itself always works.
    return tostring(interactionType) == "Store"
end

-- Checks whether the character is an outpost security NPC.
function Pickpocket.IsSecurityNPC(character)
    if character == nil or character.Removed or character.IsDead then
        return false
    end
    if tostring(character.TeamID) ~= "FriendlyNPC" then
        return false
    end
    if character.Info == nil or character.Info.Job == nil then
        return false
    end
    local jobId = tostring(character.Info.Job.Prefab.Identifier)
    for _, secId in ipairs(Pickpocket.SECURITY_JOB_IDS) do
        if jobId == secId then
            return true
        end
    end
    return false
end

-- Returns the current CampaignMode (Location.GetStore/Reputation only exist in campaign).
function Pickpocket.GetCampaign()
    if Game == nil or Game.GameSession == nil then
        return nil
    end
    return Game.GameSession.Campaign
end

-- Returns the location (outpost) the sub is currently docked at.
function Pickpocket.GetCurrentLocation()
    local campaign = Pickpocket.GetCampaign()
    if campaign == nil or campaign.Map == nil then
        return nil
    end
    return campaign.Map.CurrentLocation
end

-- Returns the Location.StoreInfo (virtual shop) for a specific vendor NPC.
function Pickpocket.GetStoreForVendor(vendor)
    if not Pickpocket.IsVendor(vendor) then
        return nil
    end
    local location = Pickpocket.GetCurrentLocation()
    if location == nil then
        return nil
    end
    local identifier = vendor.MerchantIdentifier
    if identifier == nil then
        return nil
    end
    return location.GetStore(identifier)
end
