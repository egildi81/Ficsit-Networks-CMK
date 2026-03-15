-- STOCKAGE.lua : monitore plusieurs conteneurs MK2, calcule taux de remplissage,
-- répartition par type et vitesse de remplissage/vidage.
-- Port 43 : logs → GET_LOG
-- Port 46 : découverte LOGGER (WHO_IS_LOGGER → LOGGER_ADDR)
-- Port 48 : données stockage → LOGGER (net:send ciblé)
-- Port 55 : priorité DISPATCH → mode rapide 2s si buffer concerné | PRIORITY_REQUEST → DISPATCH

local VERSION = "1.2.0"
print("=== STOCKAGE v"..VERSION.." BOOT ===")

-- === CONFIGURATION ===
-- Chaque entrée = une sous-zone : { name="NOM", containers={"NICK1","NICK2",...} }
-- Avec 1 seule sous-zone  → comportement identique à l'ancien mode flat
-- Avec 2+ sous-zones      → affichage global + détail par sous-zone dans le dashboard
local CONTAINER_NAMES = {
    { name = "PRINCIPAL", containers = { "STOCKAGE_1", "STOCKAGE_2" } },
    -- { name = "SORTIE", containers = { "STOCKAGE_OUT_1" } },
}
-- Nom de zone : nick du computer (champ Nick dans l'interface FIN), ou ID en fallback
local _inst         = computer.getInstance()
local ZONE_NAME     = (_inst and _inst.nick ~= "" and _inst.nick) or (_inst and _inst.id) or "STOCKAGE"
local SCAN_INTERVAL = 60   -- secondes entre chaque scan en mode normal / seconds between scans in normal mode
local SCAN_FAST     = 2    -- secondes entre chaque scan en mode rapide (buffer dispatch) / fast mode scan interval
local LOG_FAST_SEC  = 30   -- intervalle de log en mode rapide (évite spam GET_LOG) / log interval in fast mode
local PORT_OUT      = 48   -- port vers LOGGER / port to LOGGER
local FAST_EXPIRY   = 90   -- secondes sans heartbeat DISPATCH → retour mode normal / seconds without DISPATCH heartbeat → revert

-- === INIT RÉSEAU / NETWORK INIT ===
local net = computer.getPCIDevices(classes.NetworkCard)[1]
if net then
    event.listen(net)
    net:open(46)
    net:open(48)
    net:open(55)  -- priorité buffers DISPATCH / DISPATCH buffer priority
    net:broadcast(43,"STOCKAGE","[boot] NetworkCard OK")
else
    error("STOCKAGE: pas de NetworkCard")
end

print = function(...)
    local t={} for i=1,select('#',...)do t[i]=tostring(select(i,...))end
    pcall(function() net:broadcast(43,"STOCKAGE",table.concat(t," ")) end)
end
print("[boot] print OK")
print("=== STOCKAGE v"..VERSION.." ===")
local _totalConf = 0
for _, sz in ipairs(CONTAINER_NAMES) do _totalConf = _totalConf + #sz.containers end
print("Zone: "..ZONE_NAME.." | Sous-zones: "..#CONTAINER_NAMES.." | Conteneurs: ".._totalConf.." | Scan: "..SCAN_INTERVAL.."s")
for _, sz in ipairs(CONTAINER_NAMES) do
    print("  ["..sz.name.."] "..#sz.containers.." conteneur(s)")
    for _, n in ipairs(sz.containers) do print("    - "..n) end
end
print("=====================")

-- === DÉCOUVERTE LOGGER (adresse pour net:send ciblé) ===
-- LOGGER discovery (address for targeted net:send)
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

-- === DÉCOUVERTE DES CONTENEURS / CONTAINER DISCOVERY ===
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

-- === SCAN D'UN INVENTAIRE / INVENTORY SCAN ===
-- Retourne : items{[id]={name,count,max}}, slotsUsed, slotsTotal
-- Returns:   items{[id]={name,count,max}}, slotsUsed, slotsTotal
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

-- === STATS D'UNE LISTE DE CONTENEURS / CONTAINER LIST STATS ===
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

-- === STATS GLOBALES + SOUS-ZONES / GLOBAL STATS + SUBZONES ===
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
    -- champ subzones uniquement si 2+ sous-zones / subzones field only if 2+ subzones
    if #subzones > 1 then result.subzones = subzones end
    return result
end

-- === CALCUL VITESSE / SPEED CALCULATION (items/min) ===
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

-- === ENVOI VERS LOGGER / SEND TO LOGGER ===
local function sendStats(stats)
    if not net then return end
    if loggerAddr then
        local ok,err = pcall(function() net:send(loggerAddr,PORT_OUT,ZONE_NAME,ser(stats)) end)
        if not ok then print("ERR send: "..tostring(err)) end
    else
        pcall(function() net:broadcast(PORT_OUT,ZONE_NAME,ser(stats)) end)
    end
end

-- === MODE RAPIDE — demandé par DISPATCH si ce STOCKAGE gère un buffer dispatch ===
-- === FAST MODE — requested by DISPATCH if this STOCKAGE manages a dispatch buffer ===
local fastMode        = false
local fastExpiry      = 0   -- millis() au-delà duquel le mode rapide expire / millis() when fast mode expires

-- Vérifie si l'un des containers de ce STOCKAGE est dans la liste prioritaire
-- Checks if any of this STOCKAGE's containers is in the priority list
local function checkPriority(bufferList)
    for _, bufNick in ipairs(bufferList) do
        for _, sz in ipairs(CONTAINER_NAMES) do
            for _, cname in ipairs(sz.containers) do
                if cname == bufNick then return true end
            end
        end
    end
    return false
end

-- Demande la liste de priorité à DISPATCH (au cas où DISPATCH est déjà démarré)
-- Request priority list from DISPATCH (in case DISPATCH is already running)
pcall(function() net:broadcast(55,"PRIORITY_REQUEST") end)
print("PRIORITY_REQUEST envoyé → attente réponse DISPATCH")

-- === BOUCLE PRINCIPALE / MAIN LOOP ===
local zones    = buildZones()
local totalCont = 0
for _, z in ipairs(zones) do totalCont = totalCont + #z.containers end
print("STOCKAGE démarré — "..#zones.." sous-zone(s), "..totalCont.." conteneur(s)")

local prevStats  = nil
local prevTime   = nil
local lastStats  = nil   -- cache pour ré-envoi immédiat si LOGGER redémarre / cache for immediate resend if LOGGER restarts
local lastLog    = 0     -- timestamp dernier log (limité en mode rapide) / last log timestamp (throttled in fast mode)

while true do
    local now    = computer.millis()/1000
    local stats  = computeStats(zones)
    local dtSec  = prevTime and (now-prevTime) or 0
    stats.speed  = computeSpeed(stats, prevStats, dtSec)
    stats.ts     = now
    lastStats    = stats

    -- Log : toujours en mode normal, throttlé à LOG_FAST_SEC en mode rapide (évite spam GET_LOG)
    -- Log: always in normal mode, throttled to LOG_FAST_SEC in fast mode (avoids GET_LOG spam)
    if not fastMode or now-lastLog >= LOG_FAST_SEC then
        lastLog = now
        if stats.subzones then
            print(string.format("%s : %.1f%% (%d/%d slots | %d items) [%d sous-zones]",
                ZONE_NAME, stats.fillRate, stats.slotsUsed, stats.slotsTotal, stats.totalItems, #stats.subzones))
        else
            print(string.format("%s : %.1f%% (%d/%d slots | %d items)",
                ZONE_NAME, stats.fillRate, stats.slotsUsed, stats.slotsTotal, stats.totalItems))
        end
    end

    sendStats(stats)
    prevStats = stats
    prevTime  = now

    -- Intervalle selon le mode / Interval depends on mode
    local interval = fastMode and SCAN_FAST or SCAN_INTERVAL
    local deadline = computer.millis() + interval * 1000

    repeat
        local remaining = (deadline - computer.millis()) / 1000
        if remaining <= 0 then break end
        local e,_,sndr,prt,a1 = event.pull(remaining)

        if e=="NetworkMessage" and prt==46 then
            if a1=="LOGGER_ADDR" then
                -- LOGGER (re)démarré — mise à jour adresse + ré-envoi immédiat
                -- LOGGER (re)started — update address + immediate resend
                loggerAddr = sndr
                print("LOGGER (re)détecté: "..sndr.." → ré-envoi immédiat")
                if lastStats then sendStats(lastStats) end
            end

        elseif e=="NetworkMessage" and prt==55 then
            -- Message de priorité depuis DISPATCH / Priority message from DISPATCH
            local ok,msg = pcall(function() return (load("return "..a1))() end)
            if ok and type(msg)=="table" and msg.priority then
                local concerned = checkPriority(msg.priority)
                fastExpiry = computer.millis() + FAST_EXPIRY * 1000
                if concerned ~= fastMode then
                    fastMode = concerned
                    if fastMode then
                        print("Mode RAPIDE activé (buffer dispatch) — scan "..SCAN_FAST.."s")
                    else
                        print("Mode NORMAL rétabli — scan "..SCAN_INTERVAL.."s")
                    end
                    -- Sortir de l'attente pour appliquer le nouvel intervalle immédiatement
                    -- Exit wait loop to apply new interval immediately
                    deadline = 0
                end
            end
        end
    until computer.millis() >= deadline

    -- Expiry mode rapide : si DISPATCH silencieux depuis FAST_EXPIRY secondes → mode normal
    -- Fast mode expiry: if DISPATCH silent for FAST_EXPIRY seconds → revert to normal mode
    if fastMode and computer.millis() > fastExpiry then
        fastMode = false
        print("Mode RAPIDE expiré ("..FAST_EXPIRY.."s sans heartbeat DISPATCH) → mode NORMAL")
    end
end
