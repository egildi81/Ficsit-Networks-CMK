-- DISPATCH.lua : dispatch intelligent multi-routes, config depuis LOGGER/Web
-- Port 43: logs→GET_LOG | 44: snapshot trains←LOGGER | 53: config←LOGGER
-- Port 55: priorité buffers→STOCKAGE | 69: status→LOGGER / cmds←LOGGER

local VERSION = "4.3.0"
print("=== DISPATCH v"..VERSION.." BOOT ===")

-- === MATÉRIEL ===
local net = computer.getPCIDevices(classes.NetworkCard)[1]
if not net then error("DISPATCH: NetworkCard introuvable") end
event.listen(net)
net:open(44) net:open(53) net:open(55) net:open(69)

-- === LOG → GET_LOG ===
print = function(...)
    local t={} for i=1,select('#',...)do t[i]=tostring(select(i,...))end
    pcall(function()net:broadcast(43,"DISPATCH",table.concat(t," "))end)
end
print("DISPATCH v"..VERSION.." démarré")

-- === CONSTANTES ===
local BUF_SAMPLE_SEC   = 10
local LOG_STATUS_SEC   = 15
local STATUS_BCAST_SEC = 5
local SAFE_RETRY_SEC   = 30
local ETA_WINDOW       = 10
local SIGMA_FACTOR     = 2.0
local MIN_MARGE_SEC    = 10
local DEFAULT_ETA      = 30
local MAX_BUF_HIST     = 6
local ITEMS_PER_SLOT   = 100
local GARE_ANCHOR_NICK   = "GARE_TEST"
local PRIORITY_BCAST_SEC = 30
local MIN_BUF_DISPATCH   = 10   -- items : seuil urgence buffer critique / critical buffer emergency threshold
local TIMEOUT_ETA_FACTOR = 2.0  -- timeout = 2×(ETA+marge) si timing urgent sans charge suffisante / timeout if timing urgent without sufficient load

-- === ÉTAT GLOBAL ===
local routes     = {}
local routeState = {}
local configOk   = false
local safeMode   = false
local lastStatusBcast    = 0
local lastSafeRetry      = -SAFE_RETRY_SEC
local _lastConfigPayload = nil
local _trainSnapshot     = {}
local lastPriorityBcast  = 0
local _stockageCache     = {}  -- {[zoneName]=totalItems} mis à jour depuis port 55 STOCKAGE / {[zoneName]=totalItems} updated from port 55 STOCKAGE
local _globalStationMap  = {}  -- {[stName]=stObj} collecté depuis timetables de tous les trains au boot / {[stName]=stObj} collected from all train timetables at boot

-- === SÉRIALISEUR ===
local function ser(v)
    local t=type(v)
    if t=="string"  then return string.format("%q",v)
    elseif t=="number"  then return tostring(v)
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

-- === HELPERS TRAIN ===

-- dockState depuis snapshot LOGGER — fallback FIN direct si absent du snapshot
local function getDock(st)
    local snap=_trainSnapshot[st.name]
    if snap then return snap.dockState end
    local v=0 pcall(function()v=st.obj.dockState or 0 end) return v
end

-- Nom de la prochaine station depuis snapshot LOGGER — fallback FIN direct
local function getCurrentStopStr(st)
    local snap=_trainSnapshot[st.name]
    if snap then return snap.station end
    local s=nil
    pcall(function()
        local tt=st.obj:getTimeTable()
        local ci=tt:getCurrentStop()
        local stp=tt:getStop(ci)
        if stp then s=stp.station.name end
    end)
    return s
end

local function setSelfDriving(st, val)
    pcall(function()st.obj:setSelfDriving(val)end)
end

local function clearTimetable(st)
    pcall(function()
        local tt=st.obj:getTimeTable()
        if not tt then return end
        local stops=tt:getStops()
        for i=#stops,1,-1 do tt:removeStop(i-1) end
    end)
end

