-- POWER_MON.lua : moniteur réseau électrique en temps réel
-- Affiche graphe production/conso/batteries sur GPU T2
-- Prérequis : GPU T2, écran "POWER_SCREEN", NetworkCard,
--             un pôle/batterie/switch dans le réseau FIN avec nick "POWER_POLE"
-- Port 43 : logs → GET_LOG | Port 50 : SHUTDOWN (STARTER)
-- Port 51 : broadcast stats power → LOGGER (prod, conso, capa, batteries)
-- Adapté de PowerMonitor by Rostriano (2024-08-08)

local VERSION = "1.0.1"

print("=== POWER_MON v"..VERSION.." BOOT ===")

-- === CONFIGURATION ===
local SCREEN_NAME  = "POWER_SCREEN"  -- nick de l'écran in-game
local POWER_NICK   = "POWER_POLE"    -- nick du composant power (pôle, switch, batterie)
local POLL_SEC       = 1               -- fréquence d'actualisation (secondes)
local HISTORY_SIZE   = 100             -- points d'historique sur le graphe
local BROADCAST_SEC  = 5               -- intervalle envoi stats vers LOGGER (secondes)

-- === MATÉRIEL ===
local net = computer.getPCIDevices(classes.NetworkCard)[1]
local gpu = computer.getPCIDevices(classes.Build_GPU_T2_C)[1]
if not gpu then error("POWER_MON: GPU T2 introuvable") end

local scrId = component.findComponent(SCREEN_NAME)
if not scrId or not scrId[1] then error("POWER_MON: écran '"..SCREEN_NAME.."' introuvable") end
local scr = component.proxy(scrId[1])
gpu:bindScreen(scr)
event.listen(net)
net:open(43)
net:open(50)
net:open(51)

-- === LOG → GET_LOG (port 43) ===
print = function(...)
    local t = {} for i = 1, select('#', ...) do t[i] = tostring(select(i, ...)) end
    pcall(function() net:broadcast(43, "POWER_MON", table.concat(t, " ")) end)
end

-- === CONSTANTES ÉCRAN ===
local SW, SH    = 3000, 1800
local HEADER_H  = 60
local GRAPH_W   = 2300
local GRAPH_H   = 1490   -- SH - HEADER_H - FOOTER_H
local FOOTER_H  = 250
local BATT_W    = 700    -- SW - GRAPH_W

-- === PALETTE PROJET ===
-- Couleurs FIN : {r, g, b, a} — conformes à la DA du projet
local C = {
    BG      = {r=0,    g=0,    b=0,    a=1},
    HDR     = {r=0.06, g=0.04, b=0,    a=1},
    OR      = {r=1,    g=0.5,  b=0,    a=1},   -- orange accent (UI)
    WH      = {r=1,    g=1,    b=1,    a=1},
    DI      = {r=0.3,  g=0.3,  b=0.3,  a=1},   -- séparateurs / inactif
    GR      = {r=0,    g=0.75, b=0,    a=1},   -- vert : bonne nouvelle
    YE      = {r=1,    g=1,    b=0.2,  a=1},   -- jaune : warning
    RE      = {r=1,    g=0.2,  b=0.2,  a=1},   -- rouge : alerte
    BL      = {r=0.3,  g=0.6,  b=1,    a=1},   -- bleu
    GR2     = {r=0.5,  g=0.5,  b=0.5,  a=1},   -- gris : capacité
    -- Aliasés pour le graphe électrique
    PROD    = nil,  -- initialisé après (= WH blanc)
    CONS    = nil,  -- initialisé après (= OR orange)
    MAX_C   = nil,  -- initialisé après (= BL bleu)
    CAP     = nil,  -- initialisé après (= GR2)
}
C.PROD  = C.WH
C.CONS  = C.OR
C.MAX_C = C.BL
C.CAP   = C.GR2

