-- PANEL_INSPECT_MIN.lua
-- Version minimale : écoute les événements d'un panel et affiche la source

local PANEL_NICK = "Panel"
local MAX_X, MAX_Y, MAX_Z = 12, 12, 2

local ids = component.findComponent(PANEL_NICK)
if not ids or #ids == 0 then
    error("Panel introuvable: " .. PANEL_NICK)
end

local panel = component.proxy(ids[1])
local map = {}
local count = 0

for z = 0, MAX_Z do
    for y = 0, MAX_Y do
        for x = 0, MAX_X do
            local ok, mod = pcall(panel.getModule, panel, x, y, z)
            if ok and mod then
                map[tostring(mod)] = string.format("(%d,%d,%d)", x, y, z)
                event.listen(mod)
                count = count + 1
            end
        end
    end
end

print("Panel:", PANEL_NICK, "| modules écoutés:", count)
print("Appuie sur un bouton / tourne un knob...")

while true do
    local e = {event.pull()}
    local src = "?"
    for i = 2, #e do
        local p = map[tostring(e[i])]
        if p then src = p break end
    end
    print("[" .. tostring(e[1]) .. "] src=" .. src)
end
