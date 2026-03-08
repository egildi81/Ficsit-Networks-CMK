-- PANELSCAN.lua : liste tous les modules d'un panel avec leurs positions
-- Changer PANEL_NAME selon le panel à scanner
local PANEL_NAME = "TRAFFIC_POLE"

local list = component.findComponent(PANEL_NAME)
if not list or not list[1] then
    print("Panel '"..PANEL_NAME.."' introuvable !")
else
    local panel = component.proxy(list[1])
    print("=== Scan de '"..PANEL_NAME.."' ===")
    local found = 0
    for x = 0, 15 do
        for y = 0, 10 do
            local m = panel:getModule(x, y, 0)
            if m then
                print("  ("..x..","..y..") = "..tostring(m))
                found = found + 1
            end
        end
    end
    print("Total : "..found.." module(s)")
end