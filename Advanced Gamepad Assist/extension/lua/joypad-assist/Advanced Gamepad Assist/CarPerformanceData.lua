local lib = require "AGALib"

local M = {}

--- Only construct once per car or when the setup changes, not every frame
---@param vehicle ac.StateCar
function M:new(vehicle)
    local brokenEngineINI = true
    local idleRPM         = 0
    local maxRPM          = 0
    local turboData       = {}
    local torqueCurve     = nil

    -- Reading engine data

    local engineINI = ac.INIConfig.carData(vehicle.index, "engine.ini")

    if table.nkeys(engineINI.sections) > 0 then
        brokenEngineINI = false

        torqueCurve = ac.DataLUT11.carData(vehicle.index, engineINI:get("HEADER", "POWER_CURVE", "power.lut")) -- engineINI:tryGetLut("HEADER", "POWER_CURVE")

        if torqueCurve then
            torqueCurve.useCubicInterpolation = true
            torqueCurve.extrapolate           = true
        end

        idleRPM = engineINI:get("ENGINE_DATA", "MINIMUM", 900)
        maxRPM  = math.min(((vehicle.rpmLimiter and vehicle.rpmLimiter ~= 0) and vehicle.rpmLimiter or engineINI:get("ENGINE_DATA", "LIMITER", 99999)), engineINI:get("DAMAGE", "RPM_THRESHOLD", 99999))

        if maxRPM == 99999 then
            maxRPM = ((vehicle.rpmLimiter > 0) and vehicle.rpmLimiter or 7000)
        end

        -- Reading turbo data
        for i = 0, 3, 1 do
            local maxBoost   = engineINI:get("TURBO_" .. i, "MAX_BOOST", 0)
            local wasteGate  = engineINI:get("TURBO_" .. i, "WASTEGATE", 0)
            local boostLimit = math.min(maxBoost, wasteGate)
            if boostLimit ~= 0 then
                local referenceRPM = engineINI:get("TURBO_" .. i, "REFERENCE_RPM", -1)
                local gamma        = engineINI:get("TURBO_" .. i, "GAMMA", -1)

                if referenceRPM ~= -1 and gamma ~= -1 then
                    local ctrl = ac.INIConfig.carData(vehicle.index, "ctrl_turbo" .. i .. ".ini")

                    local controllers = {}

                    for j = 0, 3, 1 do
                        local controllerInput   = ctrl:get("CONTROLLER_" .. j, "INPUT", nil)
                        local controllerCombine = ctrl:get("CONTROLLER_" .. j, "INPUT", nil)
                        local controllerLUT     = ctrl:tryGetLut("CONTROLLER_" .. j, "LUT")

                        if controllerInput and controllerCombine and controllerLUT then
                            controllerLUT.useCubicInterpolation = true
                            controllerLUT.extrapolate = true
                            table.insert(controllers, {
                                input      = controllerInput,
                                combinator = controllerCombine,
                                LUT        = controllerLUT,
                            })
                        end
                    end

                    table.insert(turboData, {
                        boostLimit   = boostLimit,
                        referenceRPM = referenceRPM,
                        gamma        = gamma,
                        controllers  = controllers
                    })
                end
            end
        end
    end

    -- // TODO add MGU as well

    -- Reading drivetrain data

    local drivetrainINI        = ac.INIConfig.carData(vehicle.index, "drivetrain.ini")
    local shiftUpTime          = drivetrainINI:get("GEARBOX", "CHANGE_UP_TIME", vehicle.hShifter and 300 or 50) / 1000.0 -- Converted from ms to s
    local shiftDownTime        = drivetrainINI:get("GEARBOX", "CHANGE_DN_TIME", vehicle.hShifter and 300 or 50) / 1000.0 -- Converted from ms to s
    local defaultShiftUp       = drivetrainINI:get("AUTO_SHIFTER", "UP", math.lerp(idleRPM, maxRPM, 0.7))
    local electronicBlip       = drivetrainINI:get("AUTOBLIP", "ELECTRONIC", 0)
    local upshiftPoint1        = drivetrainINI:get("UPSHIFT_PROFILE", "POINT_1", 0) / 1000.0
    local upshiftPoint2        = drivetrainINI:get("UPSHIFT_PROFILE", "POINT_2", 0) / 1000.0
    local downshiftPoint1      = drivetrainINI:get("DOWNSHIFT_PROFILE", "POINT_1", 0) / 1000.0
    local downshiftPoint2      = drivetrainINI:get("DOWNSHIFT_PROFILE", "POINT_2", 0) / 1000.0
    local upshiftClutchFadeT   = (upshiftPoint1 ~= 0 and upshiftPoint2 ~= 0) and (upshiftPoint2 - upshiftPoint1) or 0
    local downshiftClutchFadeT = (downshiftPoint1 ~= 0 and downshiftPoint2 ~= 0) and (downshiftPoint2 - downshiftPoint1) or 0

    local cPhys          = ac.getCarPhysics(vehicle.index)
    local tiresINI       = ac.INIConfig.carData(car.index, "tyres.ini")

    self.__index = self

    local obj = setmetatable({
        vehicle                         = vehicle,
        brokenEngineIni                 = brokenEngineINI,
        baseTorqueCurve                 = torqueCurve,
        turboData                       = turboData,
        idleRPM                         = idleRPM,
        maxRPM                          = maxRPM,
        RPMRange                        = maxRPM - idleRPM,
        shiftUpTime                     = shiftUpTime,
        shiftDownTime                   = shiftDownTime,
        defaultShiftUpRPM               = defaultShiftUp,
        electronicBlip                  = electronicBlip,
        upshiftClutchFadeT              = upshiftClutchFadeT,
        downshiftClutchFadeT            = downshiftClutchFadeT,
        gearRatios                      = table.clone(cPhys.gearRatios, true),
        finalDrive                      = cPhys.finalRatio,
        tiresINI                        = tiresINI,
        targetSlipSmoother              = lib.SmoothTowards:new(0.12, 0.05, 0.0, 15.0, 0.0),
        loadAdditiveSmoother            = lib.SmoothTowards:new(1.4,  0.05, 0.0,  2.0, 0.0),
        fastLearningTime                = 0,
        lastCompound                    = -1,
        frontFlexGain                   = 0,
        frontFZ0                        = 0,
        maxEnginePower                  = 200
    }, self)

    if not obj.brokenEngineIni and obj.baseTorqueCurve then
        for rpm = 0.0, 1.0, 0.05 do
            local p = obj:getMaxHP(obj:getAbsoluteRPM(rpm), 1)
            if p > obj.maxEnginePower then obj.maxEnginePower = p end
        end
    end

    return obj
