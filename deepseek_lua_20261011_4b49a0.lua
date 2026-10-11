--[[
    ASTER Standalone — Auto Heal + Critter Aura
    Витягнуто з hw.lua. Власний GUI, не залежить від головного ASTER-вікна.
    Потрібен executor з: buffer, getgenv, hookmetamethod (опційно), gethui (опційно)
]]

-- ============ env / runtime ============
local function getAsterEnv()
    if type(getgenv) == "function" then
        local ok, env = pcall(getgenv)
        if ok and type(env) == "table" then return env end
    end
    return _G
end
local ENV = getAsterEnv()
ENV.ASTER_SA = ENV.ASTER_SA or {}
local RT = ENV.ASTER_SA

RT.connections = RT.connections or {}
RT.sessionId = (RT.sessionId or 0) + 1
local SESSION = RT.sessionId
local function isSessionActive(s) return s == RT.sessionId end

local function trackConn(key, conn)
    local old = RT.connections[key]
    if old and old.Disconnect then pcall(function() old:Disconnect() end) end
    RT.connections[key] = conn
    return conn
end

local Players            = game:GetService("Players")
local UserInputService   = game:GetService("UserInputService")
local RunService         = game:GetService("RunService")
local TweenService       = game:GetService("TweenService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local StatsService       = game:GetService("Stats")
local plr                = Players.LocalPlayer

-- ============ settings ============
local Settings = {
    -- Heal
    AutoHealEnabled   = false,
    AutoHealType      = "AutoHeal", -- "AutoHeal" | "SwingHeal AnimationOnly"
    SmartHealEnabled  = false,
    HealCPS           = 80,
    HealThreshold     = 99,
    HealFruit         = "Bloodfruit",
    HealHeartbeat     = false,
    AutoEatEnabled    = false,
    EatThreshold      = 99,
    EatFruit          = "Bloodfruit",
    WasteFruitsEnabled = false,
    EatCapEnabled     = false,
    WasteFruit        = "Bloodfruit",
    FruitsCapAmount   = 100,

    -- Critter Aura
    CritterAuraEnabled       = false,
    CritterRange             = 15,
    CritterTargetCount       = 3,
    CritterCooldown          = 0.08,
    CritterSwingPackedMultiHit = true,
    CritterType              = "All",
    AuraLegitSwing           = false,
    TurnOnAura               = false,

    -- BehindQueenAnt
    BehindQueenAnt       = false,
    BehindQueenAntStuds  = 3,
}

-- ============ ByteNet discovery ============
local ByteNetReliable = ReplicatedStorage:FindFirstChild("ByteNetReliable")
if not ByteNetReliable then
    ByteNetReliable = ReplicatedStorage:WaitForChild("ByteNetReliable", 5)
end
if not ByteNetReliable then
    for _, v in ipairs(ReplicatedStorage:GetDescendants()) do
        if v.Name == "ByteNetReliable" and v:IsA("RemoteEvent") then
            ByteNetReliable = v
            break
        end
    end
end

-- ============ Packet IDs (live lookup from Modules.Packets) ============
local PACKET_IDS = {}

local function readPacketObjectId(packetObj)
    if type(packetObj) ~= "table" then return nil end
    for _, key in ipairs({ "id", "Id", "_id", "packetId", "packetID", "ID" }) do
        local v = packetObj[key]
        if type(v) == "number" and v == v and v > 0 then return v end
    end
    return nil
end

local function tryRequirePacketIDs(modulesFolder)
    local candidates = {}
    local byteNet = modulesFolder:FindFirstChild("ByteNet")
    if byteNet then
        local pf = byteNet:FindFirstChild("packets")
        if pf then
            table.insert(candidates, pf:FindFirstChild("packetIDs"))
            table.insert(candidates, pf:FindFirstChild("packetIds"))
            table.insert(candidates, pf:FindFirstChild("PacketIDs"))
        end
        table.insert(candidates, byteNet:FindFirstChild("packetIDs"))
        table.insert(candidates, byteNet:FindFirstChild("packetIds"))
    end
    table.insert(candidates, modulesFolder:FindFirstChild("packetIDs"))
    table.insert(candidates, modulesFolder:FindFirstChild("packetIds"))
    for _, inst in ipairs(candidates) do
        if inst then
            local ok, result = pcall(require, inst)
            if ok and type(result) == "table" then return result end
        end
    end
    return nil
end

local function discoverPacketMap()
    local modules = ReplicatedStorage:FindFirstChild("Modules") or ReplicatedStorage:WaitForChild("Modules", 10)
    if not modules then return nil end
    local packetsInst = modules:FindFirstChild("Packets") or modules:WaitForChild("Packets", 10)
    if not packetsInst then return nil end
    local ok, gamePackets = pcall(require, packetsInst)
    if not ok or type(gamePackets) ~= "table" then return nil end

    local live = {}
    local packetIDs = tryRequirePacketIDs(modules)
    local resolved = {}

    local function applyId(name, id)
        if type(name) ~= "string" or name == "" then return end
        if type(id) ~= "number" or id ~= id or id <= 0 then return end
        if resolved[name] then return end
        resolved[name] = true
        live[name] = id
    end

    for name, packetObj in pairs(gamePackets) do
        local id = readPacketObjectId(packetObj)
        if id then applyId(name, id) end
    end

    if type(packetIDs) == "table" then
        for name, packetObj in pairs(gamePackets) do
            if type(packetObj) == "table" and not resolved[name] then
                for id, registeredPacket in pairs(packetIDs) do
                    if type(id) == "number" and registeredPacket == packetObj then
                        applyId(name, id); break
                    end
                end
            end
        end
        for id, registeredPacket in ipairs(packetIDs) do
            if type(registeredPacket) == "table" then
                for name, packetObj in pairs(gamePackets) do
                    if packetObj == registeredPacket then
                        applyId(name, id); break
                    end
                end
            end
        end
    end
    return live
end

local function syncPacketIDs()
    local live = discoverPacketMap()
    if live then
        for k, v in pairs(live) do PACKET_IDS[k] = v end
        return true
    end
    return false
end
syncPacketIDs()
task.spawn(function()
    while isSessionActive(SESSION) do
        task.wait(30)
        pcall(syncPacketIDs)
    end
end)

local function getPacketId(name)
    if not name or name == "" then return nil end
    local v = PACKET_IDS[name]
    if type(v) == "number" and v > 0 then return v end
    return nil
end

-- ============ Item IDs ============
local craftNameToID, craftItemIDs = {}, {}
do
    local modules = ReplicatedStorage:FindFirstChild("Modules")
    local itemIdsInst = modules and modules:FindFirstChild("ItemIDS")
    if itemIdsInst then
        local ok, ItemIDS = pcall(require, itemIdsInst)
        if ok and type(ItemIDS) == "table" then
            local isNameToID = false
            for k, v in pairs(ItemIDS) do
                if type(k) == "string" and type(v) == "number" then isNameToID = true break end
            end
            if isNameToID then
                for name, id in pairs(ItemIDS) do
                    craftNameToID[name] = id
                    craftItemIDs[id] = name
                end
            else
                for id, name in pairs(ItemIDS) do
                    craftItemIDs[id] = name
                    craftNameToID[name] = id
                end
            end
        end
    end
end

local function autoDiscoverItemID(itemName)
    if not itemName or itemName == "" then return nil end
    if type(craftNameToID) == "table" and craftNameToID[itemName] then
        return craftNameToID[itemName]
    end
    local Modules = ReplicatedStorage:FindFirstChild("Modules")
    if Modules then
        local ItemIDS = Modules:FindFirstChild("ItemIDS")
        if ItemIDS and ItemIDS:FindFirstChild(itemName) then
            local v = ItemIDS[itemName].Value
            craftNameToID[itemName] = v
            craftItemIDs[v] = itemName
            return v
        end
    end
    return nil
end

local function getlayout(name)
    if not name or name == "" then return nil end
    local mainGui = plr.PlayerGui:FindFirstChild("MainGui")
    if not mainGui then return nil end
    local right = mainGui:FindFirstChild("RightPanel")
    local inv = right and right:FindFirstChild("Inventory")
    local list = inv and inv:FindFirstChild("List")
    if not list then return nil end
    local lower = tostring(name):lower():match("^%s*(.-)%s*$")
    if lower == "" then return nil end
    for _, child in ipairs(list:GetChildren()) do
        if child:IsA("GuiObject") then
            local cn = tostring(child.Name):lower():match("^%s*(.-)%s*$")
            if cn == lower then return child.LayoutOrder end
        end
    end
    return nil
end

-- ============ CFrame writer + SwingTool ============
local function write18ByteCFrame(b, offset, cf)
    local pos = cf.Position
    local _, _, _, R00, R01, R02, R10, R11, R12, R20, R21, R22 = cf:GetComponents()
    local qx, qy, qz, qw
    local tr = R00 + R11 + R22
    if tr > 0 then
        local S = math.sqrt(tr + 1.0) * 2
        qw = 0.25 * S; qx = (R21 - R12) / S; qy = (R02 - R20) / S; qz = (R10 - R01) / S
    elseif (R00 > R11) and (R00 > R22) then
        local S = math.sqrt(1.0 + R00 - R11 - R22) * 2
        qw = (R21 - R12) / S; qx = 0.25 * S; qy = (R01 + R10) / S; qz = (R02 + R20) / S
    elseif R11 > R22 then
        local S = math.sqrt(1.0 + R11 - R00 - R22) * 2
        qw = (R02 - R20) / S; qx = (R01 + R10) / S; qy = 0.25 * S; qz = (R12 + R21) / S
    else
        local S = math.sqrt(1.0 + R22 - R00 - R11) * 2
        qw = (R10 - R01) / S; qx = (R02 + R20) / S; qy = (R12 + R21) / S; qz = 0.25 * S
    end
    local len = math.sqrt(qx*qx + qy*qy + qz*qz + qw*qw)
    qx, qy, qz, qw = qx/len, qy/len, qz/len, qw/len
    if qw < 0 then qx, qy, qz, qw = -qx, -qy, -qz, -qw end
    buffer.writef32(b, offset, pos.X)
    buffer.writef32(b, offset + 4, pos.Y)
    buffer.writef32(b, offset + 8, pos.Z)
    buffer.writei16(b, offset + 12, math.clamp(qx * 32767, -32768, 32767))
    buffer.writei16(b, offset + 14, math.clamp(qy * 32767, -32768, 32767))
    buffer.writei16(b, offset + 16, math.clamp(qz * 32767, -32768, 32767))
end

local function fireByteNetSwingTool(targetEntries, hrp, opts)
    opts = opts or {}
    if not targetEntries or #targetEntries == 0 or not ByteNetReliable or not hrp then return end
    local clean = {}
    for _, t in ipairs(targetEntries) do
        local id = math.floor(tonumber(t and t.eid) or 0)
        if id > 0 then table.insert(clean, { eid = id, pos = t.pos }) end
    end
    if #clean == 0 then return end
    targetEntries = clean

    local swingId = getPacketId("SwingTool")
    if not swingId then return end

    local function cframeForBatch(batch, fromPos)
        if #batch == 1 then
            local tp = batch[1].pos
            if typeof(tp) == "Vector3" and (tp - fromPos).Magnitude > 0.01 then
                return CFrame.lookAt(fromPos, tp)
            end
            return hrp.CFrame
        end
        local sum, n = Vector3.zero, 0
        for _, t in ipairs(batch) do
            if typeof(t.pos) == "Vector3" then sum = sum + t.pos; n = n + 1 end
        end
        if n > 0 then
            local center = sum / n
            if (center - fromPos).Magnitude > 0.01 then
                return CFrame.lookAt(fromPos, center)
            end
        end
        return hrp.CFrame
    end

    local maxPerPacket = math.clamp(opts.maxPerPacket or 32, 1, 64)
    local timeStep = opts.timeStep or 0.01
    local baseTime = opts.baseTime or (time() - timeStep)
    local pktIdx = 0

    for startIdx = 1, #targetEntries, maxPerPacket do
        if pktIdx > 0 then RunService.Heartbeat:Wait() end
        pktIdx = pktIdx + 1
        local batch = {}
        for i = startIdx, math.min(startIdx + maxPerPacket - 1, #targetEntries) do
            table.insert(batch, targetEntries[i])
        end
        local n = #batch
        local fromPos = hrp.Position + Vector3.new(0, 1.5, 0)
        local cf = cframeForBatch(batch, fromPos)
        local b = buffer.create(30 + 5 * n)
        buffer.writeu8(b, 0, 0)
        buffer.writeu8(b, 1, swingId)
        write18ByteCFrame(b, 2, cf)
        buffer.writeu16(b, 20, n)
        local o = 22
        for _, t in ipairs(batch) do
            buffer.writeu8(b, o, 0)
            buffer.writeu32(b, o + 1, math.floor(tonumber(t.eid) or 0))
            o = o + 5
        end
        buffer.writef64(b, o, baseTime + (pktIdx * timeStep))
        ByteNetReliable:FireServer(b)
    end
end

local function fireByteNetSwingToolPackedMultiHit(targetEntries, hrp, opts)
    opts = opts or {}
    if not targetEntries or #targetEntries == 0 or not hrp then return end
    local seen, clean = {}, {}
    local maxN = math.clamp(opts.maxTargets or 9, 1, 9)
    for _, t in ipairs(targetEntries) do
        local id = math.floor(tonumber(t and t.eid) or 0)
        if id > 0 and not seen[id] then
            seen[id] = true
            table.insert(clean, t)
            if #clean >= maxN then break end
        end
    end
    if #clean == 0 then return end
    fireByteNetSwingTool(clean, hrp, { maxPerPacket = maxN })
end

-- ============ Critter helpers ============
local CritterNames = {
    "Baby Sand Mammoth", "Bantae", "Banto", "Barbarian", "Big Stone Shelly", "Black Ant",
    "Crystal Bantae", "Fire Ant", "Giant", "Giant Shelly", "Gold Shelly", "Golden Banto",
    "Goldy Boi", "Goober", "Huge Ant", "Iron Shelly", "Lil Banto", "Lurky Boi",
    "Peeper", "Penguin", "Queen Ant", "Queen Ant's Servant", "Rentae", "Rento",
    "Sand Mammoth", "Scavenger Ant", "Shelbert", "Shelby", "Sheldon", "Shellington",
    "Shelly Spirit", "Snow Mammoth", "Stone Shelly", "Turtle", "White Ant"
}
local ValidCritters = {}
for _, n in ipairs(CritterNames) do ValidCritters[n] = true end
local CritterIDCache = setmetatable({}, { __mode = "k" })

local function getWorkspaceCritters()
    local cached = RT.crittersFolder
    if cached and cached.Parent then return cached end
    local f = workspace:FindFirstChild("Critters") or workspace:WaitForChild("Critters", 2)
    if f then RT.crittersFolder = f end
    return f
end

local function isCritterInstance(inst) return inst and (inst:IsA("Model") or inst:IsA("BasePart")) end

local function getCritterModel(inst)
    if not inst then return nil end
    if inst:IsA("Model") then return inst end
    if inst:IsA("BasePart") then
        local p = inst.Parent
        if p and p:IsA("Model") then return p end
    end
    return nil
end

local function getCritterPart(inst)
    if not inst then return nil end
    if inst:IsA("BasePart") then return inst end
    if inst:IsA("Model") then
        return inst.PrimaryPart
            or inst:FindFirstChild("HumanoidRootPart")
            or inst:FindFirstChild("Head")
            or inst:FindFirstChildWhichIsA("BasePart", true)
    end
    return nil
end

local function getCritterName(inst)
    local m = getCritterModel(inst)
    return m and m.Name or (inst and inst.Name or "")
end

local function isCritterAlive(inst)
    if not inst or not inst.Parent then return false end
    local folder = getWorkspaceCritters()
    if folder and not inst:IsDescendantOf(folder) then return false end
    local model = getCritterModel(inst) or (inst:IsA("Model") and inst or nil)
    if model then
        local hum = model:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health <= 0 then return false end
    end
    local part = getCritterPart(inst)
    if not part or not part.Parent then return false end
    if part.Size.Magnitude < 0.01 then return false end
    return true
end

local function forEachCritter(folder, fn)
    if not folder or type(fn) ~= "function" then return end
    local function walk(node)
        for _, child in ipairs(node:GetChildren()) do
            if isCritterInstance(child) then fn(child)
            elseif child:IsA("Folder") then walk(child) end
        end
    end
    walk(folder)
end

local function collectCritters(folder)
    folder = folder or getWorkspaceCritters()
    local out = {}
    if not folder then return out end
    forEachCritter(folder, function(c) table.insert(out, c) end)
    return out
end

local function critterNameMatchesFilter(modelName, filterText, allToken)
    if not modelName then return false end
    filterText = tostring(filterText or allToken or "")
    local f = string.lower(filterText):match("^%s*(.-)%s*$")
    if f == "" or f == "all" then return true end
    local token = string.lower(tostring(allToken or ""))
    if token ~= "" and f == token then return true end
    if string.sub(f, 1, 3) == "all" then return true end
    local nl = string.lower(modelName)
    if nl == f then return true end
    if string.find(nl, f, 1, true) then return true end
    return false
end

local function getCritterNameList()
    local names, seen = { "All" }, { All = true }
    local folder = getWorkspaceCritters()
    if folder then
        forEachCritter(folder, function(c)
            local n = getCritterName(c)
            if n and n ~= "" and not seen[n] then seen[n] = true; table.insert(names, n) end
        end)
        for _, child in ipairs(folder:GetChildren()) do
            if child:IsA("Folder") then
                local n = child.Name
                if n and n ~= "" and not seen[n] then seen[n] = true; table.insert(names, n) end
            end
        end
    end
    return names
end

local function getEntityID(inst, cache, minId)
    if not inst then return nil end
    if cache[inst] then return cache[inst] end
    minId = tonumber(minId) or 0
    for _, key in ipairs({ "EntityID", "NetworkId", "networkId", "NetworkID", "ID", "Id", "Eid", "EntityId" }) do
        local v = inst:GetAttribute(key)
        if v ~= nil then
            local n = math.floor(tonumber(v) or 0)
            if n > 0 then cache[inst] = n; return n end
        end
    end
    for name, value in pairs(inst:GetAttributes()) do
        if typeof(value) == "number" then
            local ln = string.lower(tostring(name))
            if value > minId and (ln:find("network") or ln == "id" or ln:find("entity") or ln == "eid") then
                local n = math.floor(value)
                if n > 0 then cache[inst] = n; return n end
            end
        end
    end
    for _, childName in ipairs({ "EntityID", "NetworkId", "ID" }) do
        local val = inst:FindFirstChild(childName)
        if val and (val:IsA("IntValue") or val:IsA("NumberValue")) then
            local n = math.floor(tonumber(val.Value) or 0)
            if n > minId then cache[inst] = n; return n end
        end
    end
    local val = inst:FindFirstChildWhichIsA("IntValue") or inst:FindFirstChildWhichIsA("NumberValue")
    if val and typeof(val.Value) == "number" and val.Value > minId then
        local n = math.floor(val.Value)
        cache[inst] = n; return n
    end
    return nil
end

local function getCritterAuraID(model)
    if CritterIDCache[model] then return CritterIDCache[model] end
    if not ValidCritters[model.Name] then return nil end
    return getEntityID(model, CritterIDCache, 1000)
end

-- ============ GUI (власний, компактний) ============
local Theme = {
    bg      = Color3.fromRGB(16, 16, 16),
    panel   = Color3.fromRGB(22, 22, 22),
    card    = Color3.fromRGB(28, 28, 28),
    control = Color3.fromRGB(38, 38, 38),
    stroke  = Color3.fromRGB(60, 60, 60),
    text    = Color3.fromRGB(255, 255, 255),
    muted   = Color3.fromRGB(170, 170, 170),
    accent  = Color3.fromRGB(170, 100, 255),
}

local function makeDraggable(frame, handle)
    local dragging, dragStart, startPos
    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, input.Position, frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
                                       startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "ASTER_SA_HealAura"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function()
    if type(gethui) == "function" then
        local ok, h = pcall(gethui)
        if ok and h then screenGui.Parent = h return end
    end
    screenGui.Parent = plr:WaitForChild("PlayerGui")
end)

local main = Instance.new("Frame", screenGui)
main.Name = "Main"
main.Size = UDim2.fromOffset(380, 470)
main.Position = UDim2.new(0.5, -190, 0.5, -235)
main.BackgroundColor3 = Theme.bg
main.BorderSizePixel = 0
main.ClipsDescendants = true
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 12)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Theme.stroke; mainStroke.Thickness = 1; mainStroke.Transparency = 0.3

