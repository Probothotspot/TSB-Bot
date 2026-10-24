--!strict
-- Read-only cooldown/dummy diagnostics with a selectable GUI report.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local TextService = game:GetService("TextService")
local player = Players.LocalPlayer
assert(player, "Run inside a Roblox client.")
local playerGui = player:FindFirstChildOfClass("PlayerGui")
assert(playerGui, "PlayerGui is not ready; run the probe after joining the game.")
local external = getfenv()
local registry = if type(external.getgenv) == "function" then external.getgenv() else (external.shared or external)
local key = "Kindmops_TSB_CooldownProbe_GUI"
local old = registry[key]
if type(old) == "table" and type(old.Destroy) == "function" then
	local ok, reason = pcall(old.Destroy)
	assert(ok, "Cannot unload previous probe: " .. tostring(reason))
end

local function collectReport(): string
	local lines = { "TSB cooldown and target probe v2 GUI", "PlaceId: " .. tostring(game.PlaceId), "Captured at: " .. tostring(os.time()) }
	local ok, serverTime = pcall(function() return Workspace:GetServerTimeNow() end)
	if ok then table.insert(lines, "Server time: " .. tostring(serverTime)) end
	local function attributes(object: Instance)
		local values = object:GetAttributes()
		local keys: { string } = {}
		for name in values do table.insert(keys, name) end
		table.sort(keys)
		for _, name in keys do table.insert(lines, "  @" .. name .. "=" .. tostring(values[name])) end
	end
	local matched = 0
	for _, object in playerGui:GetDescendants() do
		local path = object:GetFullName()
		local lower = path:lower()
		if (lower:find("hotbar", 1, true) or lower:find("backpack", 1, true)) and not lower:find("kindmops", 1, true) then
			matched += 1
			local value = path .. " [" .. object.ClassName .. "]"
			if object:IsA("GuiObject") then
				value ..= " visible=" .. tostring(object.Visible) .. " size=" .. tostring(object.Size)
				value ..= " absolute=" .. tostring(object.AbsoluteSize) .. " backgroundTransparency=" .. tostring(object.BackgroundTransparency)
			end
			if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then value ..= " text=" .. object.Text end
			if object:IsA("ScreenGui") then value ..= " enabled=" .. tostring(object.Enabled) end
			table.insert(lines, value)
			attributes(object)
		end
	end
	table.insert(lines, "Hotbar nodes captured: " .. tostring(matched))
	if matched == 0 then
		table.insert(lines, "PlayerGui roots:")
		for _, child in playerGui:GetChildren() do table.insert(lines, "  " .. child.Name .. " [" .. child.ClassName .. "]") end
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	local function tools(container: Instance?)
		if not container then return end
		for _, object in container:GetChildren() do
			if object:IsA("Tool") then
				table.insert(lines, "TOOL " .. object.Name .. " enabled=" .. tostring(object.Enabled))
				attributes(object)
			end
		end
	end
	tools(backpack)
	tools(player.Character)
	for _, model in Workspace:GetDescendants() do
		if model:IsA("Model") then
			local human = model:FindFirstChildOfClass("Humanoid")
			local name = model.Name:lower():gsub("[^%w]", "")
			local display = if human then human.DisplayName:lower():gsub("[^%w]", "") else ""
			if human and (name == "weakestdummy" or display == "weakestdummy") then
				table.insert(lines, "TARGET " .. model:GetFullName())
				table.insert(lines, "  state=" .. tostring(human:GetState()) .. " platformStand=" .. tostring(human.PlatformStand) .. " floor=" .. tostring(human.FloorMaterial))
				attributes(model)
				for _, partName in { "HumanoidRootPart", "Torso", "UpperTorso" } do
					local part = model:FindFirstChild(partName)
					if part and part:IsA("BasePart") then table.insert(lines, "  " .. partName .. ".UpY=" .. tostring(part.CFrame.UpVector.Y)) end
				end
			end
		end
	end
	return table.concat(lines, "\n")
end

local connections: { RBXScriptConnection } = {}
local destroyed = false
local report = ""
local screen = Instance.new("ScreenGui")
screen.Name = key
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = false
screen.DisplayOrder = 1000
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
local container = Instance.new("Frame")
container.Name = "SafeArea"
container.Size = UDim2.fromScale(1, 1)
container.BackgroundTransparency = 1
container.BorderSizePixel = 0
container.Parent = screen
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.fromOffset(640, 470)
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
panel.BorderSizePixel = 0
panel.Active = true
panel.Parent = container
local rounded = Instance.new("UICorner")
rounded.CornerRadius = UDim.new(0, 10)
rounded.Parent = panel
local scale = Instance.new("UIScale")
scale.Parent = panel
local function label(name: string, text: string, x: number, y: number, width: number, height: number, size: number): TextLabel
	local item = Instance.new("TextLabel")
	item.Name = name
	item.Text = text
	item.Position = UDim2.fromOffset(x, y)
	item.Size = UDim2.fromOffset(width, height)
	item.BackgroundTransparency = 1
	item.Font = Enum.Font.Gotham
	item.TextSize = size
	item.TextColor3 = Color3.fromRGB(225, 233, 245)
	item.TextXAlignment = Enum.TextXAlignment.Left
	item.TextWrapped = true
	item.Parent = panel
	return item
