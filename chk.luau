local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local running = false
local movementMode = "Tween"
local heightMode = "Above Hitbox"
local standDistance = 2

local orbitRadius = 5
local orbitSpeed = 1.5
local orbitHeightMode = "Above Hitbox"
local orbitYOffset = 0

local generation = 0
local activeTween

local noclipConn
local savedCollisions = {}

local antiGrav
local antiGravConn

local autoSkip = true
local skipCooldown = 1.5
local lastSkip = 0

local autoReady = true
local readyCooldown = 1.5
local lastReady = 0

local godRockEnabled = false
local characterToken = 0

local function getCharacter()
    local character = player.Character
    if not character then return end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
    if humanoid and root and humanoid.Health > 0 then
        return character, humanoid, root
    end
end

local function findPart(obj)
    if obj:IsA("BasePart") then return obj end
    if obj:IsA("Model") then
        return obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart", true)
    end
end

local function calcHeightOffset(mode, part, root)
    if mode == "Above Hitbox" then
        return part.Size.Y / 2 + root.Size.Y / 2 + standDistance
    elseif mode == "Below Hitbox" then
        return -(part.Size.Y / 2 + root.Size.Y / 2 + standDistance)
    else
        return standDistance
    end
end

local function getHeightOffset(part, root)
    return calcHeightOffset(heightMode, part, root)
end

local function getOrbitHeightOffset(part, root)
    return calcHeightOffset(orbitHeightMode, part, root) + orbitYOffset
end

local function targetPosition(obj)
    local part = findPart(obj)
    local _, _, root = getCharacter()
    if not part or not root then return end
    local offset = getHeightOffset(part, root)
    return part.Position + Vector3.new(0, offset, 0)
end

local function startNoclip()
    if noclipConn then return end
    noclipConn = RunService.Stepped:Connect(function()
        local character = player.Character
        if not character then return end
        for _, part in ipairs(character:GetDescendants()) do
            if part:IsA("BasePart") then
                if savedCollisions[part] == nil then
                    savedCollisions[part] = part.CanCollide
                end
                part.CanCollide = false
            end
        end
    end)
end

local function stopNoclip()
    if noclipConn then
        noclipConn:Disconnect()
        noclipConn = nil
    end
    for part, original in pairs(savedCollisions) do
        if part.Parent then
            part.CanCollide = original
        end
    end
    table.clear(savedCollisions)
end

local function startAntiGrav()
    if antiGravConn then return end
    antiGravConn = RunService.Heartbeat:Connect(function()
        local _, _, root = getCharacter()
        if not root then
            if antiGrav then
                antiGrav:Destroy()
                antiGrav = nil
            end
            return
        end
        if not antiGrav or antiGrav.Parent ~= root then
            if antiGrav then antiGrav:Destroy() end
            antiGrav = Instance.new("BodyForce")
            antiGrav.Parent = root
        end
        antiGrav.Force = Vector3.new(0, workspace.Gravity * root.AssemblyMass, 0)
    end)
end

local function stopAntiGrav()
    if antiGravConn then
        antiGravConn:Disconnect()
        antiGravConn = nil
    end
    if antiGrav then
        antiGrav:Destroy()
        antiGrav = nil
    end
end

local function stop()
    running = false
    generation += 1
    if activeTween then
        activeTween:Cancel()
        activeTween = nil
    end
    stopNoclip()
    stopAntiGrav()
end

