--==============================================================
--  Critter Aim + Hitbox  v2.1  (fixed hooks, no recursion)
--==============================================================

-- ЗАЩИТА ОТ ПОВТОРНОГО ЗАПУСКА
if _G.__CritterAimLoaded then
    warn("[Critter Aim] уже загружено. Перезайди в игру чтобы перезапустить.")
    return
end
_G.__CritterAimLoaded = true

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local plr = Players.LocalPlayer

local VirtualInputManager
pcall(function() VirtualInputManager = game:GetService("VirtualInputManager") end)

--==============================================================
--  Настройки
--==============================================================
local S = {
    SilentAim        = false,
    AutoShoot        = false,
    AllCritters      = true,
    SelectedCritters = {},

    LeadMult         = 1.0,
    TargetPart       = "HumanoidRootPart",

    HitboxEnabled    = false,
    HitboxVisuals    = false,
    HitboxBowOnly    = false,
    HitboxSize       = 7,

    ShowFOV          = false,
    FOVRadius        = 120,
    MoveFOV          = false,

    Debug            = false,
}

--==============================================================
--  Состояние
--==============================================================
local critters     = {}
local partCache    = {}
local lastRefresh  = 0
local lastHitbox   = 0
local curTarget    = nil
local curTargetM   = nil
local touchPos     = nil
local curVel       = Vector3.new(0, 0, 0)
local curPrevPos   = nil

--==============================================================
--  Криттеры
--==============================================================
local function refreshCritters()
    local f = workspace:FindFirstChild("Critters")
    local list = {}
    if f then
        local ok, kids = pcall(function() return f:GetChildren() end)
        if ok and kids then list = kids end
    end
    critters = list

    local alive = {}
    for i = 1, #critters do alive[critters[i]] = true end
    for k in pairs(partCache) do
        if not alive[k] then partCache[k] = nil end
    end
end

local function getPart(c)
    if not c or not c.Parent then return nil end
    local cache = partCache[c]
    if cache and cache.lastCheck and tick() - cache.lastCheck < 1 then
        local p = cache.part
        if p and p.Parent then return p end
    end

    local p = c:FindFirstChild(S.TargetPart)
    if not (p and p:IsA("BasePart")) then
        p = c:FindFirstChild("HumanoidRootPart")
    end
    if not (p and p:IsA("BasePart")) then
        p = c:FindFirstChild("Head")
    end
    if not (p and p:IsA("BasePart")) then
        p = c:FindFirstChild("Torso")
    end
    if not (p and p:IsA("BasePart")) then
        p = c:FindFirstChildWhichIsA("BasePart")
    end

    if not partCache[c] then partCache[c] = {} end
    partCache[c].part = p
    partCache[c].lastCheck = tick()
    return p
end

local function isAlive(c)
    if not c or not c.Parent then return false end
    local h = c:FindFirstChildOfClass("Humanoid")
    if h then return h.Health > 0 end
    return true
end

local function wantCritter(name)
    if S.AllCritters then return true end
    if type(S.SelectedCritters) ~= "table" then return false end
    return S.SelectedCritters[name] == true
end

--==============================================================
--  Лук
--==============================================================
local BOW_WORDS = { "bow", "sling", "crossbow", "cannon", "ballista" }

local function holdingBow()
    local ch = plr.Character
    if not ch then return false end
    local t = ch:FindFirstChildOfClass("Tool")
    if not t then return false end
    local n = string.lower(t.Name)
    for i = 1, #BOW_WORDS do
        if string.find(n, BOW_WORDS[i], 1, true) then return true end
    end
    return false
end

--==============================================================
--  Модули
--==============================================================
local ProjClass, ItemData, ItemIDs
pcall(function() ProjClass = require(ReplicatedStorage.Game.classes.projectile) end)
pcall(function() ItemData  = require(ReplicatedStorage.Modules.ItemData) end)
pcall(function() ItemIDs   = require(ReplicatedStorage.Modules.ItemIDS) end)

--==============================================================
--  Баллистика
--==============================================================
local SPEED_CURVE = {
    {0, 430.16}, {494, 430.16}, {532, 424.46},
    {595, 424.00}, {990, 329.71}, {10000, 329.71},
}

