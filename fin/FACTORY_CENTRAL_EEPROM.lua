-- FACTORY_CENTRAL_EEPROM.lua : bootstrap minimal → charge FACTORY_CENTRAL.lua depuis l'API web
-- Copier CE fichier dans l'EEPROM du computer FACTORY_CENTRAL
-- Ajouter NetworkCard + InternetCard dans le computer FACTORY_CENTRAL
-- Copy THIS file into the FACTORY_CENTRAL computer EEPROM
-- Add NetworkCard + InternetCard to the FACTORY_CENTRAL computer

local VERSION_BOOT = "1.0.0"
print("=== FACTORY CENTRAL EEPROM v"..VERSION_BOOT.." ===")

local WEB_URL = "http://127.0.0.1:8081"

local inet = computer.getPCIDevices(classes.FINInternetCard)[1]
if not inet then error("FACTORY CENTRAL EEPROM: pas d'InternetCard") end

print("Chargement FACTORY_CENTRAL.lua depuis API web...")
local f = inet:request(WEB_URL.."/api/fin/FACTORY_CENTRAL.lua", "GET", "")
local ok, code, body = pcall(function() return f:await() end)
if not ok or code ~= 200 or not body or body == "" then
    error("FACTORY CENTRAL EEPROM: chargement échoué (HTTP "..tostring(code)..")")
end

local fn, err = load(body)
if not fn then error("FACTORY CENTRAL EEPROM: parse — "..tostring(err)) end
print("OK ("..#body.." bytes) → lancement")
fn()
