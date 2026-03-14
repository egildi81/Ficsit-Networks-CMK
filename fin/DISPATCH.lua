-- DISPATCH.lua : dispatch intelligent entre deux gares
-- Contrôle par réécriture de timetable (pas setSelfDriving — ignoré à dock=2).
-- Hold  : timetable vide + selfDriving=false → train retenu (la gare peut forcer dock=2→0)
-- Go    : selfDriving=true + timetable [PARK, DELIVERY] → charge à ST1 PUIS livre à ST2
-- Stuck : si la gare force quand même le départ (lastDecision=="hold"), decide() gère la récupération.
-- Go    : déclenché si tbvAdj ≤ ETA+marge. tbvAdj = temps avant (curItems - trainCap) = 0.
-- À chaque arrivée au PARK : timetable vidée + selfDriving coupé immédiatement.
-- Timetable train : ST1 ↔ ST2 (2 stops).

local VERSION = "2.8.1"
print("=== DISPATCH v"..VERSION.." BOOT ===")

-- === CONFIGURATION ===
local ST1_NAME       = "ST1"           -- gare 1
local ST2_NAME       = "ST2"           -- gare 2 (buffer à monitorer)
local PARK_NAME      = "ST1"           -- gare de stationnement : "ST1" ou "ST2"
local BUF_CONTAINER  = "DISPATCH_BUF"  -- nick du conteneur à ST2
local MAX_EN_ROUTE   = 1               -- nb max de trains simultanément en livraison
local ETA_WINDOW     = 10              -- trajets mémorisés pour l'ETA
local SIGMA_FACTOR   = 2.0             -- marge = sigma * SIGMA_FACTOR
local MIN_MARGE_SEC  = 10              -- marge minimale (secondes)
local DEFAULT_ETA    = 30              -- ETA par défaut avant historique (secondes)
local POLL_SEC       = 2               -- fréquence du loop principal
local BUF_SAMPLE_SEC = 10              -- intervalle entre échantillons buffer
local LOG_STATUS_SEC = 15              -- intervalle entre logs de statut
local MAX_BUF_HIST   = 6               -- historique buffer (~60s de débit)
local TRAIN_CAP_ITEMS = 0              -- capacité train en items (0 = auto-détection, -1 = désactivé)
local ITEMS_PER_SLOT  = 100            -- items par slot cargo (pour auto-détection)

-- === COMPOSANTS ===
local function findComp(name)
    local list = component.findComponent(name)
    if list and list[1] then return component.proxy(list[1]) end
    return nil
end

local sta1 = findComp(ST1_NAME)
if not sta1 then error("DISPATCH: station introuvable: "..ST1_NAME) end
print("Station "..ST1_NAME.." OK")

local bufBox = findComp(BUF_CONTAINER)
if not bufBox then error("DISPATCH: conteneur introuvable: "..BUF_CONTAINER) end
print("Buffer "..BUF_CONTAINER.." OK")

local sta1FINId = sta1.id
local sta1Str   = nil
local sta2Str   = nil

-- Objets station sauvegardés pour réécriture des timetables
local parkStObj  = nil    -- objet RailroadStation du PARK
local delivStObj = nil    -- objet RailroadStation de la gare de livraison
local parkRS     = nil    -- ruleSet (nil en FIN, non accessible)
local delivRS    = nil    -- ruleSet (nil en FIN, non accessible)

-- === HELPERS ===
local function getDock(st)
    local v = nil; pcall(function() v = st.obj.dockState end); return v
end

local function setSelfDriving(st, val)
    pcall(function() st.obj:setSelfDriving(val) end)
end