local function speedFromDist(d)
    if d < 0 then d = 0 end
    for i = 1, #SPEED_CURVE - 1 do
        local a, b = SPEED_CURVE[i], SPEED_CURVE[i + 1]
        if d >= a[1] and d <= b[1] then
            local span = b[1] - a[1]
            if span < 1e-6 then span = 1e-6 end
            local t = (d - a[1]) / span
            return a[2] + (b[2] - a[2]) * t
        end
    end
    return SPEED_CURVE[#SPEED_CURVE][2]
end

local function getItemRow(toolID, projName)
    if type(ItemData) ~= "table" then return nil end
    local id = tonumber(toolID)
    if id then
        if ItemData[id] then return ItemData[id] end
        if type(ItemIDs) == "table" then
            local nm = ItemIDs[id] or ItemIDs[tostring(id)]
            if nm and ItemData[nm] then return ItemData[nm] end
        end
    end
    if projName and ItemData[projName] then return ItemData[projName] end
    return nil
end

local function solveArc(origin, vm, target, gravity)
    local diff = target - origin
    local dist = diff.Magnitude
    if dist < 1e-4 then return Vector3.new(0, 0, -1), 0, false, false end
    local direct = diff / dist

    local G = -gravity.Y
    if G <= 0 or vm <= 0 then return direct, dist / math.max(vm, 1), false, false end

    local hx, hz = diff.X, diff.Z
    local Dxz = math.sqrt(hx * hx + hz * hz)
    if Dxz < 8 then return direct, dist / vm, true, false end

    local v2   = vm * vm
    local disc = v2 * v2 - G * (G * Dxz * Dxz + 2 * diff.Y * v2)
    if disc < 0 then return direct, dist / vm, false, false end

    local sq = math.sqrt(disc)
    local highAngle = math.atan((v2 + sq) / (G * Dxz))
    local lowAngle  = math.atan((v2 - sq) / (G * Dxz))

    local angle = lowAngle
    local highArc = false
    if diff.Y > 100 then
        angle = highAngle
        highArc = true
    elseif angle ~= angle or math.abs(angle) > math.abs(highAngle) then
        angle = highAngle
        highArc = true
    end
    if angle < -1.5 then angle = -1.5 end
    if angle > 1.55 then angle = 1.55 end

    local flat = Vector3.new(hx, 0, hz)
    if flat.Magnitude < 1e-6 then return direct, dist / vm, true, highArc end
    flat = flat / flat.Magnitude

    local dir = flat * math.cos(angle) + Vector3.new(0, math.sin(angle), 0)
    local mag = dir.Magnitude
    if mag < 1e-6 then return direct, dist / vm, true, highArc end
    dir = dir / mag

    local hSpeed = vm * math.cos(angle)
    local ft
    if math.abs(hSpeed) < 1e-6 then ft = dist / vm
    else ft = math.min(Dxz / hSpeed, 10) end
    return dir, ft, true, highArc
end

local function predict(origin, target, tvel, vm, gravity)
    local iters = 6
    local d = (target - origin).Magnitude
    if d > 150 then iters = 10
    elseif d > 75 then iters = 8 end

    local pred = target
    for i = 1, iters do
        local _, ft, ok, highArc = solveArc(origin, vm, pred, gravity)
        if type(ft) ~= "number" or ft ~= ft or not ok then ft = 0.1 end
        local cap = highArc and 1.5 or 4
        if ft > cap then ft = cap end
        pred = target + tvel * S.LeadMult * ft
    end
    return pred
end

local function computeDir(origin, tPart, tModel, proj)
    if not origin or not tPart or not tPart.Parent then return nil end

    local item = getItemRow(proj and proj.toolID, proj and proj.projectileName)
    local projItem = nil
    if type(ItemData) == "table" and proj and proj.projectileName then
        projItem = ItemData[proj.projectileName]
    end

    local base = speedFromDist((tPart.Position - origin).Magnitude)
    if item and tonumber(item.velocityMagnitude) then
        base = tonumber(item.velocityMagnitude)
    end
    local extraV = (projItem and tonumber(projItem.additionalVelocity)) or 0
    local vm     = base + extraV
    local addG   = (projItem and tonumber(projItem.additionalGravity)) or 0
    local grav   = Vector3.new(0, -122.2 + addG, 0)

    local pos = tPart.Position + Vector3.new(0, 0.2, 0)

    local tvel = Vector3.new(0, 0, 0)
    local rv = tPart.AssemblyLinearVelocity
    if rv and rv.Magnitude > 1 then
        tvel = Vector3.new(rv.X, 0, rv.Z)
    elseif tModel == curTargetM then
        tvel = curVel
    end

    local pred = predict(origin, pos, tvel, vm, grav)
    return solveArc(origin, vm, pred, grav)
end

--==============================================================
--  Цель
--==============================================================
local function aimActive()
    return S.SilentAim or S.AutoShoot
end

local function fovCenter(cam)
    if S.MoveFOV then
        if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and touchPos then
            return touchPos
        end
        local ok, m = pcall(function() return UserInputService:GetMouseLocation() end)
        if ok and m and (m.X > 1 or m.Y > 1) then return m end
    end
    local vs = cam.ViewportSize
    return Vector2.new(vs.X * 0.5, vs.Y * 0.5)
end

local function findTarget(cam)
    if not cam then cam = workspace.CurrentCamera end
    if not cam then return nil, nil end

    local center = fovCenter(cam)
    local radius = S.FOVRadius
    local radiusSq = radius * radius
    local camPos = cam.CFrame.Position
    local wW = 0.00025

    local bestP, bestM, bestScore = nil, nil, math.huge
    for i = 1, #critters do
        local c = critters[i]
        if wantCritter(c.Name) and isAlive(c) then
            local p = getPart(c)
            if p then
                local ok, sp = pcall(function() return cam:WorldToViewportPoint(p.Position) end)
                if ok and sp.Z > 0.01 then
                    local dx, dy = sp.X - center.X, sp.Y - center.Y
                    local sd = dx * dx + dy * dy
                    if sd <= radiusSq then
                        local wd = (p.Position - camPos).Magnitude
                        local score = math.sqrt(sd) + wd * wW
                        if score < bestScore then
                            bestScore, bestP, bestM = score, p, c
                        end
                    end
                end
            end
        end
    end
    return bestM, bestP
end

--==============================================================
--  applyAim
--==============================================================
local function applyAim(self)
    if not aimActive() then return end
    if not holdingBow() then return end
    if not self then return end

    local m, p = curTargetM, curTarget
    if not (m and p and p.Parent) then
        m, p = findTarget(workspace.CurrentCamera)
    end
    if not (m and p) then return end

    local origin = self.originCF and self.originCF.Position
    if not origin then return end

    local ok, dir = pcall(computeDir, origin, p, m, self)
    if not ok or not dir or type(dir) ~= "Vector3" or dir.Magnitude < 1e-4 then return end

    self.originCF = CFrame.lookAt(origin, origin + dir)
end

--==============================================================
--  ХУК PROJECTILE.NEW  —  ИСПРАВЛЕНО
--==============================================================
local hookDepth = 0
local MAX_DEPTH = 3

if ProjClass and type(ProjClass.new) == "function" then
    pcall(function()
        local orig

        local function hookedNew(self, ...)
            -- защита от бесконечной рекурсии
            if hookDepth >= MAX_DEPTH then
                return orig(self, ...)
            end
            hookDepth = hookDepth + 1

            -- наш aim в pcall, чтобы НИКОГДА не сломать оригинал
            pcall(applyAim, self)

            local a, b, c, d, e, f, g, h
            local ok, r1, r2, r3, r4, r5, r6, r7, r8 =
                pcall(orig, self, ...)
            hookDepth = hookDepth - 1

            if ok then return r1, r2, r3, r4, r5, r6, r7, r8 end
            return nil
        end

        if type(hookfunction) == "function" then
            -- ВАЖНО: hookfunction ВОЗВРАЩАЕТ безопасный вызов оригинала
            orig = hookfunction(ProjClass.new, hookedNew)
        else
            orig = ProjClass.new
            ProjClass.new = hookedNew
        end
    end)
end

--==============================================================
--  ХУК FireServer  —  тоже с защитой
--==============================================================
if type(hookmetamethod) == "function" and type(getnamecallmethod) == "function" then
    pcall(function()
        local origNc
        local ncDepth = 0
        local NC_MAX = 3

        origNc = hookmetamethod(game, "__namecall", function(self, ...)
            if ncDepth >= NC_MAX then
                return origNc(self, ...)
            end
            ncDepth = ncDepth + 1
            local ok, a, b, c, d, e, f, g, h = pcall(function()
                if getnamecallmethod() == "FireServer"
                    and typeof(self) == "Instance"
                    and self.Name == "CreateProjectile"
                    and aimActive()
                then
                    local shot = select(1, ...)
                    if shot then pcall(applyAim, shot) end
                end
                return origNc(self, ...)
            end)
            ncDepth = ncDepth - 1
            if ok then return a, b, c, d, e, f, g, h end
            return nil
        end)
    end)
end

--==============================================================
--  Главный цикл — 20 Hz
--==============================================================
task.spawn(function()
    while true do
        task.wait(0.05)
        local now = tick()

        local aim = aimActive()
        local hbOn = S.HitboxEnabled or S.HitboxVisuals
        local visOn = S.HitboxVisuals

        if not aim and not hbOn then
            curTarget, curTargetM = nil, nil
            continue
        end

        if now - lastRefresh > 0.5 then
            lastRefresh = now
            refreshCritters()
        end

        if curTargetM and curTarget and curTarget.Parent then
            local pos = curTarget.Position
            if curPrevPos then
                local dv = (pos - curPrevPos) / 0.05
                curVel = Vector3.new(dv.X, 0, dv.Z)
            end
            curPrevPos = pos
        else
            curPrevPos = nil
            curVel = Vector3.new(0, 0, 0)
        end

        if aim then
            local ok, m, p = pcall(findTarget, workspace.CurrentCamera)
            if ok then
                curTargetM, curTarget = m, p
                curPrevPos = p and p.Position or nil
            end
        end

        if hbOn and now - lastHitbox > 0.15 then
            lastHitbox = now
            local en = S.HitboxEnabled
            if S.HitboxBowOnly and not holdingBow() then en = false end
            local myChar = plr.Character
            local myHrp = myChar and myChar:FindFirstChild("HumanoidRootPart")
            local base = S.HitboxSize

            for i = 1, #critters do
                local c = critters[i]
                if isAlive(c) then
                    local p = getPart(c)
                    if p then
                        if en then
                            local size = base
                            if myHrp then
                                local d = (p.Position - myHrp.Position).Magnitude
                                if d < 40 then
                                    local a = d / 40
                                    if a < 0.3 then a = 0.3 end
                                    size = math.max(3, base * a)
                                end
                            end
                            if math.abs(p.Size.X - size) > 0.2 then
                                pcall(function()
                                    p.Size = Vector3.new(size, size, size)
                                    p.CanCollide = false
                                    p.Transparency = 1
                                end)
                            end
                            if visOn then
                                local box = p:FindFirstChild("CritterVisual")
                                if not box then
                                    box = Instance.new("SelectionBox")
                                    box.Name = "CritterVisual"
                                    box.Adornee = p
                                    box.LineThickness = 0
                                    box.Transparency = 1
                                    box.SurfaceTransparency = 0.7
                                    box.SurfaceColor3 = Color3.fromRGB(255, 50, 50)
                                    box.Parent = p
                                end
                                box.Visible = true
                            end
                        end
                    end
                end
            end
        end
    end
end)

--==============================================================
--  Auto Shoot
--==============================================================
if VirtualInputManager then
    task.spawn(function()
        while true do
            if not S.AutoShoot then
                task.wait(0.3)
            else
                task.wait(0.05)
                if holdingBow() then
                    local cam = workspace.CurrentCamera
                    if cam then
                        local m, p = findTarget(cam)
                        if m and p then
                            local ok, loc = pcall(function() return UserInputService:GetMouseLocation() end)
                            if ok and loc then
                                local mx, my = math.floor(loc.X), math.floor(loc.Y)
                                pcall(function()
                                    VirtualInputManager:SendMouseButtonEvent(mx, my, 0, true, game, 1)
                                end)
                                task.wait(0.58)
                                pcall(function()
                                    VirtualInputManager:SendMouseButtonEvent(mx, my, 0, false, game, 1)
                                end)
                                task.wait(0.15)
                            end
                        end
                    end
                end
            end
        end
    end)
end

--==============================================================
--  FOV-кольцо
--==============================================================
do
    local sg = Instance.new("ScreenGui")
    sg.Name = "CritterFOV"
    sg.ResetOnSpawn = false
    sg.IgnoreGuiInset = true
    sg.DisplayOrder = 100
    sg.Parent = plr:WaitForChild("PlayerGui")

    local ring = Instance.new("Frame")
    ring.AnchorPoint = Vector2.new(0.5, 0.5)
    ring.BackgroundTransparency = 1
    ring.BorderSizePixel = 0
    ring.Visible = false
    ring.Parent = sg

    local st = Instance.new("UIStroke")
    st.Thickness = 1.5
    st.Color = Color3.fromRGB(255, 255, 255)
    st.Transparency = 0.3
    st.Parent = ring

    local cr = Instance.new("UICorner")
    cr.CornerRadius = UDim.new(1, 0)
    cr.Parent = ring

    local function setR(r)
        local d = math.max(8, r * 2)
        ring.Size = UDim2.fromOffset(d, d)
    end
    setR(S.FOVRadius)
    _G.__critterSetFOV = setR

    UserInputService.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch then
            touchPos = Vector2.new(input.Position.X, input.Position.Y)
        end
    end)

    RunService.RenderStepped:Connect(function()
        local show = S.ShowFOV and aimActive()
        if ring.Visible ~= show then ring.Visible = show end
        if show then
            local cam = workspace.CurrentCamera
            if cam then
                local c = fovCenter(cam)
                ring.Position = UDim2.fromOffset(c.X, c.Y)
            end
        end
    end)
