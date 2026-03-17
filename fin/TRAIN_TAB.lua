-- TRAIN_TAB.lua : tableau de bord sur 3 écrans, alimenté par LOGGER via réseau (port 44)
-- Aucun appel direct aux trains — LOGGER collecte et broadcast le snapshot toutes les 2s
-- Écran gauche  (gpuL) : trains À L'ARRÊT
-- Écran centre  (gpuC) : trains EN MOUVEMENT, triés par vitesse
-- Écran droit   (gpuR) : trains À QUAI
-- Prérequis : une NetworkCard installée dans le PC TRAIN_TAB
-- Multi-thread : thread réseau (port 44) + thread dessin (2s timer)

-- === INITIALISATION MATÉRIEL ===
local net=computer.getPCIDevices(classes.NetworkCard)[1]
local gpus=computer.getPCIDevices(classes.Build_GPU_T2_C)
local scrL=component.proxy(component.findComponent("TAB_SCREEN_L")[1])
local scrC=component.proxy(component.findComponent("TAB_SCREEN_C")[1])
local scrR=component.proxy(component.findComponent("TAB_SCREEN_R")[1])

local gpuL=gpus[1]
local gpuC=gpus[2]
local gpuR=gpus[3]
gpuL:bindScreen(scrL)
gpuC:bindScreen(scrC)
gpuR:bindScreen(scrR)

-- === LOG (broadcast port 43 → GET_LOG) ===
print=function(...)
    local t={} for i=1,select('#',...)do t[i]=tostring(select(i,...))end
    pcall(function()net:broadcast(43,"TRAIN_TAB",table.concat(t," "))end)
end

event.listen(net)
net:open(44)  -- port snapshot LOGGER
net:open(50)  -- port SHUTDOWN (STARTER)

-- === INDICATOR POLE (optionnel) ===
-- Nommer le panel en jeu : "TRAFFIC_POLE"
-- Nommer le Speaker Pole en jeu : "TRAFFIC_SPEAKER"
local POLE_NAME    = "TRAFFIC_POLE"
local SPEAKER_NAME = "TRAFFIC_SPEAKER"
local POS_LED_G    = {x=0,y=0}   -- LED bas    (verte)
local POS_LED_Y    = {x=1,y=0}   -- LED milieu (jaune)
local POS_LED_O    = {x=2,y=0}   -- LED haut   (rouge)
-- Sons custom (fichiers .ogg à placer dans %LOCALAPPDATA%\FactoryGame\Saved\SaveGames\Computers\Sounds\)
local SOUND_GREEN   = "SNCF-Passage"   -- retour au vert
local SOUND_YELLOW  = "RATP-Signal"    -- passage au jaune
local SOUND_RED     = "SNCF-Panne"     -- passage au rouge (congestion)

local function findOpt(name)
    local list=component.findComponent(name)
    if list and list[1] then
        local ok,p=pcall(component.proxy,list[1])
        return ok and p or nil
    end
    return nil
end

local pole=findOpt(POLE_NAME)

local function getModule(pos)
    if not pole or not pos then return nil end
    local ok,m=pcall(function()return pole:getModule(pos.x,pos.y,0)end)
    return ok and m or nil
end

local ledG=getModule(POS_LED_G)
local ledY=getModule(POS_LED_Y)
local ledO=getModule(POS_LED_O)
local trafSpeaker=findOpt(SPEAKER_NAME)
local lastTrafLevel="green"  -- init à green pour éviter le son au démarrage

