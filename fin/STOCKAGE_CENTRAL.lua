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

local VERSION = "1.2.0"

-- === CONFIGURATION ===
local WEB_URL          = "http://127.0.0.1:8081"
local PUSH_INTERVAL    = 30   -- secondes entre chaque push LOGGER+web / seconds between LOGGER+web push
local SAT_TIMEOUT      = 300  -- secondes avant de considérer un satellite mort / seconds before satellite is dead
local FAST_EXPIRY      = 90   -- secondes sans heartbeat DISPATCH → satellites retour normal / seconds without DISPATCH heartbeat
local POLL_CMD_INTERVAL = 5   -- secondes entre chaque poll commandes WEB / seconds between WEB command polls

-- === PORTS ===
local PORT_LOG      = 43
local PORT_LOGGER   = 46
local PORT_LOGGER_D = 48
local PORT_SHUTDOWN = 50
local PORT_DISPATCH = 55
local PORT_SAT_DATA = 56
local PORT_SAT_DISC = 57
local PORT_BUF      = 69  -- point-à-point BUF: vers DISPATCH / point-to-point BUF: to DISPATCH

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
-- satellites[addr] = { nick, lastSeen, data, containers{[uuid]=nick} }
local satellites  = {}
local loggerAddr  = nil
local dispatchAddr = nil

-- === SÉRIALISATION Lua (pour net:send → LOGGER) / Lua serialization (for net:send → LOGGER) ===
local function ser(v)
    if type(v)=="table" then
        -- table.concat évite les concaténations O(n²) / table.concat avoids O(n²) concatenations
        local parts = {}
        for k,vv in pairs(v) do
            table.insert(parts, (type(k)=="string" and ('["'..k..'"]') or "["..tostring(k).."]").."="..ser(vv))
        end
        return "{"..table.concat(parts,",").."}"
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

