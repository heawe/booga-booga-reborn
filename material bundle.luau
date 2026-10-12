--=====================================================================
--  AUTO BUY "Material Bundle"  |  fixed + speed slider
--  Исправлено:
--   * клик эмулируется не только через Activated, а ещё через
--     MouseButton1Click / getconnections / firesignal / :Activate()
--     и реальный ввод (VirtualInputManager) — по цепочке, пока не сработает;
--   * успех покупки = окно подтверждения реально ЗАКРЫЛОСЬ (счётчик не врёт);
--   * YesButton ищется с проверкой видимости ВСЕХ родителей (раньше мог
--     кликаться Yes из скрытого/шаблонного окна);
--   * ожидание окна подтверждения до 2 сек, а не ~0.6 сек;
--   * детект "недостаточно средств" + авто-стоп после 3 неудач;
--   * слайдер скорости покупки + пресеты.
--=====================================================================
local Players = game:GetService("Players")
local UIS     = game:GetService("UserInputService")
local lp      = Players.LocalPlayer
local pg      = lp:WaitForChild("PlayerGui")
local mainGui = pg:WaitForChild("MainGui")
local bundle  = mainGui.LeftPanel.HalloweenUI.Content["Material Bundle"]
local buyBtn  = bundle.Container:WaitForChild("Buy")
local prompts = mainGui.Subordinates:WaitForChild("Prompts")
--======================== НАСТРОЙКИ ==================================
local CONFIRM_TIMEOUT = 2.0      -- сколько ждать появления окна подтверждения
local CLOSE_TIMEOUT   = 2.5      -- сколько ждать, пока окно закроется
local MAX_FAILS       = 3        -- неудач подряд -> авто-стоп
local MIN_DELAY, MAX_DELAY, DEFAULT_DELAY = 0.0, 1.0, 0.15
local running, bought, target = false, 0, 0
-- НЕОБЯЗАТЕЛЬНО, но это 100% защита от "делает вид, что покупает":
-- функция должна возвращать текущее число (сколько уже куплено / сколько валюты).
-- Если она задана, покупка засчитывается ТОЛЬКО если значение изменилось.
-- Пример (подставь свои пути к тексту):
--   readOwned = function() return tonumber(bundle.Container.Amount.Text) end
local readOwned = nil
--======================== LOW-LEVEL ==================================
local vim
pcall(function() vim = game:GetService("VirtualInputManager") end)
local function isVisible(gui)
	if not gui or not gui.Parent then return false end
	local obj = gui
	while obj and obj ~= game do
		if obj:IsA("GuiObject") then
			if obj.Visible == false then return false end
			local s = obj.AbsoluteSize
			if s.X < 2 or s.Y < 2 then return false end
		end
		obj = obj.Parent
	end
	return true
end
-- дёргаем все обработчики сигнала (getconnections)
local function fireConns(signal)
	if type(getconnections) ~= "function" or not signal then return false end
	local fired = false
	pcall(function()
		for _, c in ipairs(getconnections(signal)) do
			if c.Enabled ~= false then
				if c.Function then
					fired = true
					task.spawn(function() pcall(c.Function) end)
				elseif c.Fire then
					fired = true
					pcall(function() c:Fire() end)
				end
			end
		end
	end)
	return fired
end
-- настоящий клик мышью по центру кнопки (работает даже если игра слушает Input)
local function virtualClick(btn)
	if not vim then return false end
	local ok = pcall(function()
		local pos = btn.AbsolutePosition + btn.AbsoluteSize / 2
		local x, y = math.floor(pos.X), math.floor(pos.Y)
		vim:SendMouseButtonEvent(x, y, 0, true,  game, 1)
		task.wait(0.03)
		vim:SendMouseButtonEvent(x, y, 0, false, game, 1)
	end)
	return ok
