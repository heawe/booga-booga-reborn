local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local PlayerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local CFG = {
    TOP_N = 3,
    PREVIEW_TIMEOUT = 3.0,
    CARDS_TIMEOUT = 2.0,
    SEARCH_WAIT = 2.0,

    WEBHOOK_URL = "",
    PING = "",
    SEND_NAME = true,
    SEND_PRICE = true,
    SEND_QTY = true,
    SEND_SELLER = true,
    ONLY_IF_PRICE_BELOW = 0,

    WEBHOOK_CD_ENABLED = true,
    WEBHOOK_GLOBAL_CD = 30,
    WEBHOOK_PRICE_CHANGE_ONLY = true,

    RESCAN_ENABLED = false,
    RESCAN_INTERVAL = 60,

    AUTO_SCAN_WHITELIST = false,

    DISCORD_ENABLED = false,
    DISCORD_BOT_TOKEN = "",
    DISCORD_CHANNEL_ID = "",
    DISCORD_PREFIX = "!scan",
    DISCORD_POLL = 5,
    DISCORD_REPLY_WEBHOOK = "",
}

local FILE_CFG = "market_scanner_cfg.json"
local FILE_WL = "market_scanner_whitelist.json"

local function safeWrite(f, d) if writefile then pcall(writefile, f, d) end end
local function safeRead(f)
    if isfile and readfile and isfile(f) then
        local ok, d = pcall(readfile, f)
        if ok then return d end
    end
    return nil
end
local function saveCfg() safeWrite(FILE_CFG, HttpService:JSONEncode(CFG)) end
local function loadCfg()
    local d = safeRead(FILE_CFG)
    if not d then return end
    local ok, t = pcall(HttpService.JSONDecode, HttpService, d)
    if ok and type(t) == "table" then
        for k, v in pairs(t) do CFG[k] = v end
    end
end
local function saveWL(l) safeWrite(FILE_WL, HttpService:JSONEncode(l)) end
local function loadWL()
    local d = safeRead(FILE_WL)
    if not d then return {} end
    local ok, t = pcall(HttpService.JSONDecode, HttpService, d)
    if ok and type(t) == "table" then return t end
    return {}
end
loadCfg()

local REF = {
    market = nil,
    browse = nil,
    browseList = nil,
    searchBox = nil,
    typeBtn = nil,
    preview = nil,
    previewLbl = nil,
    previewList = nil,
    browseTabBtn = nil,
}

local function refreshRefs()
    local mg = PlayerGui:FindFirstChild("MainGui")
    local pn = mg and mg:FindFirstChild("Panels")
    local m = pn and pn:FindFirstChild("GlobalMarket")
    REF.market = m
    if not m then return false end
    local mn = m:FindFirstChild("Main")
    local ts = mn and mn:FindFirstChild("Tabs")
    local br = ts and ts:FindFirstChild("Browse")
    REF.browse = br
    REF.browseList = br and br:FindFirstChild("List")
    local fl = br and br:FindFirstChild("Filters")
    REF.searchBox = fl and fl:FindFirstChild("Search")
    REF.typeBtn = fl and fl:FindFirstChild("Type")
    local cards = mn and mn:FindFirstChild("Cards")
    REF.browseTabBtn = cards and cards:FindFirstChild("Browse")
    local df = m:FindFirstChild("Defer")
    local ip = df and df:FindFirstChild("ItemPreview")
    REF.preview = ip
    REF.previewLbl = ip and ip:FindFirstChild("LabelName")
    REF.previewList = ip and ip:FindFirstChild("List")
    return true
end

local function fireSignals(btn)
    if not btn then return end
    if firesignal then
        pcall(firesignal, btn.MouseButton1Down)
        pcall(firesignal, btn.MouseButton1Up)
        pcall(firesignal, btn.MouseButton1Click)
        pcall(firesignal, btn.Activated)
    else
        pcall(function() btn.MouseButton1Down:Fire() end)
        pcall(function() btn.MouseButton1Up:Fire() end)
        pcall(function() btn.MouseButton1Click:Fire() end)
        pcall(function() btn.Activated:Fire() end)
    end
    pcall(function() btn:Activate() end)
end

local function realClick(btn)
    if not btn then return end
    local pos = btn.AbsolutePosition
    local size = btn.AbsoluteSize
    if size.X < 1 or size.Y < 1 then return end
    local x = pos.X + size.X / 2
    local y = pos.Y + size.Y / 2
    pcall(function()
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 0)
        task.wait(0.03)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
    end)
end

local function scrollToCard(frame)
    local list = REF.browseList
    if not list or not list:IsA("ScrollingFrame") then return end
    local ok = pcall(function()
        local relY = frame.AbsolutePosition.Y - list.AbsolutePosition.Y
        list.CanvasPosition = Vector2.new(0, math.max(0, list.CanvasPosition.Y + relY - 60))
    end)
    if ok then task.wait(0.08) end
end

