-- Run with LuaJIT from the repository root. Model style-bound route widgets and
-- fresh RTTI wrappers, so a tint that is immediately overwritten cannot pass.
local events, logs = {}, {}
function registerForEvent(name, fn) events[name] = fn end
CName = { new = function(v) return v end }
function NameToString(v) return v end
HDRColor = { new = function(v) return {Red=v.Red, Green=v.Green, Blue=v.Blue, Alpha=v.Alpha} end }
spdlog = {info=function(s) logs[#logs+1]=s end, error=function(s) error(s) end}

local blue = {Red=0.1583, Green=1.3033, Blue=1.4142, Alpha=0.8}
local yellow = {Red=1.0, Green=0.85, Blue=0.1, Alpha=1.0}
local orange = {Red=1.0, Green=0.2, Blue=0.0, Alpha=1.0}
local function item(color, binding)
    return {color=HDRColor.new(color), styleColor=HDRColor.new(color), binding=binding, writes=0}
end
local route, quest, road, icon = item(blue, "Mappin.IconColor"), item(yellow, "Mappin.IconColor"), item(blue), item(blue)
local function wrap(item)
    return setmetatable({
        GetTintColor=function() return HDRColor.new(item.binding and item.styleColor or item.color) end,
        SetTintColor=function(_, color) item.color=HDRColor.new(color);item.writes=item.writes+1 end,
        FlagForVisualInvalidation=function() end,
        UnbindProperty=function(_, name) assert(name=='tintColor');item.binding=nil end,
        BindProperty=function(_, name, path) assert(name=='tintColor');item.binding=path end,
    }, {__index=function(_,key)
        if key=='propertyManager' then return {bindings=item.binding and {{propertyName='tintColor',stylePath=item.binding}} or {}} end
    end})
end
inkWidgetRef = {Get=wrap}
local mounted, car, present, available = false, true, true, true
local hud = {GetGameControllers=function()
    return {{IsA=function(_, name) return name=='gameuiMinimapContainerController' end,
        gpsPlayerTrackedPathWidget=route, gpsQuestPathWidget=quest,
        road=road, icon=icon}}
end}
Game = {
    GetPlayer=function() return present and {} or nil end,
    GetMountedVehicle=function() return mounted and {IsA=function(_,name) return car and name=='vehicleCarBaseObject' end} or nil end,
    VRInkLayer=function(name) assert(name=='inkHUDLayer');return available and hud or nil end,
}
local mod = dofile('mods/cet/CyberpunkVRPort_Navigation/init.lua')
events.onInit()
local function tick() events.onUpdate(0.25) end
tick();assert(route.writes==0)
mounted=true;tick()
assert(mod.GetState().routes==1 and route.color.Red==1 and route.color.Blue<0.01)
assert(route.color.Alpha==blue.Alpha and route.binding==nil)
assert(quest.writes==0 and road.writes==0 and icon.writes==0)
for _=1,10 do tick() end
mounted=false;tick()
assert(route.color.Blue==blue.Blue and route.binding=='Mappin.IconColor')

-- A blue quest path is treated the same, while native yellow stays untouched.
quest.styleColor=HDRColor.new(blue);mounted=true;tick()
assert(mod.GetState().routes==2 and quest.color.Red==1)
events.onShutdown()
assert(route.binding=='Mappin.IconColor' and quest.binding=='Mappin.IconColor')

-- Exit to a bike, loss of the HUD, and unloading the player restore the binding.
for _,reason in ipairs({'bike','hud','player'}) do
    car=true;available=true;present=true;tick()
    if reason=='bike' then car=false elseif reason=='hud' then available=false else present=false end
    tick();assert(route.binding=='Mappin.IconColor' and quest.binding=='Mappin.IconColor')
end

-- An unrelated writer's new color belongs to it, including on our shutdown.
car=true;available=true;present=true;tick()
route.color=HDRColor.new(orange)
events.onShutdown()
assert(route.color.Green==orange.Green)
print('Navigation tint: blue routes, style binding, unchanged roads/icons/yellow routes, exit, reload and shutdown passed')
