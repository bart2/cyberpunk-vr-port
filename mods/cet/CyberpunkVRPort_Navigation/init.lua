-- The windshield map mixes its source with cyan (Render/ColorBlit.cpp). A blue
-- GPS line becomes hard to distinguish from its roads. Tint only the two native
-- route widgets warm coral while in a car; icons and map geometry keep their tint.
local patched = {}
local timer = 0.0
local lastError
local active = 0
local hudLayerName, minimapType, carType, tintProperty
local routeFields = { "gpsPlayerTrackedPathWidget", "gpsQuestPathWidget" }

local function colorCopy(c)
    return HDRColor.new({ Red = c.Red, Green = c.Green, Blue = c.Blue, Alpha = c.Alpha })
end

local function sameColor(a, b)
    return math.abs(a.Red - b.Red) < 0.0001 and math.abs(a.Green - b.Green) < 0.0001
        and math.abs(a.Blue - b.Blue) < 0.0001 and math.abs(a.Alpha - b.Alpha) < 0.0001
end

local function isBlue(c)
    return c.Blue > 0.05 and c.Blue > c.Red * 1.5 and c.Blue >= c.Green * 0.8
end

local function tintBinding(widget)
    local manager = widget.propertyManager
    if manager then
        for _, binding in ipairs(manager.bindings) do
            if NameToString(binding.propertyName) == "tintColor" then return binding.stylePath end
        end
    end
end

local function restore()
    local previous = patched
    patched = {}
    for _, entry in ipairs(previous) do
        -- A destroyed HUD or a new tint from the game/another mod is not ours.
        pcall(function()
            if sameColor(entry.widget:GetTintColor(), entry.applied) then
                entry.widget:SetTintColor(entry.original)
                if entry.binding then entry.widget:BindProperty(tintProperty, entry.binding) end
                entry.widget:FlagForVisualInvalidation()
            end
        end)
    end
end

local function update()
    -- RTTI creates new wrappers for the same widgets. Restore our previous edits
    -- before resolving the current HUD, so neither wrapper identity nor a stale
    -- controller can carry an old tint across a reload. All edits finish in this
    -- single UI-thread update, before the HUD is rendered.
    restore()
    local player = Game.GetPlayer()
    if not player then return 0 end
    local vehicle = Game.GetMountedVehicle(player)
    if not vehicle or not vehicle:IsA(carType) then return 0 end
    local layer = Game.VRInkLayer(hudLayerName)
    if not layer then return 0 end
    for _, controller in ipairs(layer:GetGameControllers()) do
        if controller:IsA(minimapType) then
            for _, field in ipairs(routeFields) do
                local ref = controller[field]
                local widget = ref and inkWidgetRef.Get(ref)
                if widget then
                    local original = widget:GetTintColor()
                    if isBlue(original) then
                        -- Strong red/orange before the windshield's cyan blend
                        -- produces a warm coral line. Keep the route's own alpha.
                        local applied = HDRColor.new({ Red = 1.0, Green = 0.03, Blue = 0.005,
                            Alpha = original.Alpha })
                        local binding = tintBinding(widget)
                        patched[#patched + 1] = { widget = widget, original = colorCopy(original),
                            applied = applied, binding = binding }
                        if binding then widget:UnbindProperty(tintProperty) end
                        widget:SetTintColor(applied)
                        widget:FlagForVisualInvalidation()
                    end
                end
            end
        end
    end
    return #patched
end

registerForEvent("onInit", function()
    hudLayerName = CName.new("inkHUDLayer")
    minimapType = CName.new("gameuiMinimapContainerController")
    carType = CName.new("vehicleCarBaseObject")
    tintProperty = CName.new("tintColor")
    spdlog.info("[Navigation] blue car routes use warm coral")
end)

registerForEvent("onUpdate", function(dt)
    if not hudLayerName then return end
    timer = timer + math.max(0.0, dt or 0.0)
    if timer < 0.25 then return end
    timer = 0.0
    local ok, result = pcall(update)
    if ok then
        if result > 0 and active == 0 then
            spdlog.info("[Navigation] car GPS route tint applied")
        end
        active, lastError = result, nil
    elseif lastError ~= tostring(result) then
        lastError = tostring(result)
        spdlog.error("[Navigation] route tint: " .. lastError)
    end
end)

registerForEvent("onShutdown", restore)

return { GetState = function() return { routes = active, error = lastError } end }