local function moveTo(obj, token)
    local part = findPart(obj)
    local character, humanoid, root = getCharacter()
    if not part or not character then return false end

    if movementMode == "Orbit" then
        startNoclip()
        startAntiGrav()

        local angle = 0
        local lastTime = tick()

        while running and generation == token and obj.Parent do
            local part2 = findPart(obj)
            if not part2 then break end

            local now = tick()
            local dt = now - lastTime
            lastTime = now

            angle = angle + dt * orbitSpeed * math.pi * 2
            if angle > math.pi * 2 then
                angle = angle - math.pi * 2
            end

            local offsetY = getOrbitHeightOffset(part2, root)

            local targetPos = part2.Position + Vector3.new(
                math.cos(angle) * orbitRadius,
                offsetY,
                math.sin(angle) * orbitRadius
            )

            root.CFrame = CFrame.new(targetPos)

            RunService.Heartbeat:Wait()
        end
        return false
    end

    local heightOffset = getHeightOffset(part, root)
    local position = part.Position + Vector3.new(0, heightOffset, 0)

    if movementMode == "Walk" then
        local path = PathfindingService:CreatePath()
        local ok = pcall(function()
            path:ComputeAsync(root.Position, position)
        end)
        if not ok or path.Status ~= Enum.PathStatus.Success then
            humanoid:MoveTo(position)
            return false
        end
        for _, waypoint in ipairs(path:GetWaypoints()) do
            if not running or generation ~= token then return false end
            if waypoint.Action == Enum.PathWaypointAction.Jump then
                humanoid.Jump = true
            end
            humanoid:MoveTo(waypoint.Position)
            if not humanoid.MoveToFinished:Wait() then return false end
        end
        return true
    end

    startNoclip()
    startAntiGrav()

    if movementMode == "Teleport" then
        root.CFrame = CFrame.new(position)
        return true
    end

    if movementMode == "Tween" then
        local distance = (root.Position - position).Magnitude
        activeTween = TweenService:Create(
            root,
            TweenInfo.new(math.clamp(distance / 25, 0.2, 5)),
            {CFrame = CFrame.new(position)}
        )
        activeTween:Play()
        local result = activeTween.Completed:Wait()
        activeTween = nil
        return result == Enum.PlaybackState.Completed and running and generation == token
    end

    return false
end

local function fireActivated(btn)
    local ok = pcall(function() firesignal(btn.Activated) end)
    if not ok then
        pcall(function()
            for _, c in ipairs(getconnections(btn.Activated)) do
                if c.Enabled and c.Function then
                    task.spawn(c.Function)
                end
            end
        end)
    end
    return ok
end

local function onSpawn(character)
    characterToken += 1
    local token = characterToken

    task.spawn(function()
        local humanoid = character:WaitForChild("Humanoid", 15)
        if not humanoid then return end

        local playerGui = player:WaitForChild("PlayerGui")
        local mainGui = playerGui:WaitForChild("MainGui", 15)
        if not mainGui then return end

        local panels = mainGui:WaitForChild("Panels", 10)
        if not panels then return end

        local toolbar = panels:WaitForChild("Toolbar", 10)
        if not toolbar then return end

        local list = toolbar:WaitForChild("List", 10)
        if not list then return end

        local slot = list:WaitForChild("1", 10)
        if not slot then return end

        task.wait(3)

        if token ~= characterToken
            or player.Character ~= character
            or humanoid.Health <= 0 then
            return
        end

        if not godRockEnabled then return end

        keypress(0x31)
        task.wait(0.1)
        keyrelease(0x31)
    end)
end

player.CharacterAdded:Connect(onSpawn)

task.spawn(function()
    local mainGui = player.PlayerGui:WaitForChild("MainGui", 15)
    if not mainGui then return end
    local panels = mainGui:WaitForChild("Panels", 5)
    if not panels then return end
    local bossbar = panels:WaitForChild("Bossbar", 5)
    if not bossbar then return end
    local skipBtn = bossbar:WaitForChild("SkipButton", 5)
    if not skipBtn then return end

    while task.wait(0.3) do
        if autoSkip and skipBtn.Visible and skipBtn.Active then
            if tick() - lastSkip > skipCooldown then
                lastSkip = tick()
                fireActivated(skipBtn)
            end
        end
    end
end)

task.spawn(function()
    local playerGui = player:WaitForChild("PlayerGui")
    local hud = playerGui:WaitForChild("HalloweenWaveHUD", 20)
    if not hud then return end
    local results = hud:WaitForChild("Results", 15)
    if not results then return end
    local bottom = results:WaitForChild("Bottom", 10)
    if not bottom then return end
    local readyBtn = bottom:WaitForChild("Ready", 10)
    if not readyBtn then return end

    while task.wait(0.3) do
        if autoReady
            and readyBtn.Parent
            and readyBtn.Visible
            and readyBtn.Active
            and results.Visible
            and tick() - lastReady >= readyCooldown then

            lastReady = tick()
            fireActivated(readyBtn)
        end
    end
end)

-- ===== MARKET HELPERS =====

