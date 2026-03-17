-- STOCKAGE_CENTRAL_EEPROM.lua : bootstrap minimal → charge STOCKAGE_CENTRAL.lua depuis l'API web
-- Copier CE fichier dans l'EEPROM du computer STOCKAGE_CENTRAL
-- Ajouter NetworkCard + InternetCard dans le computer STOCKAGE_CENTRAL
-- Copy THIS file into the STOCKAGE_CENTRAL computer EEPROM
-- Add NetworkCard + InternetCard to the STOCKAGE_CENTRAL computer

local VERSION_BOOT = "1.0.0"
print("=== STOCKAGE CENTRAL EEPROM v"..VERSION_BOOT.." ===")

local WEB_URL = "http://127.0.0.1:8081"

local inet = computer.getPCIDevices(classes.FINInternetCard)[1]
if not inet then error("CENTRAL EEPROM: pas d'InternetCard") end

print("Chargement STOCKAGE_CENTRAL.lua depuis API web...")
local f = inet:request(WEB_URL.."/api/fin/STOCKAGE_CENTRAL.lua", "GET", "")
local ok, code, body = pcall(function() return f:await() end)
if not ok or code ~= 200 or not body or body == "" then
    error("CENTRAL EEPROM: chargement échoué (HTTP "..tostring(code)..")")
end

local fn, err = load(body)
if not fn then error("CENTRAL EEPROM: parse — "..tostring(err)) end
print("OK ("..#body.." bytes) → lancement")
fn()
