--[[
    Entry point for the "Pickpocket" mod.
    Everything under Lua/Autorun runs automatically on both the client and
    the server (in singleplayer both SERVER and CLIENT are true at once,
    since Barotrauma always runs a local server internally, even offline).
    Explicitly load the shared, server and client modules in order.
]]

local modPath = ...

dofile(modPath .. "/Lua/PickpocketShared.lua")
dofile(modPath .. "/Lua/PickpocketServer.lua")
dofile(modPath .. "/Lua/PickpocketClient.lua")