local function getMarket()
    local PlayerGui = player:WaitForChild("PlayerGui")
    local MainGui = PlayerGui:FindFirstChild("MainGui")
    local Panels = MainGui and MainGui:FindFirstChild("Panels")
    return Panels and Panels:FindFirstChild("GlobalMarket")
end

local function openMarket()
    local market = getMarket()
    if market then
        market.Visible = true
    end
end

local function getHalloweenMarket()
    local PlayerGui = player:WaitForChild("PlayerGui")
    local g = PlayerGui:FindFirstChild("MainGui")
    if not g then return nil end

    local panels = g:FindFirstChild("Panels")
    if panels then
        for _, name in ipairs({
            "HalloweenMarket", "HalloweenShop",
            "Halloween", "SpookyMarket"
        }) do
            local m = panels:FindFirstChild(name)
            if m then return m end
        end
    end

    local left = g:FindFirstChild("LeftPanel")
    local hw = left and left:FindFirstChild("HalloweenUI")
    if hw then
        local content = hw:FindFirstChild("Content")
        if content then
            for _, name in ipairs({ "HalloweenMarket", "HalloweenShop", "Market" }) do
                local m = content:FindFirstChild(name)
                if m then return m end
            end
        end
        return hw
    end

    for _, obj in ipairs(g:GetDescendants()) do
        if obj:IsA("GuiObject")
            and (obj.Name == "HalloweenMarket"
                or obj.Name == "HalloweenShop"
                or obj.Name == "SpookyMarket") then
            return obj
        end
    end

    return nil
end

local function openHalloweenMarket()
    local m = getHalloweenMarket()
    if m then
        m.Visible = true
    end
end

-- ===== WINDUI =====

local WindUI = loadstring(
    game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua")
)()

local Window = WindUI:CreateWindow({
    Title = "Critter Controller",
    Icon = "paw-print",
    Author = "",
    Folder = "CritterController",
    Size = UDim2.fromOffset(560, 520),
    Transparent = true,
    Theme = "Dark",
    SideBarWidth = 180,
})

local TOGGLE_KEY = Enum.KeyCode.RightControl
local windowOpen = true

local function openWindow()
    windowOpen = true
    pcall(function() Window:Open() end)
end

local function closeWindow()
    windowOpen = false
    pcall(function() Window:Close() end)
end

local function toggleWindow()
    if windowOpen then
        closeWindow()
    else
        openWindow()
    end
end

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end

    if input.KeyCode == TOGGLE_KEY then
        toggleWindow()
        return
    end

    if input.KeyCode == Enum.KeyCode.M then
        openMarket()
    end
end)

local floatGui = Instance.new("ScreenGui")
floatGui.Name = "CritterControllerToggle"
floatGui.ResetOnSpawn = false
floatGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
floatGui.Parent = player:WaitForChild("PlayerGui")

local floatBtn = Instance.new("TextButton")
floatBtn.Size = UDim2.fromOffset(52, 52)
floatBtn.Position = UDim2.new(0, 24, 0.5, -26)
floatBtn.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
floatBtn.TextColor3 = Color3.fromRGB(235, 235, 245)
floatBtn.Text = "CC"
floatBtn.Font = Enum.Font.GothamBold
floatBtn.TextSize = 16
floatBtn.AutoButtonColor = true
floatBtn.BorderSizePixel = 0
floatBtn.Active = true
floatBtn.Draggable = true
floatBtn.Parent = floatGui

local floatCorner = Instance.new("UICorner")
floatCorner.CornerRadius = UDim.new(1, 0)
floatCorner.Parent = floatBtn

local floatStroke = Instance.new("UIStroke")
floatStroke.Color = Color3.fromRGB(80, 80, 100)
floatStroke.Thickness = 1
floatStroke.Transparency = 0.35
floatStroke.Parent = floatBtn

floatBtn.MouseButton1Click:Connect(toggleWindow)

local Tab = Window:Tab({ Title = "Critters", Icon = "paw-print" })

Tab:Dropdown({
    Title = "Movement Mode",
    Values = {"Teleport", "Tween", "Walk", "Orbit"},
    Value = "Tween",
    Multi = false,
    Callback = function(option)
        movementMode = typeof(option) == "table" and option[1] or option
        stop()
    end,
})

Tab:Section({ Title = "General Height (Teleport / Tween / Walk)" })