-- === DÉCOUVERTE COMPOSANT POWER ===
local function findPower()
    -- Essai 1 : nick configuré
    local ids = component.findComponent(POWER_NICK)
    if ids and ids[1] then return component.proxy(ids[1]) end
    -- Essai 2 : classes courantes de pôles/switches
    local classes_try = {
        "FGBuildablePowerPole",
        "CircuitSwitch",
        "Build_PriorityPowerSwitch_C",
        "PowerStorage",
    }
    for _, cname in ipairs(classes_try) do
        local ok, found = pcall(function()
            local ctype = classes[cname]
            if ctype then
                local comps = component.findComponent(ctype)
                if comps and comps[1] then return component.proxy(comps[1]) end
            end
        end)
        if ok and found then return found end
    end
    return nil
end

local power = findPower()
if not power then error("POWER_MON: aucun composant power trouvé (nick='"..POWER_NICK.."')") end
print("POWER_MON v"..VERSION.." — composant power OK")


-- ============================================================
-- CLASSES UTILITAIRES
-- ============================================================

-- === SizeLimitedList : buffer circulaire avec min/max ===
local SizeLimitedList = {}
SizeLimitedList.__index = SizeLimitedList

function SizeLimitedList.new(maxSize)
    return setmetatable({
        first    = 0,
        maxSize  = maxSize or 10,
        currSize = 0,
        items    = {},
        minVal   = nil,
        maxVal   = nil,
    }, SizeLimitedList)
end

function SizeLimitedList:add(item)
    self.items[self.first + self.currSize] = item
    if self.currSize < self.maxSize then
        self.currSize = self.currSize + 1
    else
        self.items[self.first] = nil
        self.first = self.first + 1
    end
    self:_updateMinMax()
end

function SizeLimitedList:_updateMinMax()
    self.minVal, self.maxVal = nil, nil
    self:iterate(function(v)
        self.minVal = self.minVal and math.min(self.minVal, v) or v
        self.maxVal = self.maxVal and math.max(self.maxVal, v) or v
    end)
end

function SizeLimitedList:iterate(f)
    local i = self.first
    while i < self.first + self.currSize do
        f(self.items[i])
        i = i + 1
    end
end

function SizeLimitedList:getMaxVal(default) return self.maxVal or default end
function SizeLimitedList:getSize()    return self.currSize end
function SizeLimitedList:getMaxSize() return self.maxSize  end


-- === ScreenElement : base OOP pour les éléments GPU T2 ===
-- NOTE : subElements déclaré dans :new() pour éviter le partage entre instances
local ScreenElement = {}
ScreenElement.__index = ScreenElement

function ScreenElement:new(o)
    o = o or {}
    o.subElements = {}   -- IMPORTANT : propre à chaque instance (pas partagé)
    return setmetatable(o, self)
end

function ScreenElement:init(gpu_ref, position, dimensions)
    self.gpu        = gpu_ref
    self.position   = position
    self.dimensions = dimensions
end

function ScreenElement:_reposition(pos)
    return {x = self.position.x + pos.x, y = self.position.y + pos.y}
end

function ScreenElement:drawText(pos, text, size, color, monospace)
    pcall(function()
        self.gpu:drawText(self:_reposition(pos), text, size, color, monospace)
    end)
end

function ScreenElement:drawRect(pos, size, color, image, rotation)
    pcall(function()
        self.gpu:drawRect(self:_reposition(pos), size, color, image, rotation)
    end)
end

function ScreenElement:drawLines(points, thickness, color)
    if #points < 2 then return end
    local shifted = {}
    for _, p in ipairs(points) do
        table.insert(shifted, self:_reposition(p))
    end
    pcall(function()
        self.gpu:drawLines(shifted, thickness, color)
    end)
end


-- === Plotter : courbe dans un Graph ===
local Plotter = setmetatable({}, {__index = ScreenElement})
Plotter.__index = Plotter

