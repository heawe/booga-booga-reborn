local Players = game:GetService("Players")
local lp = Players.LocalPlayer
local pg = lp:WaitForChild("PlayerGui")

local mainGui   = pg:WaitForChild("MainGui")
local bundle    = mainGui.LeftPanel.HalloweenUI.Content["Material Bundle"]
local buyBtn    = bundle.Container:WaitForChild("Buy")
local prompts   = mainGui.Subordinates:WaitForChild("Prompts")

local running, bought, target = false, 0, 0
local activeWindow = nil

-- === ScreenGui ===
local screen = Instance.new("ScreenGui")
screen.Name, screen.ResetOnSpawn = "AutoBuyBundleGUI", false
screen.Parent = pg

-- === Кнопка-глазик (показать/скрыть панель) ===
local toggleBtn = Instance.new("TextButton")
toggleBtn.Name = "ToggleBtn"
toggleBtn.Size = UDim2.new(0, 40, 0, 40)
toggleBtn.Position = UDim2.new(0, 20, 0.5, -70)
toggleBtn.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
toggleBtn.Text = "👁"
toggleBtn.TextColor3 = Color3.new(1, 1, 1)
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.TextSize = 20
toggleBtn.BorderSizePixel = 0
toggleBtn.Visible = false
toggleBtn.Parent = screen
Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 8)

-- === Основная панель ===
local frame = Instance.new("Frame")
frame.Name = "Panel"
frame.Size = UDim2.new(0, 220, 0, 160)
frame.Position = UDim2.new(0, 20, 0.5, -80)
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = screen
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

-- Заголовок (тянем за него)
local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -70, 0, 26)
title.Position = UDim2.new(0, 8, 0, 4)
title.BackgroundTransparency = 1
title.Text = "Auto Buy Bundle"
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

-- Кнопка "скрыть" (палочка в углу)
local hideBtn = Instance.new("TextButton")
hideBtn.Size = UDim2.new(0, 24, 0, 24)
hideBtn.Position = UDim2.new(1, -30, 0, 4)
hideBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
hideBtn.Text = "—"
hideBtn.TextColor3 = Color3.new(1, 1, 1)
hideBtn.Font = Enum.Font.GothamBold
hideBtn.TextSize = 16
hideBtn.BorderSizePixel = 0
hideBtn.Parent = frame
Instance.new("UICorner", hideBtn).CornerRadius = UDim.new(0, 6)

-- TextBox
local box = Instance.new("TextBox")
box.Size = UDim2.new(1, -20, 0, 28)
box.Position = UDim2.new(0, 10, 0, 34)
box.BackgroundColor3 = Color3.fromRGB(50, 50, 60)
box.TextColor3 = Color3.new(1, 1, 1)
box.Text = "50"
box.Font = Enum.Font.Gotham
box.TextSize = 14
box.BorderSizePixel = 0
box.ClearTextOnFocus = false
box.Parent = frame
Instance.new("UICorner", box).CornerRadius = UDim.new(0, 6)

local startBtn = Instance.new("TextButton")
startBtn.Size = UDim2.new(0.5, -15, 0, 30)
startBtn.Position = UDim2.new(0, 10, 0, 70)
startBtn.BackgroundColor3 = Color3.fromRGB(40, 160, 80)
startBtn.Text, startBtn.TextColor3 = "Старт", Color3.new(1, 1, 1)
startBtn.Font, startBtn.TextSize = Enum.Font.GothamBold, 14
startBtn.BorderSizePixel = 0
startBtn.Parent = frame
Instance.new("UICorner", startBtn).CornerRadius = UDim.new(0, 6)

local stopBtn = Instance.new("TextButton")
stopBtn.Size = UDim2.new(0.5, -15, 0, 30)
stopBtn.Position = UDim2.new(0.5, 5, 0, 70)
stopBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
stopBtn.Text, stopBtn.TextColor3 = "Стоп", Color3.new(1, 1, 1)
stopBtn.Font, stopBtn.TextSize = Enum.Font.GothamBold, 14
stopBtn.BorderSizePixel = 0
stopBtn.Parent = frame
Instance.new("UICorner", stopBtn).CornerRadius = UDim.new(0, 6)

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -20, 0, 22)
status.Position = UDim2.new(0, 10, 0, 105)
status.BackgroundTransparency = 1
status.Text = "Готов"
status.TextColor3 = Color3.fromRGB(200, 200, 200)
status.Font, status.TextSize = Enum.Font.Gotham, 13
status.Parent = frame

-- === Перетаскивание ===
do
    local dragging = false
    local dragStart, startPos

    local function beginDrag(input)
        dragging = true
        dragStart = input.Position
        startPos = frame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end

    frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            -- тянем только за заголовок
            if input.Target == title or input.Target == frame then
                beginDrag(input)
            end
        end
    end)

    game:GetService("UserInputService").InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
end

-- === Показать/скрыть ===
hideBtn.MouseButton1Click:Connect(function()
    frame.Visible = false
    toggleBtn.Visible = true
    toggleBtn.Position = frame.Position
end)

toggleBtn.MouseButton1Click:Connect(function()
    frame.Visible = true
    toggleBtn.Visible = false
end)

-- === Логика кликов ===
local hasFiresignal = typeof(firesignal) == "function"
local hasGetconn    = typeof(getconnections) == "function"

local function clickButton(btn)
    if not btn or not btn.Parent then return end
    if hasGetconn then
        local ok = pcall(function()
            for _, c in ipairs(getconnections(btn.Activated)) do
                if c.Function then
                    task.spawn(c.Function)
                    return
                end
            end
        end)
        if ok then return end
    end
    if hasFiresignal then
        pcall(firesignal, btn.Activated)
    else
        pcall(function() btn:Activate() end)
    end
end

local function getYesButton()
    if activeWindow and activeWindow.Parent and activeWindow.Visible then
        return activeWindow
    end
    for _, d in ipairs(prompts:GetDescendants()) do
        if d.Name == "YesButton" and d:IsA("TextButton") and d.Visible then
            local p = d.Parent
            if p and p.Name ~= "Templates" and p.Parent and p.Parent.Name ~= "Templates" then
                activeWindow = d
                return d
            end
        end
    end
    return nil
end

startBtn.MouseButton1Click:Connect(function()
    if running then return end
    target = tonumber(box.Text) or 0
    if target <= 0 then status.Text = "Введи > 0"; return end
    running, bought = true, 0
    status.Text = ("0/%d"):format(target)
end)

stopBtn.MouseButton1Click:Connect(function()
    running = false
    status.Text = "Стоп ("..bought..")"
end)

task.spawn(function()
    while true do
        if not running then task.wait(0.05); continue end
        if bought >= target then
            running = false
            status.Text = ("Готово! %d"):format(bought)
            task.wait(0.05); continue
        end

        if not (buyBtn and buyBtn.Parent and buyBtn.Visible and buyBtn.Active) then
            task.wait(0.1)
            continue
        end

        clickButton(buyBtn)

        local yesBtn, tries = nil, 0
        while not yesBtn and tries < 30 do
            yesBtn = getYesButton()
            if not yesBtn then
                task.wait(0.02)
                tries += 1
            end
        end

        if yesBtn then
            clickButton(yesBtn)
            activeWindow = nil
            bought += 1
            status.Text = ("%d/%d"):format(bought, target)
            task.wait(0.15)
        else
            task.wait(0.1)
        end
    end
end)

print("[AutoBuy] Loaded. Drag by title, hide by — button.")
