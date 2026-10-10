--==============================================================
--  Critter Aim + Hitbox  (standalone)
--  Targets: workspace.Critters
--==============================================================

local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")
local UserInputService    = game:GetService("UserInputService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local VirtualInputManager = game:GetService("VirtualInputManager")
local CoreGui             = game:GetService("CoreGui")

local plr = Players.LocalPlayer

--==============================================================
--  Settings
--==============================================================
local Settings = {
    -- Targeting
    SilentAimOnCritters = false,
    AutoShoot           = false,
    AllCritters         = true,      -- true = бить всех криттеров
    SelectedCritters    = {},        -- name -> true (используется если AllCritters=false)

    -- Prediction
    SilentAimLeadMult   = 1.0,
    SilentAimFlatCap    = 4,
    SilentAimHighArcCap = 1.5,

    -- Hitbox
    HitboxEnabled       = false,
    HitboxVisuals       = false,
    HitboxBowOnly       = false,
    HitboxSize          = 7,

    -- FOV
    ShowFOVCircle       = false,
    FOVRadius           = 120,
    MoveFOV             = false,
}

--==============================================================
--  Runtime state
--==============================================================
local velHistory          = {}
local fovLastTouchPos     = nil
local restoreOrigNew      = nil

--==============================================================
--  Critter helpers
--==============================================================
local function collectCritters()
    local folder = workspace:FindFirstChild("Critters")
    if not folder then return {} end
    return folder:GetChildren()
end

local function critterAlive(c)
    if not c or not c.Parent then return false end
    local hum = c:FindFirstChildOfClass("Humanoid")
    if hum then return hum.Health > 0 end
    return true
end

local function critterName(c)
    return c and c.Name or ""
end

local function critterPart(c)
    if not c then return nil end
    local p = c:FindFirstChild("HumanoidRootPart")
        or c:FindFirstChild("Head")
        or c:FindFirstChild("UpperTorso")
        or c:FindFirstChild("Torso")
    if p and p:IsA("BasePart") then return p end
    return c:FindFirstChildWhichIsA("BasePart", true)
end

local function wantsCritter(name)
    if Settings.AllCritters then return true end
    if type(Settings.SelectedCritters) ~= "table" then return false end
    return Settings.SelectedCritters[name] == true
end

local function hasCritterSelection()
    if Settings.AllCritters then return true end
    for _, v in pairs(Settings.SelectedCritters) do
        if v then return true end
    end
    return false
end

--==============================================================
--  Bow detection
--==============================================================
local BOW_KEYWORDS = { "bow", "sling", "crossbow", "cannon", "ballista" }

local function isHoldingBow()
    local char = plr.Character
    if not char then return false end
    local tool = char:FindFirstChildOfClass("Tool")
    if not tool then return false end
    local n = tool.Name:lower()
    for _, k in ipairs(BOW_KEYWORDS) do
        if n:find(k, 1, true) then return true end
    end
    return false
end

--==============================================================
--  Projectile modules
--==============================================================
local ProjectileClass, ItemData, ItemIDs
pcall(function()
    ProjectileClass = require(ReplicatedStorage.Game.classes.projectile)
    ItemData        = require(ReplicatedStorage.Modules.ItemData)
    ItemIDs         = require(ReplicatedStorage.Modules.ItemIDS)
end)

--==============================================================
--  Trajectory solver
--==============================================================
local SPEED_CURVE = {
    {0, 430.16}, {494, 430.16}, {532, 424.46},
    {595, 424.00}, {990, 329.71}, {10000, 329.71},
}

local function speedFromCurve(dist)
    local d = math.max(0, dist)
    for i = 1, #SPEED_CURVE - 1 do
        local a, b = SPEED_CURVE[i], SPEED_CURVE[i + 1]
        if d >= a[1] and d <= b[1] then
            local t = (d - a[1]) / math.max(b[1] - a[1], 1e-6)
            return a[2] + (b[2] - a[2]) * t
        end
    end
    return SPEED_CURVE[#SPEED_CURVE][2]
end

local function getItemRow(toolID, projectileName)
    if type(ItemData) ~= "table" then return nil end
    local id = tonumber(toolID)
    if id and ItemData[id] then return ItemData[id] end
    if type(ItemIDs) == "table" then
        local name = ItemIDs[id] or ItemIDs[tostring(id)]
        if name and ItemData[name] then return ItemData[name] end
    end
    if projectileName and ItemData[projectileName] then
        return ItemData[projectileName]
    end
    return nil
end

local function solveTrajectory(origin, vm, targetPos, gravityVec)
    local G      = -gravityVec.Y
    local direct = (targetPos - origin).Unit
    if G <= 0 or vm <= 0 then
        return direct, 0, 0, false, false
    end
    local d    = targetPos - origin
    local Dxz  = Vector2.new(d.X, d.Z).Magnitude
    if Dxz < 8 then
        return direct, 0, d.Magnitude / vm, true, false
    end
    local v2   = vm * vm
    local disc = v2 * v2 - G * (G * Dxz * Dxz + 2 * d.Y * v2)
    if disc < 0 then
        return direct, 0, d.Magnitude / vm, false, false
    end
    local sq        = math.sqrt(disc)
    local highAngle = math.atan((v2 + sq) / (G * Dxz))
    local lowAngle  = math.atan((v2 - sq) / (G * Dxz))
    local angle     = lowAngle
    local isHighArc = false
    if targetPos.Y - origin.Y > 100 then
        angle, isHighArc = highAngle, true
    elseif angle ~= angle or math.abs(angle) > math.abs(highAngle) then
        angle, isHighArc = highAngle, true
    end
    angle = math.clamp(angle, -1.5, 1.55)
    local flatDir = Vector3.new(d.X, 0, d.Z)
    if flatDir.Magnitude < 1e-6 then
        return direct, angle, d.Magnitude / vm, true, isHighArc
    end
    flatDir = flatDir.Unit
    local dir = (flatDir * math.cos(angle) + Vector3.new(0, math.sin(angle), 0)).Unit
    local horizontalSpeed = vm * math.cos(angle)
    local flightTime = (math.abs(horizontalSpeed) < 1e-6)
        and (d.Magnitude / vm)
        or math.min(Dxz / horizontalSpeed, 10)
    return dir, angle, flightTime, true, isHighArc
end

local function predictPosition(origin, targetPos, targetModel, targetPart, vm, gravityVec)
    local leadMult = Settings.SilentAimLeadMult or 1
    local vel
    local hist = velHistory[targetModel]
    if hist then
        vel = Vector3.new(hist.vel.X, 0, hist.vel.Z) * leadMult
    else
        local rv = targetPart.AssemblyLinearVelocity
        vel = Vector3.new(rv.X, 0, rv.Z) * leadMult
    end
    local dist       = (targetPos - origin).Magnitude
    local iterations = (dist > 150 and 8) or (dist > 75 and 6) or 4
    local flatCap    = Settings.SilentAimFlatCap or 4
    local highCap    = Settings.SilentAimHighArcCap or 1.5
    local predicted  = targetPos
    for _ = 1, iterations do
        local _, _, flightTime, _, isHighArc =
            solveTrajectory(origin, vm, predicted, gravityVec)
        flightTime = math.min(flightTime, isHighArc and highCap or flatCap)
        predicted  = targetPos + vel * flightTime
    end
    return predicted
end

local function computeAim(origin, targetPart, targetModel, projectileObject)
    local toolID         = projectileObject.toolID
    local projectileName = projectileObject.projectileName
    local item     = getItemRow(toolID, projectileName)
    local projItem = (type(ItemData) == "table" and projectileName and ItemData[projectileName]) or nil
    local baseSpeed = (item and tonumber(item.velocityMagnitude))
        or speedFromCurve((targetPart.Position - origin).Magnitude)
    local addVel  = (projItem and tonumber(projItem.additionalVelocity)) or 0
    local vm      = baseSpeed + addVel
    local addGrav = (projItem and tonumber(projItem.additionalGravity)) or 0
    local gravity = Vector3.new(0, -122.2 + addGrav, 0)
    local targetPos = targetPart.Position + Vector3.new(0, 0.1, 0)
    local predicted = predictPosition(origin, targetPos, targetModel, targetPart, vm, gravity)
    return select(1, solveTrajectory(origin, vm, predicted, gravity))
end

--==============================================================
--  Target selection
--==============================================================
local function isSilentAimActive()
    return Settings.SilentAimOnCritters or Settings.AutoShoot
end

local function getFovScreenCenter(c)
    if Settings.MoveFOV then
        if UserInputService.TouchEnabled
            and not UserInputService.KeyboardEnabled
            and fovLastTouchPos then
            return fovLastTouchPos
        end
        local m = UserInputService:GetMouseLocation()
        if m and (m.X > 1 or m.Y > 1) then return m end
    end
    local vs = c.ViewportSize
    return Vector2.new(vs.X * 0.5, vs.Y * 0.5)
end

local function getBestCritter(c)
    if not c then c = workspace.CurrentCamera end
    if not c then return nil, nil end
    if not hasCritterSelection() then return nil, nil end

    local fovCenter = getFovScreenCenter(c)
    local fovRadius = Settings.FOVRadius or 120
    local camPos    = c.CFrame.Position
    local worldW    = 0.00025

    local bestPart, bestModel, bestScore = nil, nil, math.huge
    for _, critter in ipairs(collectCritters()) do
        if critterAlive(critter) and wantsCritter(critterName(critter)) then
            local part = critterPart(critter)
            if part then
                local sp = c:WorldToViewportPoint(part.Position)
                if sp.Z > 0.01 then
                    local sd = (Vector2.new(sp.X, sp.Y) - fovCenter).Magnitude
                    if sd <= fovRadius then
                        local wd    = (part.Position - camPos).Magnitude
                        local score = sd + wd * worldW
                        if score < bestScore then
                            bestScore, bestPart, bestModel = score, part, critter
                        end
                    end
                end
            end
        end
    end
    return bestModel, bestPart
end

--==============================================================
--  Apply silent aim to projectile object
--==============================================================
local function applyAim(self)
    if not isSilentAimActive() then return end
    if not isHoldingBow() then return end
    local model, part = getBestCritter(workspace.CurrentCamera)
    if not (model and part) then return end
    self.drawStrength = 1.0
    local origin = self.originCF and self.originCF.Position
    if not origin then return end
    local dir = computeAim(origin, part, model, self)
    if dir and dir.Magnitude > 0 then
        self.originCF = CFrame.lookAt(origin, origin + dir)
    end
end

--==============================================================
--  Velocity tracking (for lead prediction)
--==============================================================
RunService.Heartbeat:Connect(function(dt)
    if not isSilentAimActive() then return end
    local c = workspace.CurrentCamera
    for _, critter in ipairs(collectCritters()) do
        if critterAlive(critter) and wantsCritter(critterName(critter)) then
            local part = critterPart(critter)
            if part then
                local entry = velHistory[critter]
                if not entry then
                    velHistory[critter] = { prev = part.Position, vel = Vector3.zero }
                else
                    local fv = (dt > 0) and ((part.Position - entry.prev) / dt) or Vector3.zero
                    local dist = c and (part.Position - c.CFrame.Position).Magnitude or 100
                    local alpha = math.clamp(0.5 - dist / 1000, 0.2, 0.5)
                    entry.vel = entry.vel:Lerp(fv, alpha)
                    entry.prev = part.Position
                end
            end
        end
    end
end)

--==============================================================
--  Hitbox expand / visual
--==============================================================
local hitboxAccum = 0
RunService.RenderStepped:Connect(function(dt)
    if not Settings.HitboxEnabled and not Settings.HitboxVisuals then return end
    hitboxAccum = hitboxAccum + dt
    if hitboxAccum < 0.1 then return end
    hitboxAccum = 0

    local enabled = Settings.HitboxEnabled
    local visuals = Settings.HitboxVisuals
    if Settings.HitboxBowOnly and not isHoldingBow() then enabled = false end

    local myChar = plr.Character
    local myHrp  = myChar and myChar:FindFirstChild("HumanoidRootPart")
    local baseSize = Settings.HitboxSize or 7

    for _, critter in ipairs(collectCritters()) do
        if critterAlive(critter) then
            local part = critterPart(critter)
            if part then
                if enabled then
                    local finalSize = baseSize
                    if myHrp then
                        local dist = (part.Position - myHrp.Position).Magnitude
                        if dist < 40 then
                            local alpha = math.clamp(dist / 40, 0.3, 1)
                            finalSize = math.max(3, baseSize * alpha)
                        end
                    end
                    if math.abs(part.Size.X - finalSize) > 0.2 then
                        part.Size = Vector3.new(finalSize, finalSize, finalSize)
                        part.CanCollide = false
                        part.Transparency = 1
                    end
                    if visuals then
                        local box = part:FindFirstChild("CritterHitboxVisual")
                        if not box then
                            box = Instance.new("SelectionBox")
                            box.Name              = "CritterHitboxVisual"
                            box.Adornee           = part
                            box.LineThickness     = 0
                            box.Transparency      = 1
                            box.SurfaceTransparency = 0.75
                            box.SurfaceColor3     = Color3.fromRGB(255, 50, 50)
                            box.Parent            = part
                        end
                        box.Visible = true
                    else
                        local box = part:FindFirstChild("CritterHitboxVisual")
                        if box then box.Visible = false end
                    end
                else
                    local box = part:FindFirstChild("CritterHitboxVisual")
                    if box then box:Destroy() end
                end
            end
        end
    end
end)

--==============================================================
--  Auto shoot loop
--==============================================================
task.spawn(function()
    local FULL_CHARGE = 0.58
    local POLL        = 0.02
    local COOLDOWN    = 0.13
    local lastShot    = 0

    while true do
        if not Settings.AutoShoot then
            task.wait(0.25)
            continue
        end
        task.wait(0.025)
        if not isHoldingBow() then continue end
        local c = workspace.CurrentCamera
        if not c then continue end
        local model, part = getBestCritter(c)
        if not (model and part) then continue end
        if tick() - lastShot >= COOLDOWN then
            local m  = UserInputService:GetMouseLocation()
            local mx, my = math.floor(m.X), math.floor(m.Y)
            pcall(function()
                VirtualInputManager:SendMouseButtonEvent(mx, my, 0, true, game, 1)
            end)
            local t0 = tick()
            while tick() - t0 < FULL_CHARGE do
                task.wait(POLL)
                if not Settings.AutoShoot then break end
                local m2, p2 = getBestCritter(workspace.CurrentCamera)
                if not (m2 and p2) then break end
            end
            pcall(function()
                VirtualInputManager:SendMouseButtonEvent(mx, my, 0, false, game, 1)
            end)
            lastShot = tick()
            task.wait(COOLDOWN)
        end
    end
end)

--==============================================================
--  Projectile hook
--==============================================================
if ProjectileClass then
    local oldNew = ProjectileClass.new
    local function hookedNew(self, ...)
        pcall(function() applyAim(self) end)
        return oldNew(self, ...)
    end
    if hookfunction and type(hookfunction) == "function" then
        restoreOrigNew = hookfunction(ProjectileClass.new, hookedNew)
    else
        ProjectileClass.new = function(self, ...)
            return hookedNew(self, ...)
        end
    end
end

if typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
    pcall(function()
        local oldNc
        oldNc = hookmetamethod(game, "__namecall", function(self, ...)
            if isSilentAimActive()
                and getnamecallmethod() == "FireServer"
                and typeof(self) == "Instance"
                and self.Name == "CreateProjectile"
            then
                local shot = select(1, ...)
                if shot then pcall(function() applyAim(shot) end) end
            end
            return oldNc(self, ...)
        end)
    end)
end

--==============================================================
--  FOV ring
--==============================================================
local fovGui = Instance.new("ScreenGui")
fovGui.Name            = "CritterFOV"
fovGui.ResetOnSpawn    = false
fovGui.IgnoreGuiInset  = true
fovGui.DisplayOrder    = 10000
fovGui.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
pcall(function() fovGui.Parent = CoreGui end)
if not fovGui.Parent then fovGui.Parent = plr:WaitForChild("PlayerGui") end

local fovCircle = Instance.new("Frame")
fovCircle.AnchorPoint = Vector2.new(0.5, 0.5)
fovCircle.BackgroundTransparency = 1
fovCircle.BorderSizePixel = 0
fovCircle.Visible = false
fovCircle.Parent = fovGui

local fovStroke = Instance.new("UIStroke")
fovStroke.Thickness = 1.5
fovStroke.Color = Color3.fromRGB(255, 255, 255)
fovStroke.Transparency = 0.3
fovStroke.Parent = fovCircle

local fovCorner = Instance.new("UICorner")
fovCorner.CornerRadius = UDim.new(1, 0)
fovCorner.Parent = fovCircle

local function setFovRadius(r)
    local d = math.max(8, r * 2)
    fovCircle.Size = UDim2.fromOffset(d, d)
end
setFovRadius(Settings.FOVRadius)

UserInputService.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch then
        fovLastTouchPos = Vector2.new(input.Position.X, input.Position.Y)
    end
end)

RunService.RenderStepped:Connect(function()
    local show = Settings.ShowFOVCircle and isSilentAimActive()
    fovCircle.Visible = show
    if show then
        local c = workspace.CurrentCamera
        if c then
            local center = getFovScreenCenter(c)
            fovCircle.Position = UDim2.fromOffset(center.X, center.Y)
        end
    end
end)

--==============================================================
--  GUI
--==============================================================
local gui = Instance.new("ScreenGui")
gui.Name           = "CritterAimGUI"
gui.ResetOnSpawn   = false
gui.DisplayOrder   = 9999
pcall(function() gui.Parent = CoreGui end)
if not gui.Parent then gui.Parent = plr:WaitForChild("PlayerGui") end

local main = Instance.new("Frame")
main.Size             = UDim2.fromOffset(250, 400)
main.Position         = UDim2.new(0, 20, 0, 100)
main.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
main.BorderSizePixel  = 0
main.Active           = true
main.Draggable        = true
main.Parent           = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)

