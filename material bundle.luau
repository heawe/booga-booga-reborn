print("A")
-- ============================================================
--  Auto Buy Bundle (FAST v2)
--  Правки v2:
--   * обработчики соединений могут быть КОРУТИНАМИ (thread) —
--     теперь они оживляются через coroutine.resume, а не f.Fire
--   * любой клик обёрнут в pcall: одна ошибка больше не убивает цикл
--   * диагностика соединений (PREFS.debug = true)
--   * PREFS.useConnections = false -> всегда firesignal (быстрее, если он есть)
-- ============================================================
local PREFS = {
    debug          = false,  -- true -> печатать, что возвращает getconnections
    useConnections = true,   -- false -> кликать только через firesignal
}

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
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

-- === Кнопка-глазик ===
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

    frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
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

print("B")
-- ============================================================
--  БЫСТРЫЕ КЛИКИ
-- ============================================================
local hasFiresignal = typeof(firesignal) == "function"
local hasGetconn    = typeof(getconnections) == "function"

local SIGNALS = { "Activated", "MouseButton1Click", "TouchTap" }
local clickCache = setmetatable({}, { __mode = "k" })   -- кнопка -> { groups = {...} }

-- ------------------------------------------------------------
--  Запуск одного обработчика.
--  Экзекьюторы отдают по-разному: функцию, корутину или объект
--  соединения с методом :Fire(). Поддерживаем все три случая.
-- ------------------------------------------------------------
local function fireOne(f)
    if f == nil then return false end
    local kind = typeof(f)

    if kind == "function" then
        task.spawn(f)                 -- запускается сразу, кадр не ждём
        return true
    end

    if kind == "thread" then
        -- корутину нельзя индексировать, её надо оживить;
        -- coroutine.resume не бросает ошибку на мёртвом потоке
        local ok = coroutine.resume(f)
        return ok
    end

    if kind == "table" or kind == "userdata" then
        if pcall(function() f:Fire() end) then return true end
        if pcall(f.fire, f) then return true end
    end

    return false
end

-- Достаём из элемента getconnections «что запускать»
local function pickHandler(c)
    if c == nil then return nil end
    local kind = typeof(c)
    if kind == "function" or kind == "thread" then
        return c                       -- экзотика: сразу функция/поток
    end
    if kind == "table" or kind == "userdata" then
        local fn, fire
        pcall(function() fn   = c.Function end)
        pcall(function() fire = c.Fire     end)
        if fn ~= nil then return fn end
        if fire ~= nil then return fire end
    end
    return nil
end

