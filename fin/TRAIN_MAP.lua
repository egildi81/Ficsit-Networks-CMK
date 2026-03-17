-- TRAIN_MAP.lua : carte temps réel des trains sur fond Satisfactory
-- Affiche les stations + trains en direct sur image de carte locale
-- Prérequis : GPU T2, écran "TRAINMAP_SCREEN", NetworkCard, GARE_TEST dans le réseau FIN
-- Port 44 : snapshot état trains (LOGGER) | Port 50 : SHUTDOWN (STARTER)
-- NOTE : getConnections() cause un crash serveur FIN (assert C++) — rails non dessinés
-- IMAGE : placer le PNG dans %LOCALAPPDATA%\FactoryGame\Saved\SaveGames\Computers\

local VERSION = "1.0.0"

-- === CONFIGURATION ===
local SCREEN_NAME = "TRAINMAP_SCREEN"  -- nick de l'écran in-game
-- Nom du fichier PNG dans %LOCALAPPDATA%\FactoryGame\Saved\SaveGames\Computers\
-- IMPORTANT : laisser "" tant que le fichier n'est pas en place sur chaque client
-- Un fichier absent crash le client au rendu (C++ AV, non rattrapable par pcall)
local MAP_IMAGE   = ""

-- === MATÉRIEL ===
local net = computer.getPCIDevices(classes.NetworkCard)[1]
local gpu = computer.getPCIDevices(classes.Build_GPU_T2_C)[1]
local scrId = component.findComponent(SCREEN_NAME)
if not scrId or not scrId[1] then error("Écran '"..SCREEN_NAME.."' introuvable — vérifie le nick in-game") end
local scr = component.proxy(scrId[1])
gpu:bindScreen(scr)
event.listen(net)
net:open(44)
net:open(50)

-- === LOG → GET_LOG (port 43) ===
print = function(...)
    local t = {} for i = 1, select('#', ...) do t[i] = tostring(select(i, ...)) end
    pcall(function() net:broadcast(43, "TRAIN_MAP", table.concat(t, " ")) end)
end

-- === CONSTANTES ÉCRAN ===
local SW, SH   = 2400, 1350
local HEADER_H = 60
local PAD      = 25

-- === BOUNDS CARTE SATISFACTORY (coordonnées monde) ===
local MAP = { left = -323929, top = -334717, right = 424166, bottom = 361634 }

-- === COULEURS ===
local BG  = {r=0,    g=0,    b=0,    a=1}
local HDR = {r=0.06, g=0.04, b=0,    a=1}
local OR  = {r=1,    g=0.5,  b=0,    a=1}
local WH  = {r=1,    g=1,    b=1,    a=1}
local DI  = {r=0.3,  g=0.3,  b=0.3,  a=1}
local GR  = {r=0,    g=1,    b=0,    a=1}
local YE  = {r=1,    g=1,    b=0.2,  a=1}
local RE  = {r=1,    g=0.2,  b=0.2,  a=1}
local BL  = {r=0.3,  g=0.6,  b=1,    a=1}  -- couleur stations

-- === CONVERSION COORDONNÉES MONDE → ÉCRAN ===
local function w2s(wx, wy)
    local rangeX = MAP.right  - MAP.left
    local rangeY = MAP.bottom - MAP.top
    local x      = wx - MAP.left
    local y      = wy - MAP.top
    local drawW  = SW - PAD * 2
    local drawH  = SH - PAD * 2 - HEADER_H
    if rangeY > rangeX then
        x = x + (rangeY - rangeX) / 2
        rangeX = rangeY
    else
        y = y + (rangeX - rangeY) / 2
        rangeY = rangeX
    end
    return math.floor(x / rangeX * drawW) + PAD,
           math.floor(y / rangeY * drawH) + PAD + HEADER_H
end

-- === RÉFÉRENCE TRACK GRAPH ===
-- Utilise uniquement GARE_TEST (confirmé stable sur serveur dédié)
local function getRef()
    local ref = nil
    pcall(function()
        local ids = component.findComponent("GARE_TEST")
        if ids and ids[1] then ref = component.proxy(ids[1]) end
    end)
    return ref