end

function M:getNormalizedRPM(rpm)
    rpm = rpm or self.vehicle.rpm
    return math.lerpInvSat(rpm, self.idleRPM, self.maxRPM)
end

function M:getAbsoluteRPM(normalizedRPM)
    return math.lerp(self.idleRPM, self.maxRPM, normalizedRPM)
end

-- Max theoretical torque at full throttle
function M:getMaxTQ(rpm, gear)
    if not self.baseTorqueCurve then
        return 0
    end

    local baseTorque = self.baseTorqueCurve:get(rpm)

    local totalBoost = 0.0 -- Total boost from all turbos

    for _, turbo in ipairs(self.turboData) do
        local currentTurboBoost = (rpm / turbo.referenceRPM) ^ turbo.gamma -- 0 -- Boost from this turbo

        if table.nkeys(turbo.controllers) > 0 then
            for _, controller in ipairs(turbo.controllers) do
                local controllerValue = 0 -- Boost from a single controller

                if controller.input == "RPMS" then
                    controller.LUT.useCubicInterpolation = true
                    controllerValue = controller.LUT:get(rpm)
                elseif turbo.controllerInput == "GEAR" then
                    controller.LUT.useCubicInterpolation = false
                    controllerValue = controller.LUT:get(gear)
                end

                if controller.combinator == "ADD" then
                    currentTurboBoost = currentTurboBoost + controllerValue
                elseif controller.combinator == "MULT" then
                    currentTurboBoost = currentTurboBoost * controllerValue
                end
            end
        end

        totalBoost = totalBoost + math.min(currentTurboBoost, turbo.boostLimit)
    end

    return baseTorque * (1.0 + totalBoost)
end

-- Max theoretical power at full throttle
function M:getMaxHP(rpm, gear)
    return self:getMaxTQ(rpm, gear) * rpm / 5252.0
end

function M:getGearRatio(gear)
    gear = gear or self.vehicle.gear
    return self.gearRatios[gear + 1] or math.NaN
end