function Plotter.new(o)
    local p = setmetatable(o or {}, Plotter)
    p.subElements     = {}
    p.color           = C.DI
    p.lineThickness   = 8
    p.dataSource      = nil
    p.graph           = nil
    p.scaleFactorX    = nil
    return p
end

function Plotter:setDataSource(ds)
    self.dataSource  = ds
    self.scaleFactorX = self.graph.dimensions.x / (ds:getMaxSize() - 1)
end

function Plotter:draw()
    if not self.dataSource then return end
    local i      = 0
    local points = {}
    self.dataSource:iterate(function(val)
        local xPos = (i + self.dataSource.maxSize - self.dataSource.currSize) * self.scaleFactorX
        local yPos = self.graph.dimensions.y - val * (self.graph.scaleFactorY or 0)
        table.insert(points, {x=math.floor(xPos), y=math.floor(yPos)})
        i = i + 1
    end)
    self:drawLines(points, self.lineThickness, self.color)
end


-- === Graph : conteneur de Plotters avec auto-scaling ===
local Graph = setmetatable({}, {__index = ScreenElement})
Graph.__index = Graph

function Graph.new()
    return setmetatable({
        subElements      = {},
        dataSources      = {},   -- propre à l'instance
        plotters         = {},   -- propre à l'instance
        scaleFactorY     = nil,
        maxVal           = nil,
        dimensions       = nil,
        scaleMarginFactor = 0.2,
    }, Graph)
end

function Graph:addPlotter(name, config)
    local p = Plotter.new()
    self.plotters[name] = p
    p.graph    = self
    p.gpu      = config.gpu
    p.position = config.position or {x=0, y=0}
    p.color    = config.color    or C.DI
    if config.dataSource then
        p:setDataSource(config.dataSource)
        table.insert(self.dataSources, config.dataSource)
    end
end

function Graph:setDimensions(dims)
    self.dimensions = dims
end

function Graph:draw()
    self:_autoResize()
    for _, p in pairs(self.plotters) do
        p:draw()
    end
end

function Graph:_autoResize()
    local maxVal = self:_getMaxVal()
    if not self.scaleFactorY then
        self:_initScale(maxVal)
        return
    end
    local maxDisp = self.dimensions.y / self.scaleFactorY
    if maxDisp < (maxVal or 0) or maxDisp * self.scaleMarginFactor > (maxVal or 0) then
        self:_initScale(maxVal)
    end
end

function Graph:_initScale(maxVal)
    local mv = maxVal or 0.001
    self.scaleFactorY = self.dimensions.y / (mv * (1 + self.scaleMarginFactor))
end

function Graph:_getMaxVal()
    local m = nil
    for _, ds in ipairs(self.dataSources) do
        local v = ds:getMaxVal()
        if v then m = m and math.max(m, v) or v end
    end
    return m
end


-- === Footer : légende bas de graphe ===
local Footer = setmetatable({}, {__index = ScreenElement})
Footer.__index = Footer

function Footer.new(o)
    local f = setmetatable(o or {}, Footer)
    f.subElements = {}
    f.fontSize    = 48
    f.textColor   = {r=0.75, g=0.75, b=0.75, a=1}
    f.values      = {}
    return f
end

local function mwLabel(text, value)
    local v = value and string.format("%.1f", value) or "NaN"
    return text .. "  " .. v .. " MW"
end

