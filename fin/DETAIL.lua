-- DETAIL.lua : affichage détaillé d'un train sur écran 600x900
-- Navigue entre les trains via boutons du panel DETAIL_PANEL2
-- DETAIL_SCREEN_R (gpu)  : détail du train courant
-- DETAIL_SCREEN_L (gpu2) : liste circulaire des trains
-- LED (5,8) : feedback vert sur appui bouton

-- === INITIALISATION MATÉRIEL ===
local gpus=computer.getPCIDevices(classes.Build_GPU_T2_C)
local gpu=gpus[1]   -- écran détail (droite)
local gpu2=gpus[2]  -- écran liste  (gauche)
local scr=component.proxy(component.findComponent("DETAIL_SCREEN_R")[1])
local scrL=component.proxy(component.findComponent("DETAIL_SCREEN_L")[1])
local sta=component.proxy(component.findComponent("GARE_TEST")[1])
local pan=component.proxy(component.findComponent("DETAIL_PANEL2")[1])
local net=computer.getPCIDevices(classes.NetworkCard)[1]
gpu:bindScreen(scr)
if gpu2 and scrL then gpu2:bindScreen(scrL) end

-- === LOG (broadcast port 43 → GET_LOG) ===
print=function(...)
    local t={} for i=1,select('#',...)do t[i]=tostring(select(i,...))end
    pcall(function()net:broadcast(43,"DETAIL",table.concat(t," "))end)
end

-- === PANEL DETAIL_PANEL2 ===
local bP=pan:getModule(4,8,0)    -- PushbuttonModule gauche (précédent)
local bN=pan:getModule(6,8,0)    -- PushbuttonModule droit  (suivant)
local ledFB=pan:getModule(5,8,0) -- IndicatorModule centre  (feedback vert)
event.listen(bP) event.listen(bN) event.listen(net)
net:open(42)
net:open(45)
net:open(50)  -- port SHUTDOWN (STARTER)

-- === CONSTANTES AFFICHAGE ===
local sw,sh=600,900
local BG={r=0,g=0,b=0,a=1}
local OR={r=1,g=0.5,b=0,a=1}
local WH={r=1,g=1,b=1,a=1}
local DI={r=0.4,g=0.4,b=0.4,a=1}
local GR={r=0.2,g=1,b=0.2,a=1}
local RE={r=1,g=0.2,b=0.2,a=1}
local YE={r=1,g=1,b=0.2,a=1}
local BL={r=0.2,g=0.6,b=1,a=1}
local SP={r=0.15,g=0.15,b=0.15,a=1}

-- === ÉTAT GLOBAL ===
local idx=1
local tl={}
local tm={}
local la={}
local dp={}
local dk_prev={}
local saved={}
local ledOn=false

-- Rafraîchit la liste des trains : séquentielle, master valide, timetable avec gares
local function ref()
    local raw=sta:getTrackGraph():getTrains()
    tl={}
    for _,t in pairs(raw) do
        local ok,m=pcall(function()return t:getMaster()end)
        if ok and m then
            local ok2,tt=pcall(function()return t:getTimeTable()end)
            if ok2 and tt then
                local ok3,stops=pcall(function()return tt:getStops()end)
                if ok3 and stops and #stops>0 then
                    table.insert(tl,t)
                end
            end
        end
    end
end

local function tti(t)
    local ok,tt=pcall(function()return t:getTimeTable()end)
    if not ok or not tt then return nil,nil end
    local ok2,ci=pcall(function()return tt:getCurrentStop()end)
    if not ok2 then return nil,nil end
    local ok3,st=pcall(function()return tt:getStops()end)
    if not ok3 or not st then return nil,nil end
    local n={}
    for _,s in pairs(st) do
        local ok4,nm=pcall(function()return s.station.name end)
        table.insert(n,ok4 and nm or "???")
    end
    return ci,n
end

local function upd(tn,fr,to,d)
    if not tm[tn] then tm[tn]={} end
    local k=fr.."->"..to
    if not tm[tn][k] then tm[tn][k]={t=0,c=0} end
    tm[tn][k].t=tm[tn][k].t+d tm[tn][k].c=tm[tn][k].c+1
end

local function eta(tn,fr,to)
    if not tm[tn] then return nil end
    local k=tm[tn][fr.."->"..to]
    if not k or k.c==0 then return nil end
    return math.floor(k.t/k.c)
end

local function onTrip(tn,fr,to,d,ts,invStr)
    if not saved[tn] then saved[tn]={} end
    local it={}
    local ok,fn=pcall(load,"return "..invStr)
    if ok and fn then local ok2,r=pcall(fn) if ok2 and r then it=r end end
    table.insert(saved[tn],1,{from=fr,to=to,duration=d,ts=ts,inventory=it})
    while #saved[tn]>5 do table.remove(saved[tn]) end
    upd(tn,fr,to,d)
end

