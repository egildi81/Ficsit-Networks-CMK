-- FIN_CLIENT.lua : client API multi-joueurs Satisfactory
-- Envoie les données de ta partie, peut lire celles des autres joueurs
-- Requiert : InternetCard (obligatoire)
-- Optionnel : NetworkCard pour répondre aux requêtes in-game (port 45)
--             GARE_TEST pour données trains
--             Bâtiment nommé "POWER_POLE" pour données électriques
--
-- Multi-thread :
--   Thread 1 — submit   : envoie tes données à l'API toutes les INTERVAL secondes
--   Thread 2 — listen   : répond aux requêtes in-game sur le port 45 (NetworkCard)
--
-- Ficsit Networks : coller ce script dans l'EEPROM de ton PC dédié

-- ════════════════════════════════════════════════
-- CONFIGURATION (à modifier)
-- ════════════════════════════════════════════════
local API_URL  = "http://TON_SERVEUR_IP:8082"  -- adresse IP du serveur
local API_KEY  = "TA_CLE_ICI"                   -- clé fournie par l'hôte
local PLAYER   = "TonNom"                        -- ton nom (doit correspondre à la clé)
local WORLD    = "TonMonde"                      -- nom de ta partie
local INTERVAL = 30                              -- secondes entre chaque envoi API

-- ════════════════════════════════════════════════
-- INITIALISATION MATÉRIEL
-- ════════════════════════════════════════════════
local inet = computer.getPCIDevices(classes.InternetCard)[1]
if not inet then error("InternetCard non trouvée - installe une carte réseau Internet") end

-- NetworkCard pour requêtes in-game (optionnel)
local net = computer.getPCIDevices(classes.NetworkCard)[1]
if net then
    event.listen(net)
    net:open(45)  -- port de réponse aux requêtes in-game
    print("[FIN_CLIENT] NetworkCard détectée — réponses in-game actives (port 45)")
else
    print("[FIN_CLIENT] Pas de NetworkCard — mode envoi seul")
end

-- Station train (optionnel)
local sta = nil
pcall(function()
    local sl = component.findComponent("GARE_TEST")
    if sl and sl[1] then sta = component.proxy(sl[1]) end
end)

-- ════════════════════════════════════════════════
-- COLLECTE DONNÉES TRAINS
-- ════════════════════════════════════════════════
local function getTrains()
    if not sta then return nil end
    local ok, trains = pcall(function() return sta:getTrackGraph():getTrains() end)
    if not ok or not trains then return nil end
    local total, moving, stopped, docked = 0, 0, 0, 0
    for _, t in pairs(trains) do
        total = total + 1
        local ok2, m = pcall(function() return t:getMaster() end)
        if ok2 and m then
            if m.isDocked then
                docked = docked + 1
            else
                local spd = 0
                pcall(function() spd = math.abs(math.floor(m:getMovement().speed/100*3.6)) end)
                if spd > 10 then moving = moving + 1 else stopped = stopped + 1 end
            end
        end
    end
    return {total=total, moving=moving, stopped=stopped, docked=docked}
end

-- ════════════════════════════════════════════════
-- COLLECTE DONNÉES ÉLECTRIQUES
-- ════════════════════════════════════════════════
local function getPower()
    local gen = nil
    pcall(function()
        local l = component.findComponent("POWER_POLE")
        if l and l[1] then gen = component.proxy(l[1]) end
    end)
    if not gen then return nil end
    local ok, circuit = pcall(function()
        return gen:getPowerConnectors()[1]:getCircuit()
    end)
    if not ok or not circuit then return nil end
    return {
        produced_mw = circuit.production,
        consumed_mw = circuit.consumption,
        fuse_blown  = circuit.isFuseTriggered,
    }
end

-- ════════════════════════════════════════════════
-- COLLECTE DONNÉES PRODUCTION
-- ════════════════════════════════════════════════
local function getProduction()
    local prod = {}
    -- Décommenter et adapter selon tes bâtiments :
    -- pcall(function()
    --     local l = component.findComponent("MON_USINE")
    --     if not l or not l[1] then return end
    --     local b = component.proxy(l[1])
    --     local recipe = b:getRecipe()
    --     if recipe then
    --         for _, out in pairs(recipe:getProducts()) do
    --             prod[out.type.name] = {
    --                 produced = out.amount * (b.productivity / 100) * 60,
    --                 consumed = 0
    --             }
    --         end
    --     end
    -- end)
    return prod