function Footer:draw()
    local sw = self.dimensions.x
    local cx = math.floor(sw / 2)
    local dy = 50
    local tx = 20

    -- Ligne séparatrice
    self:drawRect({x=0, y=0}, {x=sw, y=2}, C.DI, nil, nil)

    -- Colonne gauche : production & conso  (carré 36×36 centré sur fontSize=48 → offset +6)
    self:drawText({x=tx+50, y=dy},    mwLabel("Production",  self.values.production),  self.fontSize, self.textColor, false)
    self:drawRect({x=tx,    y=dy+6},  {x=36, y=36}, C.PROD, nil, nil)

    self:drawText({x=tx+50, y=dy+80}, mwLabel("Consommation", self.values.consumption), self.fontSize, self.textColor, false)
    self:drawRect({x=tx,    y=dy+86}, {x=36, y=36}, C.CONS, nil, nil)

    -- Colonne droite : max conso & capacité
    self:drawText({x=cx+50, y=dy},    mwLabel("Conso max",  self.values.maxCons),   self.fontSize, self.textColor, false)
    self:drawRect({x=cx,    y=dy+6},  {x=36, y=36}, C.MAX_C, nil, nil)

    self:drawText({x=cx+50, y=dy+80}, mwLabel("Capacité",   self.values.capacity),  self.fontSize, self.textColor, false)
    self:drawRect({x=cx,    y=dy+86}, {x=36, y=36}, C.CAP,   nil, nil)
end

function Footer:setValues(v) self.values = v end


-- === BatteryInfo : panneau batteries droit ===
local BatteryInfo = setmetatable({}, {__index = ScreenElement})
BatteryInfo.__index = BatteryInfo

function BatteryInfo.new(o)
    local b = setmetatable(o or {}, BatteryInfo)
    b.subElements  = {}
    b.line         = 0
    b.lineHeight   = 60
    b.fontSize     = 36
    b.dataFontSize = 50
    b.textColor    = {r=0.75, g=0.75, b=0.75, a=1}
    return b
end

local function battColor(pct)
    if pct < 33  then return C.RE
    elseif pct < 80  then return C.YE
    elseif pct < 100 then return C.GR
    else                  return C.DI
    end
end

local function fmtTime(s)
    return string.format("%02d:%02d:%02d",
        math.floor(s/3600)%24, math.floor(s/60)%60, math.floor(s%60))
end

function BatteryInfo:_print(text, size, color)
    self.line = self.line + 1
    self:drawText({x=30, y=self.line * self.lineHeight}, text, size or self.fontSize, color or self.textColor, false)
end

function BatteryInfo:draw()
    local circuit = nil
    pcall(function() circuit = self.connector:getCircuit() end)
    if not circuit or not circuit.hasBatteries then
        self:drawText({x=30, y=60}, "Pas de batterie", self.fontSize, C.DI, false)
        return
    end

    local pct      = (circuit.batteryStorePercent or 0) * 100
    local store    = circuit.batteryStore        or 0
    local cap      = circuit.batteryCapacity     or 0
    local tFull    = circuit.batteryTimeUntilFull  or 0
    local tEmpty   = circuit.batteryTimeUntilEmpty or 0
    local bIn      = circuit.batteryIn  or 0
    local bOut     = circuit.batteryOut or 0

    self.line = 0

    -- Titre section
    self:drawRect({x=0, y=0}, {x=self.dimensions.x, y=52}, {r=0.06,g=0.04,b=0,a=1}, nil, nil)
    self:drawText({x=30, y=10}, "BATTERIES", 28, C.OR, false)
    self:drawRect({x=0, y=50}, {x=self.dimensions.x, y=2}, C.OR, nil, nil)

    -- Charge %
    self:_print("Stocké", self.fontSize)
    self:_print(string.format("%.1f %%", pct), self.dataFontSize, battColor(pct))
    self.line = self.line + 1

    -- MWh
    self:_print("Charge")
    if pct >= 100 then
        self:_print(string.format("%.1f MWh", store), self.dataFontSize, battColor(pct))
    else
        self:_print(string.format("%.1f / %.1f MWh", store, cap), self.dataFontSize, battColor(pct))
    end
    self.line = self.line + 1

    -- Flux
    if bOut > 0 then
        self:_print("Décharge")
        self:_print(string.format("%.1f MW", bOut), self.dataFontSize, C.RE)
        self.line = self.line + 1
    elseif bIn > 0 then
        self:_print("Charge")
        self:_print(string.format("%.1f MW", bIn), self.dataFontSize, C.GR)
        self.line = self.line + 1
    end

    -- Temps restant
    if tEmpty > 0 then
        self:_print("Vide dans")
        self:_print(fmtTime(tEmpty), self.dataFontSize, C.RE)
    elseif tFull > 0 then
        self:_print("Plein dans")
        self:_print(fmtTime(tFull), self.dataFontSize, C.GR)
    end
