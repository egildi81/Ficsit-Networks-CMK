-- DISPATCH_EEPROM.lua : bootstrap minimal → charge DISPATCH.lua depuis l'API web
-- Copier CE fichier dans l'EEPROM du computer DISPATCH
-- Ajouter une InternetCard dans le computer DISPATCH
-- Copy THIS file into the DISPATCH computer EEPROM
-- Add an InternetCard to the DISPATCH computer

local VERSION_BOOT = "2.0.0"
print("=== DISPATCH EEPROM v"..VERSION_BOOT.." ===")

local WEB_URL = "http://127.0.0.1:8081"

local inet = computer.getPCIDevices(classes.FINInternetCard)[1]
if not inet then error("DISPATCH EEPROM: pas d'InternetCard") end

print("Chargement DISPATCH.lua depuis API web...")
local f = inet:request(WEB_URL.."/api/fin/DISPATCH.lua", "GET", "")
local ok, code, body = pcall(function() return f:await() end)
if not ok or code ~= 200 or not body or body == "" then
    error("DISPATCH EEPROM: chargement échoué (HTTP "..tostring(code)..")")
end

local fn, err = load(body)
if not fn then error("DISPATCH EEPROM: parse — "..tostring(err)) end
print("OK ("..#body.." bytes) → lancement")
fn()
