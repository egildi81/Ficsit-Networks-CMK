-- STOCKAGE_CENTRAL.lua : agrégateur central du réseau de stockage
-- Reçoit les données de tous les STOCKAGE_SATELLITE, agrège, push vers LOGGER et web.
-- Central aggregator for the storage network.
-- Receives data from all STOCKAGE_SATELLITE, aggregates, pushes to LOGGER and web.
--
-- Prérequis : NetworkCard + InternetCard / Requirements: NetworkCard + InternetCard
-- Port 43 : broadcast logs → GET_LOG
-- Port 46 : découverte LOGGER (WHO_IS_LOGGER) / LOGGER discovery
-- Port 48 : données agrégées → LOGGER (net:send) / aggregated data → LOGGER
-- Port 50 : SHUTDOWN
-- Port 55 : DISPATCH ↔ CENTRAL (heartbeat priorité buffers) / buffer priority heartbeat
-- Port 56 : SATELLITE → CENTRAL (données scan) / scan data from satellites
-- Port 57 : SATELLITE ↔ CENTRAL (découverte + commandes) / discovery + commands

local VERSION = "1.1.3"

-- === CONFIGURATION ===
local WEB_URL       = "http://127.0.0.1:8081"
local PUSH_INTERVAL = 30    -- secondes entre chaque push LOGGER+web / seconds between LOGGER+web push
local SAT_TIMEOUT   = 300   -- secondes avant de considérer un satellite mort / seconds before satellite is dead
local FAST_EXPIRY   = 90    -- secondes sans heartbeat DISPATCH → satellites retour normal / seconds without DISPATCH heartbeat

-- === PORTS ===
local PORT_LOG      = 43
local PORT_LOGGER   = 46
local PORT_LOGGER_D = 48
local PORT_SHUTDOWN = 50
local PORT_DISPATCH = 55
local PORT_SAT_DATA = 56
local PORT_SAT_DISC = 57

-- === INIT MATÉRIEL / HARDWARE INIT ===
local net  = computer.getPCIDevices(classes.NetworkCard)[1]
local inet = computer.getPCIDevices(classes.FINInternetCard)[1]
if not net  then error("STOCKAGE_CENTRAL: pas de NetworkCard") end
if not inet then error("STOCKAGE_CENTRAL: pas d'InternetCard") end

event.listen(net)
net:open(PORT_LOGGER)
net:open(PORT_LOGGER_D)
net:open(PORT_SHUTDOWN)
net:open(PORT_DISPATCH)
net:open(PORT_SAT_DATA)
net:open(PORT_SAT_DISC)

-- Print local AVANT override : confirme visuellement la version en jeu sur l'écran du computer
-- Local print BEFORE override: visually confirms running version on the computer screen
print("CENTRAL v"..VERSION)

-- print → GET_LOG (port 43 broadcast) / print → GET_LOG (port 43 broadcast)
print = function(...)
    local t={} for i=1,select('#',...)do t[i]=tostring(select(i,...))end
    pcall(function() net:broadcast(PORT_LOG,"CENTRAL",table.concat(t," ")) end)
end
print("=== STOCKAGE CENTRAL v"..VERSION.." BOOT ===")

-- === ÉTAT GLOBAL / GLOBAL STATE ===
-- satellites[addr] = { nick, lastSeen, data, containers{nick=true} }
local satellites  = {}
local loggerAddr  = nil
local dispatchAddr = nil

-- === SÉRIALISATION Lua (pour net:send → LOGGER) / Lua serialization (for net:send → LOGGER) ===
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