end
--=========================== UI ======================================
local screen = Instance.new("ScreenGui")
screen.Name = "AutoBuyBundleGUI"
screen.ResetOnSpawn = false
screen.Parent = pg
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
local frame = Instance.new("Frame")
frame.Name = "Panel"
frame.Size = UDim2.new(0, 240, 0, 224)
frame.Position = UDim2.new(0, 20, 0.5, -112)
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = screen
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -76, 0, 26)
title.Position = UDim2.new(0, 8, 0, 4)
title.BackgroundTransparency = 1
title.Text = "Auto Buy Bundle"
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.Active = true                     -- чтобы заголовок ловил перетаскивание
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
----------------------- слайдер скорости -----------------------------
local speedCaption = Instance.new("TextLabel")
speedCaption.Size = UDim2.new(0.6, 0, 0, 18)
speedCaption.Position = UDim2.new(0, 10, 0, 66)
speedCaption.BackgroundTransparency = 1
speedCaption.Text = "Скорость (задержка)"
speedCaption.TextColor3 = Color3.fromRGB(200, 200, 200)
speedCaption.Font = Enum.Font.Gotham
speedCaption.TextSize = 12
speedCaption.TextXAlignment = Enum.TextXAlignment.Left
speedCaption.Parent = frame
local speedValue = Instance.new("TextLabel")
speedValue.Size = UDim2.new(0, 70, 0, 18)
speedValue.Position = UDim2.new(1, -80, 0, 66)
speedValue.BackgroundTransparency = 1
speedValue.Text = "0.15 с"
speedValue.TextColor3 = Color3.fromRGB(90, 190, 255)
speedValue.Font = Enum.Font.GothamBold
speedValue.TextSize = 12
speedValue.TextXAlignment = Enum.TextXAlignment.Right
speedValue.Parent = frame
local track = Instance.new("Frame")
track.Size = UDim2.new(1, -20, 0, 10)
track.Position = UDim2.new(0, 10, 0, 88)
track.BackgroundColor3 = Color3.fromRGB(55, 55, 65)
track.BorderSizePixel = 0
track.Active = true
track.Parent = frame
Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)
local fill = Instance.new("Frame")
fill.Size = UDim2.new(0, 0, 1, 0)
fill.BackgroundColor3 = Color3.fromRGB(60, 170, 255)
fill.BorderSizePixel = 0
fill.Parent = track
Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)
local knob = Instance.new("TextButton")
knob.Size = UDim2.new(0, 16, 0, 16)
knob.AnchorPoint = Vector2.new(0.5, 0.5)
knob.Position = UDim2.new(0, 0, 0.5, 0)
knob.BackgroundColor3 = Color3.new(1, 1, 1)
knob.Text = ""
knob.AutoButtonColor = false
knob.BorderSizePixel = 0
knob.Parent = track
Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)
local currentDelay = DEFAULT_DELAY
local presetButtons = {}
local function applyDelay(v)
	currentDelay = math.clamp(v, MIN_DELAY, MAX_DELAY)
	local a = (currentDelay - MIN_DELAY) / (MAX_DELAY - MIN_DELAY)
	fill.Size = UDim2.new(a, 0, 1, 0)
	knob.Position = UDim2.new(a, 0, 0.5, 0)
	speedValue.Text = string.format("%.2f с", currentDelay)
	for _, p in ipairs(presetButtons) do
		local active = math.abs(p.Value - currentDelay) < 0.001
		p.Button.BackgroundColor3 = active and Color3.fromRGB(60, 170, 255) or Color3.fromRGB(50, 50, 60)
	end
end
local function getDelay()
	return currentDelay
end
-- пресеты
do
	local PRESETS = {
		{ name = "Турбо",  v = 0.00 },
		{ name = "Быстро", v = 0.08 },
		{ name = "Норм",   v = 0.20 },
		{ name = "Тихо",   v = 0.50 },
	}
	for i, p in ipairs(PRESETS) do
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0, 50, 0, 22)
		b.Position = UDim2.new(0, 10 + (i - 1) * 56, 0, 104)
		b.BackgroundColor3 = Color3.fromRGB(50, 50, 60)
		b.Text = p.name
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Font = Enum.Font.Gotham
		b.TextSize = 12
		b.BorderSizePixel = 0
		b.Parent = frame
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
		table.insert(presetButtons, { Button = b, Value = p.v })
		b.MouseButton1Click:Connect(function() applyDelay(p.v) end)
	end
end
-- перетаскивание ползунка
do
	local draggingSlider = false
	local function sliderTo(x)
		local trackX = track.AbsolutePosition.X
		local trackW = math.max(track.AbsoluteSize.X, 1)
		local a = (x - trackX) / trackW
		applyDelay(MIN_DELAY + math.clamp(a, 0, 1) * (MAX_DELAY - MIN_DELAY))
	end
	local function sliderBegin(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
			draggingSlider = true
			sliderTo(input.Position.X)
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					draggingSlider = false
				end
			end)
		end
	end
	track.InputBegan:Connect(sliderBegin)
	knob.InputBegan:Connect(sliderBegin)
	UIS.InputChanged:Connect(function(input)
		if draggingSlider and (input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch) then
			sliderTo(input.Position.X)
		end
	end)
