-- GET_LOG.lua : affiche les logs réseau de tous les scripts sur un écran dédié
-- Écoute le port 43 (broadcast de logs depuis LOGGER, DETAIL, TRAIN_TAB, etc.)
-- Composants requis : GPU T2, écran nommé "MAP_SCREEN", NetworkCard

-- === INITIALISATION MATÉRIEL ===
local gpu=computer.getPCIDevices(classes.Build_GPU_T2_C)[1]
local scr=component.proxy(component.findComponent("MAP_SCREEN")[1])
local net=computer.getPCIDevices(classes.NetworkCard)[1]
gpu:bindScreen(scr)
net:open(43)   -- port dédié aux logs
event.listen(net)

-- === CONSTANTES AFFICHAGE ===
local sw,sh=2400,1800
local BG={r=0,g=0,b=0,a=1}
local WH={r=1,g=1,b=1,a=1}
local DI={r=0.3,g=0.3,b=0.3,a=1}
local OR={r=1,g=0.5,b=0,a=1}
local GR={r=0.2,g=1,b=0.2,a=1}
local BL={r=0.2,g=0.6,b=1,a=1}
local YE={r=1,g=1,b=0.2,a=1}
local RE={r=1,g=0.2,b=0.2,a=1}

-- Couleur par script source
local COLORS={
    LOGGER   = GR,
    DETAIL   = BL,
    TRAIN_TAB= YE,
}

local FONT=22              -- taille de police
local LINE_H=32            -- hauteur d'une ligne en pixels
local HEADER_H=50          -- hauteur de l'en-tête
local MAX_LINES=math.floor((sh-HEADER_H)/LINE_H)  -- lignes visibles (~54)
local lines={}             -- {src, msg, ts} — index 1 = le plus ancien, dernier = le plus récent
local t0=computer.millis()
-- Retourne le temps écoulé depuis le démarrage en H:MM:SS
local function fmtTime()
    local s=math.floor((computer.millis()-t0)/1000)
    return string.format("%d:%02d:%02d",math.floor(s/3600),math.floor(s/60)%60,s%60)
end

-- Ajoute une ligne à la fin (le plus récent en bas)
local function addLine(src,msg)
    table.insert(lines,{src=src,msg=msg,ts=fmtTime()})
    if #lines>MAX_LINES then table.remove(lines,1) end  -- supprime le plus vieux
end

-- Dessine l'écran complet
local function draw()
    gpu:drawRect({x=0,y=0},{x=sw,y=sh},BG,BG,0)
    -- En-tête
    gpu:drawRect({x=0,y=0},{x=sw,y=HEADER_H},BG,{r=0.08,g=0.08,b=0.08,a=1},0)
    gpu:drawText({x=20,y=12},"LOGS RÉSEAU",26,OR,false)
    gpu:drawText({x=sw-200,y=14},#lines.." lignes",20,DI,false)
    -- Lignes de log : du plus ancien (haut) au plus récent (bas)
    local y=HEADER_H+6
    for _,l in ipairs(lines) do
        local col=COLORS[l.src] or WH
        gpu:drawText({x=20,y=y},l.ts,FONT,YE,false)           -- horodatage
        gpu:drawText({x=200,y=y},"["..l.src.."]",FONT,col,false) -- source
        gpu:drawText({x=390,y=y},l.msg,FONT,WH,false)            -- message
        y=y+LINE_H
    end
    gpu:flush()
end

-- === BOUCLE PRINCIPALE ===
draw()
while true do
    local e,src,sender,port,script,msg=event.pull(30)
    if e=="NetworkMessage" and port==43 then
        addLine(tostring(script),tostring(msg))
        print("["..tostring(script).."] "..tostring(msg))
        draw()
    else
        -- Timeout : redessine quand même (indicateur de vie)
        draw()
    end
end