function M:getDrivetrainRatio(gear)
    gear = gear or self.vehicle.gear
    return self:getGearRatio(gear) * self.finalDrive
end

function M:getRPMInGear(gear, currentRPM)
    currentRPM = currentRPM or self.vehicle.rpm
    return self:getGearRatio(gear) / self:getGearRatio(self.vehicle.gear) * currentRPM
end

function M:calcShiftingTable(minNormRPM, maxNormRPM)
    local gearData = {}

    if self.vehicle.gearCount < 2 then
        return gearData
    end

    local minRPM          = self:getAbsoluteRPM(minNormRPM)
    local maxShiftRPM     = self:getAbsoluteRPM(maxNormRPM)
    local defaultFallback = self.defaultShiftUpRPM

    for gear = 1, self.vehicle.gearCount - 1, 1 do
        local bestUpshiftRPM = defaultFallback

        if self.vehicle.mgukDeliveryCount == 0 then
            local bestArea = 0
            local areaSkew = math.lerp(1.0, 1.25, (gear - 1) / (self.vehicle.gearCount - 2)) -- shifts the bias of the power integral higher as the gear number increases
            local nextOverCurrentRatio = self:getGearRatio(gear + 1) / self:getGearRatio(gear)
            for i = 0, 300, 1 do
                local upshiftRPM = self:getAbsoluteRPM(i / 300.0)
                local nextGearRPM = upshiftRPM * nextOverCurrentRatio
                if nextGearRPM > minRPM then
                    local area = 0
                    for j = 0, 100, 1 do
                        local simRPM = math.lerp(nextGearRPM, upshiftRPM, j / 100.0)
                        area = area + self:getMaxHP(simRPM, gear + 1) / 100.0 * math.lerp(1.0, areaSkew, (j / 100.0))
                    end
                    if area > bestArea then
                        bestArea = area
                        bestUpshiftRPM = upshiftRPM
                    end
                end
            end
        end

        gearData[gear] = {
            upshiftRPM = math.min(bestUpshiftRPM, maxShiftRPM),
            gearStartRPM = (gear == 1) and self.idleRPM or (gearData[gear - 1].upshiftRPM * self:getGearRatio(gear) / self:getGearRatio(gear - 1))
        }
    end

    -- Setting first and last by hand
    gearData[1].gearStartRPM = math.max((self:getGearRatio(2) / self:getGearRatio(1)) * gearData[2].gearStartRPM, self.idleRPM)
    gearData[self.vehicle.gearCount] = {
        upshiftRPM = 9999999,
        gearStartRPM = gearData[self.vehicle.gearCount - 1].upshiftRPM * self:getGearRatio(self.vehicle.gearCount) / self:getGearRatio(self.vehicle.gearCount - 1)
    }

    return gearData
end

function M:getSlipLoadAdditive(vData)
    if self.lastCompound ~= self.vehicle.compoundIndex then
        local tireKey      = (self.vehicle.compoundIndex == 0) and "FRONT" or ("FRONT_" .. self.vehicle.compoundIndex)
        self.frontFlexGain = self.tiresINI:get(tireKey, "FLEX_GAIN", 0.029)
        self.frontFZ0      = self.tiresINI:get(tireKey, "FZ0", 3451)
        self.lastCompound  = self.vehicle.compoundIndex
    end

    local avgLoad = (self.vehicle.wheels[0].load + self.vehicle.wheels[1].load) * 0.5
    local minLoad = avgLoad * (math.sqrt(math.lerpInvSat(vData.localHVelLen, 0, 15.0)) * 0.6 + 1.0) -- Assume some amount of load to get close to the cornering slip angle right away

    local flexGainMult  = 1.0 + 12.0 * self.frontFlexGain -- 6.0 * flexGain ?
    local refLoad       = 2.0 * self.frontFZ0
    local loadAdditive0 = math.sqrt(math.max(minLoad, self.vehicle.wheels[0].load) / refLoad) * flexGainMult
    local loadAdditive1 = math.sqrt(math.max(minLoad, self.vehicle.wheels[1].load) / refLoad) * flexGainMult

    return lib.numberGuard(lib.weightedAverage({loadAdditive0, loadAdditive1}, vData.fWheelWeights), 0)
end

