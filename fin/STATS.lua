-- STATS.lua : métriques du réseau ferroviaire
-- Écoute : port 42 (trajets complétés), port 44 (snapshot état), port 45 (stats ETA LOGGER)
-- Affichage sur STATS_SCREEN + broadcast GET_LOG (port 43) toutes les 60s
-- Restaure l'historique depuis le serveur web au démarrage (InternetCard requise)

-- === INITIALISATION MATÉRIEL ===
local net =computer.getPCIDevices(classes.NetworkCard)[1]
local inet=computer.getPCIDevices(classes.FINInternetCard)[1]
local WEB_URL="http://127.0.0.1:8081"

-- === LOG (broadcast port 43 → GET_LOG) ===
-- Défini en premier pour pouvoir logger les erreurs d'init
print=function(...)
    if not net then return end
    local t={} for i=1,select('#',...)do t[i]=tostring(select(i,...))end
    pcall(function()net:broadcast(43,"STATS",table.concat(t," "))end)
end

if not net then computer.stop() end
event.listen(net)
net:open(42)
net:open(44)
net:open(45)

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

-- === ÉTAT ACCUMULÉ ===
local startTime=computer.millis()
local activeTrains={}
local snapCount=0

local trips={}  -- [{duration, inv_total}] — fenêtre glissante MAX_TRIPS

local scoreHistory={}
local MAX_HISTORY=20
local MAX_TRIPS=100

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

local function bar(ratio,width)
    local n=math.max(0,math.min(math.floor(ratio*width+0.5),width))
    return string.rep("█",n)..string.rep("░",width-n)
end

-- === CALCUL DES MÉTRIQUES (partagé écran + broadcast) ===
local function getMetrics()
    local speedSum,speedCnt=0,0
    local movingCnt,stoppedCnt,dockedCnt,totalCnt=0,0,0,0
    for _,s in pairs(activeTrains) do
        totalCnt=totalCnt+1
        if s.status=="moving" then
            speedSum=speedSum+s.speed speedCnt=speedCnt+1 movingCnt=movingCnt+1
        elseif s.status=="docked" then dockedCnt=dockedCnt+1
        else stoppedCnt=stoppedCnt+1 end
    end
    local avgSpeed=speedCnt>0 and math.floor(speedSum/speedCnt) or 0
    local durSum,invSum,invN=0,0,0
    for _,d in ipairs(trips) do
        durSum=durSum+d.duration
        if d.inv_total and d.inv_total>0 then invSum=invSum+d.inv_total invN=invN+1 end
    end
    local durCnt=#trips
    local avgDur=durCnt>0 and math.floor(durSum/durCnt) or 0
    local avgInv=invN>0 and math.floor(invSum/invN) or 0
    return movingCnt,stoppedCnt,dockedCnt,totalCnt,avgSpeed,avgDur,durCnt,avgInv,invN
end