-- === SÉRIALISATION JSON (pour HTTP POST — Content-Type: application/json obligatoire) ===
-- JSON serialization (for HTTP POST — Content-Type: application/json mandatory)
local function toJson(v)
    local t = type(v)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        if v ~= v then return "null" end  -- NaN / NaN guard
        return string.format("%.6g", v)
    elseif t == "string" then
        local s = v:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r')
        return '"'..s..'"'
    elseif t == "table" then
        -- Détection array : clés entières séquentielles depuis 1 / Array detection: sequential integer keys from 1
        local n, isArr = 0, true
        for k in pairs(v) do
            n = n + 1
            if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then isArr = false; break end
        end
        if isArr and n > 0 then
            local parts = {}
            for i = 1, n do table.insert(parts, toJson(v[i])) end
            return "["..table.concat(parts,",").."]"
        else
            local parts = {}
            for k, vv in pairs(v) do
                if type(k) == "string" then
                    table.insert(parts, '"'..k..'":'..toJson(vv))
                end
            end
            return "{"..table.concat(parts,",").."}"
        end
    end
    return "null"
end

-- === DÉCOUVERTE LOGGER / LOGGER DISCOVERY ===
local function discoverLogger()
    print("Recherche LOGGER...")
    pcall(function() net:broadcast(PORT_LOGGER,"WHO_IS_LOGGER") end)
    local deadline = computer.millis() + 15000
    while computer.millis() < deadline do
        local e,_,sndr,prt,a1 = event.pull(1)
        if e=="NetworkMessage" and prt==PORT_LOGGER and a1=="LOGGER_ADDR" then
            loggerAddr = sndr
            print("LOGGER trouvé: "..sndr)
            return
        end
    end
    print("WARN: LOGGER introuvable")
end
discoverLogger()

-- === AGRÉGATION / AGGREGATION ===
-- Construit la table de stats globale à partir de tous les satellites actifs.
-- Builds the global stats table from all active satellites.
local function aggregateStats()
    local cutoff = computer.millis() - SAT_TIMEOUT * 1000
    local result = {
        zone       = "CENTRAL",
        slotsTotal = 0,
        slotsUsed  = 0,
        fillRate   = 0,
        totalItems = 0,
        items      = {},
        subzones   = {},
        ts         = computer.millis() / 1000,
    }
    for addr, sat in pairs(satellites) do
        if sat.lastSeen and sat.lastSeen >= cutoff and sat.data then
            for _, zone in ipairs(sat.data.zones or {}) do
                result.slotsTotal = result.slotsTotal + (zone.slotsTotal or 0)
                result.slotsUsed  = result.slotsUsed  + (zone.slotsUsed  or 0)
                for id, item in pairs(zone.items or {}) do
                    if not result.items[id] then
                        result.items[id] = {name=item.name, count=0, max=item.max}
                    end
                    result.items[id].count = result.items[id].count + item.count
                end
                -- Nom de sous-zone : "NICK_SAT" ou "NICK_SAT / NOM_ZONE" si nommée
                -- Subzone name: "SAT_NICK" or "SAT_NICK / ZONE_NAME" if named
                local szName = zone.name and zone.name ~= "" and (sat.nick.." / "..zone.name) or sat.nick
                table.insert(result.subzones, {
                    name       = szName,
                    slotsTotal = zone.slotsTotal,
                    slotsUsed  = zone.slotsUsed,
                    fillRate   = zone.fillRate,
                    totalItems = zone.totalItems,
                    items      = zone.items,
                })
            end
        end
    end
    result.fillRate = result.slotsTotal > 0
        and math.floor(result.slotsUsed / result.slotsTotal * 1000) / 10 or 0
    for _, d in pairs(result.items) do result.totalItems = result.totalItems + d.count end
    return result
end

-- === PUSH LOGGER (port 48) ===
local function pushLogger(stats)
    if not loggerAddr then return end
    local ok, err = pcall(function() net:send(loggerAddr, PORT_LOGGER_D, "CENTRAL", ser(stats)) end)
    if not ok then print("ERR pushLogger: "..tostring(err)) end
end

