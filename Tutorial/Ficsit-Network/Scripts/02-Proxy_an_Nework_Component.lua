-- TEST_POWERPOLE.lua : test minimal de connexion à un composant réseau nommé "PowerPole"
-- Place un composant (ex: power pole) avec le nickname exact "PowerPole" puis lance ce script.

local pole = component.proxy(component.findComponent("PowerPole"))

if pole then
    print("OK: composant 'PowerPole' trouvé")
    print("Type: " .. tostring(pole.type))
else
    print("ERREUR: composant 'PowerPole' introuvable")
    print("Vérifie le nickname exact dans le jeu")
end