end


-- ============================================================
-- POWER MONITOR PRINCIPAL
-- ============================================================
local PowerMonitor = {}
PowerMonitor.__index = PowerMonitor

function PowerMonitor.new(powerComp, gpuRef)
    local self = setmetatable({}, PowerMonitor)
    self.gpu       = gpuRef
    self.connector = nil
    pcall(function()
        local connectors = powerComp:getPowerConnectors()
        if connectors and connectors[1] then self.connector = connectors[1] end
    end)
    if not self.connector then error("POWER_MON: aucun connecteur power sur le composant") end

    -- Listes historique
    self.prodList    = SizeLimitedList.new(HISTORY_SIZE)
    self.capList     = SizeLimitedList.new(HISTORY_SIZE)
    self.consList    = SizeLimitedList.new(HISTORY_SIZE)
    self.maxConsList = SizeLimitedList.new(HISTORY_SIZE)

    -- Graphe
    self.graph = Graph.new()
    self.graph:init(gpuRef, {x=0, y=HEADER_H}, {x=GRAPH_W, y=GRAPH_H})
    self.graph:setDimensions({x=GRAPH_W, y=GRAPH_H})
    self.graph:addPlotter("cap",     {gpu=gpuRef, position={x=0,y=0}, color=C.CAP,   dataSource=self.capList})
    self.graph:addPlotter("prod",    {gpu=gpuRef, position={x=0,y=0}, color=C.PROD,  dataSource=self.prodList})
    self.graph:addPlotter("cons",    {gpu=gpuRef, position={x=0,y=0}, color=C.CONS,  dataSource=self.consList})
    self.graph:addPlotter("maxCons", {gpu=gpuRef, position={x=0,y=0}, color=C.MAX_C, dataSource=self.maxConsList})

    -- Footer
    self.footer = Footer.new()
    self.footer:init(gpuRef, {x=0, y=HEADER_H+GRAPH_H}, {x=GRAPH_W, y=FOOTER_H})

    -- Batterie
    self.battInfo = BatteryInfo.new({connector=self.connector})
    self.battInfo:init(gpuRef, {x=GRAPH_W, y=0}, {x=BATT_W, y=SH})

    return self
end

-- Sérialise et broadcaste les stats power sur port 51 → LOGGER
function PowerMonitor:broadcastStats()
    local circuit = nil
    pcall(function() circuit = self.connector:getCircuit() end)

    local hasBatt   = circuit and circuit.hasBatteries or false
    local battPct   = hasBatt and (circuit.batteryStorePercent or 0) * 100 or 0
    local battStore = hasBatt and (circuit.batteryStore         or 0) or 0
    local battCap   = hasBatt and (circuit.batteryCapacity      or 0) or 0
    local battIn    = hasBatt and (circuit.batteryIn            or 0) or 0
    local battOut   = hasBatt and (circuit.batteryOut           or 0) or 0
    local tFull     = hasBatt and (circuit.batteryTimeUntilFull  or 0) or 0
    local tEmpty    = hasBatt and (circuit.batteryTimeUntilEmpty or 0) or 0

    local payload = string.format(
        "{prod=%s,cons=%s,cap=%s,maxCons=%s,hasBatt=%s,battPct=%s,battStore=%s,battCap=%s,battIn=%s,battOut=%s,tFull=%s,tEmpty=%s,ts=%s}",
        tostring(self.prod),    tostring(self.cons),
        tostring(self.cap),     tostring(self.maxCons),
        tostring(hasBatt),      tostring(math.floor(battPct * 10) / 10),
        tostring(battStore),    tostring(battCap),
        tostring(battIn),       tostring(battOut),
        tostring(math.floor(tFull)),  tostring(math.floor(tEmpty)),
        tostring(math.floor(computer.millis() / 1000))
    )
    pcall(function() net:broadcast(51, "POWER_MON", payload) end)
