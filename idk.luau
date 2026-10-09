local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

-- Rayfield
local Rayfield = loadstring(game:HttpGet(
    "https://sirius.menu/rayfield"
))()

local Window = Rayfield:CreateWindow({
    Name = "Critter Controller",
    LoadingTitle = "Critter Controller",
    LoadingSubtitle = "Movement Settings",
    ConfigurationSaving = {
        Enabled = false
    },
    KeySystem = false
})

local Tab = Window:CreateTab("Critters", "paw-print")

local enabled = false
local mode = "Tween"
local heightMode = "Hitbox"
local currentTween
local generation = 0

local function getCharacter()
    local character = player.Character
    if not character then return end

    local root = character:FindFirstChild("HumanoidRootPart")
    local humanoid = character:FindFirstChildOfClass("Humanoid")

    if root and humanoid and humanoid.Health > 0 then
        return character, root, humanoid
    end
end

local function getTarget(obj)
    local part

    if obj:IsA("BasePart") then
        part = obj
    elseif obj:IsA("Model") then
        part = obj.PrimaryPart
            or obj:FindFirstChildWhichIsA("BasePart", true)
    end

    if not part then return end

    local offset = 3

    if heightMode == "Hitbox" then
        local _, root = getCharacter()
        if not root then return end

        offset = part.Size.Y / 2 + root.Size.Y / 2 + 2
    end

    return part.Position + Vector3.new(0, offset, 0)
end

local function stop()
    enabled = false
    generation += 1

    if currentTween then
        currentTween:Cancel()
        currentTween = nil
    end
end

local function start()
    if enabled then return end

    enabled = true
    generation += 1
    local myGeneration = generation

    task.spawn(function()
        local folder = workspace:WaitForChild("Critters", 5)

        if not folder then
            stop()
            Rayfield:Notify({
                Title = "Critters",
                Content = "workspace.Critters не найден",
                Duration = 4
            })
            return
        end

        while enabled and generation == myGeneration do
            local found = false

            for _, critter in ipairs(folder:GetChildren()) do
                if not enabled or generation ~= myGeneration then
                    break
                end

                local position = getTarget(critter)
                local character, root, humanoid = getCharacter()

                if position and root and humanoid then
                    found = true

                    if mode == "Teleport" then
                        root.CFrame = CFrame.new(position)

                    elseif mode == "Tween" then
                        local distance = (root.Position - position).Magnitude
                        currentTween = TweenService:Create(
                            root,
                            TweenInfo.new(
                                math.clamp(distance / 25, 0.2, 5),
                                Enum.EasingStyle.Linear
                            ),
                            {CFrame = CFrame.new(position)}
                        )

                        currentTween:Play()
                        local result = currentTween.Completed:Wait()
                        currentTween = nil

                        if result ~= Enum.PlaybackState.Completed then
                            break
                        end

                    elseif mode == "Walk" then
                        humanoid:MoveTo(position)
                        local deadline = os.clock() + 8

                        while enabled
                            and generation == myGeneration
                            and (root.Position - position).Magnitude > 4
                            and os.clock() < deadline do
                            task.wait(0.2)
                        end
                    end

                    task.wait(0.15)
                end
            end

            if not found then
                task.wait(0.5)
            end
        end
    end)
end

Tab:CreateDropdown({
    Name = "Movement Mode",
    Options = {"Teleport", "Tween", "Walk"},
    CurrentOption = {"Tween"},
    MultipleOptions = false,
    Callback = function(option)
        mode = typeof(option) == "table" and option[1] or option
        stop()
    end
})

Tab:CreateDropdown({
    Name = "Height Mode",
    Options = {"Hitbox", "Normal"},
    CurrentOption = {"Hitbox"},
    MultipleOptions = false,
    Callback = function(option)
        heightMode = typeof(option) == "table" and option[1] or option
    end
})

Tab:CreateToggle({
    Name = "Auto Critters",
    CurrentValue = false,
    Callback = function(value)
        if value then
            start()
        else
            stop()
        end
    end
})

Tab:CreateButton({
    Name = "Stop Movement",
    Callback = function()
        stop()
    end
})

Rayfield:Notify({
    Title = "Critter Controller",
    Content = "Interface loaded",
    Duration = 3
})