local function updateIndicator(nMoving,nStopped,nDocked)
    local idle=nStopped+nDocked
    local total=nMoving+idle
    local level
    if total==0 then
        level="green"
    else
        local ratio=nMoving/total
        if ratio>=0.6 then level="green"
        elseif ratio>=0.4 then level="yellow"
        else level="red"
        end
    end
    -- Feu tricolore : une seule LED allumée à la fois
    pcall(function() if ledG then
        if level=="green"  then ledG:setColor(0,1,0,1) else ledG:setColor(0,0,0,0) end
    end end)
    pcall(function() if ledY then
        if level=="yellow" then ledY:setColor(1,1,0,1) else ledY:setColor(0,0,0,0) end
    end end)
    pcall(function() if ledO then
        if level=="red" then ledO:setColor(1,0,0,1) else ledO:setColor(0,0,0,0) end
    end end)
    -- Alertes sonores lors des changements d'état
    if trafSpeaker and level~=lastTrafLevel then
        if level=="green"  then pcall(function()trafSpeaker:playSound(SOUND_GREEN,0)end)
        elseif level=="yellow" then pcall(function()trafSpeaker:playSound(SOUND_YELLOW,0)end)
        elseif level=="red"    then pcall(function()trafSpeaker:playSound(SOUND_RED,0)end)
        end
    end
    lastTrafLevel=level
end

-- === CONSTANTES AFFICHAGE ===
local sw,sh=900,1500
local BG={r=0,g=0,b=0,a=1}
local WH={r=1,g=1,b=1,a=1}
local DI={r=0.4,g=0.4,b=0.4,a=1}
local GR={r=0.2,g=1,b=0.2,a=1}
local RE={r=1,g=0.2,b=0.2,a=1}
local YE={r=1,g=1,b=0.2,a=1}
local BL={r=0.2,g=0.6,b=1,a=1}
local ROW_H=68
local START_Y=110

-- Dessine l'en-tête d'un écran
local function drawHeader(gpu,title,count,color,bgColor)
    gpu:drawRect({x=0,y=0},{x=sw,y=sh},BG,BG,0)
    gpu:drawRect({x=0,y=0},{x=sw,y=100},BG,bgColor,0)
    gpu:drawText({x=20,y=22},title,36,color,false)
    gpu:drawText({x=sw-120,y=28},"("..count..")",28,DI,false)
    gpu:drawRect({x=10,y=95},{x=sw-20,y=2},color,color,0)
end

-- Dessine une ligne pour un train
local function drawRow(gpu,y,name,line2,color,altBg)
    if altBg then
        gpu:drawRect({x=0,y=y},{x=sw,y=ROW_H-4},BG,altBg,0)
    end
    gpu:drawRect({x=16,y=y+24},{x=10,y=10},color,color,0)
    gpu:drawText({x=36,y=y+10},name,24,WH,false)
    if line2 then
        gpu:drawText({x=36,y=y+38},line2,20,color,false)
    end
end

-- === ÉTAT COURANT (partagé entre les deux threads) ===
local lastState={}
local lastStateTime=0  -- computer.millis() du dernier snapshot reçu