-- === CALCUL DU SCORE RÉSEAU (0-100) ===
local function calcScore(movingCnt,totalCnt)
    local mobility=totalCnt>0 and (movingCnt/totalCnt) or 0.5
    local elapsed=math.max(1,(computer.millis()-startTime)/1000)
    local expected=math.floor(elapsed/2)
    local regularity=expected>0 and math.min(1,snapCount/expected) or 0.5
    local consistency=1.0
    if #trips>=3 then
        local sum=0
        for _,d in ipairs(trips) do sum=sum+d.duration end
        local avg=sum/#trips
        local varSum=0
        for _,d in ipairs(trips) do varSum=varSum+(d.duration-avg)^2 end
        local cv=avg>0 and (math.sqrt(varSum/#trips)/avg) or 0
        consistency=math.max(0,1-cv*1.5)
    end
    return math.floor((mobility*0.40+regularity*0.35+consistency*0.25)*100)
end

-- === NIVEAU DE CONFIANCE ===
local function confidence(avgSpeed,avgDur,durCnt)
    if durCnt==0 or avgSpeed==0 then return "INCONNUE",DI end
    local sScore=math.min(avgSpeed/150,1.0)
    local tScore
    if avgDur<=120 then tScore=1.0
    elseif avgDur>=600 then tScore=0.0
    else tScore=1.0-(avgDur-120)/480 end
    local c=(sScore+tScore)/2
    if     c>=0.80 then return "EXCELLENTE",GR
    elseif c>=0.60 then return "BONNE",GR
    elseif c>=0.40 then return "CORRECTE",YE
    elseif c>=0.20 then return "DEGRADEE",RE
    else                return "MAUVAISE",RE
    end
end

-- === RENDU ÉCRAN (1200x600, layout 3 colonnes + graphique en bas) ===
-- Col1: x=0-400   TRAINS
-- Col2: x=400-800 PERFORMANCE
-- Col3: x=800-1200 SCORE + CONFIANCE
-- Bas:  y=400-600 HISTORIQUE
local COL=400  -- largeur de chaque colonne
local HDR=70   -- hauteur header
local BODY=330 -- hauteur corps (HDR → HDR+BODY)
local GRAPH_Y=HDR+BODY  -- y départ graphique = 400
local GRAPH_H=sh-GRAPH_Y-20  -- hauteur graphique ≈ 180

local function drawScreen()
    if not gpu or not scr then return end
    local movingCnt,stoppedCnt,dockedCnt,totalCnt,avgSpeed,avgDur,durCnt,avgInv,invN=getMetrics()
    local score=#scoreHistory>0 and scoreHistory[#scoreHistory] or 0
    local scoreColor=score>=80 and GR or score>=60 and YE or RE
    local mobRatio=totalCnt>0 and movingCnt/totalCnt or 0
    local mobColor=mobRatio>=0.6 and GR or mobRatio>=0.4 and YE or RE
    local spdColor=avgSpeed>150 and GR or avgSpeed>80 and YE or RE
    local confStr,confColor=confidence(avgSpeed,avgDur,durCnt)

    gpu:drawRect({x=0,y=0},{x=sw,y=sh},BG,BG,0)

    -- === EN-TÊTE (pleine largeur) ===
    gpu:drawRect({x=0,y=0},{x=sw,y=HDR},BG,{r=0.08,g=0.05,b=0,a=1},0)
    gpu:drawText({x=20,y=16},"STATS RESEAU",32,OR,false)
    -- séparateurs verticaux dans le header
    gpu:drawRect({x=COL,y=0},{x=1,y=HDR},{r=0.15,g=0.1,b=0,a=1},{r=0.15,g=0.1,b=0,a=1},0)
    gpu:drawRect({x=COL*2,y=0},{x=1,y=HDR},{r=0.15,g=0.1,b=0,a=1},{r=0.15,g=0.1,b=0,a=1},0)
    gpu:drawText({x=COL+20,y=16},"PERFORMANCE",22,OR,false)
    gpu:drawText({x=COL*2+20,y=16},"SCORE RESEAU",22,OR,false)
    -- ligne séparatrice header/body
    gpu:drawRect({x=0,y=HDR-2},{x=sw,y=2},OR,OR,0)

    -- séparateurs verticaux corps
    gpu:drawRect({x=COL,y=HDR},{x=1,y=BODY},{r=0.15,g=0.15,b=0.15,a=1},{r=0.15,g=0.15,b=0.15,a=1},0)
    gpu:drawRect({x=COL*2,y=HDR},{x=1,y=BODY},{r=0.15,g=0.15,b=0.15,a=1},{r=0.15,g=0.15,b=0.15,a=1},0)

    -- === COL 1 : TRAINS ===
    local x1,y1=16,HDR+16
    gpu:drawText({x=x1,y=y1},"TRAINS",20,OR,false) y1=y1+34
    gpu:drawText({x=x1,y=y1},"En mouvement",18,DI,false)
    gpu:drawText({x=x1+220,y=y1},tostring(movingCnt),20,GR,false) y1=y1+26
    gpu:drawText({x=x1,y=y1},"A quai",18,DI,false)
    gpu:drawText({x=x1+220,y=y1},tostring(dockedCnt),20,BL,false) y1=y1+26
    gpu:drawText({x=x1,y=y1},"A l'arret",18,DI,false)
    gpu:drawText({x=x1+220,y=y1},tostring(stoppedCnt),20,RE,false) y1=y1+26
    gpu:drawText({x=x1,y=y1},"Total",18,DI,false)
    gpu:drawText({x=x1+220,y=y1},tostring(totalCnt),20,WH,false)

    -- === COL 2 : PERFORMANCE ===
    local x2,y2=COL+16,HDR+16
    gpu:drawText({x=x2,y=y2},"Vitesse moy",18,DI,false) y2=y2+26
    gpu:drawText({x=x2,y=y2},avgSpeed.." km/h",28,spdColor,false) y2=y2+50
    -- barre vitesse
    local svw=COL-32
    gpu:drawRect({x=x2,y=y2},{x=svw,y=14},{r=0.08,g=0.08,b=0.08,a=1},{r=0.08,g=0.08,b=0.08,a=1},0)
    gpu:drawRect({x=x2,y=y2},{x=math.floor(svw*math.min(avgSpeed/200,1)),y=14},spdColor,spdColor,0)
    y2=y2+30
    gpu:drawText({x=x2,y=y2},"Trajet moy",18,DI,false) y2=y2+26
    gpu:drawText({x=x2,y=y2},(durCnt>0 and fmt(avgDur) or "N/A"),28,YE,false)
    gpu:drawText({x=x2+120,y=y2+6},"("..durCnt.." trajets)",16,DI,false) y2=y2+50
    gpu:drawText({x=x2,y=y2},"Qte/trajet",18,DI,false) y2=y2+26
    gpu:drawText({x=x2+160,y=y2+4},"("..invN.." trajets)",15,DI,false)

    -- === COL 3 : SCORE + CONFIANCE ===
    local x3,y3=COL*2+16,HDR+16
    -- grand score
    gpu:drawText({x=x3,y=y3},tostring(score),68,scoreColor,false)
    gpu:drawText({x=x3+140,y=y3+42},"/100",22,DI,false)
    y3=y3+100
    gpu:drawText({x=x3,y=y3},"Confiance",18,DI,false) y3=y3+26
    gpu:drawText({x=x3,y=y3},confStr,26,confColor,false)
    gpu:drawText({x=x3,y=HDR+BODY-22},"UP: "..fmtUptime(computer.millis()-startTime),16,DI,false)

    -- === LIGNE SÉPARATRICE CORPS/GRAPHIQUE ===
    gpu:drawRect({x=0,y=GRAPH_Y},{x=sw,y=1},{r=0.2,g=0.2,b=0.2,a=1},{r=0.2,g=0.2,b=0.2,a=1},0)
    gpu:drawText({x=16,y=GRAPH_Y+4},"HISTORIQUE",16,OR,false)
    gpu:drawText({x=160,y=GRAPH_Y+6},"("..#scoreHistory.." mesures)",14,DI,false)

    -- === GRAPHIQUE HISTORIQUE (barres verticales) ===
    local gy=GRAPH_Y+24
    local gh=math.min(sh-gy-8, 80)
    if #scoreHistory>0 then
        local colW=math.floor((sw-32)/#scoreHistory)
        for i,sc in ipairs(scoreHistory) do
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

-- === BROADCAST GET_LOG ===
local function broadcastStats()
    local movingCnt,stoppedCnt,dockedCnt,totalCnt,avgSpeed,avgDur,durCnt,avgInv,invN=getMetrics()
    local score=calcScore(movingCnt,totalCnt)
    table.insert(scoreHistory,score)
    if #scoreHistory>MAX_HISTORY then table.remove(scoreHistory,1) end
    local graphStr=""
    for _,sc in ipairs(scoreHistory) do
        if     sc>=80 then graphStr=graphStr.."█"
        elseif sc>=60 then graphStr=graphStr.."▓"
        elseif sc>=40 then graphStr=graphStr.."▒"
        else               graphStr=graphStr.."░"
        end
    end
    local confStr,_=confidence(avgSpeed,avgDur,durCnt)
    print("════════ STATS RESEAU ════════")
    print("Uptime       : "..fmtUptime(computer.millis()-startTime))
    print("Trains       : "..movingCnt.." mvt / "..dockedCnt.." quai / "..stoppedCnt.." arret  (total "..totalCnt..")")
    print("Vitesse moy  : "..avgSpeed.." km/h")
    print("Trajet moy   : "..(durCnt>0 and fmt(avgDur) or "N/A").."  ("..durCnt.." trajets)")
    print("Qte moy/traj : "..avgInv.." items")
    print("Score reseau : "..score.."/100  ["..bar(score/100,15).."]")
    print("Historique   : ["..graphStr.."]")
    print("Confiance    : "..confStr)
    print("══════════════════════════════")
end

-- === RESTAURATION HISTORIQUE AU DÉMARRAGE ===
local function fetchHistory()
    if not inet then print("STATS: pas d'InternetCard, historique non restauré") return end
    local ok,_=pcall(function()
        return inet:request(WEB_URL.."/api/recent-trips-lua","GET","")
    end)
    if not ok then print("STATS: fetchHistory echec requete") return end
    -- attend la réponse (max 8s)
    local e,body
    local t0=computer.millis()
    repeat
        e,_,_,_,body=event.pull(1)
    until e=="HTTPRequestSucceeded" or e=="HTTPRequestFailed" or computer.millis()-t0>8000
    if e~="HTTPRequestSucceeded" then print("STATS: fetchHistory timeout/erreur") return end
    local fn=load("return "..(body or "{}"))
    if not fn then print("STATS: fetchHistory parse erreur") return end
    local ok2,recent=pcall(fn)
    if not ok2 or type(recent)~="table" then print("STATS: fetchHistory données invalides") return end
    -- liste plate [{duration, inv_total, ts}] — même source que le site web
    for _,t in ipairs(recent) do
        if t.duration and t.duration>0 then
            table.insert(trips,{duration=t.duration, inv_total=(t.inv_total or 0)})
        end
    end
    local invCnt=0 for _,t in ipairs(trips) do if (t.inv_total or 0)>0 then invCnt=invCnt+1 end end
    print("STATS: "..#trips.." trajets restaurés, "..invCnt.." avec inventaire")
end

-- === DÉMARRAGE ===
event.pull(0)
fetchHistory()
print("STATS démarré - première diffusion dans 60s")
drawScreen()

-- === BOUCLE PRINCIPALE ===
local lastBroadcast=0
local lastDraw=0
local INTERVAL=60000

while true do
    local remaining=math.max(0.1,(lastBroadcast+INTERVAL-computer.millis())/1000)
    local e,_,_,port,a1,a2,a3,a4,a5,a6=event.pull(remaining)

    if e=="NetworkMessage" then
        if port==44 then
            local ok,fn=pcall(load,"return "..(a1 or "{}"))
            if ok and fn then
                local ok2,s=pcall(fn)
                if ok2 and s then
                    activeTrains=s
                    snapCount=snapCount+1
                end
            end

        elseif port==42 then
            local dur=tonumber(a4)
            if a1 and dur and dur>0 then
                local inv_total=0
                if a6 and a6~="{}" then
                    local ok,fn=pcall(load,"return "..a6)
                    if ok and fn then
                        local ok2,it=pcall(fn)
                        if ok2 and it then
                            for _,cnt in pairs(it) do inv_total=inv_total+cnt end
                        end
                    end
                end
                table.insert(trips,1,{duration=dur,inv_total=inv_total})
                if #trips>MAX_TRIPS then table.remove(trips) end
            end

        elseif port==45 then
            local avg=tonumber(a3) local cnt=tonumber(a4)
            if a2 and avg and cnt and cnt>0 and #trips<5 then
                for _=1,math.min(cnt,3) do
                    table.insert(trips,{duration=avg,inv_total=0})
                end
            end
        end
    end

    -- Redessine l'écran toutes les 2s
    local now=computer.millis()
    if now-lastDraw>=2000 then
        drawScreen()
        lastDraw=now
    end

    -- Broadcast GET_LOG toutes les 60s
    if now-lastBroadcast>=INTERVAL then
        broadcastStats()
        lastBroadcast=now
    end
end
