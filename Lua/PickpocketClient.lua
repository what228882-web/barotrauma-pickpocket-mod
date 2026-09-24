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

-- === "[G] Steal" prompt shown near a vendor ===

local promptFrame = GUI.Frame(GUI.RectTransform(Vector2(0.16, 0.05), nil, GUI.Anchor.BottomCenter), nil)
promptFrame.CanBeFocused = false
promptFrame.Visible = false
promptFrame.RectTransform.AbsoluteOffset = Point(0, -140)

GUI.TextBlock(GUI.RectTransform(Vector2(1, 1), promptFrame.RectTransform), "[G] Steal", nil, nil, GUI.Alignment.Center)

-- === Steal window ===

local menuRoot = GUI.Frame(GUI.RectTransform(Vector2(1, 1), nil), nil)
menuRoot.CanBeFocused = false
menuRoot.Visible = false

-- clicking outside the window closes the menu
local menuBackground = GUI.Button(GUI.RectTransform(Vector2(1, 1), menuRoot.RectTransform, GUI.Anchor.Center), "", GUI.Alignment.Center, nil)

local menuWindow = GUI.Frame(GUI.RectTransform(Vector2(0.32, 0.55), menuRoot.RectTransform, GUI.Anchor.Center))

GUI.TextBlock(GUI.RectTransform(Vector2(1, 0.08), menuWindow.RectTransform, GUI.Anchor.TopCenter), "Pickpocketing", nil, nil, GUI.Alignment.Center)

local menuList = GUI.ListBox(GUI.RectTransform(Vector2(0.94, 0.78), menuWindow.RectTransform, GUI.Anchor.Center))

local closeButton = GUI.Button(GUI.RectTransform(Vector2(0.5, 0.09), menuWindow.RectTransform, GUI.Anchor.BottomCenter), "Close", GUI.Alignment.Center, "GUIButtonSmall")

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
    local count = message.ReadUInt16()
    local items = {}
    for i = 1, count do
        local identifier = message.ReadString()
        local name = message.ReadString()
        local quantity = message.ReadInt32()
        table.insert(items, { identifier = identifier, name = name, quantity = quantity })
    end

    currentItems = items
    isMenuOpen = true
    menuRoot.Visible = true
    promptFrame.Visible = false

    RebuildList()
end)

-- === Network: result of a single steal attempt ===
Networking.Receive(Pickpocket.NET.StealResult, function(message)
    local success = message.ReadBoolean()
    local identifier = message.ReadString()
    local caught = message.ReadBoolean()

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

-- === Per-frame update: show the prompt + handle the G key ===
Hook.Add("think", "Pickpocket.Think", function()
    if Character.Controlled == nil then
        promptFrame.Visible = false
        return
    end

    if isMenuOpen then
        promptFrame.Visible = false
        return
    end

    local vendor = FindNearbyVendor()
    if vendor ~= nil then
        promptFrame.Visible = true
        currentVendor = vendor

        if PlayerInput.KeyHit(Keys.G) then
            local msg = Networking.Start(Pickpocket.NET.RequestOpen)
            msg.WriteUInt16(vendor.ID)
            Networking.Send(msg)
        end
    else
        promptFrame.Visible = false
        currentVendor = nil
    end
end)

-- Without this patch the custom GUI elements would never update/render.
Hook.Patch("Barotrauma.GameScreen", "AddToGUIUpdateList", function()
    promptFrame.AddToGUIUpdateList()
    if isMenuOpen then
        menuRoot.AddToGUIUpdateList()
    end
end)