local stroke = Instance.new("UIStroke", main)
stroke.Color = Color3.fromRGB(80, 80, 110)
stroke.Thickness = 1

local title = Instance.new("TextLabel")
title.Size             = UDim2.new(1, 0, 0, 34)
title.BackgroundColor3 = Color3.fromRGB(34, 34, 44)
title.BorderSizePixel  = 0
title.Text             = "  Critter Aim"
title.TextColor3       = Color3.fromRGB(255, 255, 255)
title.Font             = Enum.Font.GothamBold
title.TextSize         = 15
title.TextXAlignment   = Enum.TextXAlignment.Left
title.Parent           = main
Instance.new("UICorner", title).CornerRadius = UDim.new(0, 10)

local minimizeBtn = Instance.new("TextButton")
minimizeBtn.Size             = UDim2.fromOffset(24, 24)
minimizeBtn.Position         = UDim2.new(1, -30, 0, 5)
minimizeBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
minimizeBtn.BorderSizePixel  = 0
minimizeBtn.Text             = "—"
minimizeBtn.TextColor3       = Color3.fromRGB(230, 230, 230)
minimizeBtn.Font             = Enum.Font.GothamBold
minimizeBtn.TextSize         = 14
minimizeBtn.Parent           = main
Instance.new("UICorner", minimizeBtn).CornerRadius = UDim.new(0, 5)