Tab:Dropdown({
    Title = "Height Mode",
    Values = {"Above Hitbox", "Below Hitbox", "Normal"},
    Value = "Above Hitbox",
    Multi = false,
    Callback = function(option)
        heightMode = typeof(option) == "table" and option[1] or option
    end,
})

Tab:Slider({
    Title = "Stand Distance",
    Step = 1,
    Value = { Min = 1, Max = 25, Default = 2 },
    Callback = function(value)
        standDistance = value
    end,
})

Tab:Section({ Title = "Orbit" })

Tab:Slider({
    Title = "Orbit Radius",
    Step = 1,
    Value = { Min = 1, Max = 50, Default = 5 },
    Callback = function(value)
        orbitRadius = value
    end,
})

Tab:Slider({
    Title = "Orbit Speed (rev/s)",
    Step = 0.1,
    Value = { Min = 0.1, Max = 10, Default = 1.5 },
    Callback = function(value)
        orbitSpeed = value
    end,
})

Tab:Dropdown({
    Title = "Orbit Height Mode",
    Values = {"Above Hitbox", "Below Hitbox", "Normal"},
    Value = "Above Hitbox",
    Multi = false,
    Callback = function(option)
        orbitHeightMode = typeof(option) == "table" and option[1] or option
    end,
})

Tab:Slider({
    Title = "Orbit Y Offset",
    Step = 1,
    Value = { Min = -50, Max = 50, Default = 0 },
    Callback = function(value)
        orbitYOffset = value
    end,
})

Tab:Section({ Title = "Automation" })

Tab:Toggle({
    Title = "Auto Critters",
    Default = false,
    Callback = function(value)
        if not value then
            stop()
            return
        end
        if running then return end
        running = true
        generation += 1
        local token = generation

        task.spawn(function()
            local folder = workspace:WaitForChild("Critters", 5)
            if not folder then
                stop()
                WindUI:Notify({
                    Title = "Critter Controller",
                    Content = "workspace.Critters not found",
                    Duration = 4,
                })
                return
            end

            while running and generation == token do
                local found = false
                for _, obj in ipairs(folder:GetChildren()) do
                    if not running or generation ~= token then break end
                    if not obj.Parent then continue end
                    found = true
                    while running and generation == token and obj.Parent do
                        moveTo(obj, token)
                        task.wait(0.05)
                    end
                    task.wait(0.1)
                end
                if not found then
                    task.wait(0.5)
                end
            end
        end)
    end,
})

Tab:Toggle({
    Title = "Auto Skip Countdown",
    Default = true,
    Callback = function(value)
        autoSkip = value
    end,
})

Tab:Toggle({
    Title = "Auto Ready Up",
    Default = true,
    Callback = function(value)
        autoReady = value
    end,
})

Tab:Button({
    Title = "God Rock",
    Callback = function()
        godRockEnabled = not godRockEnabled
        WindUI:Notify({
            Title = "Critter Controller",
            Content = godRockEnabled and "God Rock enabled" or "God Rock disabled",
            Duration = 2,
        })
    end,
})

Tab:Button({
    Title = "Stop Movement",
    Callback = stop,
})

local SettingsTab = Window:Tab({ Title = "Settings", Icon = "settings" })

SettingsTab:Section({ Title = "Interface" })

SettingsTab:Keybind({
    Title = "Menu Toggle Key",
    Value = "RightControl",
    Callback = function(key)
        local ok = pcall(function()
            TOGGLE_KEY = Enum.KeyCode[key]
        end)
        if not ok then
            WindUI:Notify({
                Title = "Critter Controller",
                Content = "Invalid key: " .. tostring(key),
                Duration = 3,
            })
        end
    end,
})

SettingsTab:Toggle({
    Title = "Floating Button",
    Default = true,
    Callback = function(value)
        floatBtn.Visible = value
    end,
})

SettingsTab:Button({
    Title = "Show / Hide Menu",
    Callback = toggleWindow,
})

SettingsTab:Section({ Title = "Markets" })

SettingsTab:Button({
    Title = "Open Market (M)",
    Callback = function()
        openMarket()
    end,
})

SettingsTab:Button({
    Title = "Open Halloween Market",
    Callback = function()
        openHalloweenMarket()
    end,
})

WindUI:Notify({
    Title = "Critter Controller",
    Content = "RightControl - open / close menu",
    Duration = 4,
})