end

function PowerMonitor:collectData()
    local circuit = nil
    pcall(function() circuit = self.connector:getCircuit() end)
    self.prod    = (circuit and circuit.production)          or 0
    self.cap     = (circuit and circuit.capacity)            or 0
    self.cons    = (circuit and circuit.consumption)         or 0
    self.maxCons = (circuit and circuit.maxPowerConsumption) or 0
    self.prodList:add(self.prod)
    self.capList:add(self.cap)
    self.consList:add(self.cons)
    self.maxConsList:add(self.maxCons)
end

function PowerMonitor:draw()
    -- Fond
    gpu:drawRect({x=0, y=0}, {x=SW, y=SH}, C.BG, nil, nil)

    -- Séparateurs
    pcall(function()
        gpu:drawLines({{x=0,y=HEADER_H+GRAPH_H}, {x=GRAPH_W,y=HEADER_H+GRAPH_H}}, 3, C.DI)
        gpu:drawLines({{x=GRAPH_W,y=0}, {x=GRAPH_W,y=SH}}, 3, C.DI)
    end)

    -- Graphe
    self.graph:draw()

    -- Footer
    self.footer:setValues({
        production  = self.prod,
        consumption = self.cons,
        maxCons     = self.maxCons,
        capacity    = self.cap,
    })
    self.footer:draw()

    -- Batterie
    self.battInfo:draw()

    -- Header (dessiné en dernier pour couvrir les débordements)
    gpu:drawRect({x=0, y=0},          {x=SW,  y=HEADER_H}, C.HDR, nil, nil)
    gpu:drawRect({x=0, y=HEADER_H-2}, {x=SW,  y=2},        C.OR,  nil, nil)
    gpu:drawText({x=20, y=14}, "POWER MONITOR  v"..VERSION, 26, C.OR, false)

    gpu:flush()
end

function PowerMonitor:run()
    print("Boucle démarrée")
    local lastBroadcast = 0
    while true do
        self:collectData()
        self:draw()

        -- Broadcast vers LOGGER (port 51) toutes les BROADCAST_SEC secondes
        local now = computer.millis() / 1000
        if now - lastBroadcast >= BROADCAST_SEC then
            self:broadcastStats()
            lastBroadcast = now
        end

        -- event.pull avec timeout → catch SHUTDOWN (port 50)
        local e, _, _, port = event.pull(POLL_SEC)
        if e == "NetworkMessage" and port == 50 then
            gpu:drawRect({x=0, y=0}, {x=SW, y=SH}, C.BG, nil, nil)
            gpu:flush()
            computer.stop()
        end
    end
end


-- === DÉMARRAGE ===
local function drawBooting(msg)
    gpu:drawRect({x=0, y=0},  {x=SW, y=SH},      C.BG,  nil, nil)
    gpu:drawRect({x=0, y=0},  {x=SW, y=HEADER_H}, C.HDR, nil, nil)
    gpu:drawText({x=20, y=14}, "POWER MONITOR  v"..VERSION, 26, C.OR, false)
    gpu:drawText({x=SW/2, y=SH/2 - 20}, msg, 28, C.DI, true)
    gpu:flush()
end

drawBooting("Démarrage...")
local ok, err = pcall(function()
    local pm = PowerMonitor.new(power, gpu)
    pm:run()
end)
if not ok then
    print("ERREUR FATALE : "..tostring(err))
    gpu:drawRect({x=0, y=0}, {x=SW, y=SH}, C.BG, nil, nil)
    gpu:drawText({x=20, y=SH/2}, "ERREUR: "..tostring(err), 28, C.RE, false)
    gpu:flush()
end