-- === PUSH WEB (HTTP POST /api/stockage/push) ===
-- Envoie les données par conteneur depuis chaque satellite actif.
-- Sends per-container data from each active satellite.
-- Ne push pas si aucun satellite connu (évite d'écraser les données au reboot CENTRAL).
-- Does not push if no satellite known (avoids overwriting data on CENTRAL reboot).
-- Content-Type obligatoire pour POST FIN / Content-Type mandatory for FIN POST
local function pushWeb()
    -- Aucun satellite enregistré → ne pas écraser les données existantes sur le web
    -- No satellite registered → do not overwrite existing web data
    local satCount = 0
    for _ in pairs(satellites) do satCount = satCount + 1 end
    if satCount == 0 then return end

    local cutoff = computer.millis() - SAT_TIMEOUT * 1000
    local allContainers = {}
    local totalSlots, usedSlots, totalItems = 0, 0, 0
    for addr, sat in pairs(satellites) do
        -- Inclure tous les satellites avec données, y compris hors-ligne (marqués stale=true)
        -- Include all satellites with data, including offline ones (marked stale=true)
        if sat.data and sat.lastSeen then
            local isStale = sat.lastSeen < cutoff
            local cs = sat.data.containers
            if type(cs) == "table" then
                for _, c in ipairs(cs) do
                    -- Totaux uniquement pour les satellites actifs / Totals only for active satellites
                    if not isStale then
                        totalSlots = totalSlots + (c.slotsTotal or 0)
                        usedSlots  = usedSlots  + (c.slotsUsed  or 0)
                        totalItems = totalItems + (c.totalItems  or 0)
                    end
                    table.insert(allContainers, {
                        satellite  = sat.nick,
                        nick       = c.nick,
                        slotsTotal = c.slotsTotal,
                        slotsUsed  = c.slotsUsed,
                        fillRate   = c.fillRate,
                        totalItems = c.totalItems,
                        items      = c.items,
                        stale      = isStale or nil,  -- nil si actif → absent du JSON / nil if active → absent from JSON
                    })
                end
            end
        end
    end
    local fillRate = totalSlots > 0 and math.floor(usedSlots / totalSlots * 1000) / 10 or 0
    local payload = {
        ts         = computer.millis() / 1000,
        slotsTotal = totalSlots,
        slotsUsed  = usedSlots,
        fillRate   = fillRate,
        totalItems = totalItems,
        containers = allContainers,
    }
    local ok, f = pcall(function()
        return inet:request(WEB_URL.."/api/stockage/push", "POST", toJson(payload),
            "Content-Type", "application/json")
    end)
    if not ok then print("ERR inet:request push") return end
    local ok2, code = pcall(function() return f:await() end)
    if not ok2 or code ~= 200 then
        print("WARN: push web échoué (HTTP "..tostring(code)..")")
    end
end

-- === PUSH DISCOVERY (HTTP POST /api/stockage/discovery) ===
local function pushDiscovery(satNick, satAddr, containerNicks)
    local ok, f = pcall(function()
        return inet:request(WEB_URL.."/api/stockage/discovery", "POST",
            toJson({satellite=satNick, addr=satAddr, containers=containerNicks}),
            "Content-Type", "application/json")
    end)
    if not ok then return end
    pcall(function() f:await() end)
end

-- === PROPAGATION FAST MODE AUX SATELLITES CONCERNÉS ===
-- Notifie uniquement les satellites qui gèrent les buffers dans la liste DISPATCH.
-- Notifies only satellites that manage buffers in the DISPATCH priority list.
local function notifyFastMode(bufferList)
    for addr, sat in pairs(satellites) do
        if sat.containers then
            local concerned = false
            for _, bufNick in ipairs(bufferList) do
                if sat.containers[bufNick] then concerned = true; break end
            end
            if concerned then
                -- Passe la liste des buffers prioritaires pour que le satellite ne scanne que ceux-là
                -- Pass priority buffer list so satellite only scans those containers
                pcall(function() net:send(addr, PORT_SAT_DISC, "FAST_MODE", ser(bufferList)) end)
            end
        end
    end
end

-- === BOUCLE PRINCIPALE / MAIN LOOP ===
print("CENTRAL prêt — en attente des satellites...")
local lastPush = 0

while true do
    local now = computer.millis()

    -- Push périodique vers LOGGER + web / Periodic push to LOGGER + web
    if now - lastPush >= PUSH_INTERVAL * 1000 then
        local stats = aggregateStats()
        pushLogger(stats)
        pushWeb()  -- collecte les données par conteneur / collects per-container data
        lastPush = computer.millis()
        local n = 0
        for _ in pairs(satellites) do n = n + 1 end
        print(string.format("CENTRAL v%s : %.1f%% (%d/%d slots | %d items | %d sat)",
            VERSION, stats.fillRate, stats.slotsUsed, stats.slotsTotal, stats.totalItems, n))
    end

    local remaining = math.max(0.1, (lastPush + PUSH_INTERVAL * 1000 - computer.millis()) / 1000)
    local e,_,sndr,prt,a1,a2 = event.pull(remaining)

    if e == "NetworkMessage" then

        -- SHUTDOWN (port 50)
        if prt == PORT_SHUTDOWN then
            print("SHUTDOWN → arrêt")
            computer.stop()

        -- LOGGER (re)détecté / LOGGER (re)discovered (port 46)
        elseif prt == PORT_LOGGER and a1 == "LOGGER_ADDR" then
            loggerAddr = sndr
            print("LOGGER (re)détecté: "..sndr)

        -- Découverte satellite / Satellite discovery (port 57)
        elseif prt == PORT_SAT_DISC then
            if a1 == "SATELLITE_HERE" then
                -- Satellite annonce sa présence / Satellite announces itself
                local nick = a2 or sndr
                local isNew = not satellites[sndr]
                satellites[sndr] = satellites[sndr] or {containers={}}
                satellites[sndr].nick     = nick
                satellites[sndr].lastSeen = computer.millis()
                -- Répondre avec adresse CENTRAL / Reply with CENTRAL address
                pcall(function() net:send(sndr, PORT_SAT_DISC, "CENTRAL_ADDR") end)
                if isNew then print("Satellite enregistré: "..nick.." ("..sndr..")") end

            elseif a1 == "CONTAINERS_REPORT" then
                -- Satellite reporte ses containers découverts / Satellite reports its discovered containers
                if satellites[sndr] then
                    local ok, data = pcall(function() return (load("return "..a2))() end)
                    if ok and type(data) == "table" then
                        -- Stocker comme set pour lookup O(1) / Store as set for O(1) lookup
                        local cset = {}
                        for _, nick in ipairs(data) do cset[nick] = true end
                        satellites[sndr].containers = cset
                        pushDiscovery(satellites[sndr].nick, sndr, data)
                        print("Discovery "..satellites[sndr].nick..": "..#data.." containers")
                    end
                end
            end

        -- Données scan depuis satellite / Scan data from satellite (port 56)
        elseif prt == PORT_SAT_DATA then
            if satellites[sndr] then
                local ok, data = pcall(function() return (load("return "..a1))() end)
                if ok and type(data) == "table" then
                    satellites[sndr].data     = data
                    satellites[sndr].lastSeen = computer.millis()
                end
            else
                -- Satellite inconnu : lui demander de se présenter / Unknown satellite: ask it to register
                pcall(function() net:send(sndr, PORT_SAT_DISC, "IDENTIFY") end)
            end

        -- DISPATCH heartbeat / queries (port 55)
        elseif prt == PORT_DISPATCH then
            dispatchAddr = sndr
            local ok, msg = pcall(function() return (load("return "..a1))() end)

            if a1 == "PRIORITY_REQUEST" then
                -- DISPATCH demande état actuel / DISPATCH requests current state
                local stats = aggregateStats()
                pcall(function() net:send(sndr, PORT_DISPATCH, ser(stats)) end)

            elseif ok and type(msg) == "table" and msg.priority then
                -- Heartbeat avec liste de buffers prioritaires / Heartbeat with priority buffer list
                notifyFastMode(msg.priority)
                local stats = aggregateStats()
                pcall(function() net:send(sndr, PORT_DISPATCH, ser(stats)) end)
            end
        end
    end
end
