-- LOGGER.lua : surveille tous les trains, broadcast réseau + push HTTP vers Python
-- LOGGER est la source primaire et effectue TOUS les calculs de stats
-- Port 42 : trajets (tn,fr,to,dur,ts,invStr)
-- Port 44 : snapshot état trains (ser(state))
-- Port 45 : stats ETA par segment (avg,count) → DETAIL
-- Port 46 : sync (TRAIN_STATS/DETAIL) + beacon LOGGER_ADDR (→ STOCKAGE) + réponse WHO_IS_LOGGER
-- Port 47 : stats calculées (avgSpeed,avgDur,score,conf,scoreHistory...) → TRAIN_STATS
-- Port 48 : réception données STOCKAGE (STOCKAGE → LOGGER)
-- Port 49 : requêtes point-à-point → réponse via net:send(addr, 49, data)
-- Port 51 : réception stats power (POWER_MON → LOGGER)
-- Port 53 : config dispatch broadcast → DISPATCH
-- Port 69 : réception status DISPATCH + envoi commandes web → DISPATCH

local VERSION = "1.6.6"

-- === INITIALISATION MATÉRIEL ===
local net=computer.getPCIDevices(classes.NetworkCard)[1]
local inets=computer.getPCIDevices(classes.FINInternetCard)
local inetPush   = inets[1]  -- POST /api/push  (état trains, toutes les 2s)
local inetTrips  = inets[2]  -- POST /api/trips (historique, sur trajet)
local inetConfig = inets[3]  -- GET  /api/dispatch/routes.lua
local inetCmd    = inets[4]  -- GET  /api/dispatch/command.lua
local WEB_URL="http://127.0.0.1:8081"
local staList=component.findComponent("GARE_TEST")
if not staList or not staList[1] then pcall(function()net:broadcast(43,"LOGGER","ERREUR: GARE_TEST non trouvee")end) end
local sta=staList and staList[1] and component.proxy(staList[1])
event.listen(net)
-- ports 42/44/45/47 : émission uniquement, pas besoin de open()
net:open(46)
net:open(48)
net:open(49)
net:open(51)
net:open(53)
net:open(69)
net:open(43)  -- écoute tous les logs FIN pour le dashboard web / listen to all FIN logs for web dashboard

print("=== LOGGER v"..VERSION.." BOOT ===")

-- === LOG (broadcast port 43 → GET_LOG) ===
local function log(msg)
    pcall(function()net:broadcast(43,"LOGGER",tostring(msg))end)
end
print=function(...)
    local t={} for i=1,select('#',...)do t[i]=tostring(select(i,...))end
    log(table.concat(t," "))
end

-- === HTTP — 1 InternetCard dédiée par endpoint, f:await() obligatoire en FIN ===
-- f:get() ne déclenche pas la requête et reste "pending" indéfiniment — toujours f:await()
-- f:get() does not trigger the request and stays "pending" forever — always use f:await()

local saved={}         -- historique des trajets en mémoire (source primaire)
local stockageData={}  -- données STOCKAGE par adresse : [addr]={name,ts,raw}
local powerData=nil    -- dernière donnée reçue de POWER_MON (port 51)
local _knownDups={}    -- zones déjà signalées comme dupliquées (évite spam GET_LOG)

-- === DISPATCH ===
-- === RING BUFFER LOGS → WEB ===
local _logRing        = {}   -- entrées {ts,tag,msg} de tous les scripts FIN / entries from all FIN scripts
local _logRingSentIdx = 0    -- index du dernier log envoyé via HTTP / index of last log sent via HTTP
local LOG_RING_MAX    = 1000 -- capacité max du ring / max ring capacity

local dispatchAddr    = nil   -- adresse DISPATCH (découverte via port 69 DISPATCH_HELLO)
local dispatchStatus  = {}    -- état temps réel reçu de DISPATCH (port 69)
local dispatchRoutes       = nil   -- config routes fetchée depuis le web (nil = pas encore chargée)
local lastDispatchPayload  = nil   -- dernier payload envoyé à DISPATCH (dédup — évite re-apply si inchangé)
local lastConfigFetch      = -999  -- uptime (s) du dernier fetch config
local lastCmdPoll     = 0     -- uptime (s) du dernier poll commande
local CONFIG_FETCH_SEC = 15   -- intervalle refresh config (s)
local CMD_POLL_SEC     = 5    -- intervalle poll commande web (s)

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

-- === DISPATCH : config + commandes ===

-- Envoie la config routes à DISPATCH — force=true ignore la dédup (ex: reconnexion DISPATCH)
-- Sends route config to DISPATCH — force=true bypasses dedup (e.g. DISPATCH reconnection)
-- Retourne true si la config a été envoyée, false si inchangée / Returns true if config was sent, false if unchanged
local function broadcastDispatchConfig(force)
    if not dispatchRoutes then return false end
    local ok,payload=pcall(function()return ser(dispatchRoutes)end)
    if not ok or not payload then return false end
    if not force and payload==lastDispatchPayload then return false end  -- config inchangée → skip
    lastDispatchPayload=payload
    if dispatchAddr then
        pcall(function()net:send(dispatchAddr,53,payload)end)
    else
        pcall(function()net:broadcast(53,payload)end)
    end
    return true
