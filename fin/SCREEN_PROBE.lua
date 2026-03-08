-- SCREEN_PROBE.lua : utilitaire — affiche la résolution d'un écran dans GET_LOG
-- Remplacer l'UUID par celui de l'écran à mesurer (copié depuis le jeu)
-- Résultat visible sur GET_LOG (port 43)

local gpu=computer.getPCIDevices(classes.Build_GPU_T2_C)[1]
local screen=component.proxy("428237B14AEA23BAD5AD1AB93709146F")  -- ← UUID à changer

gpu:bindScreen(screen)
gpu:drawRect({x=0,y=0},{x=100,y=100},{r=1,g=0,b=0,a=1},{r=1,g=0,b=0,a=1},0)
gpu:flush()

local size=gpu:getScreenSize()

local net=computer.getPCIDevices(classes.NetworkCard)[1]
if net then
    net:broadcast(43,"PROBE","ScreenSize: "..size.x.."x"..size.y)
end
print(size.x, size.y)