-- deliver=true → selfDriving=true + timetable [PARK→DELIVERY]
-- deliver=false → selfDriving=false + timetable vide (hold)
local function setRoute(st, rs, deliver)
    -- Guard nil stations — addStop(nil) crash le serveur dédié (exception C++ FIN non rattrapable)
    -- Guard nil stations — addStop(nil) crashes dedicated server (uncatchable C++ FIN exception)
    if deliver and (not rs.parkStObj or not rs.delivStObj) then
        print("WARN setRoute "..st.name.." : station nil, GO annulé (route mal configurée)")
        setSelfDriving(st, false)
        return
    end
    setSelfDriving(st, deliver)
    local ok,err=pcall(function()
        local tt=st.obj:getTimeTable()
        if not tt then return end
        local stops=tt:getStops()
        for i=#stops,1,-1 do tt:removeStop(i-1) end
        if deliver then
            tt:addStop(0,rs.parkStObj,nil)
            tt:addStop(1,rs.delivStObj,nil)
        end
    end)
    if not ok then print("WARN setRoute "..st.name.." : "..tostring(err)) end
end

local function getWagonItems(st)
    local total=0
    pcall(function()
        for _,v in ipairs(st.obj:getVehicles()) do
            pcall(function()
                for _,inv in ipairs(v:getInventories()) do
                    for i=0,inv.size-1 do
                        local ok,stack=pcall(function()return inv:getStack(i)end)
                        if ok and stack and stack.count then total=total+stack.count end
                    end
                end
            end)
        end
    end)
    return total
end

local function autoDetectCap(st)
    local cap=0
    pcall(function()
        for _,v in ipairs(st.obj:getVehicles()) do
            pcall(function()
                for _,inv in ipairs(v:getInventories()) do cap=cap+inv.size*ITEMS_PER_SLOT end
            end)
        end
    end)
    return cap
end

-- === DÉCOUVERTE TRAINS ===
-- Accès FIN direct limité au boot/reconfiguration uniquement