-- header
local header = Instance.new("Frame", main)
header.Size = UDim2.new(1, 0, 0, 40)
header.BackgroundColor3 = Theme.panel
header.BorderSizePixel = 0
Instance.new("UICorner", header).CornerRadius = UDim.new(0, 12)
local headerMask = Instance.new("Frame", header)
headerMask.Size = UDim2.new(1, 0, 0, 14)
headerMask.Position = UDim2.new(0, 0, 1, -14)
headerMask.BackgroundColor3 = Theme.panel
headerMask.BorderSizePixel = 0

local title = Instance.new("TextLabel", header)
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(14, 0)
title.Size = UDim2.new(1, -120, 1, 0)
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextColor3 = Theme.text
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "ASTER · Heal & Aura"

local closeBtn = Instance.new("TextButton", header)
closeBtn.Size = UDim2.fromOffset(26, 26)
closeBtn.Position = UDim2.new(1, -32, 0.5, -13)
closeBtn.BackgroundColor3 = Theme.control
closeBtn.Text = "x"
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 14
closeBtn.TextColor3 = Theme.text
closeBtn.BorderSizePixel = 0
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
closeBtn.MouseButton1Click:Connect(function() screenGui.Enabled = false end)

-- launcher
local openBtn = Instance.new("TextButton", screenGui)
openBtn.Size = UDim2.fromOffset(46, 46)
openBtn.Position = UDim2.new(0, 14, 0.5, -23)
openBtn.BackgroundColor3 = Theme.panel
openBtn.Text = "A"
openBtn.Font = Enum.Font.GothamBold
openBtn.TextSize = 18
openBtn.TextColor3 = Theme.accent
openBtn.BorderSizePixel = 0
Instance.new("UICorner", openBtn).CornerRadius = UDim.new(0, 10)
local openStroke = Instance.new("UIStroke", openBtn)
openStroke.Color = Theme.accent; openStroke.Thickness = 1.5
openBtn.MouseButton1Click:Connect(function() screenGui.Enabled = true end)

