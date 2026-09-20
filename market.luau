local Fluent = loadstring(game:HttpGetAsync(
    "https://github.com/ActualMasterOogway/Fluent-Renewed/releases/latest/download/Fluent.luau"
))()

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local PlayerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local function getMarket()
    local MainGui = PlayerGui:FindFirstChild("MainGui")
    local Panels = MainGui and MainGui:FindFirstChild("Panels")
    return Panels and Panels:FindFirstChild("GlobalMarket")
end

local Window = Fluent:CreateWindow{
    Title = "Market",
    SubTitle = "",
    TabWidth = 120,
    Size = UDim2.fromOffset(500, 350),
    Resize = false,
    Acrylic = false,
    Theme = "Dark",
    MinimizeKey = Enum.KeyCode.RightControl
}

local Tab = Window:CreateTab{
    Title = "Market",
    Icon = "store"
}

Tab:CreateButton{
    Title = "Open",
    Description = "",
    Callback = function()
        local Market = getMarket()
        if Market then
            Market.Visible = true
        end
    end
}

Tab:CreateButton{
    Title = "Close",
    Description = "",
    Callback = function()
        local Market = getMarket()
        if Market then
            Market.Visible = false
        end
    end
}

Window:SelectTab(1)

UIS.InputBegan:Connect(function(Input, Processed)
    if Processed then
        return
    end

    local Market = getMarket()
    if not Market then
        return
    end

    if Input.KeyCode == Enum.KeyCode.M then
        Market.Visible = true
    elseif Input.KeyCode == Enum.KeyCode.N then
        Market.Visible = false
    end
end)
