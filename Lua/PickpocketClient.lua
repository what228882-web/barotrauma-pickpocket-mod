--[[
    PickpocketClient.lua
    Client-side part of the pickpocket mechanic: a proximity prompt near a
    vendor, a custom steal-menu GUI opened with the G key, sending requests
    to the server and showing the result. No game logic (chances, item
    spawning) lives here - interface and networking only.
]]

if not CLIENT then return end

local isMenuOpen = false
local currentVendor = nil
local currentItems = {} -- { {identifier=, name=, quantity=}, ... }
local rowButtons = {}   -- identifier -> GUIButton (to lock it until the server responds)
local currentChance = nil -- current % chance of the next attempt (nil while the menu is closed)

-- Temporary message shown above the prompt (e.g. "vendor no longer trusts
-- you"), counted in frames rather than seconds so it doesn't depend on yet
-- another unverified timer API.
local tempMessageFrames = 0
local tempMessageText = nil

-- === "[G] Steal" prompt shown near a vendor ===
-- Two separate frames instead of one with a runtime Anchor switch (changing
-- Anchor on the fly is unverified and could break the fallback):
--   promptFrameNearVendor - anchored at the vendor itself (via a world-to-
--     screen projection, see PositionPromptNearVendor). The primary option.
--   promptFrameFallback   - a fixed spot at the bottom of the screen, exactly
--     as before. Shown only if the coordinate projection isn't available.
-- Only one of the two is ever visible at a time.

local promptFrameNearVendor = GUI.Frame(GUI.RectTransform(Point(220, 34), nil, GUI.Anchor.TopLeft), nil)
promptFrameNearVendor.CanBeFocused = false
promptFrameNearVendor.Visible = false
local promptTextNearVendor = GUI.TextBlock(GUI.RectTransform(Vector2(1, 1), promptFrameNearVendor.RectTransform), "[G] Steal", nil, nil, GUI.Alignment.Center)

local promptFrameFallback = GUI.Frame(GUI.RectTransform(Vector2(0.16, 0.05), nil, GUI.Anchor.BottomCenter), nil)
promptFrameFallback.CanBeFocused = false
promptFrameFallback.Visible = false
promptFrameFallback.RectTransform.AbsoluteOffset = Point(0, -140)
local promptTextFallback = GUI.TextBlock(GUI.RectTransform(Vector2(1, 1), promptFrameFallback.RectTransform), "[G] Steal", nil, nil, GUI.Alignment.Center)

-- === Steal window ===

local menuRoot = GUI.Frame(GUI.RectTransform(Vector2(1, 1), nil), nil)
menuRoot.CanBeFocused = false
menuRoot.Visible = false

-- clicking outside the window closes the menu
local menuBackground = GUI.Button(GUI.RectTransform(Vector2(1, 1), menuRoot.RectTransform, GUI.Anchor.Center), "", GUI.Alignment.Center, nil)

local menuWindow = GUI.Frame(GUI.RectTransform(Vector2(0.32, 0.6), menuRoot.RectTransform, GUI.Anchor.Center))

GUI.TextBlock(GUI.RectTransform(Vector2(1, 0.07), menuWindow.RectTransform, GUI.Anchor.TopCenter), "Pickpocketing", nil, nil, GUI.Alignment.Center)

local chanceTextRT = GUI.RectTransform(Vector2(1, 0.06), menuWindow.RectTransform, GUI.Anchor.TopCenter)
chanceTextRT.AbsoluteOffset = Point(0, 34)
local chanceText = GUI.TextBlock(chanceTextRT, "", nil, nil, GUI.Alignment.Center)

local menuListRT = GUI.RectTransform(Vector2(0.94, 0.7), menuWindow.RectTransform, GUI.Anchor.Center)
menuListRT.AbsoluteOffset = Point(0, 20)
local menuList = GUI.ListBox(menuListRT)

local closeButton = GUI.Button(GUI.RectTransform(Vector2(0.5, 0.08), menuWindow.RectTransform, GUI.Anchor.BottomCenter), "Close", GUI.Alignment.Center, "GUIButtonSmall")

local function UpdateChanceText()
    if currentChance == nil then
        chanceText.Text = ""
    else
        chanceText.Text = "Chance to steal: " .. tostring(currentChance) .. "%"
    end
end

local function SendCloseToServer()
    local msg = Networking.Start(Pickpocket.NET.CloseMenu)
    Networking.Send(msg)
end

local function CloseMenu(notifyServer)
    if isMenuOpen and notifyServer then
        SendCloseToServer()
    end
    isMenuOpen = false
    menuRoot.Visible = false
    currentVendor = nil
    currentItems = {}
    rowButtons = {}
    currentChance = nil
end

closeButton.OnClicked = function()
    CloseMenu(true)
    return true
end

menuBackground.OnClicked = function()
    CloseMenu(true)
    return true
end

local function RequestSteal(identifier)
    local msg = Networking.Start(Pickpocket.NET.AttemptSteal)
    msg.WriteString(identifier)
    Networking.Send(msg)
end

local function RebuildList()
    menuList.ClearChildren()
    rowButtons = {}

    if #currentItems == 0 then
        GUI.TextBlock(GUI.RectTransform(Vector2(1, 0.1), menuList.Content.RectTransform), "Nothing left to steal from this vendor.", nil, nil, GUI.Alignment.Center)
        return
    end

    for _, entry in ipairs(currentItems) do
        local row = GUI.Frame(GUI.RectTransform(Vector2(1, 0.14), menuList.Content.RectTransform), nil)

        GUI.TextBlock(
            GUI.RectTransform(Vector2(0.62, 1), row.RectTransform, GUI.Anchor.CenterLeft),
            entry.name .. "  x" .. entry.quantity,
            nil, nil, GUI.Alignment.CenterLeft
        )

        local button = GUI.Button(
            GUI.RectTransform(Vector2(0.34, 0.8), row.RectTransform, GUI.Anchor.CenterRight),
            "Steal", GUI.Alignment.Center, "GUIButtonSmall"
        )
        button.OnClicked = function()
            button.Enabled = false
            RequestSteal(entry.identifier)
            return true
        end

        rowButtons[entry.identifier] = button
    end
end

-- === Network: server sent the vendor's stock - open the menu ===
Networking.Receive(Pickpocket.NET.StoreData, function(message)
    local chance = message.ReadInt32()
    local count = message.ReadUInt16()
    local items = {}
    for i = 1, count do
        local identifier = message.ReadString()
        local name = message.ReadString()
        local quantity = message.ReadInt32()
        table.insert(items, { identifier = identifier, name = name, quantity = quantity })
    end

    currentItems = items
    currentChance = chance
    isMenuOpen = true
    menuRoot.Visible = true
    promptFrameNearVendor.Visible = false
    promptFrameFallback.Visible = false

    UpdateChanceText()
    RebuildList()
end)

-- === Network: result of a single steal attempt ===
Networking.Receive(Pickpocket.NET.StealResult, function(message)
    local success = message.ReadBoolean()
    local identifier = message.ReadString()
    local caught = message.ReadBoolean()
    local nextChance = message.ReadInt32()

    currentChance = nextChance
    UpdateChanceText()

    if success then
        for _, entry in ipairs(currentItems) do
            if entry.identifier == identifier then
                entry.quantity = entry.quantity - 1
                break
            end
        end
        for i = #currentItems, 1, -1 do
            if currentItems[i].quantity <= 0 then
                table.remove(currentItems, i)
            end
        end
        RebuildList()
    else
        -- Failed but not caught (e.g. item already gone) - just unlock the button.
        if not caught then
            local button = rowButtons[identifier]
            if button ~= nil then
                button.Enabled = true
            end
        end
        -- If caught = true, a separate Caught message follows and closes the menu.
    end
end)

-- === Network: player got caught red-handed - force-close the menu ===
Networking.Receive(Pickpocket.NET.Caught, function(message)
    CloseMenu(false) -- server already knows the session is closed - don't report it back
end)

-- === Network: no longer allowed to steal from this vendor (already caught once) ===
Networking.Receive(Pickpocket.NET.Banned, function(message)
    tempMessageText = "This vendor no longer trusts you"
    tempMessageFrames = 180 -- roughly 3 seconds at 60 fps
end)

-- === Find the nearest vendor eligible for stealing ===
local function FindNearbyVendor()
    local player = Character.Controlled
    if player == nil or player.Removed or player.IsDead then return nil end

    local best, bestDist = nil, Pickpocket.INTERACT_RANGE
    for _, character in pairs(Character.CharacterList) do
        if Pickpocket.IsVendor(character) then
            local dist = Vector2.Distance(player.WorldPosition, character.WorldPosition)
            if dist <= Pickpocket.INTERACT_RANGE and dist < bestDist then
                best, bestDist = character, dist
            end
        end
    end
    return best
end

-- Tries to place promptFrameNearVendor under the vanilla "[E] Trade" label
-- above the vendor's head (via a world-to-screen projection). Returns true
-- on success. If that API isn't available in this LuaForBarotrauma build,
-- remembers that once and always falls back to the fixed bottom-of-screen frame.
local worldToScreenBroken = false

local function PositionPromptNearVendor(vendor)
    if worldToScreenBroken then
        return false
    end

    local screenPos = nil
    local ok = pcall(function()
        screenPos = GameMain.GameScreen.Cam.WorldToScreen(vendor.WorldPosition)
    end)

    if not ok or screenPos == nil then
        worldToScreenBroken = true
        print("[Pickpocket DEBUG] WorldToScreen positioning unavailable, falling back to bottom-of-screen prompt")
        return false
    end

    -- Screen Y grows downward; the vanilla "[E] Trade" label is drawn roughly
    -- above the NPC's head, so ours sits a bit below that point.
    promptFrameNearVendor.RectTransform.ScreenSpaceOffset = Point(
        math.floor(screenPos.X - 110),
        math.floor(screenPos.Y + 40)
    )
    return true
end

local function HideBothPrompts()
    promptFrameNearVendor.Visible = false
    promptFrameFallback.Visible = false
end

local function ShowPrompt(vendor, text)
    if PositionPromptNearVendor(vendor) then
        promptTextNearVendor.Text = text
        promptFrameNearVendor.Visible = true
        promptFrameFallback.Visible = false
    else
        promptTextFallback.Text = text
        promptFrameFallback.Visible = true
        promptFrameNearVendor.Visible = false
    end
end

-- === Per-frame update: show the prompt + handle the G key ===
Hook.Add("think", "Pickpocket.Think", function()
    if Character.Controlled == nil or isMenuOpen then
        HideBothPrompts()
        return
    end

    local vendor = FindNearbyVendor()

    -- A temporary message (e.g. "vendor no longer trusts you") takes
    -- priority, but only while we're still standing near some vendor.
    if tempMessageFrames > 0 and vendor ~= nil then
        tempMessageFrames = tempMessageFrames - 1
        ShowPrompt(vendor, tempMessageText)
        return
    elseif tempMessageFrames > 0 then
        tempMessageFrames = 0
    end

    if vendor ~= nil then
        currentVendor = vendor
        ShowPrompt(vendor, "[G] Steal")

        if PlayerInput.KeyHit(Keys.G) then
            local msg = Networking.Start(Pickpocket.NET.RequestOpen)
            msg.WriteUInt16(vendor.ID)
            Networking.Send(msg)
        end
    else
        currentVendor = nil
        HideBothPrompts()
    end
end)

-- Without this patch the custom GUI elements would never update/render.
Hook.Patch("Barotrauma.GameScreen", "AddToGUIUpdateList", function()
    promptFrameNearVendor.AddToGUIUpdateList()
    promptFrameFallback.AddToGUIUpdateList()
    if isMenuOpen then
        menuRoot.AddToGUIUpdateList()
    end
end)
