local panel1 = component.proxy(component.findComponent("PANEL_L")[1])

local swL = panel1:getModule(2, 6, 0)
local swR = panel1:getModule(8, 6, 0)

local displays = {
    panel1:getModule(0, 0, 0),   -- zone gauche
    panel1:getModule(2, 0, 0),   -- zone gauche
    panel1:getModule(4, 0, 0),   -- zone gauche
    panel1:getModule(6, 0, 0),   -- zone droite
    panel1:getModule(8, 0, 0),   -- zone droite
    panel1:getModule(10, 0, 0),  -- zone droite
}
local gauges = {
    panel1:getModule(0, 1, 0),   -- G
    panel1:getModule(1, 1, 0),   -- G
    panel1:getModule(2, 1, 0),   -- G
    panel1:getModule(3, 1, 0),   -- G
    panel1:getModule(4, 1, 0),   -- G
    panel1:getModule(6, 1, 0),   -- D
    panel1:getModule(7, 1, 0),   -- D
    panel1:getModule(8, 1, 0),   -- D
    panel1:getModule(9, 1, 0),   -- D
    panel1:getModule(10, 1, 0),  -- D
}
local bigGauges = {
    panel1:getModule(0, 8, 0),   -- G
    panel1:getModule(3, 8, 0),   -- G
    panel1:getModule(5, 8, 0),   -- D
    panel1:getModule(9, 8, 0),   -- D
}
local pots = {
    panel1:getModule(0, 6, 0):getSubModule(),  -- → bigGauge 1
    panel1:getModule(3, 6, 0):getSubModule(),  -- → bigGauge 2
    panel1:getModule(6, 6, 0):getSubModule(),  -- → bigGauge 3
    panel1:getModule(9, 6, 0):getSubModule(),  -- → bigGauge 4
}
local leds = {
    panel1:getModule(0, 2, 0),   -- G
    panel1:getModule(0, 3, 0),   -- G
    panel1:getModule(0, 4, 0),   -- G
    panel1:getModule(1, 3, 0),   -- G
    panel1:getModule(1, 4, 0),   -- G
    panel1:getModule(3, 3, 0),   -- G
    panel1:getModule(3, 4, 0),   -- G
    panel1:getModule(4, 2, 0),   -- G
    panel1:getModule(4, 3, 0),   -- G
    panel1:getModule(4, 4, 0),   -- G
    panel1:getModule(6, 2, 0),   -- D
    panel1:getModule(6, 3, 0),   -- D
    panel1:getModule(6, 4, 0),   -- D
    panel1:getModule(7, 3, 0),   -- D
    panel1:getModule(7, 4, 0),   -- D
    panel1:getModule(9, 3, 0),   -- D
    panel1:getModule(9, 4, 0),   -- D
    panel1:getModule(10, 2, 0),  -- D
    panel1:getModule(10, 3, 0),  -- D
    panel1:getModule(10, 4, 0),  -- D
}

local zoneL = false
local zoneR = false

local dispZone  = {true, true, true, false, false, false}
local gaugeZone = {true, true, true, true, true, false, false, false, false, false}
local bgZone    = {true, true, false, false}
local ledZone   = {true,true,true,true,true,true,true,true,true,true,
                   false,false,false,false,false,false,false,false,false,false}

local COLORS = {
    {1, 0, 0, 1},
    {0, 1, 0, 1},
    {1, 0.5, 0, 1},
}

local ledTimers = {}
for i = 1, #leds do
    ledTimers[i] = math.random(1, 60)
    local c = COLORS[math.random(#COLORS)]
    leds[i]:setColor(c[1], c[2], c[3], c[4])
end

local dispTimers = {}
for i = 1, #displays do
    dispTimers[i] = math.random(1, 30)
end

local targets = {} local values = {} local timers = {}
for i = 1, #gauges do
    values[i]  = math.random() * 0.6 + 0.2
    targets[i] = values[i]
    timers[i]  = math.random(1, 40)
end

local bgValues = {0, 0, 0, 0}

-- Reset bigGauges et pots à 0 au démarrage
for i, g in ipairs(bigGauges) do
    g.percent = 0
    g.limit = 0
    
end

local function resetBigGauges(isLeft)
    for i, g in ipairs(bigGauges) do
        if bgZone[i] == isLeft then
            bgValues[i] = 0
            g.percent = 0
            g.limit = 0
            
        end
    end
end

event.listen(swL)
event.listen(swR)
for _, pot in ipairs(pots) do event.listen(pot) end

local tick = 0

local function isActive(isLeft)
    return isLeft and zoneL or zoneR
end

while true do
    tick = tick + 1

    -- Gauges
    for i, g in ipairs(gauges) do
        if isActive(gaugeZone[i]) then
            if tick >= timers[i] then
                local delta = (math.random() - 0.5) * 0.3
                targets[i] = math.max(0.05, math.min(0.95, values[i] + delta))
                timers[i] = tick + math.random(30, 80)
            end
            values[i] = values[i] + (targets[i] - values[i]) * 0.05
            g.percent = values[i]
            g.limit = targets[i]
        else
            g.percent = 0
            g.limit = 0
        end
    end

    -- Big gauges : contrôlées par les pots
    for i, g in ipairs(bigGauges) do
        if isActive(bgZone[i]) then
            g.percent = bgValues[i]
            g.limit = bgValues[i]
        else
            g.percent = 0
            g.limit = 0
        end
    end

    -- Displays
    for i, d in ipairs(displays) do
        if isActive(dispZone[i]) then
            if tick >= dispTimers[i] then
                d:setText(string.format("%02d", math.random(0, 99)))
                dispTimers[i] = tick + math.random(10, 40)
            end
        else
            d:setText("--")
        end
    end

    -- LEDs
    for i, led in ipairs(leds) do
        if isActive(ledZone[i]) then
            if tick >= ledTimers[i] then
                local c = COLORS[math.random(#COLORS)]
                led:setColor(c[1], c[2], c[3], c[4])
                ledTimers[i] = tick + math.random(20, 100)
            end
        else
            led:setColor(0, 0, 0, 0)
        end
    end

    -- Events switches + pots
    local e, src, val = event.pull(0.2)
    if e == "ChangeState" then
        if src == swL then
            zoneL = not val
            if not zoneL then resetBigGauges(true) end
        end
        if src == swR then
            zoneR = not val
            if not zoneR then resetBigGauges(false) end
        end
    elseif e == "valueChanged" then
        for i, pot in ipairs(pots) do
            if src == pot then
                bgValues[i] = val / 100
            end
        end
    end
end