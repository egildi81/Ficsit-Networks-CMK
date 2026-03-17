-- LOCO_SCAN.lua : monitor live dockState + isSelfDriving + speed de T1
-- Lancer, observer les valeurs pendant que T1 roule et se gare, puis arrêter

local net = computer.getPCIDevices(classes.NetworkCard)[1]
local _p  = print
print = function(...)
    local t={} for i=1,select('#',...)do t[i]=tostring(select(i,...))end
    local msg=table.concat(t," ")
    _p(msg)
    if net then pcall(function()net:broadcast(43,"LOCO_SCAN",msg)end) end
end

local sta = component.proxy(component.findComponent("ST1")[1])
if not sta then error("ST1 introuvable") end

local trains = sta:getTrackGraph():getTrains()
if #trains == 0 then error("Aucun train sur le graphe") end

local train = trains[1]
local name  = "???"
pcall(function() name = train:getName() end)
print("Monitoring : "..name)
print("Appuie sur Stop pour arrêter")

local lastDock = -1
local lastSelf = nil

while true do
    local dock = nil
    local self = nil
    local spd  = nil

    pcall(function() dock = train.dockState end)
    pcall(function() self = train.isSelfDriving end)
    pcall(function()
        local m = train:getMaster()
        local mv = m:getMovement()
        spd = math.abs(math.floor(mv.speed / 100 * 3.6))
    end)

    -- Log uniquement si dockState change (pour ne pas spammer)
    if dock ~= lastDock or self ~= lastSelf then
        print(string.format("dockState=%s  isSelfDriving=%s  speed=%s km/h",
            tostring(dock), tostring(self), tostring(spd)))
        lastDock = dock
        lastSelf = self
    end

    event.pull(0.5)
end
