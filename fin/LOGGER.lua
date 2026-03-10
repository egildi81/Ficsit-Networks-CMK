-- LOGGER.lua : surveille tous les trains, broadcast réseau + push HTTP vers Python
-- LOGGER est la source primaire et effectue TOUS les calculs de stats
-- Port 42 : trajets (tn,fr,to,dur,ts,invStr)
-- Port 44 : snapshot état trains (ser(state))
-- Port 45 : stats ETA par segment (avg,count) → DETAIL
-- Port 46 : sync (TRAIN_STATS/DETAIL) + beacon LOGGER_ADDR (→ STOCKAGE) + réponse WHO_IS_LOGGER
-- Port 47 : stats calculées (avgSpeed,avgDur,score,conf,scoreHistory...) → TRAIN_STATS
-- Port 48 : réception données STOCKAGE (STOCKAGE → LOGGER)
-- Port 49 : requêtes point-à-point → réponse via net:send(addr, 49, data)

-- === INITIALISATION MATÉRIEL ===
local net=computer.getPCIDevices(classes.NetworkCard)[1]
local inet=computer.getPCIDevices(classes.FINInternetCard)[1]
local WEB_URL="http://127.0.0.1:8081"
local staList=component.findComponent("GARE_TEST")
if not staList or not staList[1] then pcall(function()net:broadcast(43,"LOGGER","ERREUR: GARE_TEST non trouvee")end) end
local sta=staList and staList[1] and component.proxy(staList[1])
event.listen(net)
-- ports 42/44/45/47 : émission uniquement, pas besoin de open()
net:open(46)
net:open(48)
net:open(49)

-- === LOG (broadcast port 43 → GET_LOG) ===
local function log(msg)
    pcall(function()net:broadcast(43,"LOGGER",tostring(msg))end)
end
print=function(...)
    local t={} for i=1,select('#',...)do t[i]=tostring(select(i,...))end
    log(table.concat(t," "))
end

local saved={}         -- historique des trajets en mémoire (source primaire)
local stockageData={}  -- données STOCKAGE par adresse : [addr]={name,ts,raw}

-- === SÉRIALISEURS ===
local function ser(v)
    local t=type(v)
    if t=="string" then return string.format("%q",v)
    elseif t=="number" then return tostring(v)
    elseif t=="boolean" then return tostring(v)
    elseif t=="table" then
        local p={}
        for k,val in pairs(v) do
            local ks=type(k)=="string" and string.format("[%q]",k) or "["..k.."]"
            table.insert(p,ks.."="..ser(val))
        end
        return "{"..table.concat(p,",").."}"
    end
    return "nil"
end

local function toJson(v)
    local t=type(v)
    if t=="string" then return '"'..v:gsub('\\','\\\\'):gsub('"','\\"')..'"'
    elseif t=="number" then return tostring(v)
    elseif t=="boolean" then return tostring(v)
    elseif t=="table" then
        local n=0 for _ in pairs(v) do n=n+1 end
        if n>0 and n==#v then
            local p={} for _,val in ipairs(v) do table.insert(p,toJson(val)) end
            return "["..table.concat(p,",").."]"
        else
            local p={} for k,val in pairs(v) do table.insert(p,'"'..tostring(k)..'":'..toJson(val)) end
            return "{"..table.concat(p,",").."}"
        end
    end
    return "null"
end

-- === CALCUL CENTRALISÉ DES STATS (source unique pour TRAIN_STATS.lua et WEB) ===
-- Calculé depuis state[] (trains en temps réel) et saved[] (historique)
-- scoreHistory mis à jour toutes les 60s
local scoreHistory={}
local MAX_SCORE_HISTORY=20
local lastHistoryUpdate=0
local loggerStartTime=computer.millis()
local state={}
local la={}
local depart={}
local dk_prev={}
local currentTotalInv=0