local function resolveClicker(btn)
    local entry = { groups = {} }
    if hasGetconn and PREFS.useConnections then
        for i = 1, #SIGNALS do
            local name = SIGNALS[i]
            local ok, conns = pcall(getconnections, btn[name])
            if ok and type(conns) == "table" then
                local funcs = {}
                for j = 1, #conns do
                    local f = pickHandler(conns[j])
                    if f ~= nil then funcs[#funcs + 1] = f end
                end
                if #funcs > 0 then
                    entry.groups[#entry.groups + 1] = { name = name, funcs = funcs }
                end
            end
        end
    end
    clickCache[btn] = entry            -- кэшируем всегда, чтобы не звать getconnections каждый клик
    return entry
end

local function clickButton(btn)
    if not btn or not btn.Parent then return false end

    local entry = clickCache[btn] or resolveClicker(btn)
    local fired = false

    for i = 1, #entry.groups do
        local funcs = entry.groups[i].funcs
        for j = #funcs, 1, -1 do
            local ok, res = pcall(fireOne, funcs[j])
            if ok and res then
                fired = true
            else
                table.remove(funcs, j)  -- мёртвый обработчик убираем, дальше пойдёт firesignal
            end
        end
    end

    if not fired and hasFiresignal then
        for i = 1, #SIGNALS do
            local ok, res = pcall(firesignal, btn[SIGNALS[i]])
            if ok and res ~= false then
                fired = true
                break
            end
        end
    end

    if not fired then
        pcall(function() btn:Activate() end)
    end

    return fired
end

-- ------------------------------------------------------------
--  Диагностика: что реально возвращает getconnections
-- ------------------------------------------------------------
local function dumpConnections(btn, label)
    if not (PREFS.debug and hasGetconn) then return end
    for i = 1, #SIGNALS do
        local name = SIGNALS[i]
        local ok, conns = pcall(getconnections, btn[name])
        if ok and type(conns) == "table" and #conns > 0 then
            print(("[AutoBuy] %s.%s -> %d соединений"):format(label, name, #conns))
            for j = 1, #conns do
                local c = conns[j]
                local kind = typeof(c)
                local fn, fire = nil, nil
                if kind == "table" or kind == "userdata" then
                    pcall(function() fn   = c.Function end)
                    pcall(function() fire = c.Fire     end)
                end
                print(("   [%d] conn=%s Function=%s Fire=%s"):format(
                    j, kind, typeof(fn), typeof(fire)))
            end
        end
    end
end

-- дешёвая проверка видимости (без AbsoluteSize)
local function isShown(d)
    if not d or not d.Parent then return false end
    local o = d
    while o and o:IsA("GuiObject") do
        if not o.Visible then return false end
        o = o.Parent
    end
    return true
end

-- окно реально на экране — проверка «закрылось»
local function isLive(d)
    return isShown(d) and d.AbsoluteSize.X > 0 and d.AbsoluteSize.Y > 0
end

local tracked = nil

local function validPrompt(d)
    if not d or not d:IsA("TextButton") or d.Name ~= "YesButton" then return false end
    local p = d.Parent
    if p and p.Name ~= "Templates" and p.Parent and p.Parent.Name ~= "Templates" then
        return true
    end
    return false
end

-- окно ловим событием: мгновенно
prompts.DescendantAdded:Connect(function(d)
    if validPrompt(d) then tracked = d end
end)

local function getYesButton(deep)
    if tracked then
        if isShown(tracked) then return tracked end
        tracked = nil
    end
    if activeWindow and isShown(activeWindow) then return activeWindow end
    activeWindow = nil
    if not deep then return nil end
    for _, d in ipairs(prompts:GetDescendants()) do
        if validPrompt(d) and isShown(d) then
            activeWindow = d
            return d
        end
    end
    return nil
end

startBtn.MouseButton1Click:Connect(function()
    if running then return end
    target = tonumber(box.Text) or 0
    if target <= 0 then status.Text = "Введи > 0"; return end

    clickCache[buyBtn] = nil            -- пересобрать кэш под текущий UI
    resolveClicker(buyBtn)
    dumpConnections(buyBtn, "Buy")

    running, bought = true, 0
    status.Text = ("0/%d"):format(target)
end)

stopBtn.MouseButton1Click:Connect(function()
    running = false
    status.Text = "Стоп (" .. bought .. ")"
end)

print("C")
-- ============================================================
--  ОСНОВНОЙ ЦИКЛ
-- ============================================================
task.spawn(function()
    local misses = 0

    local function step()
        if not running then task.wait(0.1); return end

        if bought >= target then
            running = false
            status.Text = ("Готово! %d"):format(bought)
            return
        end

        if not (buyBtn and buyBtn.Parent and buyBtn.Visible and buyBtn.Active) then
            task.wait()                 -- проверяем каждый кадр
            return
        end

        clickButton(buyBtn)

        -- ждём окно подтверждения: событие + редкий fallback-скан
        local yesBtn, tries = nil, 0
        repeat
            yesBtn = getYesButton(tries % 4 == 0)
            if not yesBtn then
                task.wait()
                tries += 1
            end
        until yesBtn or tries > 60

        if yesBtn then
            misses = 0

            -- ждём, пока окно доиграет анимацию
            local spin = 0
            while not isLive(yesBtn) and spin < 20 do
                task.wait()
                spin += 1
            end

            clickButton(yesBtn)

            -- ждём закрытия; повторный клик только если окно зависло
            local frames, reclicks = 0, 0
            while isLive(yesBtn) and frames < 45 do
                task.wait()
                frames += 1
                if frames % 6 == 0 and reclicks < 2 then
                    clickButton(yesBtn)
                    reclicks += 1
                end
            end

            local closed = not isLive(yesBtn)
            activeWindow, tracked = nil, nil

            if closed then
                bought += 1
                status.Text = ("%d/%d"):format(bought, target)
            end
        else
            misses += 1
            activeWindow, tracked = nil, nil
            if misses >= 3 then
                clickCache[buyBtn] = nil    -- UI могли пересоздать
                misses = 0
            end
            task.wait(0.05)
        end
    end

    while true do
        local ok, err = pcall(step)     -- ошибка в одном шаге не убивает цикл
        if not ok then
            running = false
            status.Text = "Ошибка: см. консоль"
            print("[AutoBuy] error:", err)
        end
    end
end)

print("[AutoBuy] FAST v2 loaded. Drag by panel, hide by — button.")
