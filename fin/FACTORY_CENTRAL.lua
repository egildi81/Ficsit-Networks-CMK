-- FACTORY_CENTRAL.lua : agrégateur central du réseau de monitoring des machines de production
-- Reçoit les données de tous les FACTORY_SATELLITE, agrège, push vers le serveur web.
-- Central aggregator for the factory monitoring network.
-- Receives data from all FACTORY_SATELLITE, aggregates, pushes to web server.
--
-- Prérequis : NetworkCard + InternetCard / Requirements: NetworkCard + InternetCard
-- Port 43 : broadcast logs → GET_LOG
-- Port 50 : SHUTDOWN
-- Port 58 : FACTORY_SATELLITE → CENTRAL (données scan) / scan data from satellites
-- Port 59 : FACTORY_SATELLITE ↔ CENTRAL (découverte + commandes) / discovery + commands

local VERSION = "1.0.0"

-- === CONFIGURATION ===
local WEB_URL           = "http://127.0.0.1:8081"
local PUSH_INTERVAL     = 15  -- secondes entre push web / seconds between web push
local SAT_TIMEOUT       = 60  -- secondes avant satellite considéré mort / seconds before satellite is dead
local POLL_CMD_INTERVAL = 5   -- secondes entre poll commandes WEB / seconds between WEB command polls

-- === PORTS ===
local PORT_LOG      = 43
local PORT_SHUTDOWN = 50
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

-- Print local AVANT override / Local print BEFORE override
print("FACTORY_CENTRAL v"..VERSION)

-- print → GET_LOG (port 43 broadcast) / print → GET_LOG (port 43 broadcast)
print = function(...)
    local t={} for i=1,select('#',...)do t[i]=tostring(select(i,...))end
    pcall(function() net:broadcast(PORT_LOG,"FACTORY_CENTRAL",table.concat(t," ")) end)
end
print("=== FACTORY CENTRAL v"..VERSION.." BOOT ===")

-- === ÉTAT GLOBAL / GLOBAL STATE ===
-- satellites[addr] = { nick, lastSeen, data, version }
local satellites = {}

-- === SÉRIALISATION JSON / JSON SERIALIZATION ===
local function toJson(v)
    local t = type(v)
    if t == "nil"     then return "null"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number"  then
        if v ~= v then return "null" end  -- NaN guard
        return string.format("%.4g", v)
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

-- === AGRÉGATION / AGGREGATION ===
-- Construit la vue globale à partir de tous les satellites actifs.
-- Builds global view from all active satellites.
local function aggregateStats()
    local cutoff = computer.millis() - SAT_TIMEOUT * 1000
    local zones  = {}
    local totalMachines, activeMachines, totalPower = 0, 0, 0

    for addr, sat in pairs(satellites) do
        if sat.data then
            local isStale = not sat.lastSeen or sat.lastSeen < cutoff
            local d = sat.data

            -- Productivité moyenne des machines actives / Average productivity of active machines
            local prodSum, prodCnt = 0, 0
            for _, m in ipairs(d.machines or {}) do
                if m.active then
                    prodSum = prodSum + (m.productivity or 0)
                    prodCnt = prodCnt + 1
                end
            end
            local avgProd = prodCnt > 0 and math.floor(prodSum / prodCnt * 10) / 10 or 0

            if not isStale then
                totalMachines  = totalMachines  + (d.totalCnt  or 0)
                activeMachines = activeMachines + (d.activeCnt or 0)
                totalPower     = totalPower     + (d.totalPower or 0)
            end

            table.insert(zones, {
                name       = sat.nick,
                satellite  = sat.nick,
                addr       = addr,
                version    = sat.version or "?",
                totalCnt   = d.totalCnt   or 0,
                activeCnt  = d.activeCnt  or 0,
                totalPower = d.totalPower or 0,
                avgProd    = avgProd,
                machines   = d.machines   or {},
                ts         = d.ts,
                stale      = isStale or nil,  -- nil si actif → absent du JSON / nil if active → absent from JSON
            })
        end
    end

    return {
        ts             = computer.millis() / 1000,
        totalMachines  = totalMachines,
        activeMachines = activeMachines,
        totalPower     = math.floor(totalPower * 10) / 10,
        zones          = zones,
    }
end

-- === PUSH WEB (HTTP POST /api/factory/push) ===
-- Ne push pas si aucun satellite connu / Does not push if no satellite known
local function pushWeb()
    local satCount = 0
    for _ in pairs(satellites) do satCount = satCount + 1 end
    if satCount == 0 then return nil end

    local stats = aggregateStats()
    -- Liste des satellites avec version pour le WEB / Satellite list with version for WEB
    local satList = {}
    for addr, sat in pairs(satellites) do
        table.insert(satList, {nick=sat.nick, addr=addr, version=sat.version or "?"})
    end
    stats.satellites = satList

    local ok, f = pcall(function()
        return inet:request(WEB_URL.."/api/factory/push", "POST", toJson(stats),
            "Content-Type", "application/json")
    end)
    if not ok then print("ERR inet:request push") return nil end
    local ok2, code = pcall(function() return f:await() end)
    if not ok2 or code ~= 200 then
        print("WARN: push web échoué (HTTP "..tostring(code)..")")
    end
    return stats
end

-- === POLL COMMANDES WEB (/api/factory/central/command.lua) ===
-- Commandes supportées : reboot_satellite {addr}
-- Supported commands: reboot_satellite {addr}
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
print("FACTORY CENTRAL prêt — en attente des satellites...")
local lastPush    = 0
local lastCmdPoll = 0

while true do
    local now = computer.millis()

    -- Poll commandes WEB / WEB command poll
    if now - lastCmdPoll >= POLL_CMD_INTERVAL * 1000 then
        lastCmdPoll = computer.millis()
        pollCommand()
    end

    -- Push périodique vers web / Periodic web push
    if now - lastPush >= PUSH_INTERVAL * 1000 then
        local stats = pushWeb()
        lastPush = computer.millis()
        if stats then
            local n = 0
            for _ in pairs(satellites) do n = n + 1 end
            print(string.format("CENTRAL v%s : %d/%d actives | %.1f MW | %d sat",
                VERSION, stats.activeMachines, stats.totalMachines, stats.totalPower, n))
        end
    end

    local nextPush  = lastPush    + PUSH_INTERVAL    * 1000
    local nextCmd   = lastCmdPoll + POLL_CMD_INTERVAL * 1000
    local remaining = math.max(0.1, (math.min(nextPush, nextCmd) - computer.millis()) / 1000)
    local e,_,sndr,prt,a1,a2 = event.pull(remaining)

    if e == "NetworkMessage" then
        if prt == PORT_SHUTDOWN then
            print("SHUTDOWN → arrêt")
            computer.stop()

        -- Découverte satellite / Satellite discovery (port 59)
        elseif prt == PORT_FAC_DISC then
            if a1 == "FACTORY_SAT_HERE" then
                local nick  = a2 or sndr
                local isNew = not satellites[sndr]
                satellites[sndr] = satellites[sndr] or {}
                satellites[sndr].nick     = nick
                satellites[sndr].lastSeen = computer.millis()
                pcall(function() net:send(sndr, PORT_FAC_DISC, "FACTORY_CENTRAL_ADDR") end)
                if isNew then print("Satellite enregistré: "..nick.." ("..sndr..")") end

            elseif a1 == "MACHINES_REPORT" then
                if satellites[sndr] then
                    local ok, data = pcall(function() return (load("return "..a2))() end)
                    if ok and type(data) == "table" then
                        print("Machines "..satellites[sndr].nick..": "..#data.." unités")
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
