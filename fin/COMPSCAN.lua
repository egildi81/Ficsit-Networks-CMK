-- COMPSCAN.lua : scanner tous les composants connectés au réseau FIN
-- Affiche type, nick, position et toutes les propriétés via reflection
-- Usage : coller dans n'importe quel Computer FIN du réseau, lancer une fois

local VERSION = "1.0.0"

-- === CONFIGURATION ===
local MAX_PROPS    = 30     -- props max affichées par objet (évite flood)
local SHOW_FUNCS   = false  -- true = affiche aussi les noms de fonctions
local FILTER_NICK  = nil    -- nil = tout | ex: "TRAIN_MAP" = seulement cet objet
local FILTER_CLASS = nil    -- nil = tout | ex: classes.Build_GPU_T2_C

-- === HELPERS ===
local function safeGet(fn)
    local ok, v = pcall(fn)
    return ok and v or nil
end

local function valStr(v)
    if v == nil then return "nil" end
    local t = type(v)
    if t == "boolean" or t == "number" then return tostring(v) end
    if t == "string"  then return '"'..v..'"' end
    -- struct (Vector, Rotator…) : tenter x/y/z
    if t == "table" or t == "userdata" then
        local x = safeGet(function() return v.x end)
        if x ~= nil then
            local y = safeGet(function() return v.y end) or 0
            local z = safeGet(function() return v.z end) or 0
            return string.format("(%.1f, %.1f, %.1f)", x, y, z)
        end
        return tostring(v)
    end
    return tostring(v)
end

-- === SCAN ===
print("=== COMPSCAN v"..VERSION.." ===")

local ids = {}
if FILTER_CLASS then
    pcall(function() ids = component.findComponent(FILTER_CLASS) end)
elseif FILTER_NICK then
    pcall(function() ids = component.findComponent(FILTER_NICK) end)
else
    pcall(function() ids = component.findComponent("") end)
end

if not ids or #ids == 0 then
    print("Aucun composant trouvé.")
    print("→ Vérifie que les composants sont connectés au réseau FIN (câbles réseau)")
    print("→ Ou change FILTER_CLASS avec une classe connue (ex: classes.Build_GPU_T2_C)")
    return
end

print("Composants trouvés : "..#ids.."\n")

for idx, uuid in ipairs(ids) do
    local obj = safeGet(function() return component.proxy(uuid) end)
    if not obj then
        print("["..idx.."] UUID="..tostring(uuid).." → proxy échoué\n")
    else
        -- Infos de base (Object + Actor)
        local typeName = safeGet(function() return obj.internalName end) or "?"
        local nick     = safeGet(function() return obj.nick end)         or ""
        local hash     = safeGet(function() return obj.hash end)         or "?"
        local loc      = safeGet(function() return obj.location end)
        local locStr   = loc and string.format(" @ (%.0f, %.0f, %.0f)", loc.x, loc.y, loc.z) or ""

        print(string.format("[%d] %s  nick='%s'  hash=%s%s",
            idx, typeName, nick, tostring(hash), locStr))

        -- Reflection : toutes les propriétés du type
        local classObj = safeGet(function() return obj:getType() end)
        if classObj then
            local props = safeGet(function() return classObj:getAllProperties() end) or {}
            if #props == 0 then
                print("  (aucune propriété via reflection)")
            else
                local shown = 0
                for _, prop in ipairs(props) do
                    if shown >= MAX_PROPS then
                        print(string.format("  ... (+%d props non affichées)", #props - shown))
                        break
                    end
                    local pname = safeGet(function() return prop.internalName end) or "?"
                    local dtype = safeGet(function() return prop.dataType end)     -- 0=nil 1=bool 2=int 3=float 4=str 5=obj 6=class 7=trace 8=struct 9=array 10=any
                    local val   = safeGet(function() return obj[pname] end)
                    print(string.format("  .%-28s [%s] = %s",
                        pname,
                        dtype ~= nil and tostring(dtype) or "?",
                        valStr(val)))
                    shown = shown + 1
                end
            end

            -- Fonctions (optionnel)
            if SHOW_FUNCS then
                local funcs = safeGet(function() return classObj:getAllFunctions() end) or {}
                if #funcs > 0 then
                    local names = {}
                    for _, fn in ipairs(funcs) do
                        local fname = safeGet(function() return fn.internalName end) or "?"
                        table.insert(names, fname)
                    end
                    print("  Fonctions : "..table.concat(names, ", "))
                end
            end
        else
            -- Fallback si getType() échoue : props connues universelles
            print("  (reflection indisponible — props Object/Actor seulement)")
            local isNet  = safeGet(function() return obj.isNetworkComponent end)
            local rot    = safeGet(function() return obj.rotation end)
            if isNet  ~= nil then print("  .isNetworkComponent = "..tostring(isNet)) end
            if rot ~= nil then
                print(string.format("  .rotation = (%.1f, %.1f, %.1f)", rot.pitch or 0, rot.yaw or 0, rot.roll or 0))
            end
        end

        print("")  -- ligne vide entre chaque objet
    end
end

print("=== FIN SCAN ("..#ids.." composants) ===")