-- === POLL COMMANDES WEB (HTTP POST /api/stockage/central/command.lua) ===
-- Récupère les commandes en attente depuis le serveur web (reboot satellite, etc.)
-- Fetches pending commands from the web server (satellite reboot, etc.)
local function pollCommand()
    local ok, f = pcall(function()
        return inet:request(WEB_URL.."/api/stockage/central/command.lua", "POST", "",
            "Content-Type", "application/json")
    end)
    if not ok then return end
    local ok2, code, body = pcall(function() return f:await() end)
    if not ok2 or code ~= 200 or not body or body == "nil" then return end
    local ok3, cmd = pcall(function() return (load("return "..body))() end)
    if not ok3 or type(cmd) ~= "table" then return end
    if cmd.cmd == "reboot_satellite" then
        local addr = cmd.addr
        if addr and satellites[addr] then
            print("WEB reboot → "..satellites[addr].nick.." ("..addr..")")
            pcall(function() net:send(addr, PORT_SAT_DISC, "REBOOT") end)
        end
    end
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
                        uuid       = c.uuid,   -- UUID FIN interne / internal FIN UUID
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
    -- Liste des satellites avec version pour le WEB update / Satellite list with version for WEB update
    local satList = {}
    for addr, sat in pairs(satellites) do
        table.insert(satList, {nick=sat.nick, addr=addr, version=sat.version or "?"})
    end
    local payload = {
        ts         = computer.millis() / 1000,
        slotsTotal = totalSlots,
        slotsUsed  = usedSlots,
        fillRate   = fillRate,
        totalItems = totalItems,
        containers = allContainers,
        satellites = satList,  -- versions satellites pour le WEB / satellite versions for WEB
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

-- === MAPPING CONTENEUR → ZONE (depuis zone config WEB) ===
-- Chaque sous-zone assigne ses conteneurs → DISPATCH peut lire par nom de zone.
-- Each subzone assigns its containers → DISPATCH can read by zone name.
local containerToZone  = {}  -- {[nick] = "zoneKey"} ex: "(OIL'S CLUB) IN CHARBON COMPACT"
local zoneToContainers = {}  -- {[zoneKey] = {nick1, nick2, …}} — reverse map pour FAST_MODE / reverse map for FAST_MODE
local ZONE_CONFIG_INTERVAL = 60  -- secondes / seconds
local lastZoneConfigFetch  = -(ZONE_CONFIG_INTERVAL * 1000)  -- forcer fetch au boot / force fetch at boot

local function fetchZoneConfig()
    local ok, f = pcall(function()
        return inet:request(WEB_URL.."/api/stockage/zone-config.lua", "GET", "")
    end)
    if not ok then return end
    local ok2, code, body = pcall(function() return f:await() end)
    if not ok2 or code ~= 200 or not body or body == "nil" then return end
    local ok3, cfg = pcall(function() return (load("return "..body))() end)
    if not ok3 or type(cfg) ~= "table" then return end
    local newMap     = {}
    local newReverse = {}
    local total = 0

    local function addMapping(nick, key)
        newMap[nick] = key
        if not newReverse[key] then newReverse[key] = {} end
        table.insert(newReverse[key], nick)
        total = total + 1
    end

    for _, z in ipairs(cfg.zones or {}) do
        local zname = z.name or ""
        -- Clé zone principale : "(zname) mainLabel" si mainLabel défini, sinon "zname"
        -- Main zone key: "(zname) mainLabel" if mainLabel set, otherwise "zname"
        local mainLabel = z.mainLabel or ""
        local mainKey   = (mainLabel ~= "") and ("("..zname..") "..mainLabel) or zname
        -- Conteneurs directement dans la zone / Containers directly in the zone
        for _, nick in ipairs(z.containers or {}) do
            addMapping(nick, mainKey)
        end
        -- Conteneurs dans les sous-zones / Containers in subzones
        for _, sz in ipairs(z.subzones or {}) do
            local key = "("..zname..") "..(sz.name or "")
            for _, nick in ipairs(sz.containers or {}) do
                addMapping(nick, key)
            end
        end
    end
    containerToZone  = newMap
    zoneToContainers = newReverse
    if total > 0 then
        print("ZoneConfig: "..total.." conteneur(s) mappé(s) ("..#(cfg.zones or {}).." zones)")
    end
end

-- === ENVOI BUF: VERS DISPATCH (point-à-point port 69) ===
-- Agrège les conteneurs par zone et envoie les totaux à DISPATCH.
-- Aggregates containers by zone and sends totals to DISPATCH.
local function sendZoneBufToDispatch()
    if not dispatchAddr then return end
    if next(containerToZone) == nil then return end  -- pas de mapping / no mapping
    local cutoff = computer.millis() - SAT_TIMEOUT * 1000
    local totals = {}
    for _, sat in pairs(satellites) do
        if sat.data and sat.lastSeen and sat.lastSeen >= cutoff then
            for _, c in ipairs(sat.data.containers or {}) do
                -- UUID d'abord (nouveau format), nick en fallback (ancienne zone config)
                -- UUID first (new format), nick fallback (old zone config)
                local zkey = containerToZone[c.uuid] or containerToZone[c.nick]
                if zkey then
                    if not totals[zkey] then totals[zkey] = {items=0, slotsTotal=0, slotsUsed=0} end
                    totals[zkey].items      = totals[zkey].items      + (c.totalItems or 0)
                    totals[zkey].slotsTotal = totals[zkey].slotsTotal + (c.slotsTotal or 0)
                    totals[zkey].slotsUsed  = totals[zkey].slotsUsed  + (c.slotsUsed  or 0)
                end
            end
        end
    end
    for zkey, t in pairs(totals) do
        local msg = "BUF:"..zkey..":"..tostring(t.items)
                    ..":"..tostring(t.slotsTotal)..":"..tostring(t.slotsUsed)
        pcall(function() net:send(dispatchAddr, PORT_BUF, msg) end)
    end
end

-- === PROPAGATION FAST MODE AUX SATELLITES CONCERNÉS ===
-- Notifie uniquement les satellites qui gèrent les buffers dans la liste DISPATCH.
-- Notifies only satellites that manage buffers in the DISPATCH priority list.
local function notifyFastMode(bufferList)
    -- bufferList contient des clés de zone (ex: "(ACIERIE) TB_LFER"), pas des nicks de conteneurs.
    -- bufferList contains zone keys (e.g., "(ACIERIE) TB_LFER"), not container nicks.
    -- On résout chaque zone key → liste de nicks conteneurs via zoneToContainers (reverse map).
    -- Resolve each zone key → container nick list via zoneToContainers (reverse map).
    for addr, sat in pairs(satellites) do
        if sat.containers then
            local concerned = false
            local satUuids  = {}  -- UUIDs prioritaires pour ce satellite / priority UUIDs for this satellite
            for _, zoneKey in ipairs(bufferList) do
                local keys = zoneToContainers[zoneKey]
                if keys then
                    for _, key in ipairs(keys) do
                        -- key = UUID (nouveau format zone config) ou nick (ancien format)
                        -- key = UUID (new zone config format) or nick (old format)
                        if sat.containers[key] then
                            -- Match direct UUID / Direct UUID match
                            concerned = true
                            table.insert(satUuids, key)
                        else
                            -- Fallback nick : chercher UUID correspondant dans ce satellite
                            -- Nick fallback: search matching UUID in this satellite
                            for uuid, nick in pairs(sat.containers) do
                                if nick == key then
                                    concerned = true
                                    table.insert(satUuids, uuid)
                                    break
                                end
                            end
                        end
                    end
                end
            end
            if concerned then
                -- Envoie les UUIDs pour que le satellite filtre ses scans
                -- Send UUIDs so satellite can filter its scans
                pcall(function() net:send(addr, PORT_SAT_DISC, "FAST_MODE", ser(satUuids)) end)
            end
        end
    end
end

-- === BOUCLE PRINCIPALE / MAIN LOOP ===
print("CENTRAL prêt — en attente des satellites...")
local lastPush    = 0
local lastCmdPoll = 0

while true do
    local now = computer.millis()

    -- Poll commandes WEB (reboot satellite, etc.) / WEB command poll (satellite reboot, etc.)
    if now - lastCmdPoll >= POLL_CMD_INTERVAL * 1000 then
        lastCmdPoll = computer.millis()
        pollCommand()
    end

    -- Fetch zone config périodique / Periodic zone config fetch
    if now - lastZoneConfigFetch >= ZONE_CONFIG_INTERVAL * 1000 then
        lastZoneConfigFetch = computer.millis()
        fetchZoneConfig()
        sendZoneBufToDispatch()
    end

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

    local nextCmdPoll = lastCmdPoll + POLL_CMD_INTERVAL * 1000
    local remaining = math.max(0.1, (math.min(lastPush + PUSH_INTERVAL * 1000, nextCmdPoll) - computer.millis()) / 1000)
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
                        -- {[uuid] = nick} — évite collisions de nicks entre satellites
                        -- {[uuid] = nick} — avoids nick collisions across satellites
                        local cset     = {}
                        local contList = {}
                        for _, item in ipairs(data) do
                            if type(item) == "table" and item.uuid then
                                cset[item.uuid] = item.nick
                                table.insert(contList, {nick=item.nick, uuid=item.uuid})
                            else
                                -- Rétrocompat : ancien satellite envoie un nick string
                                -- Backward compat: old satellite sends nick string
                                local s = tostring(item)
                                cset[s] = s
                                table.insert(contList, {nick=s, uuid=s})
                            end
                        end
                        satellites[sndr].containers = cset
                        pushDiscovery(satellites[sndr].nick, sndr, contList)
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
                    -- Stocker la version du satellite / Store satellite version
                    if data.version then satellites[sndr].version = data.version end
                    -- Envoyer totaux par zone à DISPATCH / Send zone totals to DISPATCH
                    sendZoneBufToDispatch()
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