-- Only used as a starting point before learning takes over, but it's only an estimate, could use improvement
function M:getInitialTargetSlipEstimate(vData)
    local tireKey            = (self.vehicle.compoundIndex == 0) and "FRONT" or ("FRONT_" .. self.vehicle.compoundIndex)
    local frictionLimitAngle = self.tiresINI:get(tireKey, "FRICTION_LIMIT_ANGLE", 6.3)
    local camberGain         = self.tiresINI:get(tireKey, "CAMBER_GAIN", 0.213)
    local pressureIdeal      = self.tiresINI:get(tireKey, "PRESSURE_IDEAL", 23)
    local pressureFlexGain   = self.tiresINI:get(tireKey, "PRESSURE_FLEX_GAIN", 0.3)
    local pressureDGain      = self.tiresINI:get(tireKey, "PRESSURE_D_GAIN", 0.0052)
    local flexGain           = self.tiresINI:get(tireKey, "FLEX_GAIN", 0.0290)
    local fz0                = self.tiresINI:get(tireKey, "FZ0", 3451)

    local camberAdditive0 = camberGain * math.sin(math.rad(self.vehicle.wheels[0].camber))
    local camberAdditive1 = camberGain * math.sin(math.rad(self.vehicle.wheels[1].camber))

    local pressureFlexGainMult = (pressureFlexGain / 3.7)

    local pressureDiff0 = (pressureIdeal - self.vehicle.wheels[0].tyrePressure)
    local pressureDiff1 = (pressureIdeal - self.vehicle.wheels[1].tyrePressure)

    local dGainPressureMult0 = ((self.vehicle.wheels[0].tyrePressure < pressureIdeal) and 1.5 or 1.0)
    local dGainPressureMult1 = ((self.vehicle.wheels[1].tyrePressure < pressureIdeal) and 1.5 or 1.0)

    local pressureFlexGain0 = pressureDiff0 * pressureFlexGainMult - math.abs(pressureDiff0 * dGainPressureMult0) * pressureDGain * 1.7 - 0.005 * math.abs(car.wheels[0].tyreCoreTemperature - car.wheels[0].tyreOptimumTemperature)
    local pressureFlexGain1 = pressureDiff1 * pressureFlexGainMult - math.abs(pressureDiff1 * dGainPressureMult1) * pressureDGain * 1.7 - 0.005 * math.abs(car.wheels[1].tyreCoreTemperature - car.wheels[1].tyreOptimumTemperature)

    local loadMult = 1.0 / (2.0 * fz0) * (5.5 * (flexGain - 0.03))

    local avgLoad = (self.vehicle.wheels[0].load + self.vehicle.wheels[1].load) * 0.5
    local minLoad = avgLoad * 1.6 -- Assume some amount of load to get close to the cornering slip angle right away

    local loadAdditive0 = math.max(minLoad, self.vehicle.wheels[0].load) * loadMult + pressureFlexGain0
    local loadAdditive1 = math.max(minLoad, self.vehicle.wheels[1].load) * loadMult + pressureFlexGain1

    local targetSlip = lib.weightedAverage({frictionLimitAngle + camberAdditive0 + loadAdditive0, frictionLimitAngle + camberAdditive1 + loadAdditive1}, vData.fWheelWeights)

    return math.clamp(lib.numberGuard(targetSlip), 6, 11) -- Clamp the target to a safe range


    -- Different attempt, usually better but can mess up more at high tire pressures

    -- local camberAdditive0 = camberGain * math.sin(math.rad(self.vehicle.wheels[0].camber))
    -- local camberAdditive1 = camberGain * math.sin(math.rad(self.vehicle.wheels[1].camber))

    -- local pressureDiff0 = (self.vehicle.wheels[0].tyrePressure - pressureIdeal)
    -- local pressureDiff1 = (self.vehicle.wheels[1].tyrePressure - pressureIdeal)

    -- -- local dGainPressureMult0 = ((self.vehicle.wheels[0].tyrePressure < pressureIdeal) and 1.5 or 1.0)
    -- -- local dGainPressureMult1 = ((self.vehicle.wheels[1].tyrePressure < pressureIdeal) and 1.5 or 1.0)

    -- local avgLoad = (self.vehicle.wheels[0].load + self.vehicle.wheels[1].load) * 0.5
    -- local minLoad = avgLoad * 1.6 -- Assume some amount of load to get close to the cornering slip angle right away

    -- local loadAdditive0 = math.sqrt(math.max(minLoad, self.vehicle.wheels[0].load) / (2.0 * fz0)) * (1.0 + 6.0 * flexGain) - (pressureDiff0 * pressureDGain * 2.0 * math.lerp(frictionLimitAngle / 6.3, 1.0, 0.6)) - (pressureDiff0 * (pressureFlexGain / 4.0) * math.lerp(frictionLimitAngle / 6.3, 1.0, 0.6)) - (0.012 * math.max(0.0, car.wheels[0].tyreCoreTemperature - car.wheels[0].tyreOptimumTemperature))
    -- local loadAdditive1 = math.sqrt(math.max(minLoad, self.vehicle.wheels[1].load) / (2.0 * fz0)) * (1.0 + 6.0 * flexGain) - (pressureDiff1 * pressureDGain * 2.0 * math.lerp(frictionLimitAngle / 6.3, 1.0, 0.6)) - (pressureDiff1 * (pressureFlexGain / 4.0) * math.lerp(frictionLimitAngle / 6.3, 1.0, 0.6)) - (0.012 * math.max(0.0, car.wheels[1].tyreCoreTemperature - car.wheels[1].tyreOptimumTemperature))

    -- local targetSlip = lib.weightedAverage({(frictionLimitAngle - 1.25) + camberAdditive0 + loadAdditive0, (frictionLimitAngle - 1.25) + camberAdditive1 + loadAdditive1}, vData.fWheelWeights)

    -- return math.clamp(lib.numberGuard(targetSlip), 6, 11) -- Clamp the target to a safe range