end

-- Fetch config depuis le serveur web — NON BLOQUANT : fire → future → process au tick suivant
-- Fetch config from web server — NON-BLOCKING: fire → future → process on next tick
-- Fetch config (bloquant ~50ms sur HTTP local) — f:await() obligatoire en FIN
local function startFetchConfig()
    if not inetConfig then return end
    lastConfigFetch=computer.millis()/1000
    local ok,f=pcall(function()return inetConfig:request(WEB_URL.."/api/dispatch/routes.lua","GET","")end)
    if not ok or not f then return end
    local ok2,code,body=pcall(function()return f:await()end)
    if not ok2 or type(body)~="string" or body=="" or body=="nil" then return end
    local ok3,parsed=pcall(function()return (load("return "..body))()end)
    if ok3 and type(parsed)=="table" then
        dispatchRoutes=parsed
        if broadcastDispatchConfig() then
            log("DISPATCH: config envoyée ("..#parsed.." route(s))")
        end
    else
        log("DISPATCH: parse config échoué: "..body:sub(1,60))
    end
end

-- Poll commande web (bloquant ~50ms sur HTTP local) — f:await() obligatoire en FIN
local function startPollCmd()
    if not inetCmd or not dispatchAddr then return end
    local ok,f=pcall(function()return inetCmd:request(WEB_URL.."/api/dispatch/command.lua","GET","")end)
    if not ok or not f then return end
    local ok2,code,body=pcall(function()return f:await()end)
    if not ok2 or type(body)~="string" or body=="" or body=="nil" then return end
    pcall(function()net:send(dispatchAddr,69,"CMD:"..body)end)
    log("DISPATCH: commande forwardée → "..body:sub(1,60))
end

local function checkDispatch() end  -- conservé pour compatibilité / kept for compatibility

-- === PUSH HTTP VERS PYTHON ===
local function postTrips()
    if not inetTrips then return end
    local ok,body=pcall(function()return toJson(saved)end)
    if ok and body then
        local ok2,f=pcall(function()return inetTrips:request(WEB_URL.."/api/trips","POST",body,"Content-Type","application/json")end)
        if ok2 and f then pcall(function()f:await()end) end
    end
end

local function postState(cs)
    if not inetPush then return end
    local trainArr={} for _,s in pairs(state) do table.insert(trainArr,s) end
    -- Déduplication par nom de zone : si même nom depuis 2 adresses, garder le plus récent
    local byZone={}
    local dupZones={}
    for addr,d in pairs(stockageData) do
        local zname=d.name or addr
        if byZone[zname] then
            dupZones[zname]=true
            if not _knownDups[zname] then
                _knownDups[zname]=true
                log("WARN: zone '"..zname.."' dupliquee (2 adresses), gardee la plus recente")
            end
            if d.ts > byZone[zname].ts then byZone[zname]=d end
        else
            byZone[zname]=d
        end
    end
    -- Retirer du suivi les zones qui ne sont plus dupliquées
    for zname in pairs(_knownDups) do
        if not dupZones[zname] then _knownDups[zname]=nil end
    end
    local stockArr={}
    for zname,d in pairs(byZone) do
        local entry={zone=d.name,ts=d.ts,duplicate=dupZones[zname] or false}
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
            if d.stats.subzones then
                local subzones={}
                for _,sz in ipairs(d.stats.subzones) do
                    local se={name=sz.name,fillRate=sz.fillRate,slotsUsed=sz.slotsUsed,slotsTotal=sz.slotsTotal,totalItems=sz.totalItems}
                    if sz.items then
                        local items={}
                        for _,item in pairs(sz.items) do table.insert(items,{name=item.name,count=item.count,pct=item.pct}) end
                        table.sort(items,function(a,b)return a.count>b.count end)
                        se.items=items
                        local top={}
                        for i=1,math.min(3,#items) do table.insert(top,items[i]) end
                        se.topItems=top
                    end
                    table.insert(subzones,se)
                end
                entry.subzones=subzones
            end
        end
        table.insert(stockArr,entry)
    end
    -- Logs nouveaux depuis le dernier push / New logs since last push
    local newLogs={}
    for i=_logRingSentIdx+1,#_logRing do table.insert(newLogs,_logRing[i]) end
    _logRingSentIdx=#_logRing
    local ok,body=pcall(function()
        return toJson({trains=trainArr,stats=cs,stockage=stockArr,power=powerData,dispatch=dispatchStatus,logs=newLogs})
    end)
    if not ok or not body then return end
    local ok2,f=pcall(function()return inetPush:request(WEB_URL.."/api/push","POST",body,"Content-Type","application/json")end)
    if ok2 and f then pcall(function()f:await()end) end
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
            -- dockState entier (0=transit,1=chargement,2=prêt) — inclus dans snapshot port 44 pour DISPATCH
            -- dockState integer (0=transit,1=loading,2=ready) — included in port 44 snapshot for DISPATCH
            local dockInt=0
            pcall(function()dockInt=t.dockState or 0 end)
            local dk=dockInt~=0  -- booléen pour la logique interne LOGGER / boolean for LOGGER internal logic
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
            local status=dk and "docked" or (spd>10 and "moving" or "stopped")
            -- dockState inclus dans snapshot : DISPATCH lit l'état sans poll FIN direct
            -- dockState included in snapshot: DISPATCH reads state without direct FIN polling
            state[tn]={name=tn,speed=spd,status=status,station=cur,wagons=nv,dockState=dockInt}
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
log("LOGGER v"..VERSION.." démarré - "..trainCount.." trains | "..#inets.." InternetCard(s)")
-- Beacon : annonce à tous les STOCKAGE que LOGGER est prêt (sender = adresse LOGGER)
pcall(function()net:broadcast(46,"LOGGER_ADDR")end)
-- Annonce à DISPATCH que LOGGER (re)démarre → DISPATCH répondra DISPATCH_HELLO
pcall(function()net:broadcast(69,"LOGGER_READY")end)

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
        -- Relai vers DISPATCH : zone + totalItems pour le monitoring buffer
        -- Relay to DISPATCH: zone + totalItems for buffer monitoring
        if dispatchAddr and ok2 and parsed and parsed.totalItems then
            pcall(function()net:send(dispatchAddr,69,"BUF:"..arg1..":"..tostring(parsed.totalItems))end)
            -- Relai sous-zones individuelles si présentes (clé = "(PARENT) nom" = même format que web)
            -- Relay individual subzones if present (key = "(PARENT) name" = same format as web)
            if parsed.subzones then
                for _,sz in ipairs(parsed.subzones) do
                    if sz.name and sz.totalItems then
                        local fqName="("..arg1..") "..sz.name
                        pcall(function()net:send(dispatchAddr,69,"BUF:"..fqName..":"..tostring(sz.totalItems))end)
                    end
                end
            end
        end

    -- Stats power reçues de POWER_MON
    elseif e=="NetworkMessage" and port==51 then
        local ok2,parsed=pcall(function()return (load("return "..arg2))()end)
        if ok2 and parsed then
            parsed.ts=parsed.ts or math.floor(computer.millis()/1000)
            powerData=parsed
        end

    -- DISPATCH → status / hello
    elseif e=="NetworkMessage" and port==69 then
        if arg1=="DISPATCH_HELLO" then
            dispatchAddr=sender
            log("DISPATCH connecté addr="..tostring(sender))
            -- DISPATCH vient de se connecter : force l'envoi même si config inchangée
            -- DISPATCH just connected: force send even if config hasn't changed
            if dispatchRoutes then
                broadcastDispatchConfig(true)
            else
                startFetchConfig()
            end
        elseif arg1 and arg1:sub(1,4)~="CMD:" then
            -- Status broadcast de DISPATCH (table Lua sérialisée)
            local ok2,parsed=pcall(function()return (load("return "..arg1))()end)
            if ok2 and type(parsed)=="table" then dispatchStatus=parsed end
        end

    -- Logs de tous les scripts FIN → ring buffer pour dashboard web / All FIN scripts logs → ring buffer for web dashboard
    elseif e=="NetworkMessage" and port==43 then
        local entry={ts=math.floor(computer.millis()),tag=tostring(arg1),msg=tostring(arg2 or "")}
        table.insert(_logRing,entry)
        if #_logRing>LOG_RING_MAX then
            table.remove(_logRing,1)
            if _logRingSentIdx>0 then _logRingSentIdx=_logRingSentIdx-1 end
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
            local resp=ser({stats=cs,stockage=stockSummary,power=powerData})
            pcall(function()net:send(sender,49,resp)end)
        end
    end

    if computer.millis()>=nextTick then
        nextTick=nextTick+2000
        local ok,err=pcall(tick)
        if not ok then log("ERR tick: "..tostring(err)) end
        ticks=ticks+1
        checkDispatch()
        local nowSec=computer.millis()/1000
        if nowSec-lastConfigFetch>=CONFIG_FETCH_SEC then
            lastConfigFetch=nowSec
            startFetchConfig()
        end
        if nowSec-lastCmdPoll>=CMD_POLL_SEC and dispatchAddr then
            lastCmdPoll=nowSec
            startPollCmd()
        end
        if ticks>=30 then
            ticks=0
            local ok2,err2=pcall(broadcastAll)
            if not ok2 then log("ERR broadcastAll: "..tostring(err2)) end
            local ok3,err3=pcall(broadcastStats)
            if not ok3 then log("ERR broadcastStats: "..tostring(err3)) end
        end
    end
end
