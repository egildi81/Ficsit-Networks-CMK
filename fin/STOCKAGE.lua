-- STOCKAGE.lua : monitore plusieurs conteneurs MK2, calcule taux de remplissage,
-- répartition par type et vitesse de remplissage/vidage.
-- Port 43 : logs → GET_LOG
-- Port 46 : découverte LOGGER (WHO_IS_LOGGER → LOGGER_ADDR)
-- Port 48 : données stockage → LOGGER (net:send ciblé)

-- === CONFIGURATION ===
local CONTAINER_NAMES = {
    "STOCKAGE_1",
    "STOCKAGE_2",
    -- ajouter ici les nicknames des conteneurs supplémentaires
}
local ZONE_NAME     = "ELECT"  -- nom de zone affiché dans le dashboard web (unique par instance)
local SCAN_INTERVAL = 60  -- secondes entre chaque scan
local PORT_OUT      = 48  -- port vers LOGGER

-- === INIT RÉSEAU ===
local net = computer.getPCIDevices(classes.NetworkCard)[1]
if net then
    event.listen(net)
    net:open(46)
    net:open(48)
    net:broadcast(43,"STOCKAGE","[boot] NetworkCard OK")
else
    error("STOCKAGE: pas de NetworkCard")
end

print = function(...)
    local t={} for i=1,select('#',...)do t[i]=tostring(select(i,...))end
    pcall(function() net:broadcast(43,"STOCKAGE",table.concat(t," ")) end)