makeDraggable(main, header)
makeDraggable(openBtn, openBtn)

-- tabs
local tabBar = Instance.new("Frame", main)
tabBar.Size = UDim2.new(1, -20, 0, 32)
tabBar.Position = UDim2.fromOffset(10, 48)
tabBar.BackgroundTransparency = 1
local tabList = Instance.new("UIListLayout", tabBar)
tabList.FillDirection = Enum.FillDirection.Horizontal
tabList.Padding = UDim.new(0, 6)

local pages = Instance.new("Frame", main)
pages.Size = UDim2.new(1, -20, 1, -92)
pages.Position = UDim2.fromOffset(10, 86)
pages.BackgroundTransparency = 1
pages.ClipsDescendants = true

local function createPage(name)
    local btn = Instance.new("TextButton", tabBar)
    btn.Size = UDim2.new(0, 130, 1, 0)
    btn.BackgroundColor3 = Theme.control
    btn.Text = name
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 13
    btn.TextColor3 = Theme.muted
    btn.BorderSizePixel = 0
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)

    local page = Instance.new("ScrollingFrame", pages)
    page.Size = UDim2.fromScale(1, 1)
    page.BackgroundTransparency = 1
    page.BorderSizePixel = 0
    page.ScrollBarThickness = 3
    page.ScrollBarImageColor3 = Theme.accent
    page.CanvasSize = UDim2.new(0, 0, 0, 0)
    page.AutomaticCanvasSize = Enum.AutomaticSize.Y
    page.Visible = false
    local pad = Instance.new("UIPadding", page)
    pad.PaddingTop = UDim.new(0, 4)
    pad.PaddingBottom = UDim.new(0, 12)
    local list = Instance.new("UIListLayout", page)
    list.Padding = UDim.new(0, 6)

    local function activate()
        for _, p in ipairs(pages:GetChildren()) do
            if p:IsA("ScrollingFrame") then p.Visible = false end
        end
        page.Visible = true
        for _, c in ipairs(tabBar:GetChildren()) do
            if c:IsA("TextButton") then
                c.BackgroundColor3 = (c == btn) and Theme.accent or Theme.control
                c.TextColor3 = (c == btn) and Color3.new(1, 1, 1) or Theme.muted
            end
        end
    end
    btn.MouseButton1Click:Connect(activate)
    return page, activate
end

-- controls
local function addLabel(page, text)
    local l = Instance.new("TextLabel", page)
    l.Size = UDim2.new(1, -2, 0, 22)
    l.BackgroundTransparency = 1
    l.Font = Enum.Font.GothamBold
    l.TextSize = 13
    l.TextColor3 = Theme.text
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = "  " .. text
    return l
end

local function addToggle(page, text, default, callback)
    local row = Instance.new("Frame", page)
    row.Size = UDim2.new(1, -2, 0, 42)
    row.BackgroundColor3 = Theme.card
    row.BorderSizePixel = 0
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)

    local label = Instance.new("TextLabel", row)
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(1, -70, 1, 0)
    label.Position = UDim2.fromOffset(12, 0)
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 13
    label.TextColor3 = Theme.text
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = text

    local sw = Instance.new("Frame", row)
    sw.Size = UDim2.fromOffset(40, 20)
    sw.AnchorPoint = Vector2.new(1, 0.5)
    sw.Position = UDim2.new(1, -12, 0.5, 0)
    sw.BackgroundColor3 = Theme.control
    sw.BorderSizePixel = 0
    Instance.new("UICorner", sw).CornerRadius = UDim.new(1, 0)

    local dot = Instance.new("Frame", sw)
    dot.Size = UDim2.fromOffset(14, 14)
    dot.Position = UDim2.new(0, 3, 0.5, -7)
    dot.BackgroundColor3 = Theme.text
    dot.BorderSizePixel = 0
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

    local state = default == true
    local btn = Instance.new("TextButton", row)
    btn.Size = UDim2.fromScale(1, 1)
    btn.BackgroundTransparency = 1
    btn.Text = ""
    btn.ZIndex = 5

    local function render()
        if state then
            sw.BackgroundColor3 = Theme.accent
            TweenService:Create(dot, TweenInfo.new(0.2), { Position = UDim2.new(0, 23, 0.5, -7) }):Play()
        else
            sw.BackgroundColor3 = Theme.control
            TweenService:Create(dot, TweenInfo.new(0.2), { Position = UDim2.new(0, 3, 0.5, -7) }):Play()
        end
    end
    render()
    btn.MouseButton1Click:Connect(function()
        state = not state; render()
        if callback then callback(state) end
    end)
    return {
        SetValue = function(v)
            if v ~= state then state = v == true; render(); if callback then callback(state) end end
        end,
        GetValue = function() return state end,
    }
