-- GETLOG_EEPROM.lua : bootstrap minimal → charge GET_LOG.lua depuis l'API web
-- Copier CE fichier dans l'EEPROM du computer GET_LOG
-- Ajouter une InternetCard dans le computer GET_LOG
-- Copy THIS file into the GET_LOG computer EEPROM
-- Add an InternetCard to the GET_LOG computer

local VERSION_BOOT = "1.0.1"
print("=== GETLOG EEPROM v"..VERSION_BOOT.." ===")

local WEB_URL = "http://127.0.0.1:8081"

local inet = computer.getPCIDevices(classes.FINInternetCard)[1]
if not inet then error("GETLOG EEPROM: pas d'InternetCard") end

print("Chargement GET_LOG.lua depuis API web...")
local f = inet:request(WEB_URL.."/api/fin/GET_LOG.lua", "GET", "")
local ok, code, body = pcall(function() return f:await() end)
if not ok or code ~= 200 or not body or body == "" then
    error("GETLOG EEPROM: chargement échoué (HTTP "..tostring(code)..")")
end

local fn, err = load(body)
if not fn then error("GETLOG EEPROM: parse — "..tostring(err)) end
print("OK ("..#body.." bytes) → lancement")
fn()