end
print("[boot] print OK")
print("=== STOCKAGE BOOT ===")
print("Conteneurs configurés: "..#CONTAINER_NAMES)
for i, n in ipairs(CONTAINER_NAMES) do
    print("  ["..i.."] "..n)
end
print("Scan interval: "..SCAN_INTERVAL.."s | Port out: "..PORT_OUT)
print("=====================")

-- === DÉCOUVERTE LOGGER (adresse pour net:send ciblé) ===
local loggerAddr = nil
local function discoverLogger()
    if not net then return end
    print("Recherche LOGGER...")
    pcall(function() net:broadcast(46,"WHO_IS_LOGGER") end)
    local deadline = computer.millis() + 15000
    while computer.millis() < deadline do
        local e,_,sndr,prt,a1 = event.pull(1)
        if e=="NetworkMessage" and prt==46 and a1=="LOGGER_ADDR" then
            loggerAddr = sndr
            print("LOGGER trouvé: "..sndr)
            return
        end
    end
    print("WARN: LOGGER introuvable, mode broadcast fallback")
end
discoverLogger()

-- === SÉRIALISATION (pour envoi port 48) ===
local function ser(v)
    if type(v)=="table" then
        local s="{"
        for k,vv in pairs(v) do
            s=s..(type(k)=="string" and ('["'..k..'"]') or "["..tostring(k).."]").."="..ser(vv)..","
        end
        return s.."}"
    elseif type(v)=="number" then
        return string.format("%.4g",v)
    else
        return '"'..tostring(v)..'"'
    end
end

-- === DÉCOUVERTE DES CONTENEURS ===
local function findContainers()
    local list = {}
    for _, name in ipairs(CONTAINER_NAMES) do
        local found = component.findComponent(name)
        if #found > 0 then
            table.insert(list, {name=name, box=component.proxy(found[1])})
            print("Conteneur trouvé: "..name)
        else
            print("WARN: conteneur introuvable: "..name)
        end
    end
    return list
end

-- === SCAN D'UN INVENTAIRE ===
-- Retourne : items{[id]={name,count}}, slotsUsed, slotsTotal
local function scanInv(inv)
    local items = {}
    local used  = 0
    for i = 0, inv.size-1 do
        local s = inv:getStack(i)
        if s.count > 0 then
            used = used + 1
            local id = s.item.type.internalName
            if not items[id] then
                items[id] = {name=s.item.type.name, count=0, max=s.item.type.max or 1}
            end
            items[id].count = items[id].count + s.count
        end
    end
    return items, used, inv.size
end

-- === CALCUL STATS GLOBALES ===
local function computeStats(containers)
    local slotsTotal = 0
    local slotsUsed  = 0
    local allItems   = {}

    for _, c in ipairs(containers) do
        local ok, inv = pcall(function() return c.box:getInventories()[1] end)
        if ok and inv then
            local items, used, total = scanInv(inv)
            slotsTotal = slotsTotal + total
            slotsUsed  = slotsUsed  + used
            for id, d in pairs(items) do
                if not allItems[id] then allItems[id]={name=d.name,count=0,max=d.max} end
                allItems[id].count = allItems[id].count + d.count
            end
        else
            print("ERR: impossible de lire "..c.name.." err="..tostring(inv))
        end
    end

    local totalItems = 0
    for _, d in pairs(allItems) do totalItems = totalItems + d.count end

    local fillRate = slotsTotal>0 and (slotsUsed/slotsTotal*100) or 0

    -- % par type d'item + capacité réelle (slots * max)
    local itemStats = {}
    for id, d in pairs(allItems) do
        local slots    = math.ceil(d.count / d.max)          -- slots physiques occupés
        local capacity = slots * d.max                        -- capacité max de ces slots
        itemStats[id] = {
            name     = d.name,
            count    = d.count,
            max      = d.max,
            slots    = slots,
            capacity = capacity,
            pct      = totalItems>0 and math.floor(d.count/totalItems*1000)/10 or 0,
            slotFill = math.floor(d.count/capacity*1000)/10, -- % remplissage des slots utilisés
        }
    end

    return {
        containers = #containers,
        slotsTotal = slotsTotal,
        slotsUsed  = slotsUsed,
        fillRate   = math.floor(fillRate*10)/10,
        totalItems = totalItems,
        items      = itemStats,
    }
end

-- === CALCUL VITESSE (items/min par type) ===
local function computeSpeed(cur, prev, dtSec)
    local speed = {}
    if not prev or dtSec <= 0 then return speed end
    for id, d in pairs(cur.items) do
        local prevCount = prev.items[id] and prev.items[id].count or 0
        speed[id] = math.floor((d.count-prevCount)/dtSec*60*10)/10
    end
    -- types qui ont disparu → vitesse négative
    for id, d in pairs(prev.items) do
        if not cur.items[id] then
            speed[id] = math.floor(-d.count/dtSec*60*10)/10
        end
    end
    return speed
end

-- === BOUCLE PRINCIPALE ===
local containers = findContainers()
print("STOCKAGE démarré — "..#containers.." conteneur(s), scan toutes les "..SCAN_INTERVAL.."s")

local prevStats = nil
local prevTime  = nil

while true do
    local now = computer.millis()/1000
    local stats = computeStats(containers)
    local dtSec = prevTime and (now-prevTime) or 0
    stats.speed = computeSpeed(stats, prevStats, dtSec)
    stats.ts    = now

    print(string.format("%s : %.1f%% (%d/%d slots | %d items)",
        ZONE_NAME, stats.fillRate, stats.slotsUsed, stats.slotsTotal, stats.totalItems))

    -- Envoi vers LOGGER
    if net then
        if loggerAddr then
            local ok,err=pcall(function() net:send(loggerAddr,PORT_OUT,ZONE_NAME,ser(stats)) end)
            if not ok then print("ERR send: "..tostring(err)) end
        else
            pcall(function() net:broadcast(PORT_OUT,ZONE_NAME,ser(stats)) end)
        end
    end

    prevStats = stats
    prevTime  = now

    -- Écoute pendant SCAN_INTERVAL : mise à jour loggerAddr si LOGGER redémarre
    local e,_,sndr,prt,a1 = event.pull(SCAN_INTERVAL)
    if e=="NetworkMessage" and prt==46 and a1=="LOGGER_ADDR" then
        loggerAddr = sndr
        print("LOGGER mis à jour: "..sndr)
    end
end
