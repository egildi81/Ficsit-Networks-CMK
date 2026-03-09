-- STATS.lua : affichage des métriques du réseau ferroviaire
-- Reçoit les stats pré-calculées de LOGGER (port 47) — aucun calcul local
-- Port 47 : stats calculées par LOGGER (avgSpeed, score, conf, scoreHistory...)
-- Port 44 : snapshot état trains (pour snapCount/santé connexion uniquement)
-- Affichage sur STATS_SCREEN + broadcast GET_LOG (port 43) toutes les 60s

-- === INITIALISATION MATÉRIEL ===
local net=computer.getPCIDevices(classes.NetworkCard)[1]

-- === LOG (broadcast port 43 → GET_LOG) ===
print=function(...)
    if not net then return end
    local t={} for i=1,select('#',...)do t[i]=tostring(select(i,...))end
    pcall(function()net:broadcast(43,"STATS",table.concat(t," "))end)
end

if not net then computer.stop() end
event.listen(net)
net:open(44)
net:open(47)

local gpu=computer.getPCIDevices(classes.Build_GPU_T2_C)[1]
local scr=component.proxy(component.findComponent("STATS_SCREEN")[1])
if gpu and scr then gpu:bindScreen(scr) end

-- === CONSTANTES AFFICHAGE ===
local sw,sh=1200,600
local BG={r=0,g=0,b=0,a=1}
local WH={r=1,g=1,b=1,a=1}
local DI={r=0.4,g=0.4,b=0.4,a=1}
local GR={r=0.2,g=1,b=0.2,a=1}
local RE={r=1,g=0.2,b=0.2,a=1}
local YE={r=1,g=1,b=0.2,a=1}
local BL={r=0.2,g=0.6,b=1,a=1}
local OR={r=1,g=0.5,b=0,a=1}

-- === ÉTAT : DONNÉES REÇUES DE LOGGER ===
-- cs = computed stats, mis à jour à chaque réception port 47
local snapCount=0  -- compteur réceptions port 44 (santé connexion)
local cs={         -- valeurs par défaut avant première réception
    movingCnt=0, stoppedCnt=0, dockedCnt=0, totalCnt=0,
    avgSpeed=0, avgDur=0, avgInv=0, durCnt=0, invN=0,
    score=0, conf="INCONNUE", scoreHistory={}, uptime=0, totalInv=0
}

-- === UTILITAIRES ===
local function fmt(s)
    return string.format("%d:%02d",math.floor(s/60),s%60)
end

local function fmtUptime(ms)
    local s=math.floor(ms/1000)
    local h=math.floor(s/3600)
    local m=math.floor(s/60)%60
    s=s%60
    return string.format("%dh%02dm%02ds",h,m,s)
end

local function fmtNum(n)
    n=math.floor(n or 0)
    if     n>=1000000 then return string.format("%.1fM",n/1000000)
    elseif n>=100000  then return string.format("%dk",math.floor(n/1000))
    else                   return tostring(n) end
end

local function bar(ratio,width)
    local n=math.max(0,math.min(math.floor(ratio*width+0.5),width))
    return string.rep("█",n)..string.rep("░",width-n)
end

-- === RENDU ÉCRAN (1200x600, layout 3 colonnes + graphique en bas) ===
-- Col1: x=0-400   TRAINS
-- Col2: x=400-800 PERFORMANCE (X trajets)
-- Col3: x=800-1200 SCORE + CONFIANCE
-- Bas:  y=400-600 HISTORIQUE
local COL=400
local HDR=70
local BODY=330
local GRAPH_Y=HDR+BODY