end
label("Title", "TSB — диагностика cooldown", 16, 6, 560, 34, 18)
label("Instructions", "1. Пауза бота: F6.  2. Используй умение 2.\n3. Пока идёт КД, нажми «Снять отчёт», затем «Копировать».", 16, 48, 608, 42, 13)
local scroll = Instance.new("ScrollingFrame")
scroll.Name = "ReportScroll"
scroll.Position = UDim2.fromOffset(16, 102)
scroll.Size = UDim2.fromOffset(608, 274)
scroll.BackgroundColor3 = Color3.fromRGB(10, 13, 19)
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 8
scroll.ScrollingDirection = Enum.ScrollingDirection.XY
scroll.CanvasSize = UDim2.fromOffset(608, 274)
scroll.Parent = panel
local textBox = Instance.new("TextBox")
textBox.Name = "Report"
textBox.Position = UDim2.fromOffset(8, 8)
textBox.Size = UDim2.fromOffset(590, 256)
textBox.BackgroundTransparency = 1
textBox.ClearTextOnFocus = false
textBox.MultiLine = true
textBox.TextEditable = false
textBox.TextWrapped = false
textBox.Font = Enum.Font.Code
textBox.TextSize = 12
textBox.TextColor3 = Color3.fromRGB(215, 229, 243)
textBox.TextXAlignment = Enum.TextXAlignment.Left
textBox.TextYAlignment = Enum.TextYAlignment.Top
textBox.Text = "Нажми «Снять отчёт», пока способность восстанавливается."
textBox.Parent = scroll
local status = label("Status", "Отчёт появится здесь и останется доступен для копирования.", 16, 438, 608, 22, 12)
local function button(name: string, text: string, x: number, width: number): TextButton
	local item = Instance.new("TextButton")
	item.Name = name
	item.Text = text
	item.Position = UDim2.fromOffset(x, 390)
	item.Size = UDim2.fromOffset(width, 40)
	item.BackgroundColor3 = Color3.fromRGB(40, 57, 77)
	item.BorderSizePixel = 0
	item.Font = Enum.Font.Gotham
	item.TextSize = 14
	item.TextColor3 = Color3.fromRGB(245, 248, 252)
	item.Parent = panel
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 7)
	corner.Parent = item
	return item
end
local captureButton = button("Capture", "Снять отчёт", 16, 190)
captureButton.BackgroundColor3 = Color3.fromRGB(35, 130, 99)
local copyButton = button("Copy", "Копировать", 224, 190)
local selectButton = button("Select", "Выделить текст", 432, 192)
local close = button("Close", "X", 592, 32)
close.Position = UDim2.fromOffset(592, 8)
close.Size = UDim2.fromOffset(32, 32)
local controller = {}
function controller.Destroy()
	if destroyed then return end
	destroyed = true
	for _, connection in connections do connection:Disconnect() end
	table.clear(connections)
	screen:Destroy()
	if registry[key] == controller then registry[key] = nil end
end
local function selectReport()
	textBox:CaptureFocus()
	textBox.SelectionStart = 1
	textBox.CursorPosition = #textBox.Text + 1
end
table.insert(connections, captureButton.Activated:Connect(function()
	status.Text = "Читаю панель способностей..."
	local ok, result = pcall(collectReport)
	if not ok then status.Text = "Ошибка: " .. tostring(result); return end
	report = result
	textBox.Text = report
	local measured = TextService:GetTextSize(report, 12, Enum.Font.Code, Vector2.new(100000, 100000))
	local width, height = math.max(590, measured.X + 24), math.max(256, measured.Y + 24)
	textBox.Size = UDim2.fromOffset(width, height)
	scroll.CanvasSize = UDim2.fromOffset(width + 16, height + 16)
	scroll.CanvasPosition = Vector2.zero
	status.Text = "Снимок готов: " .. tostring(#report) .. " байт. Нажми «Копировать»."
end))
table.insert(connections, copyButton.Activated:Connect(function()
	if report == "" then status.Text = "Сначала нажми «Снять отчёт»."; return end
	if type(external.setclipboard) == "function" then
		local ok = pcall(external.setclipboard, report)
		if ok then status.Text = "Скопировано. Теперь вставь отчёт в чат."; return end
	end
	selectReport()
	status.Text = "Текст выделен. Нажми Ctrl+C, затем вставь в чат."
end))
table.insert(connections, selectButton.Activated:Connect(function()
	selectReport()
	status.Text = "Нажми Ctrl+C для копирования выделенного текста."
end))
table.insert(connections, close.Activated:Connect(controller.Destroy))
local function fit()
	local size = container.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then return end
	scale.Scale = math.max(0.1, math.min(1, (size.X - 24) / 640, (size.Y - 24) / 470))
end
table.insert(connections, container:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit))
registry[key] = controller
screen.Parent = playerGui
fit()

