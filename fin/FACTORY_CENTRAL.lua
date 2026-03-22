-- FACTORY_CENTRAL.lua : agrégateur central du réseau de monitoring usine
-- Reçoit les données de tous les FACTORY_SATELLITE, agrège, push vers web.
-- Central aggregator for factory monitoring network.
-- Receives data from all FACTORY_SATELLITE, aggregates, pushes to web.
--
-- Prérequis : NetworkCard + InternetCard / Requirements: NetworkCard + InternetCard
-- Port 43 : broadcast logs → GET_LOG
-- Port 61 : SHUTDOWN FACTORY (port dédié — évite cross-reboot avec STARTER port 50)
-- Port 58 : FACTORY_SATELLITE → FACTORY_CENTRAL (données scan) / scan data from satellites
-- Port 59 : FACTORY_SATELLITE ↔ FACTORY_CENTRAL (découverte + commandes) / discovery + commands

local VERSION = "1.1.0"

-- === CONFIGURATION ===
local WEB_URL          = "http://127.0.0.1:8081"
local PUSH_INTERVAL    = 30   -- secondes entre chaque push web / seconds between web push
local SAT_TIMEOUT      = 300  -- secondes avant de considérer un satellite mort / seconds before satellite dead
local POLL_CMD_INTERVAL = 5   -- secondes entre chaque poll commandes WEB / seconds between WEB command polls
local ZONE_CONFIG_INTERVAL = 60  -- secondes entre chaque fetch zone config / seconds between zone config fetch

-- === PORTS ===
local PORT_LOG      = 43
local PORT_SHUTDOWN = 61  -- port dédié FACTORY (évite cross-reboot STARTER port 50) / dedicated FACTORY shutdown port
local PORT_FAC_DATA = 58
local PORT_FAC_DISC = 59

-- === INIT MATÉRIEL / HARDWARE INIT ===
local net  = computer.getPCIDevices(classes.NetworkCard)[1]
local inet = computer.getPCIDevices(classes.FINInternetCard)[1]
if not net  then error("FACTORY_CENTRAL: pas de NetworkCard") end
if not inet then error("FACTORY_CENTRAL: pas d'InternetCard") end

event.listen(net)
net:open(PORT_SHUTDOWN)
net:open(PORT_FAC_DATA)
net:open(PORT_FAC_DISC)

-- Print local AVANT override : confirme visuellement la version en jeu sur l'écran du computer
-- Local print BEFORE override: visually confirms running version on the computer screen
print("FACTORY_CENTRAL v"..VERSION)

-- print → GET_LOG (port 43 broadcast) / print → GET_LOG (port 43 broadcast)
print = function(...)
    local t={} for i=1,select('#',...)do t[i]=tostring(select(i,...))end
    pcall(function() net:broadcast(PORT_LOG,"FACTORY_CENTRAL",table.concat(t," ")) end)
end
print("=== FACTORY_CENTRAL v"..VERSION.." BOOT ===")

-- === ÉTAT GLOBAL / GLOBAL STATE ===
-- satellites[addr] = { nick, lastSeen, data, machines{[uuid]=nick} }
local satellites = {}

-- === SÉRIALISATION JSON (pour HTTP POST — Content-Type: application/json obligatoire) ===
-- JSON serialization (for HTTP POST — Content-Type: application/json mandatory)
local function toJson(v)
    local t = type(v)
    if t == "nil"     then return "null"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number"  then
        if v ~= v then return "null" end
        return string.format("%.6g", v)
    elseif t == "string" then
        local s = v:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r')
        return '"'..s..'"'
    elseif t == "table" then
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

-- === SÉRIALISATION Lua (pour broadcast réseau) / Lua serialization (for network broadcast) ===
local function ser(v)
    if type(v)=="table" then
        local parts = {}
        for k,vv in pairs(v) do
            table.insert(parts, (type(k)=="string" and ('["'..k..'"]') or "["..tostring(k).."]").."="..ser(vv))
        end
        return "{"..table.concat(parts,",").."}"
    elseif type(v)=="number" then
        return string.format("%.4g",v)
    elseif type(v)=="boolean" then
        return v and "true" or "false"
    elseif v==nil then
        return "nil"
    else
        return '"'..tostring(v)..'"'
    end
end

-- === MAPPING MACHINE → ZONE (depuis zone config WEB) ===
-- Chaque zone assigne ses machines par UUID (clé interne) — aucun risque de collision de nicks.
-- Each zone assigns its machines by UUID (internal key) — no nick collision risk.
local machineToZone  = {}  -- {[uuid] = "zoneKey"}
local zoneToMachines = {}  -- {[zoneKey] = {uuid1, uuid2, …}} — reverse map
local lastZoneConfigFetch = -(ZONE_CONFIG_INTERVAL * 1000)  -- forcer fetch au boot / force fetch at boot

