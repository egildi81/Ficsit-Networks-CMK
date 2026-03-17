-- LOGGER_EEPROM.lua : bootstrap minimal → charge LOGGER.lua depuis l'API web
-- Copier CE fichier dans l'EEPROM du computer LOGGER
-- Ajouter une InternetCard dans le computer LOGGER (en plus des 4 dédiées aux endpoints)
-- Copy THIS file into the LOGGER computer EEPROM
-- Add an InternetCard to the LOGGER computer (in addition to the 4 dedicated endpoint cards)

local VERSION_BOOT = "1.0.0"
print("=== LOGGER EEPROM v"..VERSION_BOOT.." ===")

local WEB_URL = "http://127.0.0.1:8081"

local inet = computer.getPCIDevices(classes.FINInternetCard)[1]
if not inet then error("LOGGER EEPROM: pas d'InternetCard") end

print("Chargement LOGGER.lua depuis API web...")
local f = inet:request(WEB_URL.."/api/fin/LOGGER.lua", "GET", "")
local ok, code, body = pcall(function() return f:await() end)
if not ok or code ~= 200 or not body or body == "" then
    error("LOGGER EEPROM: chargement échoué (HTTP "..tostring(code)..")")
end

local fn, err = load(body)
if not fn then error("LOGGER EEPROM: parse — "..tostring(err)) end
print("OK ("..#body.." bytes) → lancement")
fn()
