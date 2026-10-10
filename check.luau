--==============================================================
--  DIAGNOSTIC v1 — запусти ОТДЕЛЬНО от основного скрипта
--==============================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local plr = Players.LocalPlayer

print("===== DIAGNOSTIC START =====")

-- 1) Сколько криттеров и что в них
local folder = workspace:FindFirstChild("Critters")
if not folder then
    print("[!] workspace.Critters НЕ НАЙДЕН")
    -- ищем где они вообще
    for _, name in ipairs({"Critters","critters","Animals","animals","Mobs","mobs"}) do
        local f = workspace:FindFirstChild(name)
        if f then print("[?] Нашёл похожее:", name, "#", #f:GetChildren()) end
    end
else
    local kids = folder:GetChildren()
    print("[+] workspace.Critters найден, #детей =", #kids)

    -- структура первых 3 криттеров
    for i = 1, math.min(3, #kids) do
        local c = kids[i]
        print(string.format("  [%d] %s (Class=%s) — детей: %d",
            i, c.Name, c.ClassName, #c:GetChildren()))
        local parts, models = 0, 0
        for _, ch in ipairs(c:GetChildren()) do
            if ch:IsA("BasePart") then parts = parts + 1 end
            if ch:IsA("Model") then models = models + 1 end
        end
        print(string.format("      прямых BasePart=%d Model=%d", parts, models))

        -- ищем HumanoidRootPart
        local hrp = c:FindFirstChild("HumanoidRootPart")
        print("      HumanoidRootPart:", hrp and "ЕСТЬ" or "НЕТ")

        -- рекурсивно сколько частей (это и лагает!)
        local total = 0
        for _, d in ipairs(c:GetDescendants()) do
            if d:IsA("BasePart") then total = total + 1 end
        end
        print("      ВСЕГО BasePart (рекурсивно):", total)

        -- сколько соединений висит на модели (частая причина лага)
        print("      Descendants всего:", #c:GetDescendants())
    end
end

-- 2) FPS baseline — 3 секунды без ничего
local frames = 0
local startT = tick()
local conn
conn = RunService.RenderStepped:Connect(function()
    frames = frames + 1
end)
task.wait(3)
conn:Disconnect()
local fps = frames / (tick() - startT)
print(string.format("[+] Baseline FPS (без скрипта): %.1f", fps))

-- 3) Замер стоимости GetChildren на Critters
if folder then
    local t0 = tick()
    for i = 1, 100 do
        folder:GetChildren()
    end
    local dt = tick() - t0
    print(string.format("[+] GetChildren×100 на Critters: %.3f сек (%.3f мс/вызов)",
        dt, dt * 10))
end

-- 4) Замер стоимости FindFirstChildWhichIsA рекурсивного
if folder then
    local kids = folder:GetChildren()
    if #kids > 0 then
        local c = kids[1]
        local t0 = tick()
        for i = 1, 100 do
            c:FindFirstChildWhichIsA("BasePart", true)
        end
        local dt = tick() - t0
        print(string.format("[+] Рекурсивный FindFirstChildWhichIsA×100: %.3f сек (%.3f мс/вызов)",
            dt, dt * 10))
    end
end

-- 5) Замер WorldToViewportPoint
if folder then
    local kids = folder:GetChildren()
    if #kids > 0 then
        local hrp = kids[1]:FindFirstChild("HumanoidRootPart") or kids[1]:FindFirstChildWhichIsA("BasePart")
        if hrp then
            local cam = workspace.CurrentCamera
            local t0 = tick()
            for i = 1, 200 do
                cam:WorldToViewportPoint(hrp.Position)
            end
            local dt = tick() - t0
            print(string.format("[+] WorldToViewportPoint×200: %.3f сек (%.3f мс/вызов)",
                dt, dt * 10))
        end
    end
end

-- 6) Что вообще установлено (мобильный экзекьютор?)
print("[i] Executor:")
print("   hookfunction:", type(hookfunction))
print("   hookmetamethod:", type(hookmetamethod))
print("   getnamecallmethod:", type(getnamecallmethod))
print("   is_sirhurt_closure:", type(is_sirhurt_closure))
print("   identifyexecutor:", type(identifyexecutor))
if type(identifyexecutor) == "function" then
    local ok, name, ver = pcall(identifyexecutor)
    if ok then print("   →", name, ver) end
end

-- 7) Проверка, грузится ли ItemData
local ReplicatedStorage = game:GetService("ReplicatedStorage")
print("[i] ReplicatedStorage.Game.classes.projectile:",
    ReplicatedStorage:FindFirstChild("Game")
    and ReplicatedStorage.Game:FindFirstChild("classes")
    and ReplicatedStorage.Game.classes:FindFirstChild("projectile") and "ЕСТЬ" or "НЕТ")
print("[i] ReplicatedStorage.Modules.ItemData:",
    ReplicatedStorage:FindFirstChild("Modules")
    and ReplicatedStorage.Modules:FindFirstChild("ItemData") and "ЕСТЬ" or "НЕТ")

print("===== DIAGNOSTIC END =====")