end

-- ════════════════════════════════════════════════
-- SNAPSHOT LOCAL (utilisé par les deux threads)
-- ════════════════════════════════════════════════
local function buildSnapshot()
    return {
        player     = PLAYER,
        world      = WORLD,
        trains     = getTrains(),
        power      = getPower(),
        production = getProduction(),
    }
end

-- ════════════════════════════════════════════════
-- SÉRIALISEUR JSON
-- ════════════════════════════════════════════════
local function toJson(v)
    local t = type(v)
    if t == "string"  then return '"'..v:gsub('\\','\\\\'):gsub('"','\\"')..'"'
    elseif t == "number"  then return tostring(v)
    elseif t == "boolean" then return tostring(v)
    elseif t == "nil"     then return "null"
    elseif t == "table"   then
        local n = 0 for _ in pairs(v) do n = n+1 end
        if n > 0 and n == #v then
            local p = {} for _, val in ipairs(v) do table.insert(p, toJson(val)) end
            return "["..table.concat(p,",").."]"
        else
            local p = {} for k, val in pairs(v) do
                table.insert(p, '"'..tostring(k)..'":'..toJson(val))
            end
            return "{"..table.concat(p,",").."}"
        end
    end
    return "null"
end

-- ════════════════════════════════════════════════
-- THREAD MANAGER
-- ════════════════════════════════════════════════
local threads = {}

local function spawn(fn)
    table.insert(threads, coroutine.create(fn))
end

local function runAll()
    while true do
        for i = #threads, 1, -1 do
            if coroutine.status(threads[i]) ~= "dead" then
                local ok, err = coroutine.resume(threads[i])
                if not ok then
                    print("Thread error: "..tostring(err))
                    table.remove(threads, i)
                end
            else
                table.remove(threads, i)
            end
        end
        event.pull(0)
    end
end

-- ════════════════════════════════════════════════
-- THREAD 1 : SUBMIT — envoie les données à l'API
-- ════════════════════════════════════════════════
spawn(function()
    local lastSubmit = -(INTERVAL * 1000)  -- force un envoi immédiat au démarrage
    local ticks = 0
    while true do
        local now = computer.millis()
        if now - lastSubmit >= INTERVAL * 1000 then
            local snap = buildSnapshot()
            local body = toJson(snap)
            local headers = {["Content-Type"]="application/json", ["X-API-Key"]=API_KEY}
            local ok, req = pcall(function()
                return inet:request(API_URL.."/api/v1/submit", "POST", body, headers)
            end)
            if ok and req then
                local ok2, code = pcall(function() return req:await() end)
                if ok2 then
                    if code == 200 then print("[SUBMIT] OK")
                    else print("[SUBMIT] HTTP "..tostring(code)) end
                end
            else
                print("[SUBMIT] Erreur connexion")
            end
            lastSubmit = now
            ticks = ticks + 1
            -- Toutes les 10 soumissions (~5 min) : affiche les joueurs actifs
            if ticks % 10 == 0 then
                local ok3, req2 = pcall(function()
                    return inet:request(API_URL.."/api/v1/players", "GET", "", {})
                end)
                if ok3 and req2 then
                    local ok4, code2, resp = pcall(function() return req2:await() end)
                    if ok4 and code2 == 200 then print("[PLAYERS] "..resp) end
                end
            end
        end
        coroutine.yield()
    end
end)

-- ════════════════════════════════════════════════
-- THREAD 2 : LISTEN — répond aux requêtes in-game (port 45)
-- Autre PC FIN envoie "QUERY" sur port 45 → on répond avec notre snapshot
-- ════════════════════════════════════════════════
spawn(function()
    if not net then
        -- Pas de NetworkCard : thread inactif mais on le garde pour la structure
        while true do coroutine.yield() end
    end
    while true do
        local e, _, _, port, cmd = event.pull(0)
        if e == "NetworkMessage" and port == 45 and cmd == "QUERY" then
            local snap = buildSnapshot()
            local resp = toJson(snap)
            pcall(function() net:broadcast(45, "DATA", PLAYER, resp) end)
            print("[LISTEN] Répondu à une requête in-game de "..PLAYER)
        end
        coroutine.yield()
    end
end)

-- ════════════════════════════════════════════════
-- DÉMARRAGE
-- ════════════════════════════════════════════════
print("[FIN_CLIENT] "..PLAYER.." — envoi toutes les "..INTERVAL.."s vers "..API_URL)
runAll()