end

function M:updateTargetFrontSlipAngle(vData, initialSteering, dt)
    local oneFrontGrounded  = (vData.vehicle.wheels[0].loadK > 0.0 or vData.vehicle.wheels[1].loadK > 0.0)

    local learningConditionsMet =
        (vData.frontNdSlip > 0.25 and vData.frontNdSlip < 1.5 and
        vData.fwdVelClamped > 8.0 and
        vData.rearNdSlip > 0.1 and vData.rearNdSlip < 1.5 and
        self.vehicle.wheels[0].surfaceType == ac.SurfaceType.Default and self.vehicle.wheels[1].surfaceType == ac.SurfaceType.Default and
        -- vData.inputData.brake < 0.05 and
        math.abs(initialSteering) > 0.6 and
        math.abs(self.vehicle.wheels[0].slipRatio) < 0.1 and math.abs(self.vehicle.wheels[1].slipRatio) < 0.1 and
        oneFrontGrounded)

    local v10Tires        = (self.tiresINI:get("HEADER", "VERSION", 0) == 10 and self.tiresINI:get("FRONT", "FRICTION_LIMIT_ANGLE", 0) ~= 0)
    local rawLoadAdditive = 0.0

    if v10Tires and oneFrontGrounded then
        rawLoadAdditive = self:getSlipLoadAdditive(vData)
        self.loadAdditiveSmoother:get(rawLoadAdditive, dt)
    end

    if self.targetSlipSmoother.state == 0.0 then
        if v10Tires then
            self.fastLearningTime         = 999
            self.targetSlipSmoother.state = self:getInitialTargetSlipEstimate(vData) - rawLoadAdditive
        else
            self.fastLearningTime         = 0.0
            self.targetSlipSmoother.state = 7.0
        end
    end

    if learningConditionsMet then
        local rateMult = 1.0
        if self.fastLearningTime < 1.5 then
            self.fastLearningTime = self.fastLearningTime + dt
            rateMult              = 4.0
        end

        -- With v10 tires the estimated peak slip change due to vertical load is subtracted here, then added back when the peak slip is requested from `getTargetFrontSlipAngle()`.
        -- This means that `getTargetFrontSlipAngle()` will reflect load changes much quicker than the learning algorithm could adapt.
        -- This will leave the learning algorithm to only have to learn changes from tire pressure or temperature that occur slower, since the load factor is separated.

        local idealSlip = math.abs(vData.frontSlipDeg) / vData.frontNdSlip - self.loadAdditiveSmoother.state
        self.targetSlipSmoother:getWithRateMult(v10Tires and math.clamp(idealSlip, 0.5, 14.0) or math.clamp(idealSlip, 4.0, 14.0), dt, rateMult)
    end
end

function M:getTargetFrontSlipAngle()
    return self.targetSlipSmoother.state + self.loadAdditiveSmoother.state
end

return M