local function normalize(s)
    return string.lower((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parsePrice(s)
    if not s then return nil end
    s = s:lower():gsub("%s", ""):gsub(",", "")
    local n = s:match("([%d%.]+)")
    if not n then return nil end
    local v = tonumber(n)
    if not v then return nil end
    if s:find("k") then v = v * 1000
    elseif s:find("m") then v = v * 1000000
    elseif s:find("b") then v = v * 1000000000 end
    return math.floor(v)
end

local function readCard(card)
    local cont = card:FindFirstChild("Container")
    if not cont then return nil end
    local p = cont:FindFirstChild("Price")
    if not p then return nil end
    local price = parsePrice(p.Text)
    if not price then return nil end
    local d = { price = price, priceText = p.Text }
    local q = cont:FindFirstChild("Quantity")
    local u = cont:FindFirstChild("Username")
    if q then d.quantity = q.Text end
    if u then d.seller = u.Text end
    return d
end

local function cardName(f)
    local c = f:FindFirstChild("Container")
    if not c then return nil end
    local l = c:FindFirstChild("Label")
    return l and l.Text or nil
end

local function findCardByName(name)
    local list = REF.browseList
    if not list then return nil end
    local target = normalize(name)
    local exact, prefix, contains = nil, nil, nil
    local prefixLen, containsLen = math.huge, math.huge

    for _, f in ipairs(list:GetChildren()) do
        if f:IsA("Frame") then
            local n = cardName(f)
            if n then
                local nn = normalize(n)
                if nn == target then
                    exact = f
                    break
                end
                if string.sub(nn, 1, #target) == target then
                    if #nn < prefixLen then
                        prefix = f
                        prefixLen = #nn
                    end
                elseif string.find(nn, target, 1, true) then
                    if #nn < containsLen then
                        contains = f
                        containsLen = #nn
                    end
                end
            end
        end
    end
    return exact or prefix or contains
end

local function scrollBrowse(delta)
    local list = REF.browseList
    if not list or not list:IsA("ScrollingFrame") then return false end
    local ok = pcall(function()
        list.CanvasPosition = Vector2.new(
            list.CanvasPosition.X,
            math.max(0, list.CanvasPosition.Y + (delta or 500)))
    end)
    if ok then task.wait(0.08) end
    return ok
end

local function findCardByScrolling(name)
    local list = REF.browseList
    if not list or not list:IsA("ScrollingFrame") then return nil end
    local saved = list.CanvasPosition
    pcall(function() list.CanvasPosition = Vector2.new(0, 0) end)
    task.wait(0.15)

    local found = findCardByName(name)
    if not found then
        local tries = 0
        while not found and tries < 30 do
            scrollBrowse(500)
            found = findCardByName(name)
            tries = tries + 1
        end
    end

    if not found then
        pcall(function() list.CanvasPosition = saved end)
    end
    return found
end

local function ensureBrowseTab()
    local mn = REF.market and REF.market:FindFirstChild("Main")
    local tabs = mn and mn:FindFirstChild("Tabs")
    if not tabs then return end
    local br = tabs:FindFirstChild("Browse")
    if br and not br.Visible then
        if REF.browseTabBtn then fireSignals(REF.browseTabBtn) end
        task.wait(0.3)
    end
end

local function setSearch(q)
    local box = REF.searchBox
    if not box then return false end
    pcall(function() box:CaptureFocus() end)
    task.wait(0.05)
    box.Text = q or ""
    pcall(function() box:ReleaseFocus() end)
    task.wait(0.05)
    if firesignal then
        pcall(firesignal, box.FocusLost, true)
    end
    return true
end

local function setTypeTo(target)
    local t = REF.typeBtn
    if not t then return false end
    target = string.upper(target)
    for _ = 1, 6 do
        if string.upper(t.Text) == target then return true end
        fireSignals(t)
        task.wait(0.15)
    end
    return string.upper(t.Text) == target
end

local function previewCount()
    local l = REF.previewList
    if not l then return 0 end
    local n = 0
    for _, c in ipairs(l:GetChildren()) do
        if c:IsA("Frame") and c:FindFirstChild("Container") then n = n + 1 end
    end
    return n
end

local function readTop()
    local l = REF.previewList
    if not l then return {} end
    local items = {}
    for _, c in ipairs(l:GetChildren()) do
        local d = readCard(c)
        if d then items[#items + 1] = d end
    end
    table.sort(items, function(a, b) return a.price < b.price end)
    local top = {}
    for i = 1, math.min(CFG.TOP_N, #items) do top[i] = items[i] end
    return top
end

local function openCard(frame, expectedName)
    local c = frame:FindFirstChild("Container")
    if not c then return nil end
    local prevName = (REF.previewLbl and REF.previewLbl.Text) or ""

    if normalize(prevName) == normalize(expectedName) and previewCount() > 0 then
        return readTop()
    end

    fireSignals(c)
    local deadline = tick() + CFG.PREVIEW_TIMEOUT
    repeat
        RunService.Heartbeat:Wait()
        local lbl = REF.previewLbl
        if lbl and lbl.Text ~= prevName and lbl.Text ~= "" then break end
    until tick() > deadline

    local changed = REF.previewLbl and REF.previewLbl.Text ~= prevName and REF.previewLbl.Text ~= ""

    if not changed then
        scrollToCard(frame)
        realClick(c)
        local deadline2 = tick() + CFG.PREVIEW_TIMEOUT
        repeat
            RunService.Heartbeat:Wait()
            local lbl = REF.previewLbl
            if lbl and lbl.Text ~= prevName and lbl.Text ~= "" then break end
        until tick() > deadline2
    end

    local finalLbl = REF.previewLbl
    if not finalLbl or finalLbl.Text == "" then
        return nil
    end

    local deadline3 = tick() + CFG.CARDS_TIMEOUT
    while previewCount() == 0 and tick() < deadline3 do
        RunService.Heartbeat:Wait()
    end

    return readTop()
end

local function httpRequest(opts)
    local req = request or http_request
        or (syn and syn.request) or (fluxus and fluxus.request)
        or (http and http.request)
    if not req then return nil end
    local ok, res = pcall(req, opts)
    if ok then return res end
    return nil
end

local function httpPost(url, body)
    if not url or url == "" then return end
    httpRequest({
        Url = url,
        Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = HttpService:JSONEncode({ content = body })
    })
end

local function discordGetMessages(token, channelID, limit)
    if not token or token == "" or not channelID or channelID == "" then return nil end
    local url = string.format(
        "https://discord.com/api/v10/channels/%s/messages?limit=%d",
        channelID, limit or 5)
    local res = httpRequest({
        Url = url,
        Method = "GET",
        Headers = {
            ["Authorization"] = "Bot " .. token,
            ["Content-Type"] = "application/json"
        }
    })
    if not res or not res.Body then return nil end
    local ok, data = pcall(HttpService.JSONDecode, HttpService, res.Body)
    if ok then return data end
    return nil
end

local lastNotifiedPrice = {}
local lastGlobalWebhook = 0

local function buildMessage(name, top)
    local lines = {}
    if CFG.PING ~= "" then table.insert(lines, CFG.PING) end
    if CFG.SEND_NAME then table.insert(lines, "**" .. name .. "**") end
    for i, d in ipairs(top) do
        local parts = { "#" .. i }
        if CFG.SEND_PRICE then parts[#parts + 1] = d.priceText or tostring(d.price) end
        if CFG.SEND_QTY then parts[#parts + 1] = d.quantity or "?" end
        if CFG.SEND_SELLER then parts[#parts + 1] = d.seller or "?" end
        table.insert(lines, table.concat(parts, " | "))
    end
    return table.concat(lines, "\n")
end

local function sendWebhook(name, top, opts)
    opts = opts or {}
    local url = opts.url or CFG.WEBHOOK_URL
    if url == "" or #top == 0 then return end
    if CFG.ONLY_IF_PRICE_BELOW > 0 and top[1].price > CFG.ONLY_IF_PRICE_BELOW then return end

    local key = normalize(name)
    local newPrice = top[1].price

    if CFG.WEBHOOK_PRICE_CHANGE_ONLY then
        local prev = lastNotifiedPrice[key]
        if prev ~= nil and prev == newPrice then
            return
        end
    end

    if CFG.WEBHOOK_CD_ENABLED and not opts.force then
        local now = tick()
        if CFG.WEBHOOK_GLOBAL_CD > 0 and now - lastGlobalWebhook < CFG.WEBHOOK_GLOBAL_CD then
            return
        end
    end

    lastNotifiedPrice[key] = newPrice
    if not opts.force then
        lastGlobalWebhook = tick()
    end
    httpPost(url, buildMessage(name, top))
end

local ACCENT = Color3.fromRGB(120, 90, 220)
local BG = Color3.fromRGB(24, 24, 30)
local BG2 = Color3.fromRGB(32, 32, 40)
local TXT = Color3.fromRGB(230, 230, 235)
local SUB = Color3.fromRGB(150, 150, 160)

local screen = Instance.new("ScreenGui")
screen.Name = "MarketScanner"
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.IgnoreGuiInset = true
screen.Parent = PlayerGui

local root = Instance.new("Frame")
root.Size = UDim2.new(0, 560, 0, 460)
root.Position = UDim2.new(0, 24, 0, 60)
root.BackgroundColor3 = BG
root.BorderSizePixel = 0
root.Parent = screen
Instance.new("UICorner", root).CornerRadius = UDim.new(0, 10)
do
    local s = Instance.new("UIStroke", root)
    s.Color = Color3.fromRGB(60, 60, 75)
    s.Thickness = 1
end

local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 36)
header.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
header.BorderSizePixel = 0
header.Parent = root
do
    local c = Instance.new("UICorner", header)
    c.CornerRadius = UDim.new(0, 10)
end
do
    local fx = Instance.new("Frame")
    fx.Size = UDim2.new(1, 0, 0, 12)
    fx.Position = UDim2.new(0, 0, 1, -12)
    fx.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
    fx.BorderSizePixel = 0
    fx.Parent = header
end

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -100, 1, 0)
titleLbl.Position = UDim2.new(0, 14, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "Market Scanner"
titleLbl.TextColor3 = TXT
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 15
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = header

local function tinyBtn(txt, x, color)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 26, 0, 22)
    b.Position = UDim2.new(1, x, 0, 7)
    b.BackgroundColor3 = color
    b.Text = txt
    b.TextColor3 = TXT
    b.Font = Enum.Font.GothamBold
    b.TextSize = 14
    b.BorderSizePixel = 0
    b.Parent = header
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    return b
end
local btnMin = tinyBtn("-", -60, Color3.fromRGB(60, 60, 80))
local btnClose = tinyBtn("x", -30, Color3.fromRGB(150, 60, 60))

local tabsBar = Instance.new("Frame")
tabsBar.Size = UDim2.new(1, -20, 0, 30)
tabsBar.Position = UDim2.new(0, 10, 0, 42)
tabsBar.BackgroundTransparency = 1
tabsBar.Parent = root
local tabsLayout = Instance.new("UIListLayout", tabsBar)
tabsLayout.FillDirection = Enum.FillDirection.Horizontal
tabsLayout.Padding = UDim.new(0, 6)

local content = Instance.new("Frame")
content.Size = UDim2.new(1, -20, 1, -130)
content.Position = UDim2.new(0, 10, 0, 78)
content.BackgroundTransparency = 1
content.Parent = root

local statusBar = Instance.new("TextLabel")
statusBar.Size = UDim2.new(1, -20, 0, 18)
statusBar.Position = UDim2.new(0, 10, 1, -26)
statusBar.BackgroundTransparency = 1
statusBar.Text = "ready"
statusBar.TextColor3 = SUB
statusBar.Font = Enum.Font.Gotham
statusBar.TextSize = 12
statusBar.TextXAlignment = Enum.TextXAlignment.Left
statusBar.Parent = root

local lastStatusUpdate, pendingStatus = 0, nil
local function setStatus(t) pendingStatus = t end
RunService.Heartbeat:Connect(function()
    if pendingStatus and tick() - lastStatusUpdate > 0.2 then
        statusBar.Text = pendingStatus
        pendingStatus = nil
        lastStatusUpdate = tick()
    end
end)

local pages = {}
local tabBtns = {}

local function mkPage(name)
    local p = Instance.new("Frame")
    p.Size = UDim2.new(1, 0, 1, 0)
    p.BackgroundTransparency = 1
    p.Visible = false
    p.Parent = content
    pages[name] = p
    return p
end

local function setTab(name)
    for n, p in pairs(pages) do p.Visible = (n == name) end
    for n, b in pairs(tabBtns) do
        if n == name then
            b.BackgroundColor3 = ACCENT
            b.TextColor3 = Color3.fromRGB(255, 255, 255)
        else
            b.BackgroundColor3 = BG2
            b.TextColor3 = TXT
        end
    end
end

local function mkTab(name, label)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 110, 0, 30)
    b.BackgroundColor3 = BG2
    b.Text = label
    b.TextColor3 = TXT
    b.Font = Enum.Font.GothamBold
    b.TextSize = 13
    b.BorderSizePixel = 0
    b.Parent = tabsBar
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    b.MouseButton1Click:Connect(function() setTab(name) end)
    tabBtns[name] = b
end

local pScan = mkPage("scan")

local scanRow = Instance.new("Frame")
scanRow.Size = UDim2.new(1, 0, 0, 30)
scanRow.Position = UDim2.new(0, 0, 0, 0)
scanRow.BackgroundTransparency = 1
scanRow.Parent = pScan

local scanInput = Instance.new("TextBox")
scanInput.Size = UDim2.new(1, -240, 1, 0)
scanInput.BackgroundColor3 = BG2
scanInput.BorderSizePixel = 0
scanInput.Text = ""
scanInput.PlaceholderText = "item name"
scanInput.TextColor3 = TXT
scanInput.PlaceholderColor3 = SUB
scanInput.Font = Enum.Font.Gotham
scanInput.TextSize = 13
scanInput.ClearTextOnFocus = false
scanInput.Parent = scanRow
do
    local p = Instance.new("UIPadding", scanInput)
    p.PaddingLeft = UDim.new(0, 10)
end
Instance.new("UICorner", scanInput).CornerRadius = UDim.new(0, 6)

local scanBtn = Instance.new("TextButton")
scanBtn.Size = UDim2.new(0, 74, 1, 0)
scanBtn.Position = UDim2.new(1, -232, 0, 0)
scanBtn.BackgroundColor3 = ACCENT
scanBtn.Text = "Find"
scanBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
scanBtn.Font = Enum.Font.GothamBold
scanBtn.TextSize = 13
scanBtn.BorderSizePixel = 0
scanBtn.Parent = scanRow
Instance.new("UICorner", scanBtn).CornerRadius = UDim.new(0, 6)

local typeAllBtn = Instance.new("TextButton")
typeAllBtn.Size = UDim2.new(0, 74, 1, 0)
typeAllBtn.Position = UDim2.new(1, -154, 0, 0)
typeAllBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 100)
typeAllBtn.Text = "Type: ALL"
typeAllBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
typeAllBtn.Font = Enum.Font.GothamBold
typeAllBtn.TextSize = 11
typeAllBtn.BorderSizePixel = 0
typeAllBtn.Parent = scanRow
Instance.new("UICorner", typeAllBtn).CornerRadius = UDim.new(0, 6)

local wlScanBtn = Instance.new("TextButton")
wlScanBtn.Size = UDim2.new(0, 74, 1, 0)
wlScanBtn.Position = UDim2.new(1, -74, 0, 0)
wlScanBtn.BackgroundColor3 = Color3.fromRGB(50, 120, 80)
wlScanBtn.Text = "List"
wlScanBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
wlScanBtn.Font = Enum.Font.GothamBold
wlScanBtn.TextSize = 12
wlScanBtn.BorderSizePixel = 0
wlScanBtn.Parent = scanRow
Instance.new("UICorner", wlScanBtn).CornerRadius = UDim.new(0, 6)

local results = Instance.new("ScrollingFrame")
results.Size = UDim2.new(1, 0, 1, -40)
results.Position = UDim2.new(0, 0, 0, 40)
results.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
results.BorderSizePixel = 0
results.ScrollBarThickness = 4
results.CanvasSize = UDim2.new(0, 0, 0, 0)
results.AutomaticCanvasSize = Enum.AutomaticSize.Y
results.Parent = pScan
Instance.new("UICorner", results).CornerRadius = UDim.new(0, 8)

local resultsLabel = Instance.new("TextLabel")
resultsLabel.Size = UDim2.new(1, -12, 0, 0)
resultsLabel.Position = UDim2.new(0, 6, 0, 6)
resultsLabel.BackgroundTransparency = 1
resultsLabel.AutomaticSize = Enum.AutomaticSize.Y
resultsLabel.RichText = true
resultsLabel.TextWrapped = true
resultsLabel.Text = ""
resultsLabel.TextColor3 = Color3.fromRGB(210, 210, 220)
resultsLabel.TextXAlignment = Enum.TextXAlignment.Left
resultsLabel.TextYAlignment = Enum.TextYAlignment.Top
resultsLabel.Font = Enum.Font.Gotham
resultsLabel.TextSize = 12
resultsLabel.Parent = results

local resultLines = {}
local lastResultsUpdate = 0
local dirtyResults = false

local function appendResult(name, top)
    if #top == 0 then
        table.insert(resultLines,
            '<font color="#bbaaff"><b>' .. name .. '</b></font>  <font color="#888">no listings</font>')
    else
        table.insert(resultLines, '<font color="#bbaaff"><b>' .. name .. '</b></font>')
        for i, d in ipairs(top) do
            table.insert(resultLines, string.format(
                '   <font color="#e0e0e8">#%d</font>  %s  |  %s  |  %s',
                i, d.priceText or tostring(d.price), d.quantity or "?", d.seller or "?"))
        end
    end
    dirtyResults = true
end

RunService.Heartbeat:Connect(function()
    if dirtyResults and tick() - lastResultsUpdate > 0.25 then
        resultsLabel.Text = table.concat(resultLines, "\n")
        lastResultsUpdate = tick()
        dirtyResults = false
    end
end)

local pWL = mkPage("wl")

local wlInput = Instance.new("TextBox")
wlInput.Size = UDim2.new(1, -230, 0, 30)
wlInput.Position = UDim2.new(0, 0, 0, 0)
wlInput.BackgroundColor3 = BG2
wlInput.BorderSizePixel = 0
wlInput.Text = ""
wlInput.PlaceholderText = "magnetite, iron, candy bag"
wlInput.TextColor3 = TXT
wlInput.PlaceholderColor3 = SUB
wlInput.Font = Enum.Font.Gotham
wlInput.TextSize = 13
wlInput.ClearTextOnFocus = false
wlInput.Parent = pWL
do
    local p = Instance.new("UIPadding", wlInput)
    p.PaddingLeft = UDim.new(0, 10)
end
Instance.new("UICorner", wlInput).CornerRadius = UDim.new(0, 6)

local wlAdd = Instance.new("TextButton")
wlAdd.Size = UDim2.new(0, 100, 0, 30)
wlAdd.Position = UDim2.new(1, -220, 0, 0)
wlAdd.BackgroundColor3 = BG2
wlAdd.Text = "Add"
wlAdd.TextColor3 = TXT
wlAdd.Font = Enum.Font.GothamBold
wlAdd.TextSize = 13
wlAdd.BorderSizePixel = 0
wlAdd.Parent = pWL
Instance.new("UICorner", wlAdd).CornerRadius = UDim.new(0, 6)

local wlScanNow = Instance.new("TextButton")
wlScanNow.Size = UDim2.new(0, 116, 0, 30)
wlScanNow.Position = UDim2.new(1, -116, 0, 0)
wlScanNow.BackgroundColor3 = ACCENT
wlScanNow.Text = "Scan List"
wlScanNow.TextColor3 = Color3.fromRGB(255, 255, 255)
wlScanNow.Font = Enum.Font.GothamBold
wlScanNow.TextSize = 13
wlScanNow.BorderSizePixel = 0
wlScanNow.Parent = pWL
Instance.new("UICorner", wlScanNow).CornerRadius = UDim.new(0, 6)

local wlScroll = Instance.new("ScrollingFrame")
wlScroll.Size = UDim2.new(1, 0, 1, -40)
wlScroll.Position = UDim2.new(0, 0, 0, 40)
wlScroll.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
wlScroll.BorderSizePixel = 0
wlScroll.ScrollBarThickness = 4
wlScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
wlScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
wlScroll.Parent = pWL
Instance.new("UICorner", wlScroll).CornerRadius = UDim.new(0, 8)
local wll = Instance.new("UIListLayout", wlScroll)
wll.Padding = UDim.new(0, 4)
local wlp = Instance.new("UIPadding", wlScroll)
wlp.PaddingTop = UDim.new(0, 6)
wlp.PaddingBottom = UDim.new(0, 6)
wlp.PaddingLeft = UDim.new(0, 6)
wlp.PaddingRight = UDim.new(0, 6)

local whitelist = loadWL()

local function parseWhitelistInput(raw)
    local out = {}
    if not raw or raw == "" then return out end
    for piece in string.gmatch(raw, "([^,]+)") do
        local trimmed = piece:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then out[#out + 1] = trimmed end
    end
    return out
end

local function alreadyInWhitelist(name)
    local lower = normalize(name)
    for _, n in ipairs(whitelist) do
        if normalize(n) == lower then return true end
    end
    return false
end

local function refreshWL()
    for _, c in ipairs(wlScroll:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    for i, name in ipairs(whitelist) do
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, -12, 0, 30)
        row.BackgroundColor3 = BG2
        row.BorderSizePixel = 0
        row.Parent = wlScroll
        Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

        local nl = Instance.new("TextLabel")
        nl.Size = UDim2.new(1, -40, 1, 0)
        nl.Position = UDim2.new(0, 10, 0, 0)
        nl.BackgroundTransparency = 1
        nl.Text = name
        nl.TextColor3 = TXT
        nl.Font = Enum.Font.Gotham
        nl.TextSize = 13
        nl.TextXAlignment = Enum.TextXAlignment.Left
        nl.Parent = row

        local del = Instance.new("TextButton")
        del.Size = UDim2.new(0, 26, 0, 22)
        del.Position = UDim2.new(1, -32, 0, 4)
        del.BackgroundColor3 = Color3.fromRGB(150, 60, 60)
        del.Text = "x"
        del.TextColor3 = Color3.fromRGB(255, 255, 255)
        del.Font = Enum.Font.GothamBold
        del.TextSize = 14
        del.BorderSizePixel = 0
        del.Parent = row
        Instance.new("UICorner", del).CornerRadius = UDim.new(0, 6)

        del.MouseButton1Click:Connect(function()
            table.remove(whitelist, i)
            saveWL(whitelist)
            refreshWL()
            setStatus("removed: " .. name)
        end)
    end
end

wlAdd.MouseButton1Click:Connect(function()
    local items = parseWhitelistInput(wlInput.Text)
    if #items == 0 then setStatus("enter at least one item"); return end
    local added = 0
    for _, name in ipairs(items) do
        if not alreadyInWhitelist(name) then
            table.insert(whitelist, name)
            added = added + 1
        end
    end
    if added > 0 then
        saveWL(whitelist)
        wlInput.Text = ""
        refreshWL()
        setStatus(string.format("added %d", added))
    else
        setStatus("already in list")
    end
end)

wlInput.FocusLost:Connect(function(enter)
    if enter then wlAdd:Activate() end
end)

refreshWL()

local pSet = mkPage("set")

local setScroll = Instance.new("ScrollingFrame")
setScroll.Size = UDim2.new(1, 0, 1, 0)
setScroll.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
setScroll.BorderSizePixel = 0
setScroll.ScrollBarThickness = 4
setScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
setScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
setScroll.Parent = pSet
Instance.new("UICorner", setScroll).CornerRadius = UDim.new(0, 8)
local sl = Instance.new("UIListLayout", setScroll)
sl.Padding = UDim.new(0, 6)
local sp = Instance.new("UIPadding", setScroll)
sp.PaddingTop = UDim.new(0, 8)
sp.PaddingBottom = UDim.new(0, 8)
sp.PaddingLeft = UDim.new(0, 10)
sp.PaddingRight = UDim.new(0, 10)

local function mkHint(parent, text)
    local h = Instance.new("TextLabel")
    h.Size = UDim2.new(1, -12, 0, 26)
    h.BackgroundTransparency = 1
    h.Text = text
    h.TextColor3 = Color3.fromRGB(120, 120, 130)
    h.Font = Enum.Font.Gotham
    h.TextSize = 11
    h.TextWrapped = true
    h.TextXAlignment = Enum.TextXAlignment.Left
    h.TextYAlignment = Enum.TextYAlignment.Top
    h.Parent = parent
    return h
end

local function mkHeader(parent, text)
    local h = Instance.new("TextLabel")
    h.Size = UDim2.new(1, -12, 0, 22)
    h.BackgroundTransparency = 1
    h.Text = text
    h.TextColor3 = ACCENT
    h.Font = Enum.Font.GothamBold
    h.TextSize = 13
    h.TextXAlignment = Enum.TextXAlignment.Left
    h.Parent = parent
    return h
end

local function mkRow(parent, label, placeholder, val, onApply)
    local r = Instance.new("Frame")
    r.Size = UDim2.new(1, -12, 0, 30)
    r.BackgroundTransparency = 1
    r.Parent = parent
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(0, 160, 1, 0)
    l.BackgroundTransparency = 1
    l.Text = label
    l.TextColor3 = SUB
    l.Font = Enum.Font.Gotham
    l.TextSize = 12
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Parent = r
    local t = Instance.new("TextBox")
    t.Size = UDim2.new(1, -170, 1, 0)
    t.Position = UDim2.new(0, 170, 0, 0)
    t.BackgroundColor3 = BG2
    t.BorderSizePixel = 0
    t.Text = val or ""
    t.PlaceholderText = placeholder or ""
    t.TextColor3 = TXT
    t.PlaceholderColor3 = SUB
    t.Font = Enum.Font.Gotham
    t.TextSize = 12
    t.ClearTextOnFocus = false
    t.TextXAlignment = Enum.TextXAlignment.Left
    t.Parent = r
    do
        local p = Instance.new("UIPadding", t)
        p.PaddingLeft = UDim.new(0, 8)
    end
    Instance.new("UICorner", t).CornerRadius = UDim.new(0, 6)
    t.FocusLost:Connect(function()
        if onApply then onApply(t.Text) end
        saveCfg()
    end)
    return t
end

local function mkToggle(parent, label, val, onChange)
    local r = Instance.new("Frame")
    r.Size = UDim2.new(1, -12, 0, 26)
    r.BackgroundTransparency = 1
    r.Parent = parent
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1, -40, 1, 0)
    l.BackgroundTransparency = 1
    l.Text = label
    l.TextColor3 = TXT
    l.Font = Enum.Font.Gotham
    l.TextSize = 12
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Parent = r
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 28, 0, 20)
    b.Position = UDim2.new(1, -28, 0, 3)
    b.BackgroundColor3 = val and Color3.fromRGB(60, 180, 100) or Color3.fromRGB(80, 80, 90)
    b.Text = ""
    b.BorderSizePixel = 0
    b.Parent = r
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    local state = val
    b.MouseButton1Click:Connect(function()
        state = not state
        b.BackgroundColor3 = state and Color3.fromRGB(60, 180, 100) or Color3.fromRGB(80, 80, 90)
        onChange(state)
        saveCfg()
    end)
end

mkHeader(setScroll, "Webhook")
local whInput = mkRow(setScroll, "URL", "https://discord.com/api/...", CFG.WEBHOOK_URL,
    function(v) CFG.WEBHOOK_URL = v end)
local pingInput = mkRow(setScroll, "Ping", "<@id> or @everyone", CFG.PING,
    function(v) CFG.PING = v end)
mkHint(setScroll, "Ping is added to the start of every message.")

mkHeader(setScroll, "Cooldown")
mkToggle(setScroll, "Enable global cooldown", CFG.WEBHOOK_CD_ENABLED,
    function(v) CFG.WEBHOOK_CD_ENABLED = v end)
local globalCdIn = mkRow(setScroll, "Cooldown, s", "30", tostring(CFG.WEBHOOK_GLOBAL_CD),
    function(v) CFG.WEBHOOK_GLOBAL_CD = tonumber(v) or 0 end)
mkHint(setScroll, "Minimum seconds between any two price change messages.")

mkToggle(setScroll, "Send only when price changes", CFG.WEBHOOK_PRICE_CHANGE_ONLY,
    function(v) CFG.WEBHOOK_PRICE_CHANGE_ONLY = v end)
mkHint(setScroll, "If on, message is sent only when the cheapest price for that item is different from the last notified price.")

mkHeader(setScroll, "Auto rescan")
mkToggle(setScroll, "Auto rescan every N seconds", CFG.RESCAN_ENABLED,
    function(v) CFG.RESCAN_ENABLED = v end)
local rescanIn = mkRow(setScroll, "Rescan interval, s", "60", tostring(CFG.RESCAN_INTERVAL),
    function(v) CFG.RESCAN_INTERVAL = tonumber(v) or 60 end)
mkHint(setScroll, "If enabled, script re-checks whitelist every N seconds.")

mkHeader(setScroll, "Filters")
local topInput = mkRow(setScroll, "Top listings to show", "3", tostring(CFG.TOP_N),
    function(v) CFG.TOP_N = tonumber(v) or 3 end)
local priceLimitIn = mkRow(setScroll, "Min price", "0 = no limit", tostring(CFG.ONLY_IF_PRICE_BELOW),
    function(v) CFG.ONLY_IF_PRICE_BELOW = tonumber(v) or 0 end)
mkHint(setScroll, "Min price 0 sends always. A number sends only when cheapest listing is below or equal.")

mkHeader(setScroll, "Message content")
mkToggle(setScroll, "Send item name", CFG.SEND_NAME, function(v) CFG.SEND_NAME = v end)
mkToggle(setScroll, "Send price", CFG.SEND_PRICE, function(v) CFG.SEND_PRICE = v end)
mkToggle(setScroll, "Send quantity", CFG.SEND_QTY, function(v) CFG.SEND_QTY = v end)
mkToggle(setScroll, "Send seller", CFG.SEND_SELLER, function(v) CFG.SEND_SELLER = v end)

mkHeader(setScroll, "Discord Commands")
mkToggle(setScroll, "Enable Discord commands", CFG.DISCORD_ENABLED,
    function(v) CFG.DISCORD_ENABLED = v end)
local tokenIn = mkRow(setScroll, "Bot token", "MTIz...", CFG.DISCORD_BOT_TOKEN,
    function(v) CFG.DISCORD_BOT_TOKEN = v end)
local channelIn = mkRow(setScroll, "Channel ID", "1234567890123456789", CFG.DISCORD_CHANNEL_ID,
    function(v) CFG.DISCORD_CHANNEL_ID = v end)
local prefixIn = mkRow(setScroll, "Command prefix", "!scan", CFG.DISCORD_PREFIX,
    function(v) CFG.DISCORD_PREFIX = v end)
local pollIn = mkRow(setScroll, "Poll interval, s", "5", tostring(CFG.DISCORD_POLL),
    function(v) CFG.DISCORD_POLL = tonumber(v) or 5 end)
local replyWhIn = mkRow(setScroll, "Reply webhook", "same as above if empty", CFG.DISCORD_REPLY_WEBHOOK,
    function(v) CFG.DISCORD_REPLY_WEBHOOK = v end)
mkHint(setScroll, "Use: prefix + item name, e.g. !scan Magnetite.")

mkHeader(setScroll, "Other")
mkToggle(setScroll, "Auto scan list on start", CFG.AUTO_SCAN_WHITELIST,
    function(v) CFG.AUTO_SCAN_WHITELIST = v end)

local openMarketBtn = Instance.new("TextButton")
openMarketBtn.Size = UDim2.new(1, -12, 0, 30)
openMarketBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 110)
openMarketBtn.Text = "Open Market"
openMarketBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
openMarketBtn.Font = Enum.Font.GothamBold
openMarketBtn.TextSize = 13
openMarketBtn.BorderSizePixel = 0
openMarketBtn.Parent = setScroll
Instance.new("UICorner", openMarketBtn).CornerRadius = UDim.new(0, 6)

local testBtn = Instance.new("TextButton")
testBtn.Size = UDim2.new(1, -12, 0, 30)
testBtn.BackgroundColor3 = Color3.fromRGB(50, 80, 130)
testBtn.Text = "Test Webhook"
testBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
testBtn.Font = Enum.Font.GothamBold
testBtn.TextSize = 13
testBtn.BorderSizePixel = 0
testBtn.Parent = setScroll
Instance.new("UICorner", testBtn).CornerRadius = UDim.new(0, 6)

local resetCdBtn = Instance.new("TextButton")
resetCdBtn.Size = UDim2.new(1, -12, 0, 30)
resetCdBtn.BackgroundColor3 = Color3.fromRGB(90, 60, 60)
resetCdBtn.Text = "Reset cooldown and price memory"
resetCdBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
resetCdBtn.Font = Enum.Font.GothamBold
resetCdBtn.TextSize = 13
resetCdBtn.BorderSizePixel = 0
resetCdBtn.Parent = setScroll
Instance.new("UICorner", resetCdBtn).CornerRadius = UDim.new(0, 6)

local function openMarket()
    if not refreshRefs() then return false end
    local m = REF.market
    if not m then return false end
    m.Visible = true
    task.wait(0.1)
    ensureBrowseTab()
    task.wait(0.2)
    return true
end

openMarketBtn.MouseButton1Click:Connect(function()
    if openMarket() then setStatus("market opened") else setStatus("market not found") end
end)

testBtn.MouseButton1Click:Connect(function()
    httpPost(CFG.WEBHOOK_URL, "test " .. os.date())
    setStatus("test sent")
end)

resetCdBtn.MouseButton1Click:Connect(function()
    lastNotifiedPrice = {}
    lastGlobalWebhook = 0
    setStatus("cooldown and price memory reset")
end)

mkTab("scan", "Scanner")
mkTab("wl", "List")
mkTab("set", "Settings")
setTab("scan")

do
    local dragging, ds, sp
    header.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1
            or inp.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            ds = inp.Position
            sp = root.Position
            inp.Changed:Connect(function()
                if inp.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    header.InputChanged:Connect(function(inp)
        if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement
            or inp.UserInputType == Enum.UserInputType.Touch) then
            local d = inp.Position - ds
            root.Position = UDim2.new(sp.X.Scale, sp.X.Offset + d.X, sp.Y.Scale, sp.Y.Offset + d.Y)
        end
    end)
end

local minimized = false
local openHeight = root.Size
btnMin.MouseButton1Click:Connect(function()
    minimized = not minimized
    if minimized then
        tabsBar.Visible = false
        content.Visible = false
        statusBar.Visible = false
        root.Size = UDim2.new(0, 560, 0, 36)
        btnMin.Text = "+"
    else
        tabsBar.Visible = true
        content.Visible = true
        statusBar.Visible = true
        root.Size = openHeight
        btnMin.Text = "-"
    end
end)
btnClose.MouseButton1Click:Connect(function() screen:Destroy() end)

local running, stopFlag = false, false

local function scanOneByName(name, silent)
    if not refreshRefs() then return nil end
    ensureBrowseTab()

    if not silent then setStatus("searching " .. name) end

    local frame = findCardByName(name)
    if not frame then
        if not silent then setStatus("scroll for " .. name) end
        frame = findCardByScrolling(name)
    end

    if not frame then
        if not silent then setStatus("type search " .. name) end
        setSearch(name)
        task.wait(CFG.SEARCH_WAIT)
        frame = findCardByName(name)
        if not frame then
            frame = findCardByScrolling(name)
        end
    end

    if not frame then
        if not silent then
            appendResult(name .. " (not found in market)", {})
        end
        return nil
    end

    local actualName = cardName(frame) or name

    if not silent then setStatus("opening " .. actualName) end

    local top = openCard(frame, actualName)
    if top == nil then
        if not silent then appendResult(actualName .. " (did not open)", {}) end
        return nil
    end

    if not silent then appendResult(actualName, top) end
    sendWebhook(actualName, top)
    return top
end

local function runSearch(q)
    if not refreshRefs() then setStatus("open market first"); return end
    scanOneByName(q, false)
    setStatus("done")
end

local function runWhitelist(opts)
    opts = opts or {}
    if not refreshRefs() then setStatus("open market first"); return end
    local total = #whitelist
    for i, name in ipairs(whitelist) do
        if stopFlag then break end
        if not opts.silent then
            setStatus(string.format("[%d/%d] %s", i, total, name))
        end
        scanOneByName(name, opts.silent)
        task.wait(0.2)
    end
    if not opts.silent then setStatus("list scan done") end
end

local function startSearch(q)
    if running then return end
    running = true
    stopFlag = false
    resultLines = {}
    dirtyResults = true
    task.spawn(function()
        pcall(runSearch, q)
        running = false
    end)
end

local function startWhitelist()
    if running then return end
    if #whitelist == 0 then setStatus("list empty"); return end
    running = true
    stopFlag = false
    resultLines = {}
    dirtyResults = true
    task.spawn(function()
        pcall(runWhitelist)
        running = false
    end)
end

local function runDiscordCommand(item)
    if running then
        httpPost(CFG.DISCORD_REPLY_WEBHOOK ~= "" and CFG.DISCORD_REPLY_WEBHOOK or CFG.WEBHOOK_URL,
            "busy, try again in a moment")
        return
    end
    running = true
    stopFlag = false
    resultLines = {}
    dirtyResults = true
    local replyURL = CFG.DISCORD_REPLY_WEBHOOK ~= "" and CFG.DISCORD_REPLY_WEBHOOK or CFG.WEBHOOK_URL
    httpPost(replyURL, "checking **" .. item .. "**")
    task.spawn(function()
        pcall(function()
            if not refreshRefs() then
                httpPost(replyURL, "market not open")
                return
            end
            local top = scanOneByName(item, true)
            if top == nil then
                httpPost(replyURL, "no data for **" .. item .. "**")
            else
                sendWebhook(item, top, { force = true })
            end
        end)
        running = false
    end)
end

scanBtn.MouseButton1Click:Connect(function()
    local q = scanInput.Text
    if q == "" then setStatus("enter a name"); return end
    startSearch(q)
end)

scanInput.FocusLost:Connect(function(enter)
    if enter and scanInput.Text ~= "" then startSearch(scanInput.Text) end
end)

typeAllBtn.MouseButton1Click:Connect(function()
    if not refreshRefs() then setStatus("open market first"); return end
    if setTypeTo("ALL") then
        setStatus("type set to ALL")
    else
        setStatus("could not change type")
    end
end)

wlScanBtn.MouseButton1Click:Connect(startWhitelist)
wlScanNow.MouseButton1Click:Connect(function()
    setTab("scan")
    startWhitelist()
end)

local lastDiscordMessageID = nil

local function pollDiscord()
    if not CFG.DISCORD_ENABLED then return end
    if CFG.DISCORD_BOT_TOKEN == "" or CFG.DISCORD_CHANNEL_ID == "" then return end

    local data = discordGetMessages(CFG.DISCORD_BOT_TOKEN, CFG.DISCORD_CHANNEL_ID, 5)
    if not data or type(data) ~= "table" then return end

    local newestID = nil
    local prefix = CFG.DISCORD_PREFIX or "!scan"

    for _, msg in ipairs(data) do
        if msg.id then
            if not newestID or tonumber(msg.id) > tonumber(newestID) then
                newestID = msg.id
            end
        end
    end

    if not lastDiscordMessageID then
        lastDiscordMessageID = newestID
        return
    end

    for i = #data, 1, -1 do
        local msg = data[i]
        if msg.id and tonumber(msg.id) > tonumber(lastDiscordMessageID) then
            if msg.content and #msg.content > 0 then
                local content = msg.content
                local lower = string.lower(content)
                local pl = string.lower(prefix)
                if string.sub(lower, 1, #pl) == pl then
                    local item = string.sub(content, #pl + 1)
                    item = item:gsub("^%s+", ""):gsub("%s+$", "")
                    if item ~= "" then
                        runDiscordCommand(item)
                    end
                end
            end
        end
    end

    if newestID then
        lastDiscordMessageID = newestID
    end
end

task.spawn(function()
    while true do
        task.wait(math.max(2, CFG.DISCORD_POLL or 5))
        pcall(pollDiscord)
    end
end)

task.spawn(function()
    while true do
        task.wait(math.max(5, CFG.RESCAN_INTERVAL or 60))
        if CFG.RESCAN_ENABLED and not running and #whitelist > 0 then
            running = true
            stopFlag = false
            pcall(function() runWhitelist({ silent = true }) end)
            running = false
        end
    end
end)

if CFG.AUTO_SCAN_WHITELIST and #whitelist > 0 then
    task.spawn(function()
        task.wait(1)
        startWhitelist()
    end)
end

setStatus("loaded. Open market and press Find")
