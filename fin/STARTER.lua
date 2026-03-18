-- STARTER.lua : panneau de démarrage — contrôle la séquence d'allumage/extinction des ordinateurs
-- Séquence ON : sw1 → sw2 | Séquence OFF : sw2 → sw1 | Mauvais ordre → son d'erreur
local VERSION = "1.2.3"
local panel1 = component.proxy(component.findComponent("PANEL_L")[1])
local net    = computer.getPCIDevices(classes.NetworkCard)[1]

-- === LOG → GET_LOG ===
print=function(...)local t={}for i=1,select('#',...)do t[i]=tostring(select(i,...))end
    pcall(function()net:broadcast(43,"STARTER",table.concat(t," "))end)end
print("STARTER v"..VERSION.." démarré")

local swL = panel1:getModule(2, 6, 0)
local swR = panel1:getModule(8, 6, 0)

-- === CONTRÔLE ORDINATEURS (séquence sw1→sw2 / sw2→sw1) ===
-- Sons (noms de fichiers sans extension, à déposer sur le serveur FIN)
-- Remplacer les valeurs ci-dessous par vos propres fichiers si besoin
local SOUND_START = "MS95Start"   -- démarrage des ordis  → MS95Start.ogg
local SOUND_STOP  = "W95Stop"     -- extinction des ordis → W95Stop.ogg
local SOUND_ERROR = "W2kError"    -- mauvaise séquence    → W2kError.ogg

-- LOGGER, GET_LOG, DISPATCH et STOCKAGE_CENTRAL tournent en autonome — ne pas les couper
-- LOGGER, GET_LOG, DISPATCH and STOCKAGE_CENTRAL run autonomously — do not stop them
local COMPUTERS_TO_CONTROL = { "TRAIN_STATS", "TRAIN_TAB", "TRAIN_DETAIL" }

-- Adresse réseau de GET_LOG — capturée à son boot via GET_LOG_HELLO (port 52)
-- GET_LOG network address — captured at its boot via GET_LOG_HELLO (port 52)
local getlogAddr = nil
net:open(52)
event.listen(net)

