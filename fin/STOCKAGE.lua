-- STOCKAGE.lua : monitore plusieurs conteneurs MK2, calcule taux de remplissage,
-- répartition par type et vitesse de remplissage/vidage.
-- Port 43 : logs → GET_LOG
-- Port 46 : découverte LOGGER (WHO_IS_LOGGER → LOGGER_ADDR)
-- Port 48 : données stockage → LOGGER (net:send ciblé)

-- === CONFIGURATION ===
-- Chaque entrée = une sous-zone : { name="NOM", containers={"NICK1","NICK2",...} }
-- Avec 1 seule sous-zone  → comportement identique à l'ancien mode flat
-- Avec 2+ sous-zones      → affichage global + détail par sous-zone dans le dashboard
local CONTAINER_NAMES = {
    { name = "PRINCIPAL", containers = { "STOCKAGE_1", "STOCKAGE_2" } },
    -- { name = "SORTIE", containers = { "STOCKAGE_OUT_1" } },
}
-- Nom de zone : nick du computer (champ Nick dans l'interface FIN), ou ID en fallback
local _inst = computer.getInstance()
local ZONE_NAME     = (_inst and _inst.nick ~= "" and _inst.nick) or (_inst and _inst.id) or "STOCKAGE"
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
local _totalConf = 0
for _, sz in ipairs(CONTAINER_NAMES) do _totalConf = _totalConf + #sz.containers end
print("Zone: "..ZONE_NAME.." | Sous-zones: "..#CONTAINER_NAMES.." | Conteneurs: ".._totalConf.." | Scan: "..SCAN_INTERVAL.."s")
for _, sz in ipairs(CONTAINER_NAMES) do
    print("  ["..sz.name.."] "..#sz.containers.." conteneur(s)")
    for _, n in ipairs(sz.containers) do print("    - "..n) end
end
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
local function buildZones()
    local zones = {}
    for _, sz in ipairs(CONTAINER_NAMES) do
        local containers = {}
        for _, name in ipairs(sz.containers) do
            local found = component.findComponent(name)
            if #found > 0 then
                table.insert(containers, {name=name, box=component.proxy(found[1])})
                print("Conteneur trouvé: "..name.." → ["..sz.name.."]")
            else
                print("WARN: conteneur introuvable: "..name)
            end
        end
        table.insert(zones, {name=sz.name, containers=containers})
    end
    return zones
end

-- === SCAN D'UN INVENTAIRE ===
-- Retourne : items{[id]={name,count,max}}, slotsUsed, slotsTotal
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

-- === STATS D'UNE LISTE DE CONTENEURS ===
local function computeContainerStats(containerList)
    local slotsTotal, slotsUsed = 0, 0
    local allItems = {}
    for _, c in ipairs(containerList) do
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
    local itemStats = {}
    for id, d in pairs(allItems) do
        local slots    = math.ceil(d.count / d.max)
        local capacity = slots * d.max
        itemStats[id] = {
            name=d.name, count=d.count, max=d.max, slots=slots, capacity=capacity,
            pct     =totalItems>0 and math.floor(d.count/totalItems*1000)/10 or 0,
            slotFill=math.floor(d.count/capacity*1000)/10,
        }
    end
    local fillRate = slotsTotal>0 and (slotsUsed/slotsTotal*100) or 0
    return {
        slotsTotal = slotsTotal,
        slotsUsed  = slotsUsed,
        fillRate   = math.floor(fillRate*10)/10,
        totalItems = totalItems,
        items      = itemStats,
    }
end

-- === STATS GLOBALES + SOUS-ZONES ===
local function computeStats(zones)
    local globalSlotT, globalSlotU = 0, 0
    local globalRaw = {}
    local subzones  = {}

    for _, z in ipairs(zones) do
        local s = computeContainerStats(z.containers)
        s.name = z.name
        table.insert(subzones, s)
        globalSlotT = globalSlotT + s.slotsTotal
        globalSlotU = globalSlotU + s.slotsUsed
        for id, d in pairs(s.items) do
            if not globalRaw[id] then globalRaw[id]={name=d.name,count=0,max=d.max} end
            globalRaw[id].count = globalRaw[id].count + d.count
        end
    end

    local totalItems = 0
    for _, d in pairs(globalRaw) do totalItems = totalItems + d.count end
    local itemStats = {}
    for id, d in pairs(globalRaw) do
        local slots    = math.ceil(d.count / d.max)
        local capacity = slots * d.max
        itemStats[id] = {
            name=d.name, count=d.count, max=d.max, slots=slots, capacity=capacity,
            pct     =totalItems>0 and math.floor(d.count/totalItems*1000)/10 or 0,
            slotFill=math.floor(d.count/capacity*1000)/10,
        }
    end

    local fillRate = globalSlotT>0 and (globalSlotU/globalSlotT*100) or 0
    local result = {
        slotsTotal = globalSlotT,
        slotsUsed  = globalSlotU,
        fillRate   = math.floor(fillRate*10)/10,
        totalItems = totalItems,
        items      = itemStats,
    }
    -- champ subzones uniquement si 2+ sous-zones (sinon comportement flat identique)
    if #subzones > 1 then
        result.subzones = subzones
    end
    return result
end

-- === CALCUL VITESSE (items/min, basé sur items globaux) ===
local function computeSpeed(cur, prev, dtSec)
    local speed = {}
    if not prev or dtSec <= 0 then return speed end
    for id, d in pairs(cur.items) do
        local prevCount = prev.items[id] and prev.items[id].count or 0
        speed[id] = math.floor((d.count-prevCount)/dtSec*60*10)/10
    end
    for id, d in pairs(prev.items) do
        if not cur.items[id] then
            speed[id] = math.floor(-d.count/dtSec*60*10)/10
        end
    end
    return speed
end

-- === BOUCLE PRINCIPALE ===
local zones = buildZones()
local totalCont = 0
for _, z in ipairs(zones) do totalCont = totalCont + #z.containers end
print("STOCKAGE démarré — "..#zones.." sous-zone(s), "..totalCont.." conteneur(s), scan toutes les "..SCAN_INTERVAL.."s")

local prevStats = nil
local prevTime  = nil

while true do
    local now   = computer.millis()/1000
    local stats = computeStats(zones)
    local dtSec = prevTime and (now-prevTime) or 0
    stats.speed = computeSpeed(stats, prevStats, dtSec)
    stats.ts    = now

    if stats.subzones then
        print(string.format("%s : %.1f%% (%d/%d slots | %d items) [%d sous-zones]",
            ZONE_NAME, stats.fillRate, stats.slotsUsed, stats.slotsTotal, stats.totalItems, #stats.subzones))
    else
        print(string.format("%s : %.1f%% (%d/%d slots | %d items)",
            ZONE_NAME, stats.fillRate, stats.slotsUsed, stats.slotsTotal, stats.totalItems))
    end

    -- Envoi vers LOGGER
    if net then
        if loggerAddr then
            local ok,err = pcall(function() net:send(loggerAddr,PORT_OUT,ZONE_NAME,ser(stats)) end)
            if not ok then print("ERR send: "..tostring(err)) end
        else
            pcall(function() net:broadcast(PORT_OUT,ZONE_NAME,ser(stats)) end)
        end
    end

    prevStats = stats
    prevTime  = now

    -- Écoute pendant SCAN_INTERVAL : mise à jour loggerAddr si LOGGER redémarre
    local deadline = computer.millis() + SCAN_INTERVAL * 1000
    repeat
        local remaining = (deadline - computer.millis()) / 1000
        if remaining <= 0 then break end
        local e,_,sndr,prt,a1 = event.pull(remaining)
        if e=="NetworkMessage" and prt==46 and a1=="LOGGER_ADDR" and sndr~=loggerAddr then
            loggerAddr = sndr
            print("LOGGER mis à jour: "..sndr)
        end
    until computer.millis() >= deadline
end