end

local function addSlider(page, text, min, max, default, step, callback)
    step = step or 1
    local row = Instance.new("Frame", page)
    row.Size = UDim2.new(1, -2, 0, 52)
    row.BackgroundColor3 = Theme.card
    row.BorderSizePixel = 0
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)

    local label = Instance.new("TextLabel", row)
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(12, 6)
    label.Size = UDim2.new(1, -80, 0, 18)
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 12
    label.TextColor3 = Theme.text
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = text

    local valBg = Instance.new("Frame", row)
    valBg.Size = UDim2.fromOffset(60, 20)
    valBg.Position = UDim2.new(1, -72, 0, 6)
    valBg.BackgroundColor3 = Theme.control
    valBg.BorderSizePixel = 0
    Instance.new("UICorner", valBg).CornerRadius = UDim.new(0, 6)

    local val = Instance.new("TextBox", valBg)
    val.Size = UDim2.new(1, -6, 1, 0)
    val.Position = UDim2.fromOffset(3, 0)
    val.BackgroundTransparency = 1
    val.Font = Enum.Font.GothamBold
    val.TextSize = 12
    val.TextColor3 = Theme.text
    val.Text = tostring(default)
    val.ClearTextOnFocus = false

    local barBg = Instance.new("Frame", row)
    barBg.Size = UDim2.new(1, -24, 0, 8)
    barBg.Position = UDim2.new(0, 12, 1, -18)
    barBg.BackgroundColor3 = Theme.control
    barBg.BorderSizePixel = 0
    Instance.new("UICorner", barBg).CornerRadius = UDim.new(1, 0)

    local fill = Instance.new("Frame", barBg)
    fill.BackgroundColor3 = Theme.accent
    fill.BorderSizePixel = 0
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

    local current = default
    local function snap(v)
        if max == min then return min end
        return min + math.floor((v - min) / step + 0.5) * step
    end
    local function render()
        local pos = (max == min) and 0 or ((current - min) / (max - min))
        fill.Size = UDim2.fromScale(pos, 1)
        val.Text = tostring(current)
    end
    local function setValue(v, fire)
        current = snap(math.clamp(v, min, max))
        render()
        if fire and callback then callback(current) end
    end
    setValue(default, false)
    val.FocusLost:Connect(function()
        local n = tonumber(val.Text)
        if n then setValue(n, true) else render() end
    end)

    local active = false
    local function update(input)
        local pos = math.clamp((input.Position.X - barBg.AbsolutePosition.X) / barBg.AbsoluteSize.X, 0, 1)
        setValue(min + (max - min) * pos, true)
    end
    barBg.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            active = true; update(input)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if active and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            update(input)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            active = false
        end
    end)
    return { SetValue = function(v) setValue(v, true) end, GetValue = function() return current end }
end