local function computeStats()
    -- Trains depuis state[]
    local speedSum,speedCnt=0,0
    local movingCnt,stoppedCnt,dockedCnt,totalCnt=0,0,0,0
    for _,s in pairs(state or {}) do
        totalCnt=totalCnt+1
        if s.status=="moving" then
            speedSum=speedSum+s.speed speedCnt=speedCnt+1 movingCnt=movingCnt+1
        elseif s.status=="docked" then dockedCnt=dockedCnt+1
        else stoppedCnt=stoppedCnt+1 end
    end
    local avgSpeed=speedCnt>0 and math.floor(speedSum/speedCnt) or 0

    -- Trajets : liste plate depuis saved[], triée par ts desc, max 100
    local flat={}
    for _,segs in pairs(saved) do
        for _,trips in pairs(segs) do
            for _,t in ipairs(trips) do table.insert(flat,t) end
        end
    end
    table.sort(flat,function(a,b) return (a.ts or 0)>(b.ts or 0) end)
    local cap=math.min(#flat,100)
    local durSum,invSum,invN=0,0,0
    for i=1,cap do
        local t=flat[i]
        durSum=durSum+t.duration
        if t.inv then
            local s=0 for _,cnt in pairs(t.inv) do s=s+cnt end
            if s>0 then invSum=invSum+s invN=invN+1 end
        end
    end
    local durCnt=cap
    local avgDur=durCnt>0 and math.floor(durSum/durCnt) or 0
    local avgInv=invN>0 and math.floor(invSum/invN) or 0

    -- Score : mobilité (60%) + consistance (40%)
    local mobility=totalCnt>0 and (movingCnt/totalCnt) or 0.5
    local consistency=1.0
    if durCnt>=3 then
        local varSum=0
        for i=1,cap do varSum=varSum+(flat[i].duration-avgDur)^2 end
        local cv=avgDur>0 and (math.sqrt(varSum/cap)/avgDur) or 0
        consistency=math.max(0,1-cv*1.5)
    end
    local score=math.floor((mobility*0.60+consistency*0.40)*100)

    -- Mise à jour historique scores (toutes les 60s)
    local now=computer.millis()
    if now-lastHistoryUpdate>=60000 then
        table.insert(scoreHistory,score)
        if #scoreHistory>MAX_SCORE_HISTORY then table.remove(scoreHistory,1) end
        lastHistoryUpdate=now
    end

    -- Confiance = fiabilité des données (peut-on faire confiance au score ?)
    -- mobilityConf 50% : % trains en mouvement
    -- sampleConf   30% : min(trajets enregistrés / 80, 1.0)
    -- uptimeConf   20% : min(uptime / 300s, 1.0)
    local uptime=math.floor((computer.millis()-loggerStartTime)/1000)
    local mobilityConf=totalCnt>0 and math.min(movingCnt/totalCnt/0.8,1.0) or 0
    local sampleConf=math.min(durCnt/80,1.0)
    local uptimeConf=math.min(uptime/300,1.0)
    local c=mobilityConf*0.50+sampleConf*0.30+uptimeConf*0.20
    local conf
    if     c>=0.80 then conf="HAUTE"
    elseif c>=0.60 then conf="BONNE"
    elseif c>=0.40 then conf="FAIBLE"
    else                conf="INEXISTANTE"
    end

    return {
        movingCnt=movingCnt, stoppedCnt=stoppedCnt, dockedCnt=dockedCnt, totalCnt=totalCnt,
        avgSpeed=avgSpeed, avgDur=avgDur, avgInv=avgInv, invN=invN, durCnt=durCnt,
        totalInv=currentTotalInv,
        score=score, conf=conf, scoreHistory=scoreHistory,
        uptime=uptime
    }
end

-- === PUSH HTTP VERS PYTHON ===
local function postTrips()
    if not inet then return end
    local ok,body=pcall(function()return toJson(saved)end)
    if ok and body then
        pcall(function()
            inet:request(WEB_URL.."/api/trips","POST",body,"Content-Type","application/json")
        end)
    end
end

local function postState(cs)
    if not inet then return end
    local trainArr={} for _,s in pairs(state) do table.insert(trainArr,s) end
    local stockArr={}
    for _,d in pairs(stockageData) do
        local entry={zone=d.name,ts=d.ts}
        if d.stats then
            entry.fillRate=d.stats.fillRate
            entry.slotsUsed=d.stats.slotsUsed
            entry.slotsTotal=d.stats.slotsTotal
            entry.totalItems=d.stats.totalItems
            if d.stats.items then
                local items={}
                for _,item in pairs(d.stats.items) do
                    table.insert(items,{name=item.name,count=item.count,pct=item.pct})
                end
                table.sort(items,function(a,b)return a.count>b.count end)
                entry.items=items
                local top={}
                for i=1,math.min(3,#items) do table.insert(top,items[i]) end
                entry.topItems=top
            end
        end
        table.insert(stockArr,entry)
    end
    local ok,body=pcall(function()
        return toJson({trains=trainArr,trips=saved,stats=cs,stockage=stockArr})
    end)
    if not ok or not body then return end
    pcall(function()
        inet:request(WEB_URL.."/api/push","POST",body,"Content-Type","application/json")
    end)
end

-- === LECTURE DE L'INVENTAIRE D'UN TRAIN ===
local function inv(t)
    local it={}
    local ok,v=pcall(function()return t:getVehicles()end)
    if not ok or not v then return it end
    for vi=1,#v do
        local vh=v[vi]
        local ok2,iv=pcall(function()return vh:getInventories()end)
        if ok2 and iv then
            for ji=1,#iv do
                local i=iv[ji]
                if i and i.itemCount>0 then
                    for si=0,i.size-1 do
                        local ok3,x=pcall(function()return i:getStack(si)end)
                        if ok3 and x and x.count>0 then
                            local ok4,nm=pcall(function()return x.item.type.name end)
                            local n=ok4 and nm or "???"
                            it[n]=(it[n] or 0)+x.count
                        end
                    end
                end
            end
        end
    end
    return it
end

local function wagons(t)
    local ok,v=pcall(function()return t:getVehicles()end)
    if not ok or not v then return 0 end
    local n=0 for _ in pairs(v) do n=n+1 end return n
end

-- === ENREGISTREMENT ET DIFFUSION D'UN TRAJET ===
local MAX_PER_SEG=10
local function saveTrip(tn,fr,to,d,ts,it,nv)
    local seg=fr.."->"..to
    if not saved[tn] then saved[tn]={} end
    if not saved[tn][seg] then saved[tn][seg]={} end
    table.insert(saved[tn][seg],1,{duration=d,ts=ts,inv=it,wagons=nv})
    while #saved[tn][seg]>MAX_PER_SEG do table.remove(saved[tn][seg]) end
    postTrips()
    local ok,invs=pcall(function()return ser(it)end)
    local invStr=ok and invs or "{}"
    pcall(function()net:broadcast(42,tn,fr,to,d,ts,invStr)end)
    local invLog=""
    for item,cnt in pairs(it) do invLog=invLog.." | "..item.." x"..cnt end
    log("LOG: "..tn.." "..seg.." d="..d.."s wagons="..nv..invLog)
end


-- === BOUCLE DE SURVEILLANCE (toutes les 2s) ===
local function tick()
    if not sta then return end
    local ok,trains=pcall(function()return sta:getTrackGraph():getTrains()end)
    if not ok then log("ERR getTrains: "..tostring(trains)) return end
    if not trains then return end
    local now=computer.millis()/1000
    state={}
    currentTotalInv=0
    for _,t in pairs(trains) do
        local ok2,m=pcall(function()return t:getMaster()end)
        if ok2 and m then
            local tn=t:getName()
            local dk=m.isDocked
            local cur="?"
            local hasTT=false
            pcall(function()
                local tt=t:getTimeTable()
                local stops=tt:getStops()
                if stops and #stops>0 then
                    hasTT=true
                    local ci=tt:getCurrentStop()
                    local st=tt:getStop(ci)
                    cur=st.station.name
                end
            end)
            if not hasTT then goto continue end
            local spd=0
            pcall(function()spd=math.abs(math.floor(m:getMovement().speed/100*3.6))end)
            local nv=wagons(t)
            local st=dk and "docked" or (spd>10 and "moving" or "stopped")
            state[tn]={name=tn,speed=spd,status=st,station=cur,wagons=nv}
            local it=inv(t)
            for _,cnt in pairs(it) do currentTotalInv=currentTotalInv+cnt end
            if dk then
                local ls=la[tn]
                if ls and ls.from~=cur then
                    local d=math.floor(now-ls.t)
                    if d>5 and d<7200 then
                        saveTrip(tn,ls.from,cur,d,math.floor(now),depart[tn] or {},wagons(t))
                    end
                end
                if not la[tn] or la[tn].from~=cur then
                    la[tn]={from=cur,t=now}
                end
            end
            if dk_prev[tn]==true and not dk then depart[tn]=inv(t) end
            dk_prev[tn]=dk
        end
        ::continue::
    end
    -- Calcul centralisé et diffusion
    local cs=computeStats()
    pcall(function()net:broadcast(44,ser(state))end)
    pcall(function()net:broadcast(47,ser(cs))end)
    postState(cs)
end

-- === DIFFUSION HISTORIQUE ===
local function broadcastAll()
    for tn,segs in pairs(saved) do
        for seg,trips in pairs(segs) do
            if trips then
                local fr,to=seg:match("^(.+)->(.+)$")
                if fr and to then
                    for _,trip in ipairs(trips) do
                        local ok,invs=pcall(function()return ser(trip.inv or {})end)
                        local invStr=ok and invs or "{}"
                        pcall(function()net:broadcast(42,tn,fr,to,trip.duration,trip.ts,invStr)end)
                    end
                end
            end
        end
    end
end

local function broadcastStats()
    for tn,segs in pairs(saved) do
        for seg,trips in pairs(segs) do
            if trips and #trips>0 then
                local total=0
                for _,trip in ipairs(trips) do total=total+trip.duration end
                local avg=math.floor(total/#trips)
                pcall(function()net:broadcast(45,tn,seg,avg,#trips)end)
            end
        end
    end
end

-- === DÉMARRAGE ===
local trainCount=0
if sta then pcall(function()trainCount=#sta:getTrackGraph():getTrains()end) end
log("LOGGER démarré - "..trainCount.." trains")
-- Beacon : annonce à tous les STOCKAGE que LOGGER est prêt (sender = adresse LOGGER)
pcall(function()net:broadcast(46,"LOGGER_ADDR")end)

-- === BOUCLE PRINCIPALE ===
local ticks=0
local nextTick=computer.millis()+2000
while true do
    local remaining=math.max(0.05,(nextTick-computer.millis())/1000)
    local e,_,sender,port,arg1,arg2=event.pull(remaining)

    if e=="NetworkMessage" and port==46 then
        if arg1=="WHO_IS_LOGGER" then
            -- Un STOCKAGE cherche l'adresse de LOGGER → réponse directe
            pcall(function()net:send(sender,46,"LOGGER_ADDR")end)
        elseif arg1=="LOGGER_ADDR" then
            -- Propre beacon reçu en retour → ignorer
        else
            -- Demande de sync depuis TRAIN_STATS ou DETAIL au démarrage
            local ok2,err2=pcall(broadcastAll) if not ok2 then log("ERR broadcastAll: "..tostring(err2)) end
            local ok3,err3=pcall(broadcastStats) if not ok3 then log("ERR broadcastStats: "..tostring(err3)) end
            local ok4,cs=pcall(computeStats)
            if not ok4 then log("ERR computeStats: "..tostring(cs)) else
                pcall(function()net:broadcast(47,ser(cs))end)
            end
            -- Re-beacon : un STOCKAGE qui attendait peut en profiter
            pcall(function()net:broadcast(46,"LOGGER_ADDR")end)
            local n=0
            for _,segs in pairs(saved) do for _,t in pairs(segs) do n=n+#t end end
            log("SYNC: "..n.." trips + stats broadcast")
        end

    -- Données stockage reçues de STOCKAGE.lua (net:send ciblé)
    elseif e=="NetworkMessage" and port==48 then
        local ok2,parsed=pcall(function()return (load("return "..arg2))()end)
        stockageData[sender]={name=arg1,ts=computer.millis()/1000,stats=ok2 and parsed or nil}
        if ok2 and parsed then
            log(tostring(arg1).." : "..(parsed.fillRate or "?").."%")
        end

    -- Requête point-à-point : répondre uniquement à l'expéditeur
    elseif e=="NetworkMessage" and port==49 then
        local ok5,cs=pcall(computeStats)
        if not ok5 then log("ERR computeStats: "..tostring(cs))
        else
            local stockSummary={}
            for addr,d in pairs(stockageData) do
                stockSummary[d.name or addr]={ts=d.ts,addr=addr}
            end
            local resp=ser({stats=cs,stockage=stockSummary})
            pcall(function()net:send(sender,49,resp)end)
        end
    end

    if computer.millis()>=nextTick then
        nextTick=nextTick+2000
        local ok,err=pcall(tick)
        if not ok then log("ERR tick: "..tostring(err)) end
        ticks=ticks+1
        if ticks>=30 then
            ticks=0
            local ok2,err2=pcall(broadcastAll)
            if not ok2 then log("ERR broadcastAll: "..tostring(err2)) end
            local ok3,err3=pcall(broadcastStats)
            if not ok3 then log("ERR broadcastStats: "..tostring(err3)) end
        end
    end
end
