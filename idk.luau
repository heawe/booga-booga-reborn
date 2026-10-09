-- Critter Controller — Roblox Studio
-- LocalScript в StarterPlayerScripts
-- Rayfield UI + автодвижение к криттерам.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local running = false
local movementMode = "Tween"
local heightMode = "Above Hitbox"
local standDistance = 2
local generation = 0
local activeTween

-- noclip
local noclipConn
local savedCollisions = {}

-- антигравитация
local antiGrav
local antiGravConn

-- ====== утилиты ======

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
    if obj:IsA("BasePart") then
        return obj
    elseif obj:IsA("Model") then
        return obj.PrimaryPart
            or obj:FindFirstChildWhichIsA("BasePart", true)
    end
end

local function targetPosition(obj)
    local part = findPart(obj)
    local _, _, root = getCharacter()
    if not part or not root then return end

    local offset
    if heightMode == "Above Hitbox" then
        offset = part.Size.Y / 2 + root.Size.Y / 2 + standDistance
    elseif heightMode == "Below Hitbox" then
        offset = -(part.Size.Y / 2 + root.Size.Y / 2 + standDistance)
    else
        offset = standDistance
    end

    return part.Position + Vector3.new(0, offset, 0)
end

-- ====== noclip ======

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

-- ====== антигравитация ======

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

        antiGrav.Force = Vector3.new(
            0,
            workspace.Gravity * root.AssemblyMass,
            0
        )
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

-- ====== движение ======

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
    local position = targetPosition(obj)
    local character, humanoid, root = getCharacter()

    if not position or not character then
        return false
    end

    -- Walk: обычная физика, без ноклипа и антигравитации
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
            if not running or generation ~= token then
                return false
            end

            if waypoint.Action == Enum.PathWaypointAction.Jump then
                humanoid.Jump = true
            end

            humanoid:MoveTo(waypoint.Position)

            local reached = humanoid.MoveToFinished:Wait()
            if not reached then return false end
        end

        return true
    end

    -- Teleport / Tween: включаем ноклип + антигравитацию
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

        return result == Enum.PlaybackState.Completed
            and running and generation == token
    end

    return false
end

-- ====== Rayfield ======

local Rayfield = loadstring(
    game:HttpGet("https://sirius.menu/rayfield")
)()

local Window = Rayfield:CreateWindow({
    Name = "Critter Controller",
    LoadingTitle = "Critter Controller",
    LoadingSubtitle = "Movement Settings",
    ConfigurationSaving = {Enabled = false},
    KeySystem = false
})

local Tab = Window:CreateTab("Critters", "paw-print")

Tab:CreateDropdown({
    Name = "Movement Mode",
    Options = {"Teleport", "Tween", "Walk"},
    CurrentOption = {"Tween"},
    MultipleOptions = false,
    Callback = function(option)
        movementMode = typeof(option) == "table"
            and option[1] or option
        stop()
    end
})

Tab:CreateDropdown({
    Name = "Height Mode",
    Options = {"Above Hitbox", "Below Hitbox", "Normal"},
    CurrentOption = {"Above Hitbox"},
    MultipleOptions = false,
    Callback = function(option)
        heightMode = typeof(option) == "table"
            and option[1] or option
    end
})

Tab:CreateSlider({
    Name = "Stand Distance (от хитбокса)",
    Range = {1, 25},
    Increment = 1,
    Suffix = " studs",
    CurrentValue = 2,
    Callback = function(value)
        standDistance = value
    end
})

Tab:CreateToggle({
    Name = "Auto Critters",
    CurrentValue = false,
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
                Rayfield:Notify({
                    Title = "Error",
                    Content = "workspace.Critters not found",
                    Duration = 4
                })
                return
            end

            while running and generation == token do
                local found = false

                for _, obj in ipairs(folder:GetChildren()) do
                    if not running or generation ~= token then
                        break
                    end

                    if not obj.Parent then
                        continue
                    end

                    found = true

                    -- Следуем за криттером, пока он существует:
                    -- телепорт/твин повторяется каждый кадр.
                    while running
                        and generation == token
                        and obj.Parent do

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
    end
})

Tab:CreateButton({
    Name = "Stop Movement",
    Callback = stop
})

player.CharacterAdded:Connect(function()
    stop()
end)

Rayfield:Notify({
    Title = "Critter Controller",
    Content = "Interface loaded",
    Duration = 3
})