local scroll = Instance.new("ScrollingFrame")
scroll.Size               = UDim2.new(1, -10, 1, -44)
scroll.Position           = UDim2.new(0, 5, 0, 39)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel    = 0
scroll.ScrollBarThickness = 3
scroll.ScrollBarImageColor3 = Color3.fromRGB(90, 90, 120)
scroll.CanvasSize         = UDim2.new(0, 0, 0, 0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.Parent             = main

local layout = Instance.new("UIListLayout")
layout.Padding     = UDim.new(0, 6)
layout.SortOrder   = Enum.SortOrder.LayoutOrder
layout.Parent      = scroll

local function section(text)
    local l = Instance.new("TextLabel")
    l.Size               = UDim2.new(1, 0, 0, 18)
    l.BackgroundTransparency = 1
    l.Text               = text
    l.TextColor3         = Color3.fromRGB(140, 160, 220)
    l.Font               = Enum.Font.GothamBold
    l.TextSize           = 11
    l.TextXAlignment     = Enum.TextXAlignment.Left
    l.Parent             = scroll
end

local function toggle(text, default, cb)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(1, 0, 0, 30)
    btn.BackgroundColor3 = default and Color3.fromRGB(55, 120, 65)
        or Color3.fromRGB(44, 44, 56)
    btn.BorderSizePixel  = 0
    btn.Text             = "  " .. text
    btn.TextColor3       = Color3.fromRGB(230, 230, 235)
    btn.Font             = Enum.Font.Gotham
    btn.TextSize         = 13
    btn.TextXAlignment   = Enum.TextXAlignment.Left
    btn.AutoButtonColor  = false
    btn.Parent           = scroll
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)

    local state = default
    btn.MouseButton1Click:Connect(function()
        state = not state
        btn.BackgroundColor3 = state and Color3.fromRGB(55, 120, 65)
            or Color3.fromRGB(44, 44, 56)
        cb(state)
    end)
    return btn
