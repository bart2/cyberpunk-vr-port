-- Recenter after changing between a physical chair and standing. Use the mount
-- and vehicle PSM together: the mount alone changes during entry/exit animations.
local M = {}

function M.new(requestRecenter, delay)
    local self = { delay = delay or 2.0 }
    local vehicleKey
    local warned = false

    function self.reset()
        self.playerId, self.seated, self.pending = nil, nil, nil
        self.elapsed = 0.0
    end

    local function update(player, dt, loading)
        if not player then self.reset(); return end
        local requests = Game.GetSystemRequestsHandler()
        if requests:IsPreGame() then self.reset(); return end
        if requests:IsGamePaused() then self.elapsed = 0.0; return end

        -- RTTI returns fresh Lua wrappers; compare the entity ID, never wrappers.
        local playerId = tostring(player:GetEntityID().hash)
        if self.playerId ~= playerId then
            self.reset()
            self.playerId = playerId
        end
        vehicleKey = vehicleKey or Game.GetAllBlackboardDefs().PlayerStateMachine.Vehicle
        local bb = player:GetPlayerStateMachineBlackboard()
        if not bb then self.elapsed = 0.0; return end
        local state = bb:GetInt(vehicleKey)
        local vehicle = Game.GetMountedVehicle(player)
        -- gamePSMVehicle: Default=0, Transition=4. Wait for both sources to
        -- agree that entry/exit has finished before starting the full delay.
        if state == 4 or (vehicle == nil and state ~= 0) or (vehicle ~= nil and state == 0) then
            self.elapsed = 0.0
            return
        end
        local seated = vehicle ~= nil and vehicle:IsA(CName.new("vehicleCarBaseObject"))
        if loading or self.seated == nil then
            -- The existing save-load recenter owns this first pose.
            self.seated, self.pending, self.elapsed = seated, nil, 0.0
            return
        end
        if seated ~= self.seated then
            self.seated = seated
            self.pending = seated and "car entry" or "car exit"
            self.elapsed = 0.0
            spdlog.info(string.format("[VRIK] %s: recenter queued in %.1fs", self.pending, self.delay))
            return
        end
        if not self.pending then return end
        -- A loading stall or suspended frame is not time spent settling in the
        -- new posture. Ordinary frame times retain the same two-second delay.
        self.elapsed = self.elapsed + math.max(0.0, math.min(dt or 0.0, 0.1))
        if self.elapsed + 1e-6 < self.delay then return end
        assert(requestRecenter(), "could not write the HMD recenter request")
        spdlog.info("[VRIK] " .. self.pending .. ": HMD recenter requested")
        self.pending = nil
    end

    function self.update(player, dt, loading)
        local ok, err = pcall(update, player, dt, loading)
        if not ok then
            self.elapsed = 0.0
            if not warned then spdlog.error("[VRIK] car recenter: " .. tostring(err)) end
            warned = true
        else
            warned = false
        end
    end

    self.reset()
    return self
end

return M