-- Scan unique du graphe au boot → map {nom → {obj, duplicate}}
local function buildTrainMap()
    local map={}
    local anchId=component.findComponent(GARE_ANCHOR_NICK)
    if not anchId or not anchId[1] then
        print("WARN buildTrainMap: ancrage '"..GARE_ANCHOR_NICK.."' introuvable")
        return map
    end
    local anch=component.proxy(anchId[1])
    _globalStationMap={}  -- reset à chaque buildTrainMap / reset on each buildTrainMap
    local graph=nil
    pcall(function()
        local all=anch:getTrackGraph():getTrains()
        graph=anch:getTrackGraph()
        print("buildTrainMap: "..#all.." trains sur le graphe")
        for _,t in ipairs(all) do
            local name="???"
            pcall(function()name=t:getName()end)
            if map[name] then
                map[name].duplicate=true
                print("WARN buildTrainMap: nom dupliqué '"..name.."'")
            else
                map[name]={obj=t,duplicate=false}
            end
            -- Collecter les objets station depuis toutes les timetables (même si le train cible est en hold)
            -- Collect station objects from all timetables (even if target train is in hold)
            pcall(function()
                local tt=t:getTimeTable()
                if not tt then return end
                for _,stop in ipairs(tt:getStops()) do
                    local s=stop.station
                    if s then
                        local sname="" pcall(function()sname=s.name end)
                        if sname~="" and not _globalStationMap[sname] then
                            _globalStationMap[sname]=s
                        end
                    end
                end
            end)
        end
    end)
    -- Tentative getStations() sur le graphe — découvre les stations sans passer par les timetables
    -- Try getStations() on the graph — discovers stations without going through timetables
    -- (utile si le train cible est en hold avec timetable vide / useful if target train is in hold with empty timetable)
    if graph then
        pcall(function()
            local allStations=graph:getStations()
            local n=0
            for _,s in ipairs(allStations) do
                local sname="" pcall(function()sname=s.name end)
                if sname~="" and not _globalStationMap[sname] then
                    _globalStationMap[sname]=s
                    n=n+1
                end
            end
            if n>0 then print("buildTrainMap: +"..n.." station(s) via getStations()") end
        end)
    end
    return map
end

local function discoverRoute(route, trainMap)
    local rs={
        trains={},
        parkStObj=nil, delivStObj=nil,
        parkStr=route.park, delivStr=route.delivery,
        bufBox=nil, bufName=route.buffer,  -- bufName = nick STOCKAGE computer pour cache relai LOGGER / STOCKAGE computer nick for LOGGER relay cache
        trainCap=0,
        etaHistory={}, bufHistory={},
        lastBufSample=0, lastStatusLog=0,
    }

    local bufId=component.findComponent(route.buffer)
    if bufId and bufId[1] then
        rs.bufBox=component.proxy(bufId[1])
    else
        print("WARN route "..route.name.." : buffer '"..route.buffer.."' introuvable")
    end

    -- Stations via findComponent — fonctionne même si timetable vide
    local parkId=component.findComponent(route.park)
    if parkId and parkId[1] then rs.parkStObj=component.proxy(parkId[1]) end
    local delivId=component.findComponent(route.delivery)
    if delivId and delivId[1] then rs.delivStObj=component.proxy(delivId[1]) end
    -- Fallback 2 : _globalStationMap (collecté depuis toutes les timetables au boot)
    -- Fallback 2: _globalStationMap (collected from all timetables at boot)
    if not rs.parkStObj  then rs.parkStObj  = _globalStationMap[route.park]     end
    if not rs.delivStObj then rs.delivStObj = _globalStationMap[route.delivery]  end
    if not rs.parkStObj  then print("WARN route "..route.name.." : station PARK '"..route.park.."' introuvable") end
    if not rs.delivStObj then print("WARN route "..route.name.." : station DELIVERY '"..route.delivery.."' introuvable") end

    -- Mode assignation : route.trains fourni → lookup par nom dans trainMap
    if route.trains and #route.trains>0 then
        for _,tname in ipairs(route.trains) do
            local entry=trainMap[tname]
            if not entry then
                print("WARN route "..route.name.." : train '"..tname.."' introuvable")
            elseif entry.duplicate then
                print("WARN route "..route.name.." : train '"..tname.."' nom dupliqué → ignoré")
            else
                local t=entry.obj
                local key=tostring(t)
                local stops={} pcall(function()local tt=t:getTimeTable() if tt then stops=tt:getStops() end end)
                -- Capture station objects depuis timetable — plus fiable que findComponent
                -- Capture station objects from timetable — more reliable than findComponent
                for _,stop in ipairs(stops) do
                    local s=stop.station
                    if s then
                        local sname="" pcall(function()sname=s.name end)
                        if sname==route.park     and not rs.parkStObj  then rs.parkStObj=s  end
                        if sname==route.delivery and not rs.delivStObj then rs.delivStObj=s end
                    end
                end
                local restoredFromHold=false
                local skipTrain=false
                if #stops<2 then
                    if rs.parkStObj and rs.delivStObj then
                        pcall(function()
                            local tt=t:getTimeTable()
                            local ex=tt:getStops()
                            for i=#ex,1,-1 do tt:removeStop(i-1) end
                            tt:addStop(0,rs.parkStObj,nil)
                            tt:addStop(1,rs.delivStObj,nil)
                        end)
                        restoredFromHold=true
                        print("Route "..route.name.." — train '"..tname.."' : timetable restaurée (hold)")
                    else
                        print("WARN route "..route.name.." — '"..tname.."' : 0 stops + stations introuvables")
                        skipTrain=true
                    end
                end
                if not skipTrain then
                    rs.trains[key]={
                        obj=t, name=tname,
                        lastDock=nil, lastStation=nil, departTime=nil,
                        arrivedAt=nil, delivering=false, lastDecision=nil,
                        timingUrgentSince=nil,
                        restoredFromHold=restoredFromHold,
                    }
                    if rs.trainCap==0 then rs.trainCap=autoDetectCap(rs.trains[key]) end
                    print("Route "..route.name.." — train: "..tname..(restoredFromHold and " [hold]" or ""))
                end
            end
        end
    else
        -- Fallback scan timetable (aucun route.trains configuré)
        local anchId=component.findComponent(GARE_ANCHOR_NICK)
        if not anchId or not anchId[1] then
            print("WARN: ancrage '"..GARE_ANCHOR_NICK.."' introuvable")
            return rs
        end
        local anch=component.proxy(anchId[1])
        pcall(function()
            local all=anch:getTrackGraph():getTrains()
            print("Route "..route.name.." — "..#all.." trains (scan fallback)")
            for _,t in ipairs(all) do
                local tt=t:getTimeTable()
                if not tt then goto cont_scan end
                local stops=tt:getStops()
                if not stops or #stops<2 then goto cont_scan end
                local hasPark,hasDeliv=false,false
                for _,stop in ipairs(stops) do
                    local s=stop.station
                    if not s then break end
                    local sname="" pcall(function()sname=s.name end)
                    if sname==route.park then
                        hasPark=true
                        -- Capture l'objet station depuis timetable si findComponent a échoué
                        -- Capture station object from timetable if findComponent failed
                        if not rs.parkStObj then rs.parkStObj=s end
                    elseif sname==route.delivery then
                        hasDeliv=true
                        if not rs.delivStObj then rs.delivStObj=s end
                    end
                end
                if hasPark and hasDeliv then
                    local name="???"
                    pcall(function()name=t:getName()end)
                    local key=tostring(t)
                    rs.trains[key]={
                        obj=t, name=name,
                        lastDock=nil, lastStation=nil, departTime=nil,
                        arrivedAt=nil, delivering=false, lastDecision=nil,
                        timingUrgentSince=nil,
                    }
                    if rs.trainCap==0 then rs.trainCap=autoDetectCap(rs.trains[key]) end
                    print("Route "..route.name.." — train: "..name)
                end
                ::cont_scan::
            end
        end)
    end

    return rs
end

-- === LIBÉRATION TRAINS (route supprimée) ===
local function releaseRoute(rs, rname)
    for _,st in pairs(rs.trains) do
        if rs.parkStObj and rs.delivStObj then
            pcall(function()
                local tt=st.obj:getTimeTable()
                local stops=tt:getStops()
                for i=#stops,1,-1 do tt:removeStop(i-1) end
                tt:addStop(0,rs.parkStObj,nil)
                tt:addStop(1,rs.delivStObj,nil)
            end)
        end
        setSelfDriving(st,true)
        print(st.name.." libéré (route '"..rname.."' supprimée)")
    end
end

-- === PRIORITÉ BUFFERS → STOCKAGE (port 55) ===
local function broadcastPriorityBuffers()
    local buffers={}
    for _,r in ipairs(routes) do
        if r.buffer and r.buffer~="" then table.insert(buffers,r.buffer) end
    end
    if #buffers==0 then return end
    lastPriorityBcast=computer.millis()/1000
    pcall(function()net:broadcast(55,ser({priority=buffers}))end)
    print("Buffers prioritaires: "..table.concat(buffers,", "))
end

-- === SAFE MODE ===
local function enterSafeMode()
    if safeMode then return end
    safeMode=true
    print("SAFE MODE : config indisponible — tous trains → PARK + hold")
    for _,rs in pairs(routeState) do
        for _,st in pairs(rs.trains) do
            setSelfDriving(st,false)
            clearTimetable(st)
        end
    end
end

local function exitSafeMode()
    if not safeMode then return end
    safeMode=false
    print("SAFE MODE levé")
end

-- === APPLICATION CONFIG ===
local function applyConfig(newRoutes)
    if type(newRoutes)~="table" or #newRoutes==0 then
        print("WARN applyConfig : routes vides ou invalides")
        return false
    end
    routes=newRoutes

    -- Scan unique du graphe pour toutes les routes
    local trainMap=buildTrainMap()
    routeState={}
    for _,r in ipairs(routes) do
        routeState[r.name]=discoverRoute(r,trainMap)
    end

    -- Boot recovery : repositionner chaque train
    for _,r in ipairs(routes) do
        local rs=routeState[r.name]
        if not rs or not rs.parkStr then goto cont end
        for _,st in pairs(rs.trains) do
            -- Train restauré depuis hold → forcément au PARK
            if st.restoredFromHold then
                local dock=getDock(st)
                local stStr=getCurrentStopStr(st)
                st.lastDock=dock        -- évite nil~=0=true → fausse transition Départ / avoids nil~=0=true → false Depart transition
                st.lastStation=stStr
                st.arrivedAt=rs.parkStr
                setRoute(st,rs,false)
                print(st.name.." boot → hold @ PARK (restauré hold)")
            else
                local dock=getDock(st)
                local stStr=getCurrentStopStr(st)
                st.lastDock=dock
                st.lastStation=stStr
                if dock~=0 then
                    -- getCurrentStop = prochain stop = inverse de la position physique
                    if stStr==rs.delivStr then
                        st.arrivedAt=rs.parkStr
                        print(st.name.." boot @ PARK ("..r.name..")")
                    elseif stStr==rs.parkStr then
                        st.arrivedAt=rs.delivStr
                        print(st.name.." boot @ DELIVERY ("..r.name..")")
                    end
                end
                if st.arrivedAt==rs.parkStr then
                    setRoute(st,rs,false)
                    print(st.name.." boot → hold @ PARK")
                else
                    setSelfDriving(st,true)
                    print(st.name.." boot → selfDriving=true")
                end
            end
        end
        ::cont::
    end

    configOk=true
    exitSafeMode()
    print("Config appliquée : "..#routes.." route(s)")
    return true
end

-- === BUFFER PAR ROUTE ===
local function countBufferItems(rs)
    -- Préférer les données STOCKAGE relayées par LOGGER (source authoritative)
    -- Prefer STOCKAGE data relayed by LOGGER (authoritative source)
    if rs.bufName and _stockageCache[rs.bufName] then
        return _stockageCache[rs.bufName]
    end
    -- Fallback : lecture directe FIN (si STOCKAGE pas encore connecté ou pas en mode rapide)
    -- Fallback: direct FIN read (if STOCKAGE not yet connected or not in fast mode)
    if not rs.bufBox then return 0 end
    local total=0
    pcall(function()
        local invs=rs.bufBox:getInventories()
        for _,inv in ipairs(invs) do
            for i=0,inv.size-1 do
                local ok,s=pcall(function()return inv:getStack(i)end)
                if ok and s and s.count then total=total+s.count end
            end
        end
    end)
    return total
end

local function addBufSample(rs,val)
    table.insert(rs.bufHistory,{t=computer.millis()/1000,v=val})
    if #rs.bufHistory>MAX_BUF_HIST then table.remove(rs.bufHistory,1) end
end

-- Retourne drain(/s), temps avant vide (s), items actuels
local function getBufferStats(rs)
    local cur=countBufferItems(rs)
    if cur==0 then return 0,0,0 end
    if #rs.bufHistory<2 then return 0,math.huge,cur end
    local old,new=rs.bufHistory[1],rs.bufHistory[#rs.bufHistory]
    local dt=new.t-old.t
    if dt<=0 then return 0,math.huge,cur end
    local drain=(old.v-new.v)/dt
    if drain<=0 then return drain,math.huge,cur end
    return drain,cur/drain,cur
end

-- === ETA PAR ROUTE ===
local function addETA(rs,dur)
    table.insert(rs.etaHistory,dur)
    if #rs.etaHistory>ETA_WINDOW then table.remove(rs.etaHistory,1) end
end

local function calcETA(rs)
    if #rs.etaHistory==0 then return DEFAULT_ETA,DEFAULT_ETA*0.5 end
    local sum=0
    for _,v in ipairs(rs.etaHistory) do sum=sum+v end
    local avg=sum/#rs.etaHistory
    local varSum=0
    for _,v in ipairs(rs.etaHistory) do varSum=varSum+(v-avg)^2 end
    return avg,math.sqrt(varSum/#rs.etaHistory)
end

local function countEnRoute(rs)
    local n=0
    for _,st in pairs(rs.trains) do if st.delivering then n=n+1 end end
    return n
end

-- === TRANSITIONS DOCK STATE ===
local function checkTransition(rs, route, st, dock, stStr)
    -- Arrivée : transit → gare
    if st.lastDock==0 and dock~=0 then
        -- lastStation pendant dock=0 = destination en cours = station d'arrivée réelle
        st.arrivedAt=st.lastStation
        if st.arrivedAt==rs.parkStr then
            setRoute(st,rs,false)
            st.lastDecision=nil
            print(st.name.." ARRIVÉE "..route.park.." → hold")
        elseif st.arrivedAt==rs.delivStr and st.departTime then
            local dur=computer.millis()/1000-st.departTime
            addETA(rs,dur)
            local avg,sigma=calcETA(rs)
            print(string.format("%s ARRIVÉE %s | trajet=%.0fs avg=%.0fs s=%.0fs",
                st.name,route.delivery,dur,avg,sigma))
            st.departTime=nil
        end
    end
    -- Départ : gare → transit
    if st.lastDock~=0 and dock==0 then
        if st.arrivedAt==rs.parkStr then
            st.departTime=computer.millis()/1000
            if st.lastDecision=="hold" then
                print("WARN "..st.name.." : gare a forcé départ malgré hold")
            else
                print(st.name.." DÉPART "..route.park.." → "..route.delivery)
            end
            st.delivering=true
        elseif st.arrivedAt==rs.delivStr then
            st.delivering=false
        end
        st.arrivedAt=nil
    end
    st.lastDock=dock
    st.lastStation=stStr
end

-- === DÉCISION DISPATCH ===
local function decide(rs, route, st, dock, stStr)
    -- atPark : docké AU PARK (dock~=0) OU en hold au PARK (timetable vide → dock=0 toujours)
    -- atPark: docked AT PARK (dock~=0) OR held at PARK (empty timetable → dock always 0)
    -- ⚠ RÉGRESSION RÉCURRENTE — voir feedback_dispatch_atpark.md avant toute modification
    local atPark  = st.arrivedAt==rs.parkStr and (dock~=0 or not st.delivering)
    local isStuck = dock==0 and st.delivering and st.lastDecision=="hold"
    if not atPark and not isStuck then return end

    local maxEnRoute = route.maxEnRoute or 1
    local drain,_,curItems = getBufferStats(rs)
    local avgETA,sigma = calcETA(rs)
    local marge = math.max(MIN_MARGE_SEC, sigma*SIGMA_FACTOR)
    local enRoute = countEnRoute(rs)-(isStuck and 1 or 0)
    local wagonItems = rs.trainCap>0 and getWagonItems(st) or 0
    local now = computer.millis()/1000

    -- URGENCE : buffer critique → GO immédiat / EMERGENCY: critical buffer → immediate GO
    local emergency = curItems<=MIN_BUF_DISPATCH

    -- TIMING : le buffer s'épuise avant l'arrivée du train / TIMING: buffer runs out before train arrives
    -- Seul drain>0 est temporellement urgent (drain≤0 = buffer stable ou croissant)
    -- Only drain>0 is time-critical (drain≤0 = buffer stable or growing)
    local tbv = drain>0 and curItems/drain or math.huge
    local timingUrgent = drain>0 and tbv<=(avgETA+marge)

    -- CHARGE : le train apporte assez pour couvrir la consommation pendant le voyage
    -- LOAD: train brings enough to cover buffer consumption during the trip
    -- Référence : drain×(ETA+marge) — indépendant de trainCap et bufCap (tous deux gonflés par design)
    -- Reference: drain×(ETA+marge) — independent of trainCap and bufCap (both inflated by design)
    local loadThreshold = drain*(avgETA+marge)
    local loadOk = drain<=0 or wagonItems>=loadThreshold

    -- TIMEOUT : timing urgent depuis trop longtemps sans charge suffisante (production lente)
    -- TIMEOUT: timing urgent too long without sufficient load (slow production)
    -- Basé sur timingUrgentSince (pas parkSince — évite timeout immédiat après longue attente drain<0)
    -- Based on timingUrgentSince (not parkSince — avoids immediate timeout after long drain<0 wait)
    if timingUrgent and not loadOk then
        if not st.timingUrgentSince then st.timingUrgentSince=now end
    else
        st.timingUrgentSince=nil
    end
    local timeout = timingUrgent and st.timingUrgentSince
        and (now-st.timingUrgentSince)>=(TIMEOUT_ETA_FACTOR*(avgETA+marge))

    local shouldGo = (emergency or timeout or (timingUrgent and loadOk)) and enRoute<maxEnRoute
    local decision = shouldGo and "go" or "hold"

    if now-rs.lastStatusLog>=LOG_STATUS_SEC then
        rs.lastStatusLog=now
        local dockStr = isStuck and "stuck" or (dock==1 and "charge" or "attente")
        local tbvStr  = tbv==math.huge and "inf" or string.format("%.0fs",tbv)
        local seuil   = string.format("%.0f",loadThreshold)
        local why
        if emergency       then why="URGENCE buf<"..MIN_BUF_DISPATCH
        elseif timeout     then why="TIMEOUT "..string.format("%.0fs",now-st.timingUrgentSince)
        elseif not timingUrgent then why="tbv="..tbvStr..">"..(avgETA+marge).."s"
        elseif loadOk      then why="timing+charge ok"
        else                    why="wagon="..wagonItems.."<seuil="..seuil
        end
        print(string.format(
            "[%s/%s] buf=%d(min%d) drain=%.2f tbv=%s seuil=%s wagon=%d ETA=%.0f+-%.0f en=%d/%d -> %s (%s)",
            route.name,dockStr,curItems,MIN_BUF_DISPATCH,drain,tbvStr,seuil,wagonItems,
            avgETA,sigma,enRoute,maxEnRoute,shouldGo and "GO" or "HOLD",why
        ))
    end

    if decision~=st.lastDecision then
        st.lastDecision=decision
        if shouldGo then
            setRoute(st,rs,true)
            local why=emergency and "URGENCE" or (timeout and "TIMEOUT" or "timing+charge")
            print(string.format("%s GO [%s->%s] buf=%d wagon=%d seuil=%.0f (%s)",
                st.name,route.park,route.delivery,curItems,wagonItems,loadThreshold,why))
        else
            local reason
            if enRoute>=maxEnRoute then
                reason=string.format("quota %d/%d",enRoute,maxEnRoute)
            elseif not timingUrgent then
                reason=string.format("tbv=%s > ETA+m=%.0fs",tbv==math.huge and "inf" or string.format("%.0f",tbv).."s",avgETA+marge)
            else
                reason=string.format("wagon=%d < seuil=%.0f",wagonItems,loadThreshold)
            end
            print(st.name.." HOLD ("..reason..")")
        end
    end
end

-- === COMMANDES WEB ===
local function handleCommand(cmdStr)
    local ok,cmd=pcall(function()return (load("return "..cmdStr))()end)
    if not ok or type(cmd)~="table" then
        print("WARN CMD parse: "..tostring(cmdStr)) ; return
    end
    local c=cmd.cmd or ""
    print("CMD: "..c.." train="..(cmd.train or "?").." route="..(cmd.route or "?"))

    local targetSt,targetRs=nil,nil
    for _,r in ipairs(routes) do
        local rs=routeState[r.name]
        if rs then
            for _,st in pairs(rs.trains) do
                if st.name==cmd.train or cmd.train==nil then
                    targetSt=st ; targetRs=rs ; break
                end
            end
        end
        if targetSt then break end
    end

    if c=="force_go" and targetSt then
        setRoute(targetSt,targetRs,true)
        targetSt.lastDecision="go" ; targetSt.delivering=true
        print("CMD force_go OK: "..targetSt.name)
    elseif c=="force_hold" and targetSt then
        setRoute(targetSt,targetRs,false)
        targetSt.lastDecision="hold"
        print("CMD force_hold OK: "..targetSt.name)
    elseif c=="recovery" and targetSt then
        setRoute(targetSt,targetRs,false)
        targetSt.lastDecision=nil ; targetSt.delivering=false ; targetSt.arrivedAt=nil
        setSelfDriving(targetSt,true)
        print("CMD recovery OK: "..targetSt.name)
    elseif c=="reload" then
        pcall(function()net:broadcast(69,"DISPATCH_HELLO")end)
        print("CMD reload : DISPATCH_HELLO envoyé")
    else
        print("CMD inconnue: "..c)
    end
end

-- === BROADCAST STATUS → LOGGER ===
local function broadcastStatus()
    local routesSummary={}
    for _,r in ipairs(routes) do
        local rs=routeState[r.name]
        if not rs then goto cont end
        local trainsList={}
        for _,st in pairs(rs.trains) do
            local dock=getDock(st)
            local phase
            if dock~=0 then
                phase=st.arrivedAt==rs.parkStr  and "PARK"     or
                      st.arrivedAt==rs.delivStr and "DELIVERY" or "GARE"
            else
                if st.arrivedAt==rs.parkStr and not st.delivering then
                    phase="PARK"   -- hold : timetable vide → dock=0 / hold: empty timetable → dock=0
                else
                    phase=st.delivering and "EN_ROUTE" or "TRANSIT"
                end
            end
            table.insert(trainsList,{
                name=st.name, phase=phase,
                decision=st.lastDecision or "nil",
                delivering=st.delivering,
            })
        end
        local drain,tbv,curItems=getBufferStats(rs)
        local avgETA,sigma=calcETA(rs)
        table.insert(routesSummary,{
            name=r.name, trains=trainsList,
            buffer={items=curItems,drain=drain,tbv=tbv==math.huge and -1 or tbv},
            eta={avg=avgETA,sigma=sigma,n=#rs.etaHistory},
            enRoute=countEnRoute(rs), maxEnRoute=r.maxEnRoute or 1,
        })
        ::cont::
    end
    pcall(function()net:broadcast(69,ser({
        v=VERSION, configOk=configOk, safeMode=safeMode,
        routes=routesSummary,
        ts=math.floor(computer.millis()/1000),
    }))end)
end

-- === BOUCLE PRINCIPALE ===
pcall(function()net:broadcast(69,"DISPATCH_HELLO")end)
print("DISPATCH_HELLO envoyé — en attente config LOGGER")

local nextTick         = computer.millis()+2000
local lastBufSampleAll = 0

while true do
    local remaining=math.max(0.05,(nextTick-computer.millis())/1000)
    local e,_,sender,port,arg1=event.pull(remaining)

    if e=="NetworkMessage" and port==44 then
        local ok,snap=pcall(function()return (load("return "..arg1))()end)
        if ok and type(snap)=="table" then
            for name,data in pairs(snap) do
                _trainSnapshot[name]={
                    dockState=data.dockState or 0,
                    station  =data.station   or "",
                }
            end
        end

    elseif e=="NetworkMessage" and port==53 then
        if configOk and arg1==_lastConfigPayload then goto continue_loop end
        local ok,parsed=pcall(function()return (load("return "..arg1))()end)
        if ok and type(parsed)=="table" then
            print("Config reçue ("..#parsed.." route(s))")
            if configOk then
                local newNames={}
                for _,r in ipairs(parsed) do newNames[r.name]=true end
                for rname,rs in pairs(routeState) do
                    if not newNames[rname] then
                        print("Route '"..rname.."' supprimée")
                        releaseRoute(rs,rname)
                    end
                end
            end
            _lastConfigPayload=arg1
            applyConfig(parsed)
            broadcastPriorityBuffers()
        else
            print("WARN port 53 : parse config échoué")
        end
        ::continue_loop::

    elseif e=="NetworkMessage" and port==55 then
        if arg1=="PRIORITY_REQUEST" and configOk then
            broadcastPriorityBuffers()
        end

    elseif e=="NetworkMessage" and port==69 then
        if arg1=="LOGGER_READY" then
            pcall(function()net:broadcast(69,"DISPATCH_HELLO")end)
            print("LOGGER_READY → DISPATCH_HELLO renvoyé")
        elseif arg1 and arg1:sub(1,4)=="BUF:" then
            -- Données buffer relayées par LOGGER depuis STOCKAGE / Buffer data relayed by LOGGER from STOCKAGE
            local rest=arg1:sub(5)
            local sep=rest:find(":")
            if sep then
                local zone=rest:sub(1,sep-1)
                local count=tonumber(rest:sub(sep+1)) or 0
                _stockageCache[zone]=count
                -- Compatibilité : si clé = "(PARENT) szname", stocker aussi "szname" seul (anciens configs)
                -- Backward compat: if key = "(PARENT) szname", also store bare "szname" (old configs)
                local shortZone=zone:match("^%b() (.+)$")
                if shortZone then _stockageCache[shortZone]=count end
            end
        elseif arg1 and arg1:sub(1,4)=="CMD:" then
            handleCommand(arg1:sub(5))
        end
    end

    if computer.millis()>=nextTick then
        nextTick=nextTick+2000
        local now=computer.millis()/1000

        if not configOk then
            if now-lastSafeRetry>=SAFE_RETRY_SEC then
                lastSafeRetry=now
                enterSafeMode()
                pcall(function()net:broadcast(69,"DISPATCH_HELLO")end)
                print("Retry DISPATCH_HELLO...")
            end
        else
            if now-lastBufSampleAll>=BUF_SAMPLE_SEC then
                lastBufSampleAll=now
                for _,r in ipairs(routes) do
                    local rs=routeState[r.name]
                    if rs then addBufSample(rs,countBufferItems(rs)) end
                end
            end
            for _,r in ipairs(routes) do
                local rs=routeState[r.name]
                if not rs or not rs.parkStr then goto cont end
                for _,st in pairs(rs.trains) do
                    local dock=getDock(st)
                    local stStr=getCurrentStopStr(st)
                    checkTransition(rs,r,st,dock,stStr)
                    decide(rs,r,st,dock,stStr)
                end
                ::cont::
            end
        end

        if now-lastStatusBcast>=STATUS_BCAST_SEC then
            lastStatusBcast=now
            pcall(broadcastStatus)
        end
        if configOk and now-lastPriorityBcast>=PRIORITY_BCAST_SEC then
            broadcastPriorityBuffers()
        end
    end
end