end

local function slider(text, mn, mx, default, step, cb)
    local holder = Instance.new("Frame")
    holder.Size             = UDim2.new(1, 0, 0, 48)
    holder.BackgroundColor3 = Color3.fromRGB(38, 38, 48)
    holder.BorderSizePixel  = 0
    holder.Parent           = scroll
    Instance.new("UICorner", holder).CornerRadius = UDim.new(0, 6)

    local label = Instance.new("TextLabel")
    label.Size               = UDim2.new(1, -12, 0, 20)
    label.Position           = UDim2.new(0, 8, 0, 4)
    label.BackgroundTransparency = 1
    label.TextColor3         = Color3.fromRGB(230, 230, 235)
    label.Font               = Enum.Font.Gotham
    label.TextSize           = 12
    label.TextXAlignment     = Enum.TextXAlignment.Left
    label.Parent             = holder

    local bar = Instance.new("Frame")
    bar.Size             = UDim2.new(1, -20, 0, 8)
    bar.Position         = UDim2.new(0, 10, 0, 32)
    bar.BackgroundColor3 = Color3.fromRGB(62, 62, 78)
    bar.BorderSizePixel  = 0
    bar.Parent           = holder
    Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)

    local fill = Instance.new("Frame")
    fill.Size             = UDim2.new((default - mn) / (mx - mn), 0, 1, 0)
    fill.BackgroundColor3 = Color3.fromRGB(90, 160, 255)
    fill.BorderSizePixel  = 0
    fill.Parent           = bar
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

    local isFloat = step < 1
    local function fmt(v)
        if isFloat then return string.format("%.2f", v) end
        return tostring(math.floor(v + 0.5))
    end
    label.Text = text .. ": " .. fmt(default)

    local dragging = false
    local function update(x)
        local rel = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
        local val = mn + (mx - mn) * rel
        val = math.floor(val / step + 0.5) * step
        fill.Size = UDim2.new((val - mn) / (mx - mn), 0, 1, 0)
        label.Text = text .. ": " .. fmt(val)
        cb(val)
    end

    bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            update(input.Position.X)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging
            and (input.UserInputType == Enum.UserInputType.MouseMovement
                or input.UserInputType == Enum.UserInputType.Touch) then
            update(input.Position.X)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