end

-- === FOND DE CARTE (image locale) ===
-- Fichier PNG à placer dans : %LOCALAPPDATA%\FactoryGame\Saved\SaveGames\Computers\
-- Chemin dans le script : "Computers/nom_du_fichier.png"
-- Si MAP_IMAGE == "" ou drawBox échoue → fond noir de secours
local function drawBackground()
    if MAP_IMAGE == "" then return end
    pcall(function()
        gpu:drawBox({
            position          = {0, HEADER_H},
            size              = {SW, SH - HEADER_H},
            rotation          = 0,
            color             = {1, 1, 1, 1},
            image             = MAP_IMAGE,
            imageSize         = {SW, SH - HEADER_H},
            hasCenteredOrigin = false,
            verticalTiling    = false,
            horizontalTiling  = false,
            isBorder          = false,
            margin            = {0, 0, 0, 0},
            isRounded         = false,
            radii             = {0, 0, 0, 0},
            hasOutline        = false,
            outlineThickness  = false,
            outlineColor      = {1, 1, 1, 1},
        })
    end)
end

-- === THREAD MANAGER ===
local threads    = {}
local shouldStop = false

local function spawn(fn)
    table.insert(threads, coroutine.create(fn))
end

local function runAll()
    while not shouldStop do
        for i = #threads, 1, -1 do
            if coroutine.status(threads[i]) ~= "dead" then
                local ok, err = coroutine.resume(threads[i])
                if not ok then
                    print("ERR thread: " .. tostring(err))
                    table.remove(threads, i)
                end
            else
                table.remove(threads, i)
            end
        end
        event.pull(0)
    end
    gpu:drawRect({x=0,y=0}, {x=SW,y=SH}, BG, BG, 0)
    gpu:flush()
    computer.stop()
end

-- État reçu de LOGGER
local lastLoggerTime = 0

-- === THREAD 1 : RÉSEAU ===
spawn(function()
    while true do
        local e, _, _, port, data = event.pull(0)
        if e == "NetworkMessage" then
            if port == 50 then
                shouldStop = true
            elseif port == 44 and data then
                local ok, fn = pcall(load, "return " .. data)
                if ok and fn then
                    local ok2, s = pcall(fn)
                    if ok2 and s then lastLoggerTime = computer.millis() end
                end
            end
        end
        coroutine.yield()
    end
end)