local function addDropdown(page, text, options, default, callback)
    local row = Instance.new("Frame", page)
    row.Size = UDim2.new(1, -2, 0, 40)
    row.BackgroundColor3 = Theme.card
    row.BorderSizePixel = 0
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)

    local label = Instance.new("TextLabel", row)
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(12, 0)
    label.Size = UDim2.new(1, -40, 1, 0)
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 13
    label.TextColor3 = Theme.text
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = text .. ": " .. tostring(default)

    local arrow = Instance.new("TextLabel", row)
    arrow.BackgroundTransparency = 1
    arrow.Size = UDim2.fromOffset(20, 20)
    arrow.Position = UDim2.new(1, -26, 0.5, -10)
    arrow.Font = Enum.Font.GothamBold
    arrow.TextSize = 12
    arrow.TextColor3 = Theme.muted
    arrow.Text = "v"

    local btn = Instance.new("TextButton", row)
    btn.Size = UDim2.fromScale(1, 1)
    btn.BackgroundTransparency = 1
    btn.Text = ""

    local pop = Instance.new("Frame", screenGui)
    pop.BackgroundColor3 = Theme.panel
    pop.BorderSizePixel = 0
    pop.Visible = false
    pop.ZIndex = 50
    Instance.new("UICorner", pop).CornerRadius = UDim.new(0, 8)
    local ps = Instance.new("UIStroke", pop)
    ps.Color = Theme.stroke; ps.Thickness = 1

    local scroll = Instance.new("ScrollingFrame", pop)
    scroll.Size = UDim2.fromScale(1, 1)
    scroll.BackgroundTransparency = 1
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 3
    scroll.ScrollBarImageColor3 = Theme.accent
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    local pad = Instance.new("UIPadding", scroll)
    pad.PaddingTop = UDim.new(0, 4); pad.PaddingBottom = UDim.new(0, 4)
    local list = Instance.new("UIListLayout", scroll)
    list.Padding = UDim.new(0, 2)

    local current = default
    local function rebuild()
        for _, c in ipairs(scroll:GetChildren()) do
            if c:IsA("TextButton") then c:Destroy() end
        end
        for _, v in ipairs(options) do
            local ob = Instance.new("TextButton", scroll)
            ob.Size = UDim2.new(1, -8, 0, 26)
            ob.Position = UDim2.fromOffset(4, 0)
            ob.BackgroundColor3 = Theme.card
            ob.BackgroundTransparency = (v == current) and 0 or 1
            ob.BorderSizePixel = 0
            ob.Font = Enum.Font.Gotham
            ob.TextSize = 12
            ob.TextColor3 = (v == current) and Theme.accent or Theme.text
            ob.TextXAlignment = Enum.TextXAlignment.Left
            ob.Text = "  " .. tostring(v)
            Instance.new("UICorner", ob).CornerRadius = UDim.new(0, 5)
            ob.MouseButton1Click:Connect(function()
                current = v
                label.Text = text .. ": " .. tostring(v)
                pop.Visible = false
                rebuild()
                if callback then callback(v) end
            end)
        end
    end
    rebuild()

    local dropped = false
    local function close() dropped = false; pop.Visible = false; arrow.Text = "v" end
    btn.MouseButton1Click:Connect(function()
        if dropped then close(); return end
        dropped = true; pop.Visible = true; arrow.Text = "^"
        local a, s = row.AbsolutePosition, row.AbsoluteSize
        pop.Position = UDim2.fromOffset(a.X, a.Y + s.Y + 4)
        pop.Size = UDim2.fromOffset(s.X, math.min(#options * 28 + 8, 220))
    end)

    UserInputService.InputBegan:Connect(function(input)
        if not dropped then return end
        local t = input.UserInputType
        if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.MouseButton2
            or t == Enum.UserInputType.Touch then
            local p = input.Position
            local absp, abss = pop.AbsolutePosition, pop.AbsoluteSize
            local inPop = p.X >= absp.X and p.X <= absp.X + abss.X
                       and p.Y >= absp.Y and p.Y <= absp.Y + abss.Y
            local rp, rs = row.AbsolutePosition, row.AbsoluteSize
            local inRow = p.X >= rp.X and p.X <= rp.X + rs.X
                       and p.Y >= rp.Y and p.Y <= rp.Y + rs.Y
            if not inPop and not inRow then close() end
        end
    end)

    return {
        SetValue = function(v) current = v; label.Text = text .. ": " .. tostring(v); rebuild(); if callback then callback(v) end end,
        GetValue = function() return current end,
        SetValues = function(newOpts) options = newOpts; rebuild() end,
    }
end

-- =================== AUTO HEAL ===================
do -- Heal block
    local ALL_HEAL_FRUIT_NAMES = {
        "Apple","Banana","Barley","Berry","Bloodfruit","Bluefruit","Blossom",
        "Carrot","Cloudberry","Coconut","Corn","Cooked Meat","Frostfruit",
        "Jelly","Lemon","Mango","Oddberry","Orange","Prickly Pear","Pumpkin",
        "Strangefruit","Strawberry","Sunfruit","Watermelon",
    }
    local healFruitData = {}
    for _, name in ipairs(ALL_HEAL_FRUIT_NAMES) do
        local id = autoDiscoverItemID(name) or (craftNameToID and craftNameToID[name])
        healFruitData[name] = id or false
    end

    local SMARTHEAL_TRIGGER_PERCENT  = 65
    local SMARTHEAL_RECOVER_PERCENT  = 98
    local SMARTHEAL_CPS              = 140
    local SMARTHEAL_ACTIVE_SEC       = 7
    local SMARTHEAL_PAUSE_SEC        = 0.30

    local H = {
        gen = 0,
        running = false,
        active = false,
        conn = nil,
        healthConn = nil,
        perfConn = nil,
        smartBursting = false,
        smartCycleStart = 0,
        smoothFps = 60,
        smoothPingMs = 80,
        lastPingSample = 0,
        lastFrameClock = 0,
        lastDamageTime = 0,
        damageBurstHits = 0,
        adaptiveDelay = 0,
        noGainStreak = 0,
        pendingHealthCheck = nil,
        pendingHealthAt = 0,
        lagPauseUntil = 0,
        lastTrackedHealth = nil,
        lastHealthChangeClock = 0,
        recentHitTimes = {},
        cachedFruitName = nil,
        cachedFruitId = nil,
        cachedSlotId = nil,
        cacheRefreshAt = 0,
    }

    local function invalidateHealFruitCache()
        H.cachedFruitName = nil; H.cachedFruitId = nil; H.cachedSlotId = nil; H.cacheRefreshAt = 0
    end

    local function isSmartHealOn()
        return Settings.AutoHealEnabled == true and Settings.SmartHealEnabled == true
    end

    local function clearSmartHealRuntime()
        H.smartBursting = false; H.smartCycleStart = 0
        H.damageBurstHits = 0; H.lastDamageTime = 0
        table.clear(H.recentHitTimes)
    end

    local function startSmartHealDutyCycle()
        H.smartCycleStart = 0; H.smartBursting = false
    end

    local function readServerPingMs()
        local pingMs = nil
        pcall(function()
            local network = StatsService:FindFirstChild("Network")
            local ss = network and network:FindFirstChild("ServerStatsItem")
            local dp = ss and ss:FindFirstChild("Data Ping")
            if dp and dp.GetValue then pingMs = tonumber(dp:GetValue()) end
        end)
        if not pingMs then
            pcall(function()
                if plr.GetNetworkPing then pingMs = plr:GetNetworkPing() * 1000 end
            end)
        end
        return math.clamp(tonumber(pingMs) or H.smoothPingMs or 80, 1, 2000)
    end

    local function stopHealPerfSampler()
        if H.perfConn then pcall(function() H.perfConn:Disconnect() end); H.perfConn = nil end
        H.lastFrameClock = 0
    end

    local function startHealPerfSampler()
        if H.perfConn then return end
        H.smoothFps = 60
        H.smoothPingMs = readServerPingMs()
        H.lastFrameClock = os.clock()
        H.lastPingSample = 0
        H.perfConn = RunService.Heartbeat:Connect(function(dt)
            if not Settings.AutoHealEnabled then return end
            if typeof(dt) == "number" and dt > 0 and dt < 2 then
                local instFps = 1 / math.max(dt, 0.001)
                local alpha = (dt >= 0.1) and 0.45 or 0.15
                H.smoothFps = H.smoothFps * (1 - alpha) + instFps * alpha
                if dt >= 0.55 then
                    local now = os.clock()
                    H.lagPauseUntil = math.max(H.lagPauseUntil, now + math.clamp(dt * 0.25, 0.08, 0.22))
                end
            end
            local now = os.clock()
            if now - H.lastPingSample >= 0.25 then
                H.lastPingSample = now
                H.smoothPingMs = H.smoothPingMs * 0.7 + readServerPingMs() * 0.3
            end
            H.lastFrameClock = now
        end)
        trackConn("sa_healPerf", H.perfConn)
    end

    local function resetSmartHealState()
        H.lastTrackedHealth = nil
        H.lastDamageTime = 0
        H.damageBurstHits = 0
        H.adaptiveDelay = 0
        H.noGainStreak = 0
        H.pendingHealthCheck = nil
        H.pendingHealthAt = 0
        H.smartBursting = false
        H.smartCycleStart = 0
        H.lagPauseUntil = 0
        H.smoothFps = 60
        H.smoothPingMs = 80
        invalidateHealFruitCache()
        table.clear(H.recentHitTimes)
    end

    local function pruneHealHitTimes(now)
        local window = 0.65
        for i = #H.recentHitTimes, 1, -1 do
            if now - H.recentHitTimes[i] > window then table.remove(H.recentHitTimes, i) end
        end
        H.damageBurstHits = #H.recentHitTimes
    end

    local function registerHealDamageHit()
        local now = os.clock()
        table.insert(H.recentHitTimes, now)
        pruneHealHitTimes(now)
        H.lastDamageTime = now
        H.adaptiveDelay = math.max(0, H.adaptiveDelay * 0.45)
        H.noGainStreak = 0
        return H.damageBurstHits
    end

    local function sampleHealPerf(now)
        if now - H.lastPingSample >= 0.25 then
            H.lastPingSample = now
            H.smoothPingMs = H.smoothPingMs * 0.65 + readServerPingMs() * 0.35
        end
    end

    local function isRecentlyDamaged(now)
        now = now or os.clock()
        return (now - (H.lastDamageTime or 0)) < 1.25
    end

    local function getPingFpsHealScale(hpPercent, recentlyDamaged)
        local fps, ping = H.smoothFps, H.smoothPingMs
        local critical = (hpPercent or 100) <= 45
        local underPressure = critical or recentlyDamaged or (isSmartHealOn() and H.smartBursting)
        local fpsScale
        if fps < 8 then fpsScale = underPressure and 0.55 or 0.4
        elseif fps < 15 then fpsScale = underPressure and 0.7 or (0.55 + (fps - 8) / 7 * 0.2)
        elseif fps < 25 then fpsScale = 0.75 + (fps - 15) / 10 * 0.15
        elseif fps < 40 then fpsScale = 0.9 + (fps - 25) / 15 * 0.08
        else fpsScale = 1 end
        local pingScale
        if ping <= 90 then pingScale = 1
        elseif ping <= 140 then pingScale = 1 - (ping - 90) / 50 * 0.12
        elseif ping <= 200 then pingScale = 0.88 - (ping - 140) / 60 * 0.15
        elseif ping <= 300 then pingScale = 0.73 - (ping - 200) / 100 * 0.15
        elseif ping <= 450 then pingScale = 0.58 - (ping - 300) / 150 * 0.13
        else pingScale = underPressure and 0.45 or 0.35 end
        local floor = underPressure and 0.45 or 0.32
        return math.clamp(math.min(fpsScale, pingScale), floor, 1)
    end

    local function getSmartHealDutyCycle(now)
        now = now or os.clock()
        if H.smartCycleStart <= 0 then H.smartCycleStart = now end
        local period = SMARTHEAL_ACTIVE_SEC + SMARTHEAL_PAUSE_SEC
        local elapsed = (now - H.smartCycleStart) % period
        if elapsed < SMARTHEAL_ACTIVE_SEC then
            return true, SMARTHEAL_ACTIVE_SEC - elapsed
        end
        return false, period - elapsed
    end

    local function getEffectiveHealCPS()
        local now = os.clock()
        local lagPaused = now < H.lagPauseUntil
        local hum = plr.Character and plr.Character:FindFirstChild("Humanoid")
        local hpPercent = 100
        if hum and hum.MaxHealth > 0 then hpPercent = (hum.Health / hum.MaxHealth) * 100 end
        local recentlyDamaged = isRecentlyDamaged(now)
        local scale = getPingFpsHealScale(hpPercent, recentlyDamaged)
        local base
        if isSmartHealOn() then
            base = math.max(SMARTHEAL_CPS, math.clamp(tonumber(Settings.HealCPS) or 50, 1, 500))
        else
            base = math.clamp(tonumber(Settings.HealCPS) or 50, 1, 500)
        end
        local gainScale = 1
        if not recentlyDamaged then
            if H.noGainStreak >= 8 then gainScale = 0.45
            elseif H.noGainStreak >= 5 then gainScale = 0.65
            elseif H.noGainStreak >= 3 then gainScale = 0.85 end
        end
        local cps = base * scale * gainScale
        if lagPaused and not recentlyDamaged and hpPercent > 45 then
            cps = math.min(cps, math.max(14, base * 0.35))
        end
        local survivalFloor = 14
        if hpPercent <= 30 then survivalFloor = 28
        elseif hpPercent <= 45 then survivalFloor = 22
        elseif recentlyDamaged or (isSmartHealOn() and H.smartBursting) then survivalFloor = 18 end
        if cps < survivalFloor then cps = survivalFloor end
        return math.clamp(cps, survivalFloor, base)
    end

    local function getHealInterval()
        local cps = getEffectiveHealCPS()
        if cps <= 0 then return 0.1 end
        local delay = math.min(H.adaptiveDelay or 0, 0.08)
        return math.max((1 / cps) + delay, 0.008)
    end

    local function resolveHealFruitItemId(fruitName)
        if not fruitName or fruitName == "" then return nil end
        local cached = healFruitData[fruitName]
        if cached == false then cached = nil end
        if type(cached) == "number" and cached > 0 then return cached end
        local id = autoDiscoverItemID(fruitName)
        if id == nil and craftNameToID then id = craftNameToID[fruitName] end
        if type(id) == "number" and id > 0 then
            healFruitData[fruitName] = id
            return id
        end
        return nil
    end

    local healSwingAnimTrack, healSwingLastAnim, healSwingLastChar = nil, 0, nil
    local function playHealSwingAnimation()
        if os.clock() - healSwingLastAnim < 0.3 then return end
        healSwingLastAnim = os.clock()
        pcall(function()
            local char = plr.Character
            if not char then return end
            if char ~= healSwingLastChar then healSwingLastChar = char; healSwingAnimTrack = nil end
            local animator = char:FindFirstChild("Humanoid") and char.Humanoid:FindFirstChild("Animator")
            if animator and not healSwingAnimTrack then
                local anim = Instance.new("Animation")
                anim.AnimationId = "rbxassetid://10761451679"
                healSwingAnimTrack = animator:LoadAnimation(anim)
            end
            if healSwingAnimTrack then healSwingAnimTrack:Play() end
        end)
    end

    local function hasHealSwingTool()
        local excludedTools = {"bow","potion","sling","saddle","fishing rod","horn","shovel"}
        local function isSwingable(name)
            if not name or name == "" then return false end
            local lower = string.lower(name)
            for _, kw in ipairs(excludedTools) do
                if string.find(lower, kw, 1, true) then return false end
            end
            return true
        end
        local pf = workspace:FindFirstChild("Players")
        if pf then
            local plrFolder = pf:FindFirstChild(plr.Name)
            local tools = plrFolder and plrFolder:FindFirstChild("Tools")
            if tools then
                for _, t in ipairs(tools:GetChildren()) do
                    if isSwingable(t.Name) then return true end
                end
            end
        end
        local char = plr.Character
        if char then
            for _, c in ipairs(char:GetChildren()) do
                if c:IsA("Tool") and isSwingable(c.Name) then return true end
            end
        end
        return false
    end

    local function fireHealEquippedToolSwing()
        local hrp = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
        if not hrp or not ByteNetReliable then return end
        if not hasHealSwingTool() then return end
        pcall(function()
            local swingId = getPacketId("ClientSwing")
            if swingId then
                local b = buffer.create(2)
                buffer.writeu8(b, 0, 0)
                buffer.writeu8(b, 1, swingId)
                ByteNetReliable:FireServer(b)
            end
            playHealSwingAnimation()
            local char = plr.Character
            if char then
                for _, child in ipairs(char:GetChildren()) do
                    if child:IsA("Tool") then pcall(function() child:Activate() end); break end
                end
            end
        end)
    end

    local function getAutoHealType()
        local t = Settings.AutoHealType or "AutoHeal"
        if t == "SwingTool" then t = "SwingHeal AnimationOnly"; Settings.AutoHealType = t end
        return t
    end

    local function isHealSwingModeActive()
        if not Settings.AutoHealEnabled then return false end
        if getAutoHealType() ~= "SwingHeal AnimationOnly" then return false end
        if not hasHealSwingTool() then return false end
        local hum = plr.Character and plr.Character:FindFirstChild("Humanoid")
        if not hum or hum.Health <= 0 then return false end
        local hpPercent = (hum.Health / hum.MaxHealth) * 100
        return hpPercent <= (tonumber(Settings.HealThreshold) or 70)
    end

    local function executeHealFruit()
        local fruitName = Settings.HealFruit
        if not fruitName or fruitName == "" or not ByteNetReliable then return end
        local now = os.clock()
        local fruitID, slotID = H.cachedFruitId, H.cachedSlotId
        local fresh = H.cachedFruitName == fruitName and now < H.cacheRefreshAt
        if not fresh or not fruitID or not slotID then
            fruitID = resolveHealFruitItemId(fruitName)
            slotID = fruitID and getlayout(fruitName) or nil
            if fruitID and slotID then
                H.cachedFruitName = fruitName
                H.cachedFruitId = fruitID
                H.cachedSlotId = slotID
                H.cacheRefreshAt = now + 0.75
            else
                invalidateHealFruitCache()
                return
            end
        end
        local actionId = getPacketId("UseBagItem")
        if not actionId then return end
        local b = buffer.create(8)
        buffer.writeu8(b, 0, 0)
        buffer.writeu8(b, 1, actionId)
        buffer.writeu32(b, 2, slotID)
        buffer.writeu16(b, 6, fruitID)
        ByteNetReliable:FireServer(b)
    end

    local function executeHeal(forceSmartBurst)
        local now = os.clock()
        if now < H.lagPauseUntil then
            local hum = plr.Character and plr.Character:FindFirstChild("Humanoid")
            local critical = hum and hum.MaxHealth > 0 and (hum.Health / hum.MaxHealth) <= 0.45
            if not critical then return end
        end
        pcall(function()
            local char = plr.Character
            local humanoid = char and char:FindFirstChild("Humanoid")
            if humanoid and humanoid.Health > 0 then
                local hpPercent = (humanoid.Health / humanoid.MaxHealth) * 100
                local allow = (forceSmartBurst == true) and isSmartHealOn()
                if not allow then
                    allow = hpPercent <= (tonumber(Settings.HealThreshold) or 70)
                end
                if allow then
                    local healType = getAutoHealType()
                    if healType == "AutoHeal" or healType == "SwingHeal AnimationOnly" then
                        executeHealFruit()
                    end
                    if healType == "SwingHeal AnimationOnly" then
                        fireHealEquippedToolSwing()
                    end
                end
            end
        end)
    end

    local function bindSmartHealHealthWatch(character)
        if H.healthConn then H.healthConn:Disconnect(); H.healthConn = nil end
        local hum = character and character:FindFirstChild("Humanoid")
        if not hum then return end
        H.lastTrackedHealth = hum.Health
        H.lastHealthChangeClock = os.clock()
        H.healthConn = hum.HealthChanged:Connect(function(newHealth)
            H.lastHealthChangeClock = os.clock()
            if H.lagPauseUntil > 0 then H.lagPauseUntil = 0 end
            if not isSmartHealOn() then
                H.lastTrackedHealth = newHealth
                H.smartBursting = false
                return
            end
            if H.lastTrackedHealth and newHealth < H.lastTrackedHealth - 0.01 then
                local hitCount = registerHealDamageHit()
                if hitCount == 2 then
                    -- double hit burst
                    task.spawn(function()
                        for _ = 1, 8 do
                            if not isSmartHealOn() or not H.smartBursting then break end
                            local active = getSmartHealDutyCycle()
                            if not active then break end
                            local h = plr.Character and plr.Character:FindFirstChild("Humanoid")
                            if not h or h.Health <= 0 then break end
                            local hpPct = (h.Health / h.MaxHealth) * 100
                            if hpPct >= SMARTHEAL_RECOVER_PERCENT then break end
                            executeHeal(true)
                            task.wait(0.03)
                        end
                    end)
                end
            elseif H.lastTrackedHealth and newHealth > H.lastTrackedHealth + 0.75 then
                H.noGainStreak = 0
                H.adaptiveDelay = math.max(0, H.adaptiveDelay - 0.012)
            end
            H.lastTrackedHealth = newHealth
        end)
        trackConn("sa_healHealth", H.healthConn)
    end

    local function noteHealAttemptResult(healthBefore)
        if not healthBefore then return end
        local hum = plr.Character and plr.Character:FindFirstChild("Humanoid")
        if not hum then return end
        local after = hum.Health
        if after <= healthBefore + 0.01 then
            if isRecentlyDamaged() then return end
            H.noGainStreak = H.noGainStreak + 1
            if H.noGainStreak >= 4 then
                H.adaptiveDelay = math.min(0.12, H.adaptiveDelay + 0.008)
            end
        else
            H.noGainStreak = 0
            H.adaptiveDelay = math.max(0, H.adaptiveDelay - 0.02)
        end
    end

    local function runSmartHealTick()
        local now = os.clock()
        if H.pendingHealthCheck ~= nil then
            local waitFor = math.clamp((H.smoothPingMs or 80) / 1000 * 1.15, 0.08, 0.35)
            if (now - (H.pendingHealthAt or 0)) >= waitFor then
                noteHealAttemptResult(H.pendingHealthCheck)
                H.pendingHealthCheck = nil
                H.pendingHealthAt = 0
            end
        end
        pruneHealHitTimes(now)
        sampleHealPerf(now)

        local cps = getEffectiveHealCPS()
        if cps <= 0 then return 0.15 end

        local hum = plr.Character and plr.Character:FindFirstChild("Humanoid")
        if not hum or hum.Health <= 0 then return getHealInterval() end
        local hpPercent = (hum.Health / hum.MaxHealth) * 100
        local critical = hpPercent <= 45
        local recentlyDamaged = isRecentlyDamaged(now)

        if now < H.lagPauseUntil and not critical and not recentlyDamaged then
            return math.max(0.05, math.min(0.12, H.lagPauseUntil - now))
        end

        if isSmartHealOn() then
            if not H.smartBursting then
                if hpPercent <= SMARTHEAL_TRIGGER_PERCENT then
                    H.smartBursting = true
                    H.smartCycleStart = now
                else
                    return 0.08
                end
            elseif hpPercent >= SMARTHEAL_RECOVER_PERCENT then
                H.smartBursting = false
                H.smartCycleStart = 0
                H.pendingHealthCheck = nil
                H.pendingHealthAt = 0
                return 0.08
            end
            local cycleActive, phaseLeft = getSmartHealDutyCycle(now)
            if not cycleActive then
                H.pendingHealthCheck = nil
                H.pendingHealthAt = 0
                return math.clamp(phaseLeft, 0.05, 0.25)
            end
            if H.pendingHealthCheck == nil then
                H.pendingHealthCheck = hum.Health
                H.pendingHealthAt = now
            end
            executeHeal(true)
            return getHealInterval()
        end

        clearSmartHealRuntime()
        local threshold = tonumber(Settings.HealThreshold) or 70
        if hpPercent > threshold then
            H.noGainStreak = 0
            H.adaptiveDelay = math.max(0, H.adaptiveDelay - 0.006)
            return 0.1
        end
        if H.pendingHealthCheck == nil then
            H.pendingHealthCheck = hum.Health
            H.pendingHealthAt = now
        end
        executeHeal(false)
        return getHealInterval()
    end

    local function stopAutoHeal()
        H.gen += 1
        H.running = false
        H.active = false
        stopHealPerfSampler()
        if H.conn then H.conn:Disconnect(); H.conn = nil end
        if H.healthConn then H.healthConn:Disconnect(); H.healthConn = nil end
        resetSmartHealState()
    end

    local function startAutoHeal()
        if not Settings.AutoHealEnabled then return end
        H.gen += 1
        local gen = H.gen
        H.active = true
        H.running = true
        resetSmartHealState()
        startHealPerfSampler()
        bindSmartHealHealthWatch(plr.Character)

        if H.conn then H.conn:Disconnect(); H.conn = nil end
        if Settings.HealHeartbeat then
            local lastHeal = 0
            local pendingInterval = getHealInterval()
            H.conn = RunService.Heartbeat:Connect(function()
                if gen ~= H.gen or not Settings.AutoHealEnabled then
                    if H.conn then H.conn:Disconnect(); H.conn = nil end
                    H.active = false; H.running = false
                    stopHealPerfSampler()
                    return
                end
                if not Settings.HealHeartbeat then
                    if H.conn then H.conn:Disconnect(); H.conn = nil end
                    H.active = false; H.running = false
                    startAutoHeal()
                    return
                end
                if os.clock() - lastHeal >= pendingInterval then
                    pendingInterval = runSmartHealTick()
                    lastHeal = os.clock()
                end
            end)
        else
            task.spawn(function()
                while gen == H.gen and Settings.AutoHealEnabled do
                    local waitTime = runSmartHealTick()
                    task.wait(waitTime)
                end
                if gen == H.gen then
                    H.active = false; H.running = false
                    stopHealPerfSampler()
                end
            end)
        end
    end

    -- Auto Eat
    local autoEatActive = false
    local function startAutoEat()
        if autoEatActive then return end
        autoEatActive = true
        task.spawn(function()
            while Settings.AutoEatEnabled do
                if plr.Character and plr.Character:FindFirstChild("HumanoidRootPart") then
                    local mainGui = plr.PlayerGui:FindFirstChild("MainGui")
                    local hungerVal = 100
                    if mainGui then
                        local bars = mainGui:FindFirstChild("Panels") and mainGui.Panels:FindFirstChild("Stats") and mainGui.Panels.Stats:FindFirstChild("Bars")
                        local hungerLabel = bars and bars:FindFirstChild("Hunger") and bars.Hunger:FindFirstChild("ValueLabel")
                        if hungerLabel and hungerLabel:IsA("TextLabel") then
                            local n = tonumber(hungerLabel.Text)
                            if n then hungerVal = n end
                        end
                    end
                    if hungerVal <= (Settings.EatThreshold or 70) then
                        local fruitName = Settings.EatFruit or "Bloodfruit"
                        local fruitID = resolveHealFruitItemId(fruitName)
                        local slotID = fruitID and getlayout(fruitName) or nil
                        if fruitID and slotID then
                            local actionId = getPacketId("UseBagItem")
                            if actionId and ByteNetReliable then
                                local b = buffer.create(8)
                                buffer.writeu8(b, 0, 0)
                                buffer.writeu8(b, 1, actionId)
                                buffer.writeu32(b, 2, slotID)
                                buffer.writeu16(b, 6, fruitID)
                                ByteNetReliable:FireServer(b)
                            end
                            task.wait(1 / math.max(Settings.HealCPS or 1, 1))
                        else
                            task.wait(1)
                        end
                    else
                        task.wait(0.5)
                    end
                else
                    task.wait(1)
                end
            end
            autoEatActive = false
        end)
    end

    -- Waste Fruits
    local function eatDownToCap(fruitName, cap)
        local fruitID = resolveHealFruitItemId(fruitName)
        if not fruitID then return end
        cap = tonumber(cap) or 0
        local slotID = getlayout(fruitName)
        if not slotID then return end
        -- read count
        local mainGui = plr.PlayerGui:FindFirstChild("MainGui")
        local list = mainGui and mainGui.RightPanel and mainGui.RightPanel.Inventory and mainGui.RightPanel.Inventory.List
        local count = 0
        if list then
            local item = list:FindFirstChild(fruitName)
            if item then
                local qImg = item:FindFirstChild("QuantityImage")
                local qText = qImg and qImg:FindFirstChild("QuantityText")
                if qText then
                    local clean = qText.Text:gsub("%D", "")
                    count = tonumber(clean) or 0
                end
            end
        end
        if count > cap then
            local toEat = math.min(count - cap, 20)
            for _ = 1, toEat do
                if not (Settings.WasteFruitsEnabled or Settings.EatCapEnabled) then break end
                pcall(function()
                    local actionId = getPacketId("UseBagItem")
                    if actionId and ByteNetReliable then
                        local b = buffer.create(8)
                        buffer.writeu8(b, 0, 0)
                        buffer.writeu8(b, 1, actionId)
                        buffer.writeu32(b, 2, slotID)
                        buffer.writeu16(b, 6, fruitID)
                        ByteNetReliable:FireServer(b)
                    end
                end)
                task.wait(0.25)
            end
        end
    end

    local function startEatCap()
        task.spawn(function()
            while Settings.WasteFruitsEnabled or Settings.EatCapEnabled do
                local waste = Settings.WasteFruit or "Bloodfruit"
                local cap = tonumber(Settings.FruitsCapAmount) or 100
                eatDownToCap(waste, cap)
                task.wait(1)
            end
        end)
    end

    -- ==== Heal page UI ====
    local pageHeal = createPage("Auto Heal")
    addLabel(pageHeal, "Heal Mode")
    addDropdown(pageHeal, "AutoHealType", { "AutoHeal", "SwingHeal AnimationOnly" },
        Settings.AutoHealType, function(v) Settings.AutoHealType = v end)
    addToggle(pageHeal, "Auto Heal", false, function(v)
        Settings.AutoHealEnabled = v
        if v then startAutoHeal() else stopAutoHeal() end
    end)
    addToggle(pageHeal, "CMethod / SmartHeal", false, function(v)
        Settings.SmartHealEnabled = v == true
        resetSmartHealState()
        if v then startSmartHealDutyCycle() else clearSmartHealRuntime() end
    end)
    addDropdown(pageHeal, "Heal Fruit", ALL_HEAL_FRUIT_NAMES, "Bloodfruit", function(v)
        Settings.HealFruit = v
        invalidateHealFruitCache()
    end)
    addSlider(pageHeal, "Max Heal CPS", 1, 500, 80, 1, function(v) Settings.HealCPS = v end)
    addSlider(pageHeal, "Heal Threshold %", 1, 99, 99, 1, function(v) Settings.HealThreshold = v end)
    addToggle(pageHeal, "Heal Heartbeat", false, function(v)
        Settings.HealHeartbeat = v
        if Settings.AutoHealEnabled then startAutoHeal() end
    end)

    addLabel(pageHeal, "Auto Eat")
    addToggle(pageHeal, "Auto Eat", false, function(v)
        Settings.AutoEatEnabled = v
        if v then startAutoEat() end
    end)
    addDropdown(pageHeal, "Eat Fruit", ALL_HEAL_FRUIT_NAMES, "Bloodfruit", function(v) Settings.EatFruit = v end)
    addSlider(pageHeal, "Eat Threshold %", 1, 99, 99, 1, function(v) Settings.EatThreshold = v end)

    addLabel(pageHeal, "Waste Fruits")
    addToggle(pageHeal, "Waste Fruits", false, function(v)
        Settings.WasteFruitsEnabled = v
        Settings.EatCapEnabled = v
        if v then startEatCap() end
    end)
    addDropdown(pageHeal, "Waste Fruit", ALL_HEAL_FRUIT_NAMES, "Bloodfruit", function(v) Settings.WasteFruit = v end)
    addSlider(pageHeal, "Cap Amount", 1, 500, 100, 1, function(v)
        Settings.FruitsCapAmount = v
    end)

    RT.stopAutoHeal = stopAutoHeal
end

-- =================== CRITTER AURA ===================
do -- Critter Aura block
    local state = {
        active = false,
        cache = {},
        cacheFolder = nil,
        connAdded = nil,
        connRemoved = nil,
        scanAt = 0,
    }

    local function ensureWatcher()
        local folder = getWorkspaceCritters()
        if folder == state.cacheFolder then return end
        if state.connAdded then state.connAdded:Disconnect(); state.connAdded = nil end
        if state.connRemoved then state.connRemoved:Disconnect(); state.connRemoved = nil end
        state.cacheFolder = folder
        table.clear(state.cache)
        if folder then
            for _, c in ipairs(collectCritters(folder)) do
                table.insert(state.cache, c)
            end
            state.connAdded = folder.ChildAdded:Connect(function(child)
                if isCritterInstance(child) then
                    table.insert(state.cache, child)
                elseif child:IsA("Folder") then
                    for _, c in ipairs(collectCritters(child)) do
                        table.insert(state.cache, c)
                    end
                end
            end)
            state.connRemoved = folder.ChildRemoved:Connect(function(child)
                for i = #state.cache, 1, -1 do
                    if state.cache[i] == child then table.remove(state.cache, i) end
                end
            end)
        end
        state.scanAt = tick()
    end

    local function collectCritterAuraTargets(hrpPos, now)
        ensureWatcher()
        if state.cacheFolder and now - state.scanAt > 10 then
            state.scanAt = now
            table.clear(state.cache)
            for _, c in ipairs(collectCritters(state.cacheFolder)) do
                table.insert(state.cache, c)
            end
        end
        local range = Settings.CritterRange or 15
        local rangeSq = range * range
        local detectionRangeSq = (range + 10) * (range + 10)
        local filter = Settings.CritterType or "All"
        local targets, newCache = {}, {}
        for i = 1, #state.cache do
            local critter = state.cache[i]
            if critter and critter.Parent and state.cacheFolder
                and critter:IsDescendantOf(state.cacheFolder) and isCritterAlive(critter) then
                table.insert(newCache, critter)
                local eid = getCritterAuraID(critter)
                if eid and critterNameMatchesFilter(getCritterName(critter), filter, "All") then
                    local ppart = getCritterPart(critter)
                    if ppart then
                        local diff = ppart.Position - hrpPos
                        local distSq = diff:Dot(diff)
                        if distSq <= detectionRangeSq then
                            table.insert(targets, { eid = eid, distSq = distSq, pos = ppart.Position })
                        end
                    end
                end
            end
        end
        state.cache = newCache
        return targets, rangeSq
    end

    local function auraTargetCount()
        return math.clamp(tonumber(Settings.CritterTargetCount) or 1, 1, 9)
    end

    local function pickAndSwing(hrp, hrpPos, now)
        local targets, rangeSq = collectCritterAuraTargets(hrpPos, now)
        if #targets == 0 then return end
        table.sort(targets, function(a, b) return a.distSq < b.distSq end)
        local maxPick = auraTargetCount()
        local rows, seen = {}, {}
        for i = 1, #targets do
            if #rows >= maxPick then break end
            local t = targets[i]
            if t.distSq <= rangeSq then
                local id = math.floor(tonumber(t.eid) or 0)
                if id > 0 and not seen[id] then
                    seen[id] = true
                    table.insert(rows, { eid = id, pos = t.pos })
                end
            end
        end
        if #rows == 0 then return end
        if Settings.CritterSwingPackedMultiHit then
            fireByteNetSwingToolPackedMultiHit(rows, hrp, { maxTargets = maxPick })
        else
            fireByteNetSwingTool(rows, hrp, { maxPerPacket = maxPick })
        end
        if Settings.AuraLegitSwing then
            pcall(function()
                local swingId = getPacketId("ClientSwing")
                if swingId and ByteNetReliable then
                    local b = buffer.create(2)
                    buffer.writeu8(b, 0, 0)
                    buffer.writeu8(b, 1, swingId)
                    ByteNetReliable:FireServer(b)
                end
            end)
        end
    end

    local function startCritterAuraLoop()
        if state.active then return end
        state.active = true
        task.spawn(function()
            while Settings.CritterAuraEnabled and isSessionActive(SESSION) do
                pcall(function()
                    if not getPacketId("SwingTool") then return end
                    local hrp = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
                    if not hrp then return end
                    pickAndSwing(hrp, hrp.Position, tick())
                end)
                task.wait(math.max(tonumber(Settings.CritterCooldown) or 0.08, 0.05))
            end
            if state.connAdded then state.connAdded:Disconnect(); state.connAdded = nil end
            if state.connRemoved then state.connRemoved:Disconnect(); state.connRemoved = nil end
            state.cacheFolder = nil
            state.active = false
        end)
    end

    -- ===== Behind Queen Ant =====
    local behindActive = false
    local function startBehindQueenAntFollow()
        if behindActive then return end
        behindActive = true
        local cachedQueenAnt, cachedQPart
        local lastSearch = 0
        local conn
        conn = RunService.Heartbeat:Connect(function()
            if not Settings.BehindQueenAnt then
                conn:Disconnect()
                behindActive = false
                return
            end
            local ok = pcall(function()
                local char = plr.Character
                if not char then return end
                local hum = char:FindFirstChildOfClass("Humanoid")
                local hrp = char:FindFirstChild("HumanoidRootPart")
                if not hum or not hrp or hum.Health <= 0 then return end
                local now = tick()
                if not cachedQueenAnt or not cachedQueenAnt.Parent then
                    cachedQPart = nil
                    if now - lastSearch < 0.5 then return end
                    lastSearch = now
                    local folder = getWorkspaceCritters()
                    if not folder then return end
                    for _, child in ipairs(folder:GetChildren()) do
                        if child:IsA("Model") and child.Name == "Queen Ant" then
                            cachedQueenAnt = child
                            break
                        end
                    end
                end
                if not cachedQueenAnt or not cachedQueenAnt.Parent then return end
                if not cachedQPart or not cachedQPart.Parent then
                    cachedQPart = cachedQueenAnt.PrimaryPart
                        or cachedQueenAnt:FindFirstChild("HumanoidRootPart")
                        or cachedQueenAnt:FindFirstChildWhichIsA("BasePart")
                end
                if not cachedQPart then return end
                local studs = math.clamp(tonumber(Settings.BehindQueenAntStuds) or 3, 0, 10)
                local look = cachedQPart.CFrame.LookVector
                local flat = Vector3.new(look.X, 0, look.Z)
                local dir
                if flat.Magnitude > 0.05 then
                    dir = flat.Unit
                else
                    local toMe = Vector3.new(
                        hrp.Position.X - cachedQPart.Position.X,
                        0,
                        hrp.Position.Z - cachedQPart.Position.Z)
                    dir = toMe.Magnitude > 0.05 and (-toMe.Unit) or Vector3.new(0, 0, 1)
                end
                local behind = cachedQPart.Position - dir * studs
                local goal = Vector3.new(behind.X, hrp.Position.Y, behind.Z)
                local dist = (Vector3.new(
                    goal.X - hrp.Position.X, 0, goal.Z - hrp.Position.Z)).Magnitude
                local deadzone = math.max(0.6, studs * 0.15)
                if dist > deadzone then
                    hum:MoveTo(goal)
                else
                    hum:MoveTo(hrp.Position)
                end
            end)
            if not ok then cachedQueenAnt, cachedQPart = nil, nil end
        end)
    end

    -- ==== Critter Aura page UI ====
    local pageAura = createPage("Critter Aura")
    addLabel(pageAura, "Critter Aura")
    addDropdown(pageAura, "Critter Type", getCritterNameList(), "All", function(v)
        Settings.CritterType = v
    end)
    addToggle(pageAura, "Critter Aura", false, function(v)
        Settings.CritterAuraEnabled = v
        Settings.TurnOnAura = v
        if v then startCritterAuraLoop() end
    end)
    addSlider(pageAura, "Target Count", 1, 9, 3, 1, function(v)
        Settings.CritterTargetCount = math.floor(v + 0.5)
    end)
    addSlider(pageAura, "Range", 1, 50, 15, 1, function(v) Settings.CritterRange = v end)
    addSlider(pageAura, "Cooldown", 0.03, 1, 0.08, 0.01, function(v) Settings.CritterCooldown = v end)
    addToggle(pageAura, "Packed MultiHit", true, function(v)
        Settings.CritterSwingPackedMultiHit = v == true
    end)
    addToggle(pageAura, "Legit Swing", false, function(v)
        Settings.AuraLegitSwing = v == true
    end)

    addLabel(pageAura, "Behind Queen Ant")
    addToggle(pageAura, "BehindQueenAnt", false, function(v)
        Settings.BehindQueenAnt = v
        if v then startBehindQueenAntFollow() end
    end)
    addSlider(pageAura, "Distance From Queen", 0, 10, 3, 0.1, function(v)
        Settings.BehindQueenAntStuds = v
    end)
end

-- activate first tab
local firstBtn = tabBar:GetChildren()[1]
if firstBtn then
    task.defer(function() firstBtn:Fire("MouseButton1Click") end)
end