end
----------------------- старт / стоп / статус ------------------------
local startBtn = Instance.new("TextButton")
startBtn.Size = UDim2.new(0.5, -15, 0, 30)
startBtn.Position = UDim2.new(0, 10, 0, 134)
startBtn.BackgroundColor3 = Color3.fromRGB(40, 160, 80)
startBtn.Text, startBtn.TextColor3 = "Старт", Color3.new(1, 1, 1)
startBtn.Font, startBtn.TextSize = Enum.Font.GothamBold, 14
startBtn.BorderSizePixel = 0
startBtn.Parent = frame
Instance.new("UICorner", startBtn).CornerRadius = UDim.new(0, 6)
local stopBtn = Instance.new("TextButton")
stopBtn.Size = UDim2.new(0.5, -15, 0, 30)
stopBtn.Position = UDim2.new(0.5, 5, 0, 134)
stopBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
stopBtn.Text, stopBtn.TextColor3 = "Стоп", Color3.new(1, 1, 1)
stopBtn.Font, stopBtn.TextSize = Enum.Font.GothamBold, 14
stopBtn.BorderSizePixel = 0
stopBtn.Parent = frame
Instance.new("UICorner", stopBtn).CornerRadius = UDim.new(0, 6)
local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -20, 0, 20)
status.Position = UDim2.new(0, 10, 0, 170)
status.BackgroundTransparency = 1
status.Text = "Готов"
status.TextColor3 = Color3.fromRGB(200, 200, 200)
status.Font, status.TextSize = Enum.Font.Gotham, 13
status.TextXAlignment = Enum.TextXAlignment.Left
status.Parent = frame
local hint = Instance.new("TextLabel")
hint.Size = UDim2.new(1, -20, 0, 18)
hint.Position = UDim2.new(0, 10, 0, 194)
hint.BackgroundTransparency = 1
hint.Text = "Счёт растёт только после реальной покупки"
hint.TextColor3 = Color3.fromRGB(120, 120, 130)
hint.Font, hint.TextSize = Enum.Font.Gotham, 11
hint.TextXAlignment = Enum.TextXAlignment.Left
hint.Parent = frame
local function setStatus(text)
	status.Text = text
