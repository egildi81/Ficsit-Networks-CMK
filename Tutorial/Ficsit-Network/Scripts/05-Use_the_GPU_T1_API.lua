
-- HELLOWORLD_GPU_T1_MIN.lua
-- Minimal: affiche "Hello world" sur l'écran interne avec GPU T1

local gpu = computer.getPCIDevices(classes.Build_GPU_T1_C)[1]
local screen = computer.getPCIDevices(classes.FINComputerScreen)[1]

if not gpu or not screen then
    error("GPU T1 ou screen interne introuvable")
end

gpu:bindScreen(screen)
gpu:setBackground(0, 0, 0, 1)
gpu:setForeground(1, 1, 1, 1)

local s = gpu:getScreenSize()
gpu:fill(0, 0, s.x, s.y, " ", " ")
gpu:setText(2, 2, "Hello world")
gpu:flush()
