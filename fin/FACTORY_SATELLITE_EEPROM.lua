-- FACTORY_SATELLITE_EEPROM.lua : bootstrap minimal → charge FACTORY_SATELLITE.lua depuis l'API web
-- Copier CE fichier dans l'EEPROM de chaque computer FACTORY_SATELLITE
-- Ajouter NetworkCard + InternetCard dans le computer (InternetCard sert au boot uniquement)
-- Copy THIS file into each FACTORY_SATELLITE computer EEPROM
-- Add NetworkCard + InternetCard (InternetCard used at boot only)

local VERSION_BOOT = "1.0.0"
print("=== FACTORY SATELLITE EEPROM v"..VERSION_BOOT.." ===")

local WEB_URL = "http://127.0.0.1:8081"

local inet = computer.getPCIDevices(classes.FINInternetCard)[1]
if not inet then error("FACTORY SATELLITE EEPROM: pas d'InternetCard") end

print("Chargement FACTORY_SATELLITE.lua depuis API web...")
local f = inet:request(WEB_URL.."/api/fin/FACTORY_SATELLITE.lua", "GET", "")
local ok, code, body = pcall(function() return f:await() end)
if not ok or code ~= 200 or not body or body == "" then
    error("FACTORY SATELLITE EEPROM: chargement échoué (HTTP "..tostring(code)..")")
end

local fn, err = load(body)
if not fn then error("FACTORY SATELLITE EEPROM: parse — "..tostring(err)) end
print("OK ("..#body.." bytes) → lancement")
fn()
