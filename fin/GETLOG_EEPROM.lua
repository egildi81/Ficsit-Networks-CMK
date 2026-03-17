-- GETLOG_EEPROM.lua : bootstrap GET_LOG.lua depuis le serveur web
-- Charge et exécute GET_LOG.lua depuis http://127.0.0.1:8081/api/fin/GET_LOG.lua
local VERSION_BOOT = "1.0.0"
print("=== GETLOG EEPROM v"..VERSION_BOOT.." ===")

local WEB_URL = "http://127.0.0.1:8081"

local inet = computer.getPCIDevices(classes.FINInternetCard)[1]
if not inet then error("GETLOG EEPROM: pas d'InternetCard") end

local f = inet:request(WEB_URL.."/api/fin/GET_LOG.lua", "GET", "")
local ok, code, body = pcall(function() return f:await() end)
if not ok or type(body)~="string" or body=="" then
    error("GETLOG EEPROM: fetch échoué (code="..tostring(code)..")")
end

local fn, err = load(body)
if not fn then error("GETLOG EEPROM: load() échoué — "..tostring(err)) end
fn()