end

--==============================================================
--  GUI
--==============================================================
do
    local gui = Instance.new("ScreenGui")
    gui.Name = "CritterAim"
    gui.ResetOnSpawn = false
    gui.Parent = plr:WaitForChild("PlayerGui")

    local main = Instance.new("Frame")
    main.Size = UDim2.fromOffset(230, 370)
    main.Position = UDim2.new(0, 20, 0, 100)
    main.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
    main.BorderSizePixel = 0
    main.Active = true
    main.Draggable = true
    main.Parent = gui
    local mc = Instance.new("UICorner")
    mc.CornerRadius = UDim.new(0, 10)
    mc.Parent = main

    local st = Instance.new("UIStroke")
    st.Color = Color3.fromRGB(80, 80, 110)
    st.Thickness = 1
    st.Parent = main

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 34)
    title.BackgroundColor3 = Color3.fromRGB(34, 34, 44)
    title.BorderSizePixel = 0
    title.Text = "  Critter Aim v2.1"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 15
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = main
    local tc = Instance.new("UICorner")
    tc.CornerRadius = UDim.new(0, 10)
    tc.Parent = title

    local minBtn = Instance.new("TextButton")
    minBtn.Size = UDim2.fromOffset(24, 24)
    minBtn.Position = UDim2.new(1, -30, 0, 5)
    minBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
    minBtn.BorderSizePixel = 0
    minBtn.Text = "—"
    minBtn.TextColor3 = Color3.fromRGB(230, 230, 230)
    minBtn.Font = Enum.Font.GothamBold
    minBtn.TextSize = 14
    minBtn.Parent = main
    local mbc = Instance.new("UICorner")
    mbc.CornerRadius = UDim.new(0, 5)
    mbc.Parent = minBtn

    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1, -10, 1, -44)
    scroll.Position = UDim2.new(0, 5, 0, 39)
    scroll.BackgroundTransparency = 1
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 3
    scroll.ScrollBarImageColor3 = Color3.fromRGB(90, 90, 120)
    scroll.CanvasSize = UDim2.new(0, 0, 0, 600)
    scroll.Parent = main

    local lay = Instance.new("UIListLayout")
    lay.Padding = UDim.new(0, 6)
    lay.SortOrder = Enum.SortOrder.LayoutOrder
    lay.Parent = scroll

    local function section(txt)
        local l = Instance.new("TextLabel")
        l.Size = UDim2.new(1, 0, 0, 18)
        l.BackgroundTransparency = 1
        l.Text = txt
        l.TextColor3 = Color3.fromRGB(140, 160, 220)
        l.Font = Enum.Font.GothamBold
        l.TextSize = 11
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.Parent = scroll
    end

    local function toggle(txt, def, cb)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, 0, 0, 30)
        b.BackgroundColor3 = def and Color3.fromRGB(55, 120, 65) or Color3.fromRGB(44, 44, 56)
        b.BorderSizePixel = 0
        b.Text = "  " .. txt
        b.TextColor3 = Color3.fromRGB(230, 230, 235)
        b.Font = Enum.Font.Gotham
        b.TextSize = 13
        b.TextXAlignment = Enum.TextXAlignment.Left
        b.AutoButtonColor = false
        b.Parent = scroll
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = b
        local state = def
        b.MouseButton1Click:Connect(function()
            state = not state
            b.BackgroundColor3 = state and Color3.fromRGB(55, 120, 65) or Color3.fromRGB(44, 44, 56)
            cb(state)
        end)
    end

    local function slider(txt, mn, mx, def, step, cb)
        local h = Instance.new("Frame")
        h.Size = UDim2.new(1, 0, 0, 48)
        h.BackgroundColor3 = Color3.fromRGB(38, 38, 48)
        h.BorderSizePixel = 0
        h.Parent = scroll
        local hc = Instance.new("UICorner")
        hc.CornerRadius = UDim.new(0, 6)
        hc.Parent = h

        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, -12, 0, 20)
        lbl.Position = UDim2.new(0, 8, 0, 4)
        lbl.BackgroundTransparency = 1
        lbl.TextColor3 = Color3.fromRGB(230, 230, 235)
        lbl.Font = Enum.Font.Gotham
        lbl.TextSize = 12
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Parent = h

        local bar = Instance.new("Frame")
        bar.Size = UDim2.new(1, -20, 0, 8)
        bar.Position = UDim2.new(0, 10, 0, 32)
        bar.BackgroundColor3 = Color3.fromRGB(62, 62, 78)
        bar.BorderSizePixel = 0
        bar.Parent = h
        local bc = Instance.new("UICorner")
        bc.CornerRadius = UDim.new(1, 0)
        bc.Parent = bar

        local fill = Instance.new("Frame")
        fill.Size = UDim2.new((def - mn) / (mx - mn), 0, 1, 0)
        fill.BackgroundColor3 = Color3.fromRGB(90, 160, 255)
        fill.BorderSizePixel = 0
        fill.Parent = bar
        local fc = Instance.new("UICorner")
        fc.CornerRadius = UDim.new(1, 0)
        fc.Parent = fill

        local isF = step < 1
        local function fmt(v)
            if isF then return string.format("%.2f", v) end
            return tostring(math.floor(v + 0.5))
        end
        lbl.Text = txt .. ": " .. fmt(def)

        local drag = false
        local function upd(x)
            local ax = bar.AbsolutePosition.X
            local aw = bar.AbsoluteSize.X
            if aw < 1 then return end
            local rel = (x - ax) / aw
            if rel < 0 then rel = 0 end
            if rel > 1 then rel = 1 end
            local val = mn + (mx - mn) * rel
            val = math.floor(val / step + 0.5) * step
            fill.Size = UDim2.new((val - mn) / (mx - mn), 0, 1, 0)
            lbl.Text = txt .. ": " .. fmt(val)
            cb(val)
        end

        bar.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                drag = true
                upd(input.Position.X)
            end
        end)
        UserInputService.InputChanged:Connect(function(input)
            if drag and (input.UserInputType == Enum.UserInputType.MouseMovement
                or input.UserInputType == Enum.UserInputType.Touch) then
                upd(input.Position.X)
            end
        end)
        UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                drag = false
            end
        end)
    end

    local minimized = false
    minBtn.MouseButton1Click:Connect(function()
        minimized = not minimized
        scroll.Visible = not minimized
        main.Size = minimized and UDim2.fromOffset(230, 34) or UDim2.fromOffset(230, 370)
        minBtn.Text = minimized and "+" or "—"
    end)

    section("— Targeting —")
    toggle("Silent Aim", S.SilentAim, function(v) S.SilentAim = v end)
    toggle("Auto Shoot", S.AutoShoot, function(v) S.AutoShoot = v end)
    toggle("Target ALL Critters", S.AllCritters, function(v) S.AllCritters = v end)

    section("— Hitbox —")
    toggle("Expand Hitboxes", S.HitboxEnabled, function(v) S.HitboxEnabled = v end)
    toggle("Show Hitbox", S.HitboxVisuals, function(v) S.HitboxVisuals = v end)
    toggle("Bow Only", S.HitboxBowOnly, function(v) S.HitboxBowOnly = v end)
    slider("Hitbox Size", 2, 15, S.HitboxSize, 1, function(v) S.HitboxSize = v end)

    section("— FOV —")
    toggle("Show FOV Circle", S.ShowFOV, function(v) S.ShowFOV = v end)
    toggle("Move FOV", S.MoveFOV, function(v) S.MoveFOV = v end)
    slider("FOV Radius", 30, 800, S.FOVRadius, 5, function(v)
        S.FOVRadius = v
        if _G.__critterSetFOV then _G.__critterSetFOV(v) end
    end)

    section("— Prediction —")
    slider("Lead Mult", 0, 5, S.LeadMult, 0.1, function(v) S.LeadMult = v end)

    section("— Debug —")
    toggle("Debug Prints", S.Debug, function(v) S.Debug = v end)
end

print("[Critter Aim v2.1] loaded — хуки исправлены")
