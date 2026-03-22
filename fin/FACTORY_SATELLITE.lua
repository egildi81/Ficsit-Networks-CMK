-- FACTORY_SATELLITE.lua : satellite de monitoring des machines de production
-- Se connecte à FACTORY_CENTRAL, découvre les machines FIN locales, envoie les données de scan.
-- Factory satellite: connects to FACTORY_CENTRAL, discovers local FIN machines, sends scan data.
--
-- Prérequis : NetworkCard (+ InternetCard dans l'EEPROM pour le boot)
-- Requirements: NetworkCard (+ InternetCard in EEPROM for boot)
-- Port 43 : broadcast logs → GET_LOG
-- Port 50 : SHUTDOWN
-- Port 58 : données scan → FACTORY_CENTRAL (net:send ciblé) / scan data → FACTORY_CENTRAL (targeted)
-- Port 59 : FACTORY_SAT ↔ FACTORY_CENTRAL (découverte + commandes) / discovery + commands

local VERSION = "1.1.0"

-- === CONFIGURATION ===
-- Classes de machines à monitorer (vanilla uniquement — retirer si non utilisé)
-- Machine classes to monitor (vanilla only — remove if not used)
local MACHINE_CLASSES = {
    -- Extracteurs / Extractors
    "Build_MinerMk1_C", "Build_MinerMk2_C", "Build_MinerMk3_C",
    "Build_OilPump_C", "Build_WaterPump_C",
    "Build_FrackingExtractor_C",
    -- Production standard / Standard production
    "Build_SmelterMk1_C", "Build_FoundryMk1_C",
    "Build_ConstructorMk1_C", "Build_AssemblerMk1_C",
    "Build_ManufacturerMk1_C",
    "Build_OilRefinery_C", "Build_Blender_C",
    "Build_Packager_C", "Build_HadronCollider_C",
    -- Mise à jour 8 / Update 8
    "Build_QuantumEncoder_C", "Build_Converter_C",
}

local SCAN_INTERVAL = 10    -- secondes entre chaque scan / seconds between scans
local DISC_TIMEOUT  = 15000 -- ms attente CENTRAL au boot / ms waiting for CENTRAL at boot

-- === PORTS ===
local PORT_LOG      = 43
local PORT_SHUTDOWN = 50
local PORT_FAC_DATA = 58
local PORT_FAC_DISC = 59

-- === INIT MATÉRIEL / HARDWARE INIT ===
local net = computer.getPCIDevices(classes.NetworkCard)[1]
if not net then error("FACTORY_SATELLITE: pas de NetworkCard") end

event.listen(net)
net:open(PORT_SHUTDOWN)
net:open(PORT_FAC_DATA)
net:open(PORT_FAC_DISC)

-- Nick du computer = identifiant du satellite / Computer nick = satellite identifier
local _inst = computer.getInstance()
local NICK  = (_inst and _inst.nick ~= "" and _inst.nick) or "FAC_SAT"

-- Print local AVANT override : confirme visuellement la version en jeu sur l'écran du computer
-- Local print BEFORE override: visually confirms running version on the computer screen
print("FACTORY_SATELLITE v"..VERSION.." — "..NICK)

-- print → GET_LOG (tag "FACTORY:NICK" pour identifier la source) / print → GET_LOG (tag "FACTORY:NICK" to identify source)
print = function(...)
    local t={} for i=1,select('#',...)do t[i]=tostring(select(i,...))end
    pcall(function() net:broadcast(PORT_LOG,"FACTORY:"..NICK,table.concat(t," ")) end)
end
print("=== FACTORY SATELLITE v"..VERSION.." BOOT — "..NICK.." ===")

-- === SÉRIALISATION / SERIALIZATION ===
local function ser(v)
    local t = type(v)
    if t == "table" then
        local parts = {}
        for k,vv in pairs(v) do
            table.insert(parts, (type(k)=="string" and ('["'..k..'"]') or "["..tostring(k).."]").."="..ser(vv))
        end
        return "{"..table.concat(parts,",").."}"
    elseif t == "number"  then return string.format("%.4g", v)
    elseif t == "boolean" then return tostring(v)
    else return '"'..tostring(v):gsub('\\','\\\\'):gsub('"','\\"')..'"' end
end

-- === DÉCOUVERTE CENTRAL / CENTRAL DISCOVERY ===
local centralAddr = nil
local function discoverCentral()
    print("Recherche FACTORY_CENTRAL...")
    pcall(function() net:broadcast(PORT_FAC_DISC, "FACTORY_SAT_HERE", NICK) end)
    local deadline = computer.millis() + DISC_TIMEOUT
    while computer.millis() < deadline do
        local e,_,sndr,prt,a1 = event.pull(1)
        if e=="NetworkMessage" and prt==PORT_FAC_DISC and a1=="FACTORY_CENTRAL_ADDR" then
            centralAddr = sndr
            print("CENTRAL trouvé: "..sndr)
            return
        end
    end
    print("WARN: FACTORY_CENTRAL introuvable — envoi dès qu'il apparaît")
end
discoverCentral()

-- === DÉCOUVERTE DES MACHINES / MACHINE DISCOVERY ===
-- Scanne le réseau FIN local pour toutes les machines accessibles.
-- Scans the local FIN network to find all accessible machines.
local function discoverMachines()
    local found  = {}
    local report = {}  -- liste de nicks pour rapport CENTRAL / nick list for CENTRAL report
    local seen   = {}

    for _, className in ipairs(MACHINE_CLASSES) do
        local ok, cls = pcall(function() return classes[className] end)
        if ok and cls then
            local ok2, ids = pcall(function() return component.findComponent(cls) end)
            if ok2 and ids then
                for _, id in ipairs(ids) do
                    local sid = tostring(id)
                    if not seen[sid] then
                        local ok3, proxy = pcall(function() return component.proxy(id) end)
                        if ok3 and proxy then
                            seen[sid] = true
                            -- Nick : proxy.nick si défini, sinon classe abrégée + ID court
                            -- Nick: proxy.nick if set, otherwise abbreviated class + short ID
                            local ok4, pn = pcall(function() return proxy.nick end)
                            local nick = (ok4 and pn and pn ~= "") and pn
                                or (className:match("Build_(.-)_C") or "MACHINE").."_"..sid:sub(1,6)
                            table.insert(found,  {id=sid, nick=nick, class=className})
                            table.insert(report, nick)
                        end
                    end
                end
            end
        end
        event.pull(0.01)  -- yield entre classes pour éviter timeout FIN / yield between classes to avoid FIN timeout
    end
    print("Discovery: "..#found.." machine(s) trouvée(s)")
    return found, report
end

print("Scan des machines...")
local allMachines, allNicks = discoverMachines()

if centralAddr then
    pcall(function() net:send(centralAddr, PORT_FAC_DISC, "MACHINES_REPORT", ser(allNicks)) end)
end

-- === SCAN D'UN INVENTAIRE / INVENTORY SCAN ===
local function scanInv(inv)
    if not inv then return {}, 0, 0 end
    local ok0, sz = pcall(function() return inv.size end)
    if not ok0 or not sz or sz == 0 then return {}, 0, 0 end
    local items = {}
    local used  = 0
    for i = 0, sz - 1 do
        local ok, s = pcall(function() return inv:getStack(i) end)
        if ok and s and s.count > 0 then
            used = used + 1
            local ok2, nm = pcall(function() return s.item.type.name end)
            if ok2 and nm then items[nm] = (items[nm] or 0) + s.count end
        end
    end
    -- Convertir en array / Convert to array
    local arr = {}
    for name, count in pairs(items) do table.insert(arr, {name=name, count=count}) end
    local fill = math.floor(used / sz * 1000) / 10
    return arr, fill, sz
end

-- === SCAN D'UNE MACHINE / MACHINE SCAN ===
local function scanMachine(m)
    local ok0, proxy = pcall(function() return component.proxy(m.id) end)
    if not ok0 or not proxy then return nil end

    -- État / State
    local standby = true
    pcall(function() standby = proxy.standby end)

    local productivity = 0
    pcall(function() productivity = math.floor((proxy.productivity or 0) * 1000) / 10 end)  -- → %

    local progress = 0
    pcall(function() progress = math.floor((proxy.progress or 0) * 1000) / 10 end)  -- → %

    local cycleTime = 0
    pcall(function() cycleTime = math.floor((proxy.cycleTime or 0) * 10) / 10 end)  -- secondes / seconds

    -- Puissance consommée pendant la production (MW) / Power consumed while producing (MW)
    local power = 0
    pcall(function() power = math.floor((proxy.powerConsumProducing or 0) * 10) / 10 end)

    -- Overclock : potential FIN = 0-1 → converti en % / FIN potential = 0-1 → converted to %
    local potential = 100.0
    pcall(function() potential = math.floor((proxy.potential or 1) * 1000) / 10 end)

    -- Recette et attendus / Recipe and expected items
    local recipeName  = nil
    local ingredients = {}
    local products    = {}
    pcall(function()
        local r = proxy:getRecipe()
        if r then
            pcall(function() recipeName = r.name end)
            pcall(function()
                for _, ia in ipairs(r:getIngredients() or {}) do
                    local nm, amt
                    pcall(function() nm  = ia.type.name end)
                    pcall(function() amt = ia.amount    end)
                    if nm then table.insert(ingredients, {name=nm, amount=amt or 0}) end
                end
            end)
            pcall(function()
                for _, ia in ipairs(r:getProducts() or {}) do
                    local nm, amt
                    pcall(function() nm  = ia.type.name end)
                    pcall(function() amt = ia.amount    end)
                    if nm then table.insert(products, {name=nm, amount=amt or 0}) end
                end
            end)
        end
    end)

    -- Taux réel en items/min selon rendement actuel / Real rate in items/min at current productivity
    -- Formule : amount / cycleTime * 60 * (productivity / 100)
    -- Formula:  amount / cycleTime * 60 * (productivity / 100)
    if cycleTime > 0 then
        local effFactor = productivity / 100
        for _, ing in ipairs(ingredients) do
            ing.ratePerMin = math.floor(ing.amount / cycleTime * 60 * effFactor * 100) / 100
        end
        for _, prod in ipairs(products) do
            prod.ratePerMin = math.floor(prod.amount / cycleTime * 60 * effFactor * 100) / 100
        end
    end

    -- Inventaires entrée / sortie / Input / output inventories
    local inputItems,  inputFill  = {}, 0
    local outputItems, outputFill = {}, 0
    pcall(function() inputItems,  inputFill  = scanInv(proxy:getInputInv())  end)
    pcall(function() outputItems, outputFill = scanInv(proxy:getOutputInv()) end)

    return {
        nick         = m.nick,
        class        = m.class,
        active       = not standby,
        productivity = productivity,   -- % efficacité / efficiency %
        progress     = progress,       -- % cycle en cours / current cycle %
        cycleTime    = cycleTime,      -- secondes / seconds
        power        = power,          -- MW
        potential    = potential,      -- % overclock
        recipe       = recipeName,
        ingredients  = ingredients,    -- attendu en entrée par cycle / expected input per cycle
        products     = products,       -- attendu en sortie par cycle / expected output per cycle
        inputItems   = inputItems,     -- inventaire entrée actuel / current input inventory
        outputItems  = outputItems,    -- inventaire sortie actuel / current output inventory
        inputFill    = inputFill,      -- % slots occupés entrée / input fill %
        outputFill   = outputFill,     -- % slots occupés sortie / output fill %
    }
end

-- === SCAN COMPLET / FULL SCAN ===
local function scanAll()
    local machines  = {}
    local activeCnt = 0
    local totalPow  = 0
    for i, m in ipairs(allMachines) do
        if i > 1 and i % 5 == 1 then event.pull(0.01) end  -- yield tous les 5 / yield every 5
        local data = scanMachine(m)
        if data then
            table.insert(machines, data)
            if data.active then
                activeCnt = activeCnt + 1
                totalPow  = totalPow + (data.power or 0)
            end
        end
    end
    return {
        nick       = NICK,
        version    = VERSION,
        ts         = computer.millis() / 1000,
        activeCnt  = activeCnt,
        totalCnt   = #allMachines,
        totalPower = math.floor(totalPow * 10) / 10,
        machines   = machines,
    }
end

-- === BOUCLE PRINCIPALE / MAIN LOOP ===
print(string.format("Satellite prêt — %d machine(s) | Scan: %ds", #allMachines, SCAN_INTERVAL))

while true do
    local data = scanAll()
    if centralAddr then
        pcall(function() net:send(centralAddr, PORT_FAC_DATA, ser(data)) end)
    end
    print(string.format("%s : %d/%d actives | %.1f MW",
        NICK, data.activeCnt, data.totalCnt, data.totalPower))

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
                if a1 == "FACTORY_CENTRAL_ADDR" then
                    centralAddr = sndr
                    print("CENTRAL (re)détecté: "..sndr)
                    pcall(function() net:send(centralAddr, PORT_FAC_DISC, "MACHINES_REPORT", ser(allNicks)) end)
                elseif a1 == "IDENTIFY" then
                    pcall(function() net:send(sndr, PORT_FAC_DISC, "FACTORY_SAT_HERE", NICK) end)
                elseif a1 == "REBOOT" then
                    print("Reboot demandé depuis WEB → redémarrage...")
                    computer.reset()
                end
            end
        end
    until computer.millis() >= deadline
end
