-- WRITE_DISK.lua : exemple court pour écrire un fichier avec Ficsit Networks (FIN)
-- 1) Adapte DISK_UUID à ton disque
-- 2) Lance le script sur l'ordinateur FIN

local fs = filesystem
local DISK_UUID = "REMPLACE_PAR_UUID_DU_DISQUE"
local PATH = "/note.txt"

fs.initFileSystem("/dev")
fs.mount("/dev/" .. DISK_UUID, "/")

local f = fs.open(PATH, "w") -- "w" = écrase ; utiliser "a" pour append
if not f then
    print("Erreur: impossible d'ouvrir " .. PATH)
    return
end

f:write("Bonjour depuis Ficsit Networks!\n")
f:write("Timestamp: " .. tostring(computer.millis()) .. " ms\n")
f:close()

print("OK: fichier écrit -> " .. PATH)