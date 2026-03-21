-- FAC_SATELLITE.lua : satellite de monitoring de machines usine
-- Découvre les machines Manufacturer locales, scanne leur état, envoie à FAC_CENTRAL.
-- Factory satellite: discovers local Manufacturer machines, scans their state, sends to FAC_CENTRAL.
--
-- Prérequis : NetworkCard (+ InternetCard dans l'EEPROM uniquement pour le boot)
-- Requirements: NetworkCard (+ InternetCard in EEPROM only for boot)
-- Port 43 : broadcast logs → GET_LOG
-- Port 61 : SHUTDOWN FACTORY (port dédié — évite cross-reboot avec STARTER port 50)
-- Port 58 : données scan → FAC_CENTRAL (net:send ciblé) / scan data → FAC_CENTRAL (targeted)
-- Port 59 : FAC_SATELLITE ↔ FAC_CENTRAL (découverte + commandes) / discovery + commands

local VERSION = "1.0.0"

-- === CONFIGURATION ===
local SCAN_INTERVAL = 30    -- secondes entre chaque scan normal / seconds between normal scans
local DISC_TIMEOUT  = 15000 -- ms attente FAC_CENTRAL au boot / ms to wait for FAC_CENTRAL at boot

-- === PORTS ===
local PORT_LOG      = 43
local PORT_SHUTDOWN = 61  -- port dédié FACTORY (évite cross-reboot STARTER port 50) / dedicated FACTORY shutdown port
local PORT_FAC_DATA = 58
local PORT_FAC_DISC = 59

-- === INIT MATÉRIEL / HARDWARE INIT ===
local net = computer.getPCIDevices(classes.NetworkCard)[1]
if not net then error("FAC_SATELLITE: pas de NetworkCard") end

event.listen(net)
net:open(PORT_SHUTDOWN)
net:open(PORT_FAC_DATA)
net:open(PORT_FAC_DISC)

-- Nick du computer = identifiant du satellite / Computer nick = satellite identifier
local _inst = computer.getInstance()
local NICK  = (_inst and _inst.nick ~= "" and _inst.nick) or "FAC"

-- Print local AVANT override : confirme visuellement la version en jeu sur l'écran du computer
-- Local print BEFORE override: visually confirms running version on the computer screen
print("FAC_SATELLITE v"..VERSION.." — "..NICK)

-- print → GET_LOG (tag "FAC:NICK" pour identifier la source) / print → GET_LOG (tag "FAC:NICK" to identify source)
print = function(...)
    local t={} for i=1,select('#',...)do t[i]=tostring(select(i,...))end
    pcall(function() net:broadcast(PORT_LOG,"FAC:"..NICK,table.concat(t," ")) end)
end
print("=== FAC_SATELLITE v"..VERSION.." BOOT — "..NICK.." ===")

-- === SÉRIALISATION / SERIALIZATION ===
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
    elseif type(v)=="boolean" then
        return v and "true" or "false"
    elseif v==nil then
        return "nil"
    else
        return '"'..tostring(v)..'"'
    end
end

-- === DÉCOUVERTE FAC_CENTRAL / FAC_CENTRAL DISCOVERY ===
local centralAddr = nil
local function discoverCentral()
    print("Recherche FAC_CENTRAL...")
    pcall(function() net:broadcast(PORT_FAC_DISC, "FAC_SAT_HERE", NICK) end)
    local deadline = computer.millis() + DISC_TIMEOUT
    while computer.millis() < deadline do
        local e,_,sndr,prt,a1 = event.pull(1)
        if e=="NetworkMessage" and prt==PORT_FAC_DISC and a1=="FAC_CENTRAL_ADDR" then
            centralAddr = sndr
            print("FAC_CENTRAL trouvé: "..sndr)
            return
        end
    end
    print("WARN: FAC_CENTRAL introuvable — données envoyées dès qu'il apparaît")
end
discoverCentral()

-- === DÉCOUVERTE DES MACHINES / MACHINE DISCOVERY ===
-- Utilise classes.Manufacturer — couvre smelters, constructors, assemblers, foundries, manufacturers, refineries, blenders…
-- Uses classes.Manufacturer — covers smelters, constructors, assemblers, foundries, manufacturers, refineries, blenders...
local function discoverMachines()
    local found    = {}   -- liste de {id, nick, class} / list of {id, nick, class}
    local seen     = {}   -- dédup par id / dedup by id
    local machineIds = {}

    -- Chercher toutes les machines Manufacturer sur le réseau FIN local
    -- Find all Manufacturer machines on the local FIN network
    local ok, ids = pcall(function() return component.findComponent(classes.Manufacturer) end)
    if ok and ids then
        for _, id in ipairs(ids) do
            machineIds[#machineIds+1] = id
        end
    end

    for _, id in ipairs(machineIds) do
        local sid = tostring(id)
        if not seen[sid] then
            local ok2, proxy = pcall(function() return component.proxy(id) end)
            if ok2 and proxy then
                seen[sid] = true
                local nick = (proxy.nick and proxy.nick ~= "") and proxy.nick or ("ID:"..sid:sub(1,8))
                -- Nom de la classe pour info / Class name for info
                local ok3, className = pcall(function() return tostring(proxy.internalName or "") end)
                className = ok3 and className or "?"
                table.insert(found, {id=sid, nick=nick, class=className})
                print("  Machine: "..nick.." ["..className.."]")
            end
        end
    end

    print("Discovery: "..#found.." machine(s) trouvée(s)")
    return found
end

print("Scan des machines...")
local allMachines = discoverMachines()

-- Table {nick, uuid} pour identification sans collision de nicks
-- {nick, uuid} table for nick-collision-free identification
local allMachineIds = {}
for _, m in ipairs(allMachines) do
    table.insert(allMachineIds, {nick=m.nick, uuid=m.id, class=m.class})
end

-- Rapport au FAC_CENTRAL ({nick, uuid, class}) / Report to FAC_CENTRAL ({nick, uuid, class})
if centralAddr then
    pcall(function() net:send(centralAddr, PORT_FAC_DISC, "MACHINES_REPORT", ser(allMachineIds)) end)
end

-- === SCAN D'UNE MACHINE / MACHINE SCAN ===
local function scanMachine(proxy)
    -- Productivité (0.0 = 0%, 1.0 = 100%) / Productivity (0.0=0%, 1.0=100%)
    local ok1, prod = pcall(function() return proxy.productivity end)
    local productivity = (ok1 and prod) and (math.floor(prod * 1000) / 10) or 0  -- en % avec 1 décimale / as % with 1 decimal

    -- Pause manuelle / Manual standby
    local ok2, sb = pcall(function() return proxy.standby end)
    local standby = ok2 and (sb == true) or false

    -- Overclock / Clock speed
    local ok3, pot = pcall(function() return proxy.potential end)
    local potential = (ok3 and pot) and math.floor(pot * 100) or 100  -- en % / as %

    -- Recette courante / Current recipe
    local recipe = nil
    local ok4, r = pcall(function() return proxy:getRecipe() end)
    if ok4 and r then
        local ok5, rn = pcall(function() return r.name end)
        if ok5 and rn then recipe = tostring(rn) end
    end

    -- Statut dérivé / Derived status
    -- "producing" si prod > 1% et pas standby / "producing" if prod > 1% and not standby
    -- "standby"   si pause manuelle / if manually paused
    -- "idle"      sinon (pas de recette, attente matières) / otherwise (no recipe, waiting for input)
    local status
    if standby then
        status = "standby"
    elseif productivity > 1 then
        status = "producing"
    else
        status = "idle"
    end

    return {
        productivity = productivity,
        standby      = standby,
        potential    = potential,
        recipe       = recipe,
        status       = status,
    }
end

-- === SCAN COMPLET / FULL SCAN ===
local function scanAll()
    local machineData  = {}  -- détail par machine / per-machine detail
    local totalMachines   = #allMachines
    local producing    = 0
    local idle         = 0
    local standbyCount = 0
    local sumProd      = 0   -- somme productivité pour moyenne / sum for average

    for _, m in ipairs(allMachines) do
        event.pull(0.01)  -- yield pour éviter watchdog / yield to avoid watchdog
        local ok, proxy = pcall(function() return component.proxy(m.id) end)
        if ok and proxy then
            local s = scanMachine(proxy)
            sumProd = sumProd + s.productivity
            if s.status == "producing" then
                producing    = producing    + 1
            elseif s.status == "standby" then
                standbyCount = standbyCount + 1
            else
                idle         = idle         + 1
            end
            table.insert(machineData, {
                uuid         = m.id,     -- UUID FIN interne / internal FIN UUID
                nick         = m.nick,
                class        = m.class,
                productivity = s.productivity,
                standby      = s.standby,
                potential    = s.potential,
                recipe       = s.recipe,
                status       = s.status,
            })
        else
            print("WARN: machine inaccessible: "..m.nick)
        end
    end

    local avgProd = totalMachines > 0 and math.floor(sumProd / totalMachines * 10) / 10 or 0

    return {
        nick    = NICK,
        version = VERSION,
        ts      = computer.millis() / 1000,
        summary = {
            total    = totalMachines,
            producing    = producing,
            idle         = idle,
            standby      = standbyCount,
            avgProd  = avgProd,
        },
        machines = machineData,  -- détail par machine pour le web / per-machine detail for web
    }
end

-- === BOUCLE PRINCIPALE / MAIN LOOP ===
print(string.format("FAC Satellite prêt — %d machine(s) | Scan: %ds", #allMachines, SCAN_INTERVAL))

while true do
    local data = scanAll()

    if centralAddr then
        pcall(function() net:send(centralAddr, PORT_FAC_DATA, ser(data)) end)
    end

    -- Log périodique / Periodic log
    local s = data.summary
    print(string.format("%s : %.1f%% avg | %d prod / %d idle / %d standby (%d total)",
        NICK, s.avgProd, s.producing, s.idle, s.standby, s.total))

    -- Attente événements / Wait for events
    local deadline = computer.millis() + SCAN_INTERVAL * 1000
    repeat
        local remaining = (deadline - computer.millis()) / 1000
        if remaining <= 0 then break end
        local e,_,sndr,prt,a1,a2 = event.pull(remaining)

        if e == "NetworkMessage" then
            if prt == PORT_SHUTDOWN then
                print("SHUTDOWN → arrêt")
                computer.stop()

            elseif prt == PORT_FAC_DISC then
                if a1 == "FAC_CENTRAL_ADDR" then
                    -- FAC_CENTRAL (re)démarré / FAC_CENTRAL (re)started
                    centralAddr = sndr
                    print("FAC_CENTRAL (re)détecté: "..sndr)
                    pcall(function() net:send(centralAddr, PORT_FAC_DISC, "MACHINES_REPORT", ser(allMachineIds)) end)

                elseif a1 == "IDENTIFY" then
                    -- FAC_CENTRAL nous a perdus, on se réenregistre / FAC_CENTRAL lost us, re-register
                    pcall(function() net:send(sndr, PORT_FAC_DISC, "FAC_SAT_HERE", NICK) end)

                elseif a1 == "REBOOT" then
                    -- WEB demande une mise à jour / WEB requests update
                    print("Reboot demandé depuis WEB → redémarrage...")
                    computer.reset()
                end
            end
        end
    until computer.millis() >= deadline
end
