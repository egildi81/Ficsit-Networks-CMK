-- GET_LOG.lua : affiche les logs réseau de tous les scripts sur un écran dédié
-- Écoute le port 43 (broadcast de logs depuis LOGGER, DETAIL, TRAIN_TAB, etc.)
-- Port 50 : SHUTDOWN (STARTER) | Port 52 : SCREEN_ON (STARTER)
-- Composants requis : GPU T2, écran "MAP_SCREEN", NetworkCard, panel "GETLOG_PANEL" (1 bouton)

local VERSION = "1.2.2"
print("=== GET_LOG v"..VERSION.." BOOT ===")

-- === INITIALISATION MATÉRIEL ===
local gpu = computer.getPCIDevices(classes.Build_GPU_T2_C)[1]
local scr = component.proxy(component.findComponent("MAP_SCREEN")[1])
local net = computer.getPCIDevices(classes.NetworkCard)[1]
gpu:bindScreen(scr)
net:open(43)   -- port dédié aux logs / dedicated log port
net:open(50)   -- port SHUTDOWN (STARTER)
net:open(52)   -- port SCREEN_ON (STARTER) / SCREEN_ON port from STARTER
event.listen(net)

-- Bouton panel mono — allumer/éteindre l'écran manuellement
-- Single panel button — manually toggle screen on/off
local PANEL_NICK = "GETLOG_PANEL"
local btn = nil
local ok_btn, err_btn = pcall(function()
    local ids = component.findComponent(PANEL_NICK)
    if not ids or not ids[1] then
        print("WARN: panel '"..PANEL_NICK.."' introuvable")
        return
    end
    local panel = component.proxy(ids[1])
    btn = panel:getModule(0, 0, 0)
    if not btn then
        print("WARN: module (0,0,0) introuvable sur "..PANEL_NICK)
        return
    end
    event.listen(btn)
    print("Bouton panel OK — en écoute")
end)
if not ok_btn then print("ERR init bouton: "..tostring(err_btn)) end

-- === ÉTAT ÉCRAN ===
-- Éteint au boot — allumé par STARTER (port 52 net:send) ou bouton
-- Off at boot — turned on by STARTER (port 52 net:send) or button
local screenOn = false

-- Annonce l'adresse à STARTER pour qu'il puisse faire net:send (pas broadcast)
-- Announce address to STARTER so it can use net:send (not broadcast)
pcall(function() net:broadcast(52, "GET_LOG", "GET_LOG_HELLO") end)

-- === CONSTANTES AFFICHAGE ===
local sw, sh = 2400, 1800
local BG = {r=0,   g=0,   b=0,   a=1}
local WH = {r=1,   g=1,   b=1,   a=1}
local DI = {r=0.3, g=0.3, b=0.3, a=1}
-- Palette (fond noir — toutes les couleurs sont vives)
-- Color palette (black background — all colors are bright)
local GR = {r=0.2, g=1,   b=0.2, a=1}  -- vert   / green
local BL = {r=0.2, g=0.6, b=1,   a=1}  -- bleu   / blue
local YE = {r=1,   g=1,   b=0.2, a=1}  -- jaune  / yellow
local OR = {r=1,   g=0.5, b=0,   a=1}  -- orange
local RE = {r=1,   g=0.2, b=0.2, a=1}  -- rouge  / red
local CY = {r=0,   g=0.9, b=1,   a=1}  -- cyan
local PU = {r=0.8, g=0.4, b=1,   a=1}  -- violet / purple
local MI = {r=0.2, g=1,   b=0.7, a=1}  -- menthe / mint
local PK = {r=1,   g=0.4, b=0.8, a=1}  -- rose   / pink

-- Couleur par script source (fond noir — ne pas mettre de couleurs sombres)
-- Color per source script (black background — no dark colors)
local COLORS = {
    LOGGER      = GR,  -- vert
    DETAIL      = BL,  -- bleu
    TRAIN_TAB   = YE,  -- jaune
    DISPATCH    = CY,  -- cyan
    STOCKAGE    = PU,  -- violet
    TRAIN_STATS = OR,  -- orange
    TRAIN_MAP   = MI,  -- menthe
    POWER_MON   = PK,  -- rose
    STARTER     = RE,  -- rouge
}

local FONT     = 22
local LINE_H   = 32
local HEADER_H = 50
local MAX_LINES = math.floor((sh - HEADER_H) / LINE_H)
local lines = {}
local t0 = computer.millis()

local function fmtTime()
    local s = math.floor((computer.millis() - t0) / 1000)
    return string.format("%d:%02d:%02d", math.floor(s/3600), math.floor(s/60)%60, s%60)
end

local function addLine(src, msg)
    table.insert(lines, {src=src, msg=msg, ts=fmtTime()})
    if #lines > MAX_LINES then table.remove(lines, 1) end
end

-- Dessine l'écran — fond noir si éteint, logs si allumé
-- Draws screen — black if off, logs if on
local function draw()
    if not screenOn then
        gpu:drawRect({x=0,y=0}, {x=sw,y=sh}, BG, BG, 0)
        gpu:flush()
        return
    end
    gpu:drawRect({x=0,y=0}, {x=sw,y=sh}, BG, BG, 0)
    -- En-tête
    gpu:drawRect({x=0,y=0}, {x=sw,y=HEADER_H}, BG, {r=0.08,g=0.08,b=0.08,a=1}, 0)
    gpu:drawText({x=20,y=12}, "LOGS RÉSEAU", 26, OR, false)
    gpu:drawText({x=sw-200,y=14}, #lines.." lignes", 20, DI, false)
    -- Lignes de log
    local y = HEADER_H + 6
    for _, l in ipairs(lines) do
        local col = COLORS[l.src] or WH
        gpu:drawText({x=20,  y=y}, l.ts,              FONT, YE,  false)
        gpu:drawText({x=200, y=y}, "["..l.src.."]",   FONT, col, false)
        gpu:drawText({x=390, y=y}, l.msg,             FONT, WH,  false)
        y = y + LINE_H
    end
    gpu:flush()
end

-- === BOUCLE PRINCIPALE ===
draw()  -- fond noir au boot / black screen at boot
while true do
    local e, src, sender, port, script, msg = event.pull(30)

    if e ~= nil and e ~= "NetworkMessage" then
        -- Debug : log tout event non-réseau pour identifier le nom exact du bouton
        -- Debug: log all non-network events to identify exact button event name
        print("EVT e='"..tostring(e).."' src="..tostring(src))
    end

    if e == "Trigger" and src == btn then
        -- Bouton panel : toggle écran / Panel button: toggle screen
        screenOn = not screenOn
        print("Bouton : écran "..(screenOn and "ON" or "OFF"))
        draw()

    elseif e == "NetworkMessage" and port == 52 then
        -- STARTER allume le système → écran ON / STARTER starts system → screen ON
        if msg == "SCREEN_ON" then
            screenOn = true
            print("SCREEN_ON reçu de STARTER → écran ON")
            draw()
        end

    elseif e == "NetworkMessage" and port == 50 then
        -- SHUTDOWN : efface l'écran et s'arrête / SHUTDOWN: clear screen and stop
        print("SHUTDOWN reçu → arrêt")
        gpu:drawRect({x=0,y=0}, {x=sw,y=sh}, BG, BG, 0)
        gpu:flush()
        computer.stop()

    elseif e == "NetworkMessage" and port == 43 then
        addLine(tostring(script), tostring(msg))
        print("["..tostring(script).."] "..tostring(msg))
        draw()

    else
        draw()  -- timeout : redessine (indicateur de vie) / timeout: redraw (heartbeat)
    end
end