local function drawScreen()
    if not gpu or not scr then return end
    local score=cs.scoreHistory and #cs.scoreHistory>0 and cs.scoreHistory[#cs.scoreHistory] or cs.score or 0
    local scoreColor=score>=80 and GR or score>=60 and YE or RE
    local spdColor=cs.avgSpeed>150 and GR or cs.avgSpeed>80 and YE or RE
    local confColor=cs.conf=="EXCELLENTE" and GR or cs.conf=="BONNE" and GR
        or cs.conf=="CORRECTE" and YE or cs.conf=="INCONNUE" and DI or RE

    gpu:drawRect({x=0,y=0},{x=sw,y=sh},BG,BG,0)

    -- === EN-TÊTE ===
    gpu:drawRect({x=0,y=0},{x=sw,y=HDR},BG,{r=0.08,g=0.05,b=0,a=1},0)
    gpu:drawText({x=20,y=16},"STATS RESEAU",32,OR,false)
    gpu:drawRect({x=COL,y=0},{x=1,y=HDR},{r=0.15,g=0.1,b=0,a=1},{r=0.15,g=0.1,b=0,a=1},0)
    gpu:drawRect({x=COL*2,y=0},{x=1,y=HDR},{r=0.15,g=0.1,b=0,a=1},{r=0.15,g=0.1,b=0,a=1},0)
    gpu:drawRect({x=0,y=HDR-2},{x=sw,y=2},OR,OR,0)

    -- séparateurs verticaux corps
    gpu:drawRect({x=COL,y=HDR},{x=1,y=BODY},{r=0.15,g=0.15,b=0.15,a=1},{r=0.15,g=0.15,b=0.15,a=1},0)
    gpu:drawRect({x=COL*2,y=HDR},{x=1,y=BODY},{r=0.15,g=0.15,b=0.15,a=1},{r=0.15,g=0.15,b=0.15,a=1},0)

    -- === COL 1 : TRAINS ===
    local x1,y1=16,HDR+16
    gpu:drawText({x=x1,y=y1},"TRAINS",20,OR,false) y1=y1+34
    gpu:drawText({x=x1,y=y1},"En mouvement",18,DI,false)
    gpu:drawText({x=x1+220,y=y1},tostring(cs.movingCnt),20,GR,false) y1=y1+26
    gpu:drawText({x=x1,y=y1},"A quai",18,DI,false)
    gpu:drawText({x=x1+220,y=y1},tostring(cs.dockedCnt),20,BL,false) y1=y1+26
    gpu:drawText({x=x1,y=y1},"A l'arret",18,DI,false)
    gpu:drawText({x=x1+220,y=y1},tostring(cs.stoppedCnt),20,RE,false) y1=y1+26
    gpu:drawText({x=x1,y=y1},"Total",18,DI,false)
    gpu:drawText({x=x1+220,y=y1},tostring(cs.totalCnt),20,WH,false)

    -- === COL 2 : PERFORMANCE ===
    local x2,y2=COL+16,HDR+16
    local perfLabel="PERFORMANCE"..(cs.durCnt>0 and " ("..cs.durCnt.." trajets)" or "")
    gpu:drawText({x=x2,y=y2},perfLabel,20,OR,false) y2=y2+34
    gpu:drawText({x=x2,y=y2},"Vitesse moy",18,DI,false) y2=y2+26
    gpu:drawText({x=x2,y=y2},cs.avgSpeed.." km/h",28,spdColor,false) y2=y2+50
    local svw=COL-32
    gpu:drawRect({x=x2,y=y2},{x=svw,y=14},{r=0.08,g=0.08,b=0.08,a=1},{r=0.08,g=0.08,b=0.08,a=1},0)
    gpu:drawRect({x=x2,y=y2},{x=math.floor(svw*math.min(cs.avgSpeed/200,1)),y=14},spdColor,spdColor,0)
    y2=y2+30
    gpu:drawText({x=x2,y=y2},"Trajet moy",18,DI,false) y2=y2+26
    gpu:drawText({x=x2,y=y2},(cs.durCnt>0 and fmt(cs.avgDur) or "N/A"),28,YE,false) y2=y2+50
    -- Qté : moyenne/trajet (gauche) | total en circulation (droite)
    local half=math.floor((COL-32)/2)
    gpu:drawText({x=x2,y=y2},"Moy/trajet",16,DI,false)
    gpu:drawText({x=x2+half,y=y2},"Total circ.",16,DI,false) y2=y2+22
    gpu:drawText({x=x2,y=y2},(cs.invN>0 and fmtNum(cs.avgInv).." it." or "N/A"),24,YE,false)
    gpu:drawText({x=x2+half,y=y2},((cs.totalInv or 0)>0 and fmtNum(cs.totalInv).." it." or "N/A"),24,OR,false)

    -- === COL 3 : SCORE + CONFIANCE ===
    local x3,y3=COL*2+16,HDR+16
    gpu:drawText({x=x3,y=y3},"SCORE RESEAU",20,OR,false) y3=y3+34
    gpu:drawText({x=x3,y=y3},tostring(score),68,scoreColor,false)
    gpu:drawText({x=x3+140,y=y3+42},"/100",22,DI,false)
    y3=y3+118
    gpu:drawText({x=x3,y=y3},"Confiance",18,DI,false) y3=y3+26
    gpu:drawText({x=x3,y=y3},cs.conf,26,confColor,false)
    gpu:drawText({x=x3,y=HDR+BODY-22},"UP: "..fmtUptime((cs.uptime or 0)*1000),16,DI,false)

    -- === LIGNE SÉPARATRICE CORPS/GRAPHIQUE ===
    local hist=cs.scoreHistory or {}
    gpu:drawRect({x=0,y=GRAPH_Y},{x=sw,y=1},{r=0.2,g=0.2,b=0.2,a=1},{r=0.2,g=0.2,b=0.2,a=1},0)
    gpu:drawText({x=16,y=GRAPH_Y+4},"HISTORIQUE",16,OR,false)
    gpu:drawText({x=160,y=GRAPH_Y+6},"("..#hist.." mesures)",14,DI,false)

    -- === GRAPHIQUE HISTORIQUE ===
    local gy=GRAPH_Y+38
    local gh=math.min(sh-gy-8,80)
    if #hist>0 then
        local colW=math.floor((sw-32)/#hist)
        for i,sc in ipairs(hist) do
            local bh=math.floor(gh*sc/100)
            local bc=sc>=80 and GR or sc>=60 and YE or RE
            local bx=16+(i-1)*colW
            gpu:drawRect({x=bx,y=gy},{x=colW-2,y=gh},{r=0.06,g=0.06,b=0.06,a=1},{r=0.06,g=0.06,b=0.06,a=1},0)
            if bh>0 then gpu:drawRect({x=bx,y=gy+gh-bh},{x=colW-2,y=bh},bc,bc,0) end
        end
    else
        gpu:drawText({x=16,y=gy+gh/2-10},"En attente des donnees...",20,DI,false)
    end

    gpu:flush()
end

-- === BROADCAST GET_LOG (toutes les 60s) ===
local function broadcastLog()
    local hist=cs.scoreHistory or {}
    local graphStr=""
    for _,sc in ipairs(hist) do
        if     sc>=80 then graphStr=graphStr.."█"
        elseif sc>=60 then graphStr=graphStr.."▓"
        elseif sc>=40 then graphStr=graphStr.."▒"
        else               graphStr=graphStr.."░"
        end
    end
    local score=hist and #hist>0 and hist[#hist] or cs.score or 0
    print("════════ STATS RESEAU ════════")
    print("Uptime       : "..fmtUptime((cs.uptime or 0)*1000))
    print("Trains       : "..cs.movingCnt.." mvt / "..cs.dockedCnt.." quai / "..cs.stoppedCnt.." arret  (total "..cs.totalCnt..")")
    print("Vitesse moy  : "..cs.avgSpeed.." km/h")
    print("Trajet moy   : "..(cs.durCnt>0 and fmt(cs.avgDur) or "N/A").."  ("..cs.durCnt.." trajets)")
    print("Qte moy/traj : "..fmtNum(cs.avgInv).." items  |  Total circ. : "..fmtNum(cs.totalInv or 0).." items")
    print("Score reseau : "..score.."/100  ["..bar(score/100,15).."]")
    print("Historique   : ["..graphStr.."]")
    print("Confiance    : "..cs.conf)
    print("══════════════════════════════")
end

-- === DÉMARRAGE ===
-- Demande une sync à LOGGER via port 46 → LOGGER répond avec historique + stats (port 47)
pcall(function() net:broadcast(46,"SYNC") end)
drawScreen()
print("STATS démarré — sync LOGGER demandée")

-- === BOUCLE PRINCIPALE ===
local lastBroadcast=0
local lastDraw=0
local INTERVAL=60000

while true do
    local remaining=math.max(0.1,(lastBroadcast+INTERVAL-computer.millis())/1000)
    local e,_,_,port,a1=event.pull(remaining)

    if e=="NetworkMessage" then
        if port==47 then
            -- Stats calculées par LOGGER — source unique de vérité
            local ok,fn=pcall(load,"return "..(a1 or "{}"))
            if ok and fn then
                local ok2,data=pcall(fn)
                if ok2 and type(data)=="table" then cs=data end
            end

        elseif port==44 then
            -- Snapshot état trains — utilisé uniquement pour compter les réceptions (santé connexion)
            snapCount=snapCount+1
        end
    end

    local now=computer.millis()
    if now-lastDraw>=2000 then
        drawScreen()
        lastDraw=now
    end

    if now-lastBroadcast>=INTERVAL then
        broadcastLog()
        lastBroadcast=now
    end
end
