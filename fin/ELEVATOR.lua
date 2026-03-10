-- ELEVATOR.lua : allume/éteint des ordinateurs FIN selon l'étage de l'ascenseur
-- Signal utilisé : ProductionChanged(Int State) sur chaque ElevatorFloorStop
-- Port 43 : logs → GET_LOG

-- === CONFIGURATION ===
-- Nicks des ElevatorFloorStop en jeu (champ Nick dans l'interface FIN)
local FLOOR_START = "CONTROL_CENTER"  -- arrivée ici → allumer les ordis
local FLOOR_STOP  = "EXIT"            -- arrivée ici → éteindre les ordis

-- Nicks des ComputerCase à contrôler (champ Nick dans l'interface FIN)
local COMPUTERS_TO_CONTROL = {
    "GET_LOG",
    "TRAIN_STATS",
    "TRAIN_TAB",
    "TRAIN_DETAIL",
}

-- === INIT RÉSEAU (logs → GET_LOG) ===
local net = computer.getPCIDevices(classes.NetworkCard)[1]
print = function(...)
    local t={} for i=1,select('#',...)do t[i]=tostring(select(i,...))end
    pcall(function() net:broadcast(43,"ELEVATOR",table.concat(t," ")) end)
end

-- === DÉCOUVERTE DES COMPOSANTS ===
local function findOne(nick)
    local found = component.findComponent(nick)
    if not found or #found == 0 then
        print("WARN: composant introuvable: "..nick)
        return nil
    end
    return component.proxy(found[1])
end

local floorStart = findOne(FLOOR_START)
local floorStop  = findOne(FLOOR_STOP)

if not floorStart then error("ElevatorFloorStop '"..FLOOR_START.."' introuvable") end
if not floorStop  then error("ElevatorFloorStop '"..FLOOR_STOP .."' introuvable") end

-- Résolution des ordinateurs à contrôler
local computers = {}
for _, nick in ipairs(COMPUTERS_TO_CONTROL) do
    local c = findOne(nick)
    if c then
        table.insert(computers, {nick=nick, case=c})
        print("Ordi trouvé: "..nick)
    end
end
if #computers == 0 then error("Aucun ordinateur trouvé") end

-- === ABONNEMENT AUX SIGNAUX ===
event.listen(floorStart)
event.listen(floorStop)

print("=== ELEVATOR démarré ===")
print("Déclencheur ON  : "..FLOOR_START)
print("Déclencheur OFF : "..FLOOR_STOP)
print(#computers.." ordinateur(s) contrôlé(s)")

-- === ACTIONS ===
local function startAll()
    print("Arrivée "..FLOOR_START.." → démarrage ordis")
    for _, c in ipairs(computers) do
        local ok, err = pcall(function() c.case:startComputer() end)
        if ok then print("  START: "..c.nick)
        else       print("  ERR START "..c.nick..": "..tostring(err)) end
    end
end

local function stopAll()
    print("Arrivée "..FLOOR_STOP.." → arrêt ordis")
    for _, c in ipairs(computers) do
        local ok, err = pcall(function() c.case:stopComputer() end)
        if ok then print("  STOP: "..c.nick)
        else       print("  ERR STOP "..c.nick..": "..tostring(err)) end
    end
end

-- === BOUCLE PRINCIPALE ===
while true do
    local sig, sender, state = event.pull()

    if sig == "ProductionChanged" then
        -- Log pour calibrer : noter les valeurs state reçues au premier test
        print("ProductionChanged — sender="..tostring(sender).." state="..tostring(state))

        -- State > 0 = ascenseur présent à cet étage (à confirmer au premier test)
        if state ~= nil and state > 0 then
            if sender == floorStart then
                startAll()
            elseif sender == floorStop then
                stopAll()
            end
        end
    end
end