-- === RENDU DEPUIS L'ÉTAT REÇU ===
local function drawAll(state)
    local stopped={}
    local moving={}
    local docked={}

    for _,t in pairs(state) do
        if t.status=="docked" then
            table.insert(docked,t)
        elseif t.status=="moving" then
            table.insert(moving,t)
        else
            table.insert(stopped,t)
        end
    end

    table.sort(moving,function(a,b)return a.speed>b.speed end)
    updateIndicator(#moving,#stopped,#docked)

    local bottom=sh-20

    -- === ÉCRAN GAUCHE : TRAINS À L'ARRÊT ===
    drawHeader(gpuL,"A L'ARRET",#stopped,RE,{r=0.1,g=0,b=0,a=1})
    for i,t in ipairs(stopped) do
        local y=bottom-i*ROW_H
        if y<START_Y then break end
        local alt=i%2==0 and {r=0.06,g=0,b=0,a=1} or nil
        drawRow(gpuL,y,t.name,"Arrete",RE,alt)
    end
    gpuL:flush()

    -- === ÉCRAN CENTRE : TRAINS EN MOUVEMENT ===
    drawHeader(gpuC,"EN MOUVEMENT",#moving,GR,{r=0,g=0.1,b=0,a=1})
    for i,t in ipairs(moving) do
        local y=bottom-i*ROW_H
        if y<START_Y then break end
        local color=t.speed>100 and GR or YE
        local alt=i%2==0 and {r=0,g=0.06,b=0,a=1} or nil
        local line2=t.speed.." km/h  -> "..t.station
        drawRow(gpuC,y,t.name,line2,color,alt)
    end
    gpuC:flush()

    -- === ÉCRAN DROIT : TRAINS À QUAI ===
    drawHeader(gpuR,"A QUAI",#docked,BL,{r=0,g=0,b=0.1,a=1})
    for i,t in ipairs(docked) do
        local y=bottom-i*ROW_H
        if y<START_Y then break end
        local alt=i%2==0 and {r=0,g=0,b=0.06,a=1} or nil
        drawRow(gpuR,y,t.name,"-> "..t.station,BL,alt)
    end
    gpuR:flush()
end

local function drawWaiting()
    local msg="En attente de LOGGER..."
    for _,gpu in ipairs({gpuL,gpuC,gpuR}) do
        gpu:drawRect({x=0,y=0},{x=sw,y=sh},BG,BG,0)
        gpu:drawText({x=20,y=sh/2},msg,28,DI,false)
        gpu:flush()
    end
end

-- ════════════════════════════════════════════════════════════
-- THREAD MANAGER
-- ════════════════════════════════════════════════════════════
local threads={}
local shouldStop=false  -- flag levé par n'importe quelle coroutine, exécuté par runAll()

local function shutdown()
    for _,g in ipairs({gpuL,gpuC,gpuR}) do
        pcall(function() g:drawRect({x=0,y=0},{x=sw,y=sh},BG,BG,0); g:flush() end)
    end
    computer.stop()
end

local function spawn(fn)
    table.insert(threads,coroutine.create(fn))
end

local function runAll()
    while true do
        for i=#threads,1,-1 do
            if coroutine.status(threads[i])~="dead" then
                local ok,err=coroutine.resume(threads[i])
                if not ok then
                    print("Thread error: "..tostring(err))
                    table.remove(threads,i)
                end
            else
                table.remove(threads,i)
            end
        end
        -- Point de basculement + interception SHUTDOWN depuis le thread principal
        local e,_,_,port=event.pull(0)
        if e=="NetworkMessage" and port==50 then shouldStop=true end
        if shouldStop then shutdown() end
    end
end

-- ════════════════════════════════════════════════════════════
-- THREAD 1 : RÉSEAU — reçoit le snapshot de LOGGER (port 44)
-- ════════════════════════════════════════════════════════════
spawn(function()
    while true do
        local e,_,_,port,stateStr=event.pull(0)
        if e=="NetworkMessage" and port==50 then
            shouldStop=true  -- délègue à runAll() pour exécuter depuis le thread principal
        elseif e=="NetworkMessage" and port==44 and stateStr then
            local ok,fn=pcall(load,"return "..stateStr)
            if ok and fn then
                local ok2,s=pcall(fn)
                if ok2 and s then
                    lastState=s
                    lastStateTime=computer.millis()
                end
            end
        end
        coroutine.yield()
    end
end)

-- ════════════════════════════════════════════════════════════
-- THREAD 2 : DESSIN — redraw toutes les 2s, indépendamment du réseau
-- Affiche "(LOGGER inactif)" si aucun snapshot depuis 10s
-- ════════════════════════════════════════════════════════════
spawn(function()
    local lastDraw=0
    while true do
        local now=computer.millis()
        if now-lastDraw>=2000 then
            local age=now-lastStateTime
            if lastStateTime==0 then
                drawWaiting()
            elseif age>10000 then
                -- LOGGER silencieux depuis >10s : affiche quand même les dernières données
                drawHeader(gpuL,"A L'ARRET (LOGGER ?)",0,RE,{r=0.1,g=0,b=0,a=1})
                gpuL:flush()
                drawAll(lastState)
            else
                drawAll(lastState)
            end
            lastDraw=now
        end
        coroutine.yield()
    end
end)

-- === DÉMARRAGE ===
print("TRAIN_TAB démarré")
drawWaiting()
runAll()