end
--=================== ПЕРЕТАСКИВАНИЕ ПАНЕЛИ ===========================
do
	local dragging, dragStart, startPos = false, nil, nil
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
	title.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
			beginDrag(input)
		end
	end)
	UIS.InputChanged:Connect(function(input)
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
--=================== ПОКАЗАТЬ / СКРЫТЬ ===============================
hideBtn.MouseButton1Click:Connect(function()
	frame.Visible = false
	toggleBtn.Visible = true
	toggleBtn.Position = frame.Position
end)
toggleBtn.MouseButton1Click:Connect(function()
	frame.Visible = true
	toggleBtn.Visible = false
end)
--================ ОКНО ПОДТВЕРЖДЕНИЯ =================================
local YES_NAMES = {
	YesButton = true, Yes = true, Confirm = true, ConfirmButton = true,
	Accept = true, AcceptButton = true, Approve = true, OkButton = true,
}
local BAD_TEXTS = {
	"not enough", "insufficient", "cannot afford", "too expensive",
	"недостаточно", "не хватает", "мало средств",
}
local function inTemplate(obj)
	local o = obj
	while o and o ~= mainGui and o ~= pg do
		local n = o.Name
		if n == "Templates" or n == "Template" or n == "TemplateStorage" then
			return true
		end
		o = o.Parent
	end
	return false
end
-- ближайший предок-окно (прямой ребёнок Prompts / PlayerGui)
local function windowOf(btn)
	local o = btn
	while o and o.Parent and o.Parent ~= prompts and o.Parent ~= pg
	and not o.Parent:IsA("ScreenGui") do
		o = o.Parent
	end
	return o
end
local function hasErrorText(root)
	if not root or not root.Parent then return nil end
	local found
	pcall(function()
		for _, d in ipairs(root:GetDescendants()) do
			if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text and d.Text ~= "" then
				local t = string.lower(d.Text)
				for _, bad in ipairs(BAD_TEXTS) do
					if string.find(t, bad, 1, true) then
						found = d.Text
						break
					end
				end
			end
			if found then break end
		end
	end)
	return found
end
-- ищем РЕАЛЬНО видимую кнопку "Да" (с учётом видимости всех родителей)
local function findPrompt()
	for _, root in ipairs({ prompts, pg }) do
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("GuiButton") and YES_NAMES[d.Name]
			and isVisible(d) and not inTemplate(d)
			and not (screen and d:IsDescendantOf(screen)) then
				return d, windowOf(d)
			end
		end
	end
	return nil
end
--=================== КЛИКИ С ПРОВЕРКОЙ ===============================
local function clickUntil(btn, verify, timeout, alive)
	if not btn or not btn.Parent then return false end
	if verify() then return true end
	local deadline = os.clock() + timeout
	local strategies = {
		function() return fireConns(btn.MouseButton1Click) end,
		function() return fireConns(btn.Activated) end,
		function() pcall(firesignal, btn.MouseButton1Click) return true end,
		function() pcall(firesignal, btn.Activated)          return true end,
		function() pcall(function() btn:Activate() end)      return true end,
		function() return virtualClick(btn) end,
	}
	for _, strat in ipairs(strategies) do
		if alive and not alive() then return false end
		if os.clock() >= deadline then break end
		local fired = false
		pcall(function() fired = strat() end)
		if fired then
			-- что-то дёрнули: ждём результат, другими способами НЕ долбим,
			-- иначе можно купить два раза
			repeat
				if verify() then return true end
				task.wait(0.02)
			until os.clock() >= deadline
			return verify()
		else
			task.wait(0.06)
		end
	end
	local t = os.clock() + 0.3
	repeat
		if verify() then return true end
		task.wait(0.02)
	until os.clock() >= t
	return verify()
end
--=================== ЛОГИКА ПОКУПКИ ==================================
local function confirmPurchase(yesBtn, win)
	local function closed()
		return not (win and win.Parent and isVisible(win))
	end
	if closed() then return true end
	if clickUntil(yesBtn, closed, CLOSE_TIMEOUT, function() return running end) then
		return true
	end
	local err = hasErrorText(win)
	if err then return false, "игра ответила: " .. tostring(err) end
	if not findPrompt() then return true end
	return false, "кнопка «Да» не сработала"
end
local function buyOnce()
	-- если окно уже висит — сначала закрываем его, Buy не трогаем
	local yesBtn, win = findPrompt()
	if yesBtn then
		return confirmPurchase(yesBtn, win)
	end
	if not isVisible(buyBtn) then
		return false, "кнопка Buy не видна"
	end
	local appeared = clickUntil(
		buyBtn,
		function() return findPrompt() ~= nil end,
		CONFIRM_TIMEOUT,
		function() return running end
	)
	yesBtn, win = findPrompt()
	if appeared and yesBtn then
		return confirmPurchase(yesBtn, win)
	end
	local err = hasErrorText(buyBtn.Parent)
	if err then return false, "игра ответила: " .. tostring(err) end
	return false, "окно подтверждения не открылось"
end
startBtn.MouseButton1Click:Connect(function()
	if running then return end
	target = math.floor(tonumber(box.Text) or 0)
	if target <= 0 then
		setStatus("Введи число больше 0")
		return
	end
	running, bought = true, 0
	setStatus(("0 / %d"):format(target))
end)
stopBtn.MouseButton1Click:Connect(function()
	if not running then
		setStatus("Уже остановлено")
		return
	end
	running = false
	setStatus(("Стоп (%d)"):format(bought))
end)
task.spawn(function()
	local fails = 0
	while true do
		if not running then
			fails = 0
			task.wait(0.05)
			continue
		end
		if bought >= target then
			running = false
			setStatus(("Готово! Куплено %d"):format(bought))
			continue
		end
		local before = nil
		if readOwned then pcall(function() before = readOwned() end) end
		local ok, err = buyOnce()
		if not running then continue end   -- нажали Стоп во время покупки
		-- доп. проверка: изменился ли счётчик игры
		if ok and readOwned and before ~= nil then
			local after
			pcall(function() after = readOwned() end)
			if after == before then
				ok, err = false, "счётчик игры не изменился — покупка не прошла"
			end
		end
		if ok then
			bought += 1
			fails = 0
			setStatus(("%d / %d"):format(bought, target))
		else
			fails += 1
			setStatus(("Неудача: %s [%d]"):format(tostring(err), fails))
			if fails >= MAX_FAILS then
				running = false
				setStatus("Стоп: " .. tostring(err))
			end
		end
		task.wait(math.max(getDelay(), 0.03))
	end
end)
applyDelay(DEFAULT_DELAY)
print("[AutoBuy] Loaded. Слайдер = задержка между покупками. Тяни панель за заголовок, скрыть — «—».")