-- Minimize
local minimized = false
minimizeBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    scroll.Visible = not minimized
    main.Size = minimized and UDim2.fromOffset(250, 34)
        or UDim2.fromOffset(250, 400)
    minimizeBtn.Text = minimized and "+" or "—"
end)

--=== Build UI ===
section("— Targeting —")
toggle("Silent Aim On Critters", Settings.SilentAimOnCritters, function(v)
    Settings.SilentAimOnCritters = v
end)
toggle("Auto Shoot", Settings.AutoShoot, function(v)
    Settings.AutoShoot = v
end)
toggle("Target ALL Critters", Settings.AllCritters, function(v)
    Settings.AllCritters = v
end)

section("— Hitbox —")
toggle("Expand Hitboxes", Settings.HitboxEnabled, function(v)
    Settings.HitboxEnabled = v
end)
toggle("Show Hitbox", Settings.HitboxVisuals, function(v)
    Settings.HitboxVisuals = v
end)
toggle("Bow Only", Settings.HitboxBowOnly, function(v)
    Settings.HitboxBowOnly = v
end)
slider("Hitbox Size", 2, 15, Settings.HitboxSize, 1, function(v)
    Settings.HitboxSize = v
end)

section("— FOV —")
toggle("Show FOV Circle", Settings.ShowFOVCircle, function(v)
    Settings.ShowFOVCircle = v
end)
toggle("Move FOV", Settings.MoveFOV, function(v)
    Settings.MoveFOV = v
end)
slider("FOV Radius", 30, 800, Settings.FOVRadius, 5, function(v)
    Settings.FOVRadius = v
    setFovRadius(v)
end)

section("— Prediction —")
slider("Lead Mult", 0, 5, Settings.SilentAimLeadMult, 0.1, function(v)
    Settings.SilentAimLeadMult = v
end)

--==============================================================
--  Notify
--==============================================================
print("[Critter Aim] loaded — GUI в левом верхнем углу")
