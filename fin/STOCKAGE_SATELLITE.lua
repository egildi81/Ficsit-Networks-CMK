-- STOCKAGE_SATELLITE.lua : satellite de monitoring de conteneurs
-- Se connecte à STOCKAGE_CENTRAL, découvre ses containers, envoie les données de scan.
-- Storage satellite: connects to STOCKAGE_CENTRAL, discovers containers, sends scan data.
--
-- Prérequis : NetworkCard (+ InternetCard dans l'EEPROM uniquement pour le boot)
-- Requirements: NetworkCard (+ InternetCard in EEPROM only for boot)
-- Port 43 : broadcast logs → GET_LOG
-- Port 50 : SHUTDOWN
-- Port 56 : données scan → CENTRAL (net:send ciblé) / scan data → CENTRAL (targeted)
-- Port 57 : SATELLITE ↔ CENTRAL (découverte + commandes) / discovery + commands

local VERSION = "1.1.2"

-- === CONFIGURATION ===
local SCAN_INTERVAL = 60    -- secondes entre chaque scan normal / seconds between normal scans
local SCAN_FAST     = 2     -- secondes entre scans en mode priorité DISPATCH / seconds between scans in DISPATCH priority mode
local FAST_EXPIRY   = 90    -- secondes sans heartbeat DISPATCH → retour mode normal / seconds without DISPATCH heartbeat → back to normal
local DISC_TIMEOUT  = 15000 -- ms attente CENTRAL au boot / ms to wait for CENTRAL at boot

-- Classes de containers à découvrir (ajuster selon le jeu) / Container classes to discover (adjust per game)
local CONTAINER_CLASSES = {
    "Build_StorageContainerMk2_C",
    "Build_StorageContainerMk1_C",
    "Build_IndustrialContainer_C",
}

-- === PORTS ===
local PORT_LOG      = 43
local PORT_SHUTDOWN = 50
local PORT_SAT_DATA = 56
local PORT_SAT_DISC = 57

-- === INIT MATÉRIEL / HARDWARE INIT ===
local net = computer.getPCIDevices(classes.NetworkCard)[1]
if not net then error("STOCKAGE_SATELLITE: pas de NetworkCard") end

event.listen(net)
net:open(PORT_SHUTDOWN)
net:open(PORT_SAT_DATA)
net:open(PORT_SAT_DISC)

-- Nick du computer = identifiant du satellite / Computer nick = satellite identifier
local _inst = computer.getInstance()
local NICK  = (_inst and _inst.nick ~= "" and _inst.nick) or "SAT"

-- Print local AVANT override : confirme visuellement la version en jeu sur l'écran du computer
-- Local print BEFORE override: visually confirms running version on the computer screen
print("SATELLITE v"..VERSION.." — "..NICK)

-- print → GET_LOG (tag "SAT:NICK" pour identifier la source) / print → GET_LOG (tag "SAT:NICK" to identify source)
print = function(...)
    local t={} for i=1,select('#',...)do t[i]=tostring(select(i,...))end
    pcall(function() net:broadcast(PORT_LOG,"SAT:"..NICK,table.concat(t," ")) end)
end
-- Annonce version sur GET_LOG : permet de savoir à distance quelle version tourne sur chaque satellite
-- Version announcement on GET_LOG: allows remote check of which version runs on each satellite
print("=== STOCKAGE SATELLITE v"..VERSION.." BOOT — "..NICK.." ===")

-- === SÉRIALISATION / SERIALIZATION ===
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

-- === DÉCOUVERTE CENTRAL / CENTRAL DISCOVERY ===
local centralAddr = nil
local function discoverCentral()
    print("Recherche CENTRAL...")
    pcall(function() net:broadcast(PORT_SAT_DISC, "SATELLITE_HERE", NICK) end)
    local deadline = computer.millis() + DISC_TIMEOUT
    while computer.millis() < deadline do
        local e,_,sndr,prt,a1 = event.pull(1)
        if e=="NetworkMessage" and prt==PORT_SAT_DISC and a1=="CENTRAL_ADDR" then
            centralAddr = sndr
            print("CENTRAL trouvé: "..sndr)
            return
        end
    end
    print("WARN: CENTRAL introuvable — les données seront envoyées dès qu'il apparaît")
end
discoverCentral()

-- === DÉCOUVERTE DES CONTAINERS FIN / FIN CONTAINER DISCOVERY ===
-- Scanne le réseau FIN local pour trouver tous les containers accessibles.
-- Scans the local FIN network to find all accessible containers.
local function discoverContainers()
    local found     = {}   -- liste de {id, nick, class} / list of {id, nick, class}
    local nickList  = {}   -- liste de nicks pour le rapport / nick list for report
    local seen      = {}   -- dédup par id / dedup by id

    for _, className in ipairs(CONTAINER_CLASSES) do
        local ok, cls = pcall(function() return classes[className] end)
        if ok and cls then
            local ok2, ids = pcall(function() return component.findComponent(cls) end)
            if ok2 and ids then
                for _, id in ipairs(ids) do
                    local sid = tostring(id)
                    if not seen[sid] then
                        local ok3, proxy = pcall(function() return component.proxy(id) end)
                        if ok3 and proxy then
                            -- Vérifier que le composant a bien un inventaire / Verify component has an inventory
                            local ok4, invs = pcall(function() return proxy:getInventories() end)
                            if ok4 and invs and #invs > 0 then
                                local nick = (proxy.nick and proxy.nick ~= "") and proxy.nick or ("ID:"..sid:sub(1,8))
                                seen[sid]  = true
                                table.insert(found,    {id=sid, nick=nick, class=className})
                                table.insert(nickList, nick)
                                print("  Container: "..nick.." ["..className.."]")
                            end
                        end
                    end
                end
            end
        end
    end
    print("Discovery: "..#found.." container(s) trouvé(s)")
    return found, nickList
end

print("Scan des containers...")
local allContainers, allNicks = discoverContainers()

-- Rapport au CENTRAL (liste des nicks) / Report to CENTRAL (nick list)
if centralAddr then
    pcall(function() net:send(centralAddr, PORT_SAT_DISC, "CONTAINERS_REPORT", ser(allNicks)) end)
end

-- === SCAN D'UN INVENTAIRE / INVENTORY SCAN ===
local function scanInv(inv)
    local items = {}
    local used  = 0
    for i = 0, inv.size - 1 do
        local s = inv:getStack(i)
        if s.count > 0 then
            used = used + 1
            -- pcall : certains items moddés ont un type nil → évite crash SATELLITE
            -- pcall: some modded items have a nil type → prevents SATELLITE crash
            local ok, id = pcall(function() return s.item.type.internalName end)
            if ok and id then
                if not items[id] then
                    local ok2, nm = pcall(function() return s.item.type.name end)
                    local ok3, mx = pcall(function() return s.item.type.max  end)
                    items[id] = {name=(ok2 and nm or id), count=0, max=(ok3 and mx or 1) or 1}
                end
                items[id].count = items[id].count + s.count
            end
        end
    end
    return items, used, inv.size
end

-- === SCAN COMPLET DE TOUS LES CONTAINERS / FULL CONTAINER SCAN ===
local function scanAll()
    local slotsTotal, slotsUsed = 0, 0
    local allItems = {}
    local containerData = {}  -- détail par conteneur pour le web / per-container detail for web

    for _, c in ipairs(allContainers) do
        -- Yield entre chaque conteneur : laisse le jeu respirer, évite le lag sur les convoyeurs
        -- Yield between each container: lets the game breathe, prevents conveyor lag
        event.pull(0)
        local ok, proxy = pcall(function() return component.proxy(c.id) end)
        if ok and proxy then
            local ok2, invs = pcall(function() return proxy:getInventories() end)
            if ok2 and invs and invs[1] then
                local items, used, total = scanInv(invs[1])
                slotsTotal = slotsTotal + total
                slotsUsed  = slotsUsed  + used
                for id, d in pairs(items) do
                    if not allItems[id] then allItems[id]={name=d.name,count=0,max=d.max} end
                    allItems[id].count = allItems[id].count + d.count
                end
                -- Agréger les stats par conteneur / Per-container stats
                local cTotal = 0
                for _, d in pairs(items) do cTotal = cTotal + d.count end
                local cFill = total > 0 and math.floor(used / total * 1000) / 10 or 0
                table.insert(containerData, {
                    nick       = c.nick,
                    slotsTotal = total,
                    slotsUsed  = used,
                    fillRate   = cFill,
                    totalItems = cTotal,
                    items      = items,
                })
            else
                print("WARN: inventaire inaccessible: "..c.nick)
            end
        end
    end

    local totalItems = 0
    for _, d in pairs(allItems) do totalItems = totalItems + d.count end
    local fillRate   = slotsTotal > 0 and math.floor(slotsUsed / slotsTotal * 1000) / 10 or 0

    return {
        nick = NICK,
        ts   = computer.millis() / 1000,
        zones = {{
            name       = "",
            slotsTotal = slotsTotal,
            slotsUsed  = slotsUsed,
            fillRate   = fillRate,
            totalItems = totalItems,
            items      = allItems,
        }},
        containers = containerData,  -- détail par conteneur pour le web / per-container detail for web
    }
end

-- === BOUCLE PRINCIPALE / MAIN LOOP ===
-- Mode rapide (FAST_MODE) activé par DISPATCH quand buffers prioritaires concernés.
-- Fast mode activated by DISPATCH when priority buffers are involved.
local fastMode  = false
local fastUntil = 0  -- computer.millis() deadline pour le mode rapide / fast mode expiry

print(string.format("Satellite prêt — %d container(s) | Scan: %ds / fast: %ds", #allContainers, SCAN_INTERVAL, SCAN_FAST))

while true do
    -- Vérification expiry mode rapide / Fast mode expiry check
    if fastMode and computer.millis() > fastUntil then
        fastMode = false
        print("Mode normal restauré ("..SCAN_INTERVAL.."s)")
    end

    local interval = fastMode and SCAN_FAST or SCAN_INTERVAL

    -- Scan + envoi / Scan + send
    local data = scanAll()
    if centralAddr then
        pcall(function() net:send(centralAddr, PORT_SAT_DATA, ser(data)) end)
    end

    -- Log périodique uniquement en mode normal (évite le flood en mode rapide)
    -- Periodic log only in normal mode (avoids flooding in fast mode)
    if not fastMode then
        local z = data.zones[1]
        print(string.format("%s (v%s) : %.1f%% (%d/%d slots | %d items)",
            NICK, VERSION, z.fillRate, z.slotsUsed, z.slotsTotal, z.totalItems))
    end

    -- Attente événements / Wait for events
    local deadline = computer.millis() + interval * 1000
    repeat
        local remaining = (deadline - computer.millis()) / 1000
        if remaining <= 0 then break end
        local e,_,sndr,prt,a1 = event.pull(remaining)

        if e == "NetworkMessage" then
            if prt == PORT_SHUTDOWN then
                print("SHUTDOWN → arrêt")
                computer.stop()

            elseif prt == PORT_SAT_DISC then
                if a1 == "CENTRAL_ADDR" then
                    -- CENTRAL (re)démarré / CENTRAL (re)started
                    centralAddr = sndr
                    print("CENTRAL (re)détecté: "..sndr)
                    pcall(function() net:send(centralAddr, PORT_SAT_DISC, "CONTAINERS_REPORT", ser(allNicks)) end)

                elseif a1 == "IDENTIFY" then
                    -- CENTRAL nous a perdus, on se réenregistre / CENTRAL lost us, re-register
                    pcall(function() net:send(sndr, PORT_SAT_DISC, "SATELLITE_HERE", NICK) end)

                elseif a1 == "FAST_MODE" then
                    -- DISPATCH a des buffers prioritaires sur ce satellite → passer en mode rapide
                    -- DISPATCH has priority buffers on this satellite → switch to fast mode
                    if not fastMode then print("Mode rapide activé ("..SCAN_FAST.."s) — DISPATCH prio") end
                    fastMode  = true
                    fastUntil = computer.millis() + FAST_EXPIRY * 1000
                end
            end
        end
    until computer.millis() >= deadline
end