-- === THREAD 2 : DESSIN (toutes les 2s) ===
spawn(function()
    local ref      = getRef()
    local lastDraw = 0

    while true do
        local now = computer.millis()
        if now - lastDraw >= 2000 then
            lastDraw = now

            -- Fond noir
            gpu:drawRect({x=0, y=0}, {x=SW, y=SH}, BG, BG, 0)

            -- Image de carte (si disponible localement)
            drawBackground()

            if ref then
                pcall(function()
                    local graph  = ref:getTrackGraph()
                    local trains = graph:getTrains()

                    -- === MARQUEURS STATIONS ===
                    -- getStations() : safe (pas de getConnections)
                    local stations = graph:getStations()
                    for _, sta in ipairs(stations) do
                        pcall(function()
                            local loc = sta.location
                            if not loc then return end
                            local sx, sy = w2s(loc.x, loc.y)
                            -- Losange station (2 drawRect croisés)
                            gpu:drawRect({x=sx-6, y=sy-2}, {x=12, y=4},  BL, BL, 0)
                            gpu:drawRect({x=sx-2, y=sy-6}, {x=4,  y=12}, BL, BL, 0)
                            -- Nom station
                            local name = ""
                            pcall(function() name = sta.name end)
                            if name ~= "" then
                                gpu:drawText({x=sx+8, y=sy-8}, name, 14, BL, false)
                            end
                        end)
                    end

                    -- === DOTS TRAINS ===
                    for _, tr in ipairs(trains) do
                        pcall(function()
                            -- Filtrer sans timetable
                            local hasTT = false
                            pcall(function()
                                local tt = tr:getTimeTable()
                                hasTT = tt ~= nil and #tt:getStops() > 0
                            end)
                            if not hasTT then return end

                            local name = tr:getName()
                            local m    = tr:getMaster()
                            local loc  = m.location
                            if not loc then return end

                            local sx, sy = w2s(loc.x, loc.y)

                            -- Couleur selon état
                            local color    = RE
                            local isDocked = m.isDocked
                            local spd      = 0
                            pcall(function()
                                spd = math.abs(math.floor(m:getMovement().speed / 100 * 3.6))
                            end)
                            if isDocked then
                                color = YE
                            elseif spd > 10 then
                                color = GR
                            end

                            -- Dot (carré 16×16 + contour blanc)
                            local r = 8
                            gpu:drawRect({x=sx-r-1, y=sy-r-1}, {x=r*2+2, y=r*2+2}, WH, BG,    0)
                            gpu:drawRect({x=sx-r,   y=sy-r},   {x=r*2,   y=r*2},   color, color, 0)

                            -- Nom
                            gpu:drawText({x=sx+r+4, y=sy-10}, name, 18, WH, false)
                            -- Vitesse
                            if spd > 10 then
                                gpu:drawText({x=sx+r+4, y=sy+8}, spd.."km/h", 16, GR, false)
                            end
                        end)
                    end
                end)
            end

            -- Header (dessiné en dernier pour couvrir les labels qui dépassent)
            gpu:drawRect({x=0, y=0},          {x=SW, y=HEADER_H}, HDR, HDR, 0)
            gpu:drawRect({x=0, y=HEADER_H-2}, {x=SW, y=2},        OR,  OR,  0)
            gpu:drawText({x=20, y=16}, "TRAIN MAP  v"..VERSION, 26, OR, false)

            -- Légende
            gpu:drawRect({x=SW-490, y=22}, {x=12,y=12}, BL, BL, 0)
            gpu:drawText({x=SW-473, y=18}, "STATION",   18, BL, false)
            gpu:drawRect({x=SW-370, y=22}, {x=12,y=12}, GR, GR, 0)
            gpu:drawText({x=SW-353, y=18}, "EN ROUTE",  18, GR, false)
            gpu:drawRect({x=SW-240, y=22}, {x=12,y=12}, YE, YE, 0)
            gpu:drawText({x=SW-223, y=18}, "A QUAI",    18, YE, false)
            gpu:drawRect({x=SW-135, y=22}, {x=12,y=12}, RE, RE, 0)
            gpu:drawText({x=SW-118, y=18}, "ARRET",     18, RE, false)

            -- Indicateur LOGGER
            local logAge = lastLoggerTime > 0 and (computer.millis() - lastLoggerTime) / 1000 or -1
            local logStr, logCol
            if logAge < 0 then    logStr, logCol = "LOGGER: attente...", DI
            elseif logAge < 10 then logStr, logCol = "LOGGER: OK", GR
            else                  logStr, logCol = "LOGGER: "..math.floor(logAge).."s", RE
            end
            gpu:drawText({x=280, y=18}, logStr, 18, logCol, false)

            gpu:flush()
        end
        coroutine.yield()
    end
end)

-- === DÉMARRAGE ===
local function drawBooting(msg)
    gpu:drawRect({x=0, y=0}, {x=SW, y=SH}, BG, BG, 0)
    gpu:drawRect({x=0, y=0}, {x=SW, y=HEADER_H}, HDR, HDR, 0)
    gpu:drawText({x=20, y=16}, "TRAIN MAP  v"..VERSION, 26, OR, false)
    gpu:drawText({x=SW/2, y=SH/2 - 20}, msg, 28, DI, true)
    gpu:flush()
end

drawBooting("Démarrage...")
print("TRAIN_MAP v"..VERSION.." démarré")
runAll()