-- Réécrit la timetable du train ET gère selfDriving.
-- deliver=true  → selfDriving=true  + timetable [PARK, DELIVERY]
-- deliver=false → selfDriving=false + timetable vide (hold stable, pas de flip-flop)
-- NOTE: préserver la timetable testé en v2.8.0 → rejeté (gare force départ quand même,
--       + flip-flop go/hold toggle selfDriving en mid-loading → instable)
local function setRoute(st, deliver)
    setSelfDriving(st, deliver)
    local ok, err = pcall(function()
        local tt = st.obj:getTimeTable()
        if not tt then return end
        local stops = tt:getStops()
        for i = #stops, 1, -1 do tt:removeStop(i - 1) end
        if deliver then
            tt:addStop(0, parkStObj, parkRS)
            tt:addStop(1, delivStObj, delivRS)
        end
    end)
    if not ok then print("WARN setRoute "..st.name.." : "..tostring(err)) end
end

-- === DÉCOUVERTE DES TRAINS ===
local function discoverTrains()
    local found = {}
    local all = {}
    pcall(function() all = sta1:getTrackGraph():getTrains() end)
    print("Trains sur graphe: "..#all)
    for _, t in ipairs(all) do
        local name = "???"
        pcall(function() name = t:getName() end)
        local stops = {}
        pcall(function()
            local tt = t:getTimetable()
            if tt then stops = tt:getStops() end
        end)
        local hasST1 = false
        for _, stop in ipairs(stops) do
            local s = stop.station
            if not s then break end
            local ss = tostring(s)
            if s.id == sta1FINId then
                hasST1 = true
                if not sta1Str then
                    sta1Str = ss
                    print("ST1 résolu: "..ss)
                end
                if not parkStObj then
                    parkStObj = s
                    pcall(function() parkRS = stop.ruleSet end)
                    print("PARK stObj OK (ruleSet="..(parkRS and "oui" or "nil")..")")
                end
            else
                if not sta2Str then
                    sta2Str = ss
                    print("ST2 résolu: "..ss)
                end
                if not delivStObj then
                    delivStObj = s
                    pcall(function() delivRS = stop.ruleSet end)
                    print("DELIVERY stObj OK (ruleSet="..(delivRS and "oui" or "nil")..")")
                end
            end
        end
        if hasST1 then
            found[tostring(t)] = {
                obj=t, name=name,
                lastDock=nil, lastStation=nil, departTime=nil,
                arrivedAt=nil,      -- station physique courante
                delivering=false,   -- true si en route vers DELIVERY
                lastDecision=nil    -- "hold" ou "go" — pour éviter les réécritures inutiles
            }
            print("Train géré: "..name)
        end
    end
    return found
end

local trains = discoverTrains()
local count = 0; for _ in pairs(trains) do count = count + 1 end
if count == 0 then error("DISPATCH: aucun train passant par "..ST1_NAME.." trouvé") end
if not sta2Str then error("DISPATCH: impossible de résoudre ST2 depuis les timetables") end
if not parkStObj  then error("DISPATCH: objet station PARK non résolu") end
if not delivStObj then error("DISPATCH: objet station DELIVERY non résolu") end

local parkStr, deliveryStr
if PARK_NAME == ST1_NAME then
    parkStr = sta1Str; deliveryStr = sta2Str
elseif PARK_NAME == ST2_NAME then
    parkStr = sta2Str; deliveryStr = sta1Str
else
    error("DISPATCH: PARK_NAME doit être ST1_NAME ou ST2_NAME")
end
print(count.." train(s) géré(s) | PARK="..PARK_NAME)

-- === CAPACITÉ TRAIN ===
local trainCap = TRAIN_CAP_ITEMS
if trainCap == 0 then
    -- Auto-détection depuis les inventaires des wagons
    for _, st in pairs(trains) do
        local cap = 0
        pcall(function()
            for _, v in ipairs(st.obj:getVehicles()) do
                pcall(function()
                    for _, inv in ipairs(v:getInventories()) do
                        cap = cap + inv.size * ITEMS_PER_SLOT
                    end
                end)
            end
        end)
        if cap > 0 then trainCap = cap; break end
    end
end
if trainCap > 0 then
    print("Capacité train: "..trainCap.." items (mode capacité ON)")
elseif trainCap == 0 then
    print("WARN: capacité train non détectée — configurer TRAIN_CAP_ITEMS manuellement ou laisser 0 pour mode ETA seul")
end

-- === INVENTAIRE WAGON ===
-- Lit le nombre d'items actuellement chargés dans le train (via ses wagons).
local function getWagonItems(st)
    local total = 0
    pcall(function()
        for _, v in ipairs(st.obj:getVehicles()) do
            pcall(function()
                for _, inv in ipairs(v:getInventories()) do
                    for i = 0, inv.size-1 do
                        local stack = inv:getStack(i)
                        if stack and stack.count then total = total + stack.count end
                    end
                end
            end)
        end
    end)
    return total
end

-- Initialisation de l'état courant AVANT boot recovery
-- (timetable originale encore intacte → getCurrentStop() = prochain stop = inverse de la position physique)
for _, st in pairs(trains) do
    local dock = nil
    pcall(function() dock = st.obj.dockState end)
    local stStr = nil
    pcall(function()
        local tt = st.obj:getTimeTable()
        if tt then
            local stp = tt:getStop(tt:getCurrentStop())
            if stp then stStr = tostring(stp.station) end
        end
    end)
    st.lastDock    = dock
    st.lastStation = stStr
    if dock ~= 0 then
        if stStr == deliveryStr then
            st.arrivedAt = parkStr
            print(st.name.." : boot détecté @ PARK")
        elseif stStr == parkStr then
            st.arrivedAt = deliveryStr
            print(st.name.." : boot détecté @ DELIVERY")
        else
            print(st.name.." : boot position inconnue (stStr="..(stStr or "nil")..")")
        end
    else
        print(st.name.." : boot en transit")
    end
end

-- Boot recovery
-- → trains au PARK : timetable vide + selfDriving=false → hold immédiat
-- → trains à DELIVERY ou en transit : timetable originale conservée, rentreront naturellement
for _, st in pairs(trains) do
    if st.arrivedAt == parkStr then
        setRoute(st, false)
        print(st.name.." : boot recovery @ PARK → hold (timetable vide, selfDriving OFF)")
    else
        setSelfDriving(st, true)
        print(st.name.." : boot recovery → timetable originale, rentre au PARK")
    end
end

local function getCurrentStopStr(st)
    local s = nil
    pcall(function()
        local tt  = st.obj:getTimeTable()
        local ci  = tt:getCurrentStop()
        local stp = tt:getStop(ci)
        if stp then s = tostring(stp.station) end
    end)
    return s
end

local function countEnRoute()
    local n = 0
    for _, st in pairs(trains) do
        if st.delivering then n = n + 1 end
    end
    return n
end

-- === BUFFER ===
local function countBufferItems()
    local total = 0
    pcall(function()
        local inv = bufBox:getInventories()[1]
        if inv then
            for i = 0, inv.size-1 do
                local s = inv:getStack(i)
                if s and s.count then total = total + s.count end
            end
        end
    end)
    return total
end

local bufHistory = {}

local function addBufSample(val)
    table.insert(bufHistory, {t=computer.millis()/1000, v=val})
    if #bufHistory > MAX_BUF_HIST then table.remove(bufHistory, 1) end
end

local function getBufferStats()
    local cur = countBufferItems()
    if cur == 0 then return 0, 0, 0 end
    if #bufHistory < 2 then return 0, math.huge, cur end
    local old, new = bufHistory[1], bufHistory[#bufHistory]
    local dt = new.t - old.t
    if dt <= 0 then return 0, math.huge, cur end
    local drain = (old.v - new.v) / dt
    if drain <= 0 then return drain, math.huge, cur end
    return drain, cur / drain, cur
end

-- === ETA ===
local etaHistory = {}

local function addETA(dur)
    table.insert(etaHistory, dur)
    if #etaHistory > ETA_WINDOW then table.remove(etaHistory, 1) end
end

local function calcETA()
    if #etaHistory == 0 then return DEFAULT_ETA, DEFAULT_ETA * 0.5 end
    local sum = 0
    for _, v in ipairs(etaHistory) do sum = sum + v end
    local avg = sum / #etaHistory
    local varSum = 0
    for _, v in ipairs(etaHistory) do varSum = varSum + (v - avg)^2 end
    return avg, math.sqrt(varSum / #etaHistory)
end

-- === TRANSITIONS ===
local function checkTransition(st, dock, stStr)
    if st.lastDock == 0 and dock ~= 0 then
        st.arrivedAt = st.lastStation
        if st.arrivedAt == parkStr then
            -- Arrivée au PARK : hold immédiat (timetable vide + selfDriving=false)
            setRoute(st, false)
            st.lastDecision = nil
            print(st.name.." ARRIVÉE "..PARK_NAME.." → hold (timetable vide, selfDriving OFF)")
        elseif st.arrivedAt == deliveryStr and st.departTime then
            local dur = computer.millis()/1000 - st.departTime
            addETA(dur)
            local avg, sigma = calcETA()
            print(string.format("%s ARRIVÉE %s | trajet=%.0fs avg=%.0fs σ=%.0fs n=%d",
                st.name, ST2_NAME, dur, avg, sigma, #etaHistory))
            st.departTime = nil
        end
    end
    if st.lastDock ~= 0 and dock == 0 then
        if st.arrivedAt == parkStr then
            st.departTime = computer.millis() / 1000
            if st.lastDecision == "hold" then
                -- Gare a forcé dock=2→0 malgré selfDriving=false → stuck
                print("WARN "..st.name.." : gare a forcé le départ (hold override, selfDriving=false) → stuck")
            else
                print(st.name.." DÉPART "..PARK_NAME.." → "..
                      (PARK_NAME == ST1_NAME and ST2_NAME or ST1_NAME))
            end
            st.delivering = true
        elseif st.arrivedAt == deliveryStr then
            st.delivering = false
        end
        st.arrivedAt = nil
    end
    st.lastDock    = dock
    st.lastStation = stStr
end

-- === DÉCISION DISPATCH ===
local lastStatusLog = 0

local function decide(st, dock, stStr)
    -- Cas 1 : train docké au PARK (normal)
    local atPark  = st.arrivedAt == parkStr and dock ~= 0
    -- Cas 2 : train stuck (gare a forcé dock=2→0 malgré selfDriving=false en hold)
    local isStuck = dock == 0 and st.delivering and st.lastDecision == "hold"
    if not atPark and not isStuck then return end

    local drain, tbv, curItems = getBufferStats()
    local avgETA, sigma        = calcETA()
    local marge                = math.max(MIN_MARGE_SEC, sigma * SIGMA_FACTOR)
    -- Un train stuck ne livre rien : ne pas le compter dans le quota enRoute
    local enRoute    = countEnRoute() - (isStuck and 1 or 0)
    -- wagonItems = items réellement chargés (lu depuis le wagon, même si stuck)
    local wagonItems = trainCap > 0 and getWagonItems(st) or 0
    local trainFull  = trainCap <= 0 or wagonItems >= trainCap
    -- tbvAdj : temps avant buffer < livraison réelle du train (floor = wagonItems).
    -- Train à moitié plein → floor plus petit → urgence déclenchée plus tôt.
    -- trainCap inconnu → floor=0 → tbvAdj=tbv brut (vers 0).
    local tbvAdj  = drain > 0 and math.max(0, (curItems - wagonItems) / drain) or tbv
    local urgent  = tbvAdj <= avgETA + marge
    local shouldGo   = urgent and (enRoute < MAX_EN_ROUTE)
    local decision   = shouldGo and "go" or "hold"

    local now = computer.millis() / 1000
    if now - lastStatusLog >= LOG_STATUS_SEC then
        lastStatusLog = now
        local dockStr  = isStuck and "stuck" or (dock == 1 and "chargement" or "attente")
        local fillStr  = trainCap > 0
            and string.format(" wagon=%d/%d", wagonItems, trainCap)
            or ""
        print(string.format(
            "STATUS[PARK/%s] | buf=%d%s drain=%.2f/s tbv=%s(adj=%s) ETA=%.0f±%.0fs marge=%.0fs enRoute=%d/%d full=%s → %s",
            dockStr, curItems, fillStr, drain,
            tbv    == math.huge and "∞" or string.format("%.0f", tbv).."s",
            tbvAdj == math.huge and "∞" or string.format("%.0f", tbvAdj).."s",
            avgETA, sigma, marge, enRoute, MAX_EN_ROUTE,
            tostring(trainFull),
            shouldGo and "LIBÉRER" or "RETENIR"
        ))
    end

    -- Réécrire la timetable uniquement si la décision change
    if decision ~= st.lastDecision then
        st.lastDecision = decision
        if shouldGo then
            setRoute(st, true)   -- selfDriving=true + [PARK→DELIVERY]
            if isStuck then
                print(string.format("%s RECOVERY stuck → LIBÉRÉ (buf=%d tbv=%s)",
                    st.name, curItems,
                    tbv == math.huge and "∞" or string.format("%.0f", tbv).."s"))
            else
                print(string.format("%s → LIBÉRÉ → route [PARK→DELIVERY] (wagon=%d/%d tbvAdj=%.0fs ≤ %.0fs)",
                    st.name, wagonItems, trainCap, tbvAdj, avgETA + marge))
            end
        else
            -- hold : timetable déjà vidée à l'arrivée (checkTransition ou boot recovery)
            local reason
            if enRoute >= MAX_EN_ROUTE then
                reason = string.format("quota enRoute=%d/%d", enRoute, MAX_EN_ROUTE)
            elseif not trainFull then
                reason = string.format("chargement %d/%d items", wagonItems, trainCap)
            else
                reason = string.format("tbvAdj=%s > ETA+marge=%.0fs",
                    tbvAdj == math.huge and "∞" or string.format("%.0f", tbvAdj).."s",
                    avgETA + marge)
            end
            print(st.name.." → EN ATTENTE ("..reason..")")
        end
    end
end


-- === MAIN LOOP ===
addBufSample(countBufferItems())
local lastBufSample = computer.millis() / 1000
local lastLoopLog   = -15
print(string.format("Boucle démarrée | trains=%d park=%s poll=%ds",
    count, PARK_NAME, POLL_SEC))

while true do
    local now = computer.millis() / 1000

    if now - lastBufSample >= BUF_SAMPLE_SEC then
        addBufSample(countBufferItems())
        lastBufSample = now
    end

    for _, st in pairs(trains) do
        local dock  = getDock(st)
        local stStr = getCurrentStopStr(st)

        if now - lastLoopLog >= 15 then
            lastLoopLog = now
            local phase
            if dock ~= 0 then
                phase = (st.arrivedAt == parkStr) and "PARK" or
                        (st.arrivedAt == deliveryStr) and "DELIVERY" or "gare?"
            else
                phase = stStr == nil      and "→?(vide)" or
                        stStr == parkStr  and "→PARK"     or
                        stStr == deliveryStr and "→DELIVERY" or "→?"
            end
            print(string.format("DBG %s dock=%s phase=%s delivering=%s decision=%s",
                st.name, tostring(dock), phase,
                tostring(st.delivering), tostring(st.lastDecision)))
        end

        checkTransition(st, dock, stStr)
        decide(st, dock, stStr)
    end

    event.pull(POLL_SEC)
end