local function fetchZoneConfig()
    local ok, f = pcall(function()
        return inet:request(WEB_URL.."/api/factory/zone-config.lua", "GET", "")
    end)
    if not ok then return end
    local ok2, code, body = pcall(function() return f:await() end)
    if not ok2 or code ~= 200 or not body or body == "nil" then return end
    local ok3, cfg = pcall(function() return (load("return "..body))() end)
    if not ok3 or type(cfg) ~= "table" then return end

    local newMap     = {}
    local newReverse = {}
    local total      = 0

    local function addMapping(uuid, key)
        -- uuid = clé interne machine / machine internal key
        newMap[uuid] = key
        if not newReverse[key] then newReverse[key] = {} end
        table.insert(newReverse[key], uuid)
        total = total + 1
    end

    for _, z in ipairs(cfg.zones or {}) do
        local zname   = z.name or ""
        local mainKey = zname
        -- Machines directement dans la zone / Machines directly in the zone
        for _, uuid in ipairs(z.machines or {}) do
            addMapping(uuid, mainKey)
        end
        -- Machines dans les sous-zones / Machines in subzones
        for _, sz in ipairs(z.subzones or {}) do
            local key = "("..zname..") "..(sz.name or "")
            for _, uuid in ipairs(sz.machines or {}) do
                addMapping(uuid, key)
            end
        end
    end

    machineToZone  = newMap
    zoneToMachines = newReverse
    if total > 0 then
        print("ZoneConfig: "..total.." machine(s) mappée(s) ("..#(cfg.zones or {}).." zones)")
    end
end

-- === PUSH DISCOVERY (HTTP POST /api/factory/discovery) ===
local function pushDiscovery(satNick, satAddr, machineList)
    -- machineList = [{nick, uuid, class}] / machineList = [{nick, uuid, class}]
    local ok, f = pcall(function()
        return inet:request(WEB_URL.."/api/factory/discovery", "POST",
            toJson({satellite=satNick, addr=satAddr, machines=machineList}),
            "Content-Type", "application/json")
    end)
    if not ok then return end
    pcall(function() f:await() end)
end

-- === PUSH WEB (HTTP POST /api/factory/push) ===
local function pushWeb()
    local satCount = 0
    for _ in pairs(satellites) do satCount = satCount + 1 end
    if satCount == 0 then return end  -- ne pas écraser les données existantes / don't overwrite existing data

    local cutoff     = computer.millis() - SAT_TIMEOUT * 1000
    local allMachines = {}
    local totalMachines, producing, idle, standbyCount = 0, 0, 0, 0
    local sumProd    = 0

    for addr, sat in pairs(satellites) do
        if sat.data and sat.lastSeen then
            local isStale = sat.lastSeen < cutoff
            local ms = sat.data.machines
            if type(ms) == "table" then
                for _, m in ipairs(ms) do
                    if not isStale then
                        totalMachines = totalMachines + 1
                        sumProd       = sumProd + (m.productivity or 0)
                        if m.status == "producing"    then producing    = producing    + 1
                        elseif m.status == "standby"  then standbyCount = standbyCount + 1
                        else                               idle         = idle         + 1
                        end
                    end
                    table.insert(allMachines, {
                        satellite    = sat.nick,
                        uuid         = m.uuid,    -- UUID FIN interne / internal FIN UUID
                        nick         = m.nick,
                        class        = m.class,
                        productivity = m.productivity,
                        standby      = m.standby,
                        potential    = m.potential,
                        recipe       = m.recipe,
                        status       = m.status,
                        stale        = isStale or nil,
                    })
                end
            end
        end
    end

    local avgProd = totalMachines > 0 and math.floor(sumProd / totalMachines * 10) / 10 or 0

    -- Liste des satellites avec version / Satellite list with version
    local satList = {}
    for addr, sat in pairs(satellites) do
        table.insert(satList, {nick=sat.nick, addr=addr, version=sat.version or "?"})
    end

    local payload = {
        ts           = computer.millis() / 1000,
        total        = totalMachines,
        producing    = producing,
        idle         = idle,
        standby      = standbyCount,
        avgProd      = avgProd,
        machines     = allMachines,
        satellites   = satList,
    }

    local ok, f = pcall(function()
        return inet:request(WEB_URL.."/api/factory/push", "POST", toJson(payload),
            "Content-Type", "application/json")
    end)
    if not ok then print("ERR inet:request factory push") return end
    local ok2, code = pcall(function() return f:await() end)
    if not ok2 or code ~= 200 then
        print("WARN: push factory web échoué (HTTP "..tostring(code)..")")
    end
end

-- === POLL COMMANDES WEB (HTTP POST /api/factory/central/command.lua) ===
local function pollCommand()
    local ok, f = pcall(function()
        return inet:request(WEB_URL.."/api/factory/central/command.lua", "POST", "",
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
            pcall(function() net:send(addr, PORT_FAC_DISC, "REBOOT") end)
        end
    end
end

-- === BOUCLE PRINCIPALE / MAIN LOOP ===
print("FAC_CENTRAL prêt — en attente des satellites...")
local lastPush    = 0
local lastCmdPoll = 0

while true do
    local now = computer.millis()

    -- Poll commandes WEB / WEB command poll
    if now - lastCmdPoll >= POLL_CMD_INTERVAL * 1000 then
        lastCmdPoll = computer.millis()
        pollCommand()
    end

    -- Fetch zone config périodique / Periodic zone config fetch
    if now - lastZoneConfigFetch >= ZONE_CONFIG_INTERVAL * 1000 then
        lastZoneConfigFetch = computer.millis()
        fetchZoneConfig()
    end

    -- Push périodique vers web / Periodic web push
    if now - lastPush >= PUSH_INTERVAL * 1000 then
        pushWeb()
        lastPush = computer.millis()
        local n = 0
        for _ in pairs(satellites) do n = n + 1 end
        print(string.format("FAC_CENTRAL v%s : %d satellite(s)", VERSION, n))
    end

    local nextCmdPoll = lastCmdPoll + POLL_CMD_INTERVAL * 1000
    local remaining = math.max(0.1, (math.min(lastPush + PUSH_INTERVAL * 1000, nextCmdPoll) - computer.millis()) / 1000)
    local e,_,sndr,prt,a1,a2 = event.pull(remaining)

    if e == "NetworkMessage" then

        -- SHUTDOWN (port 50)
        if prt == PORT_SHUTDOWN then
            print("SHUTDOWN → arrêt")
            computer.stop()

        -- Découverte satellite / Satellite discovery (port 59)
        elseif prt == PORT_FAC_DISC then
            if a1 == "FAC_SAT_HERE" then
                -- Satellite annonce sa présence / Satellite announces itself
                local nick  = a2 or sndr
                local isNew = not satellites[sndr]
                satellites[sndr] = satellites[sndr] or {machines={}}
                satellites[sndr].nick     = nick
                satellites[sndr].lastSeen = computer.millis()
                pcall(function() net:send(sndr, PORT_FAC_DISC, "FAC_CENTRAL_ADDR") end)
                if isNew then print("Satellite enregistré: "..nick.." ("..sndr..")") end

            elseif a1 == "MACHINES_REPORT" then
                -- Satellite reporte ses machines découvertes / Satellite reports its discovered machines
                if satellites[sndr] then
                    local ok, data = pcall(function() return (load("return "..a2))() end)
                    if ok and type(data) == "table" then
                        -- {[uuid] = nick} — évite collisions de nicks entre satellites
                        -- {[uuid] = nick} — avoids nick collisions across satellites
                        local mset     = {}
                        local machList = {}
                        for _, item in ipairs(data) do
                            if type(item) == "table" and item.uuid then
                                mset[item.uuid] = item.nick
                                table.insert(machList, {nick=item.nick, uuid=item.uuid, class=item.class or "?"})
                            else
                                -- Rétrocompat : ancien format (ne devrait pas arriver pour FAC)
                                -- Backward compat: old format (should not happen for FAC)
                                local s = tostring(item)
                                mset[s] = s
                                table.insert(machList, {nick=s, uuid=s, class="?"})
                            end
                        end
                        satellites[sndr].machines = mset
                        pushDiscovery(satellites[sndr].nick, sndr, machList)
                        print("Discovery "..satellites[sndr].nick..": "..#data.." machines")
                    end
                end
            end

        -- Données scan depuis satellite / Scan data from satellite (port 58)
        elseif prt == PORT_FAC_DATA then
            if satellites[sndr] then
                local ok, data = pcall(function() return (load("return "..a1))() end)
                if ok and type(data) == "table" then
                    satellites[sndr].data     = data
                    satellites[sndr].lastSeen = computer.millis()
                    if data.version then satellites[sndr].version = data.version end
                end
            else
                -- Satellite inconnu : lui demander de se présenter / Unknown satellite: ask it to register
                pcall(function() net:send(sndr, PORT_FAC_DISC, "IDENTIFY") end)
            end
        end
    end
end