local function fmt(s) return string.format("%d:%02d",math.floor(s/60),s%60) end
local function sep(y) gpu:drawRect({x=10,y=y},{x=sw-20,y=1},SP,SP,0) end

-- Contrôle la LED de feedback
local function setLed(on)
    pcall(function() if ledFB then
        if on then ledFB:setColor(0,1,0,1) else ledFB:setColor(0,0,0,0) end
    end end)
end

-- === LISTE DES TRAINS (écran gauche, affichage circulaire) ===
local function drawList()
    if not gpu2 then return end
    gpu2:drawRect({x=0,y=0},{x=sw,y=sh},BG,BG,0)
    gpu2:drawRect({x=0,y=0},{x=sw,y=60},BG,{r=0.08,g=0.08,b=0.08,a=1},0)
    gpu2:drawText({x=10,y=16},"LISTE DES TRAINS",22,OR,false)
    gpu2:drawText({x=sw-100,y=20},#tl.." trains",17,DI,false)
    gpu2:drawRect({x=10,y=58},{x=sw-20,y=1},SP,SP,0)
    local rowH=28
    local maxRows=math.floor((sh-70)/rowH)
    if #tl==0 then gpu2:flush() return end
    local y=70
    for r=0,maxRows-1 do
        local i=((idx-1+r)%#tl)+1
        local t=tl[i]
        local tn=t:getName()
        local isCur=(i==idx)
        if isCur then gpu2:drawRect({x=0,y=y-2},{x=sw,y=rowH},{r=0.12,g=0.12,b=0.12,a=1},{r=0.18,g=0.18,b=0.18,a=1},0) end
        gpu2:drawText({x=10,y=y},string.format("%2d",i),17,isCur and OR or DI,false)
        gpu2:drawText({x=38,y=y},(isCur and "-> " or "   ")..tn,17,isCur and WH or DI,false)
        local ok,m=pcall(function()return t:getMaster()end)
        if ok and m then
            local mv=m:getMovement()
            local spd=math.abs(math.floor(mv.speed/100*3.6))
            local dk=m.isDocked
            local st,sc
            if dk then st="quai" sc=BL
            elseif spd>0 then st=spd.."km/h" sc=spd>100 and GR or YE
            else st="arret" sc=RE end
            gpu2:drawText({x=sw-90,y=y},st,15,sc,false)
        end
        y=y+rowH
    end
    gpu2:flush()
end

-- === DÉTAIL DU TRAIN COURANT (écran droit) ===
local function draw()
    if #tl==0 then gpu:drawRect({x=0,y=0},{x=sw,y=sh},BG,BG,0) gpu:drawText({x=20,y=440},"Aucun train",25,RE,false) gpu:flush() return end
    if idx>#tl then idx=1 end if idx<1 then idx=#tl end
    local t=tl[idx] local m=t:getMaster()
    if not m then idx=idx+1 if idx>#tl then idx=1 end return end

    local tn=t:getName()
    local mv=m:getMovement()
    local spd=math.abs(math.floor(mv.speed/100*3.6))
    local mspd=math.abs(math.floor(mv.maxSpeed/100*3.6))
    local dk=m.isDocked
    local veh={} pcall(function()veh=t:getVehicles()end)
    local nv=0 if veh then for _ in pairs(veh) do nv=nv+1 end end
    local ci,sn=tti(t)
    local now=computer.millis()/1000

    local dn=nil
    if ci and sn and #sn>0 then
        local ns=#sn
        dn=sn[(ci+1)%ns+1] or "???"
        if dk then
            local cur=sn[ci+1] or "???"
            local ls=la[tn]
            if ls and ls.from~=cur then
                local d=math.floor(now-ls.t)
                if d>5 and d<7200 then upd(tn,ls.from,cur,d) end
            end
            if not la[tn] or la[tn].from~=cur then la[tn]={from=cur,t=now} end
        end
        if dk_prev[tn]==true and not dk then
            local from=la[tn] and la[tn].from or "?"
            local av=eta(tn,from,dn)
            if av then dp[tn]={t=now,to=dn,av=av} end
        end
        dk_prev[tn]=dk
    end

    gpu:drawRect({x=0,y=0},{x=sw,y=sh},BG,BG,0)
    gpu:drawRect({x=0,y=0},{x=sw,y=60},BG,{r=0.08,g=0.08,b=0.08,a=1},0)
    gpu:drawText({x=10,y=14},"<<",30,OR,false)
    gpu:drawText({x=sw-44,y=14},">>",30,OR,false)
    local nx=math.floor(sw/2-#tn*9)
    gpu:drawText({x=nx,y=16},tn,24,WH,false)
    sep(62)

    local y=72
    local sc=spd>100 and GR or (spd>10 and YE or RE)
    gpu:drawText({x=10,y=y},"Vitesse",19,DI,false) gpu:drawText({x=130,y=y},spd.." km/h",19,sc,false) gpu:drawText({x=300,y=y},"max "..mspd,19,DI,false)
    y=y+28
    gpu:drawText({x=10,y=y},"Etat",19,DI,false)
    if dk then gpu:drawText({x=130,y=y},"A QUAI",19,BL,false)
    elseif spd>0 then gpu:drawText({x=130,y=y},"EN ROUTE",19,GR,false)
    else gpu:drawText({x=130,y=y},"ARRETE",19,RE,false) end
    y=y+28
    gpu:drawText({x=10,y=y},"Wagons",19,DI,false) gpu:drawText({x=130,y=y},tostring(nv),19,WH,false)
    y=y+32 sep(y) y=y+10

    gpu:drawText({x=10,y=y},"TIMETABLE",19,OR,false)
    if not dk and dn then
        local etaStr,etaColor
        local d=dp[tn]
        if d and dn==d.to then
            local rem=math.floor(d.av-(now-d.t))
            etaColor=rem>=0 and GR or RE
            etaStr=rem>=0 and fmt(rem) or "-"..fmt(-rem)
        else
            local pn=la[tn] and la[tn].from or "?"
            local av=eta(tn,pn,dn)
            if av then etaStr="~"..fmt(av) etaColor=YE end
        end
        if etaStr then
            gpu:drawText({x=160,y=y},"→ "..dn,17,DI,false)
            gpu:drawText({x=sw-80,y=y},etaStr,19,etaColor,false)
        end
    end
    y=y+26
    if sn and #sn>0 then
        local ns=#sn
        for i,nm in ipairs(sn) do
            if y>sh-160 then gpu:drawText({x=10,y=y},"...",17,DI,false) break end
            local i0=i-1 local isc=(i0==ci) local isp=(i0==(ci-1)%ns)
            local px="  " local pc=DI
            if isc then px="→ " pc=GR elseif isp then px="✓ " pc={r=0.3,g=0.3,b=0.3,a=1} end
            gpu:drawText({x=10,y=y},px..nm,17,pc,false)
            y=y+21
        end
    else gpu:drawText({x=10,y=y},"Pas de timetable",17,DI,false) end

    y=y+6 sep(y) y=y+10
    gpu:drawText({x=10,y=y},"INVENTAIRE",19,OR,false) y=y+26
    local it=(saved[tn] and saved[tn][1] and saved[tn][1].inventory) or {}
    local has=false
    for nm,cnt in pairs(it) do
        if y>sh-40 then break end
        gpu:drawText({x=10,y=y},nm.."  x"..cnt,17,WH,false) y=y+21 has=true
    end
    if not has then gpu:drawText({x=10,y=y},"En attente LOGGER...",17,DI,false) end

    gpu:drawRect({x=0,y=sh-35},{x=sw,y=35},BG,BG,0)
    local cnt=idx.." / "..#tl
    local cx=math.floor((sw-#cnt*11)/2)
    gpu:drawText({x=cx,y=sh-28},cnt,22,WH,false)
    gpu:flush()
end

-- === DÉMARRAGE ===
print("DETAIL démarré - "..#tl.." trains")
ref()
setLed(false)
for _,t in pairs(tl) do
    local ok,m=pcall(function()return t:getMaster()end)
    if ok and m then dk_prev[t:getName()]=m.isDocked end
end

local function shutdownNow()
    gpu:drawRect({x=0,y=0},{x=sw,y=sh},BG,BG,0)
    gpu:flush()
    if gpu2 then gpu2:drawRect({x=0,y=0},{x=sw,y=sh},BG,BG,0); gpu2:flush() end
    computer.stop()
end

-- === BOUCLE PRINCIPALE ===
while true do
    -- Vérifie SHUTDOWN en priorité avant chaque draw (non-bloquant)
    do local e,_,_,p=event.pull(0) if e=="NetworkMessage" and p==50 then shutdownNow() end end
    draw()
    drawList()
    -- LED : éteindre après un cycle de feedback
    if not ledOn then setLed(false) end
    ledOn=false
    local e,src,sender,port,a1,a2,a3,a4,a5,a6=event.pull(2)
    if e=="Trigger" then
        local curName=#tl>0 and tl[idx] and tl[idx]:getName() or nil
        ref()
        if curName then
            for i,t in ipairs(tl) do if t:getName()==curName then idx=i break end end
        end
        if src==bN then idx=idx%#tl+1 end
        if src==bP then idx=(idx-2)%#tl+1 end
        ledOn=true
        setLed(true)
    elseif e=="NetworkMessage" then
        if port==50 then
            shutdownNow()
        elseif port==42 then
            onTrip(a1,a2,a3,a4,a5,a6)
        elseif port==45 then
            local tn,seg,avg,cnt=a1,a2,a3,a4
            if tn and seg and avg and cnt and cnt>0 then
                if not tm[tn] then tm[tn]={} end
                tm[tn][seg]={t=avg*cnt,c=cnt}
            end
        end
    end
end