local function findOpt(nick)
    local f = component.findComponent(nick)
    return (#f > 0) and component.proxy(f[1]) or nil
end

local speaker   = findOpt("TRAFFIC_SPEAKER")
local computers = {}
for _, nick in ipairs(COMPUTERS_TO_CONTROL) do
    local c = findOpt(nick)
    if c then table.insert(computers, {nick=nick, case=c}) end
end

-- Déclarées ici pour être accessibles dans startAll/stopAll
local zoneL = false
local zoneR = false
local resetBigGauges  -- forward declaration (définie plus bas)

local function playError()
    if speaker then pcall(function() speaker:playSound(SOUND_ERROR, 0) end) end
end

local function startAll()
    for _, c in ipairs(computers) do
        pcall(function() c.case:startComputer() end)
    end
    if speaker then pcall(function() speaker:playSound(SOUND_START, 0) end) end
    -- Attendre GET_LOG_HELLO pour récupérer son adresse (net:send, pas broadcast)
    -- Wait for GET_LOG_HELLO to get its address (net:send, not broadcast)
    local deadline = computer.millis() + 5000
    while computer.millis() < deadline do
        local e2,_,sender2,port2,_,msg2 = event.pull(0.5)
        if e2=="NetworkMessage" and port2==52 and msg2=="GET_LOG_HELLO" then
            getlogAddr = sender2
            pcall(function() net:send(getlogAddr, 52, "SCREEN_ON") end)
            break
        end
    end
    -- Allume l'animation du panel entier
    zoneL = true
    zoneR = true
end

local function clearPanel()
    -- Force le refresh immédiat de tous les éléments visuels (sans attendre le tick)
    if displays then
        for _, d in ipairs(displays) do pcall(function() d:setText("--") end) end
    end
    if leds then
        for _, led in ipairs(leds) do pcall(function() led:setColor(0,0,0,0) end) end
    end
    if gauges then
        for _, g in ipairs(gauges) do pcall(function() g.percent=0; g.limit=0 end) end
    end
    if bigGauges then
        for _, g in ipairs(bigGauges) do pcall(function() g.percent=0; g.limit=0 end) end
    end
end

local function stopAll()
    if speaker then pcall(function() speaker:playSound(SOUND_STOP, 0) end) end
    -- Signal SHUTDOWN aux scripts → chacun efface son GPU et s'arrête lui-même
    if net then pcall(function() net:open(50); net:broadcast(50, "SHUTDOWN") end) end
    -- Laisse 3s aux scripts pour finir leur draw en cours, vider leurs GPUs et s'arrêter
    event.pull(3)
    -- Fallback : force l'arrêt des ordinateurs restants
    for _, c in ipairs(computers) do
        pcall(function() c.case:stopComputer() end)
    end
    -- Éteint l'animation du panel entier
    zoneL = false
    zoneR = false
    if resetBigGauges then resetBigGauges(true); resetBigGauges(false) end
    clearPanel()
end

-- Machine à états séquence :
--   idle     → sw1 ON  → armed
--   armed    → sw2 ON  → on      + startAll()
--   on       → sw2 OFF → shutdown
--   shutdown → sw1 OFF → idle    + stopAll()
-- Tout autre changement hors séquence → playError() (panel inchangé)
local seqState = "idle"

local displays = {
    panel1:getModule(0, 0, 0),   -- zone gauche
    panel1:getModule(2, 0, 0),   -- zone gauche
    panel1:getModule(4, 0, 0),   -- zone gauche
    panel1:getModule(6, 0, 0),   -- zone droite
    panel1:getModule(8, 0, 0),   -- zone droite
    panel1:getModule(10, 0, 0),  -- zone droite
}
local gauges = {
    panel1:getModule(0, 1, 0),   -- G
    panel1:getModule(1, 1, 0),   -- G
    panel1:getModule(2, 1, 0),   -- G
    panel1:getModule(3, 1, 0),   -- G
    panel1:getModule(4, 1, 0),   -- G
    panel1:getModule(6, 1, 0),   -- D
    panel1:getModule(7, 1, 0),   -- D
    panel1:getModule(8, 1, 0),   -- D
    panel1:getModule(9, 1, 0),   -- D
    panel1:getModule(10, 1, 0),  -- D
}
local bigGauges = {
    panel1:getModule(0, 8, 0),   -- G
    panel1:getModule(3, 8, 0),   -- G
    panel1:getModule(5, 8, 0),   -- D
    panel1:getModule(9, 8, 0),   -- D
}
local pots = {
    panel1:getModule(0, 6, 0):getSubModule(),  -- → bigGauge 1
    panel1:getModule(3, 6, 0):getSubModule(),  -- → bigGauge 2
    panel1:getModule(6, 6, 0):getSubModule(),  -- → bigGauge 3
    panel1:getModule(9, 6, 0):getSubModule(),  -- → bigGauge 4
}
local leds = {
    panel1:getModule(0, 2, 0),   -- G
    panel1:getModule(0, 3, 0),   -- G
    panel1:getModule(0, 4, 0),   -- G
    panel1:getModule(1, 3, 0),   -- G
    panel1:getModule(1, 4, 0),   -- G
    panel1:getModule(3, 3, 0),   -- G
    panel1:getModule(3, 4, 0),   -- G
    panel1:getModule(4, 2, 0),   -- G
    panel1:getModule(4, 3, 0),   -- G
    panel1:getModule(4, 4, 0),   -- G
    panel1:getModule(6, 2, 0),   -- D
    panel1:getModule(6, 3, 0),   -- D
    panel1:getModule(6, 4, 0),   -- D
    panel1:getModule(7, 3, 0),   -- D
    panel1:getModule(7, 4, 0),   -- D
    panel1:getModule(9, 3, 0),   -- D
    panel1:getModule(9, 4, 0),   -- D
    panel1:getModule(10, 2, 0),  -- D
    panel1:getModule(10, 3, 0),  -- D
    panel1:getModule(10, 4, 0),  -- D
}

local dispZone  = {true, true, true, false, false, false}
local gaugeZone = {true, true, true, true, true, false, false, false, false, false}
local bgZone    = {true, true, false, false}
local ledZone   = {true,true,true,true,true,true,true,true,true,true,
                   false,false,false,false,false,false,false,false,false,false}

local COLORS = {
    {1, 0, 0, 1},
    {0, 1, 0, 1},
    {1, 0.5, 0, 1},
}

local ledTimers = {}
for i = 1, #leds do
    ledTimers[i] = math.random(1, 60)
    local c = COLORS[math.random(#COLORS)]
    leds[i]:setColor(c[1], c[2], c[3], c[4])
end

local dispTimers = {}
for i = 1, #displays do
    dispTimers[i] = math.random(1, 30)
end

local targets = {} local values = {} local timers = {}
for i = 1, #gauges do
    values[i]  = math.random() * 0.6 + 0.2
    targets[i] = values[i]
    timers[i]  = math.random(1, 40)
end

local bgValues = {0, 0, 0, 0}

for i, g in ipairs(bigGauges) do
    g.percent = 0
    g.limit = 0
end

-- Définition réelle de resetBigGauges (forward-déclarée plus haut)
resetBigGauges = function(isLeft)
    for i, g in ipairs(bigGauges) do
        if bgZone[i] == isLeft then
            bgValues[i] = 0
            g.percent = 0
            g.limit = 0
        end
    end
end

event.listen(swL)
event.listen(swR)
for _, pot in ipairs(pots) do event.listen(pot) end

-- Absorbe les événements initiaux que FIN envoie au boot (état courant des switchs)
-- Sans ça, les switchs en position ON/OFF déclenchent la séquence au démarrage
do local t0=computer.millis() repeat event.pull(0.05) until computer.millis()-t0>=300 end

local tick = 0

local function isActive(isLeft)
    return isLeft and zoneL or zoneR
end

while true do
    tick = tick + 1

    -- Gauges
    for i, g in ipairs(gauges) do
        if isActive(gaugeZone[i]) then
            if tick >= timers[i] then
                local delta = (math.random() - 0.5) * 0.3
                targets[i] = math.max(0.05, math.min(0.95, values[i] + delta))
                timers[i] = tick + math.random(30, 80)
            end
            values[i] = values[i] + (targets[i] - values[i]) * 0.05
            g.percent = values[i]
            g.limit = targets[i]
        else
            g.percent = 0
            g.limit = 0
        end
    end

    -- Big gauges : contrôlées par les pots
    for i, g in ipairs(bigGauges) do
        if isActive(bgZone[i]) then
            g.percent = bgValues[i]
            g.limit = bgValues[i]
        else
            g.percent = 0
            g.limit = 0
        end
    end

    -- Displays
    for i, d in ipairs(displays) do
        if isActive(dispZone[i]) then
            if tick >= dispTimers[i] then
                d:setText(string.format("%02d", math.random(0, 99)))
                dispTimers[i] = tick + math.random(10, 40)
            end
        else
            d:setText("--")
        end
    end

    -- LEDs
    for i, led in ipairs(leds) do
        if isActive(ledZone[i]) then
            if tick >= ledTimers[i] then
                local c = COLORS[math.random(#COLORS)]
                led:setColor(c[1], c[2], c[3], c[4])
                ledTimers[i] = tick + math.random(20, 100)
            end
        else
            led:setColor(0, 0, 0, 0)
        end
    end

    -- Events switches + pots + réseau
    -- a3 = val(switch/pot) OU sender(NetworkMessage) selon le type d'événement
    -- a3 = val(switch/pot) OR sender(NetworkMessage) depending on event type
    local e, src, a3, a4, a5, a6 = event.pull(0.2)

    -- Mise à jour adresse GET_LOG si redémarre / Update GET_LOG address if it restarts
    if e == "NetworkMessage" and a4 == 52 and a6 == "GET_LOG_HELLO" then
        getlogAddr = a3
        print("GET_LOG_HELLO reçu — adresse capturée")
    elseif e == "NetworkMessage" then
        print("NET port="..tostring(a4).." msg="..tostring(a6))
    end

    if e == "ChangeState" then
        -- a3==false → switch ALLUMÉ, a3==true → ÉTEINT (convention FIN panel toggle)
        -- a3==false → switch ON, a3==true → OFF (FIN panel toggle convention)
        local isNowOn = (a3 == false)
        local swName = src==swL and "SW1" or (src==swR and "SW2" or "?")
        print(swName.." "..(isNowOn and "ON" or "OFF").." | état="..seqState)

        if src == swL then
            if isNowOn then
                if     seqState == "idle"     then seqState = "armed"
                elseif seqState == "shutdown" then playError()
                elseif seqState == "on"       then playError()
                end
            else
                if     seqState == "shutdown" then seqState = "idle"; stopAll()
                elseif seqState == "armed"    then seqState = "idle"; playError()
                elseif seqState == "on"       then playError()
                end
            end

        elseif src == swR then
            if isNowOn then
                if     seqState == "armed"    then seqState = "on"; startAll()
                elseif seqState == "idle"     then playError()
                elseif seqState == "shutdown" then playError()
                end
            else
                if seqState == "on" then seqState = "shutdown" end
            end
        end
        print("→ nouvel état="..seqState)

    elseif e == "valueChanged" then
        for i, pot in ipairs(pots) do
            if src == pot then
                bgValues[i] = a3 / 100
            end
        end
    end
end
