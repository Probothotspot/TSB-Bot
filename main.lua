--!strict
-- The Strongest Battlegrounds: nearest visible player, approach, M1 input.
-- F6: enable/pause. F7: fighter report. End: unload. Starts paused.
-- No downloaded code or game-specific remote payloads.

local Config = {
	AcquireRadius = 80,
	LoseRadius = 110,
	StopDistance = 3.5,
	AttackDistance = 5,
	MaxHeightDifference = 6,
	ClickInterval = 0.18,
	ClickHold = 0.06,
	ScanInterval = 0.2,
	ToggleKey = Enum.KeyCode.F6,
	ReportKey = Enum.KeyCode.F7,
	UnloadKey = Enum.KeyCode.End,
}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Input = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer
assert(player, "TSB Bot: run in a loaded Roblox client.")
assert(game.PlaceId == 10449761463, "TSB Bot: this script targets the main TSB place.")

local external = getfenv()
local registry = if type(external.getgenv) == "function"
	then external.getgenv()
	else (external.shared or external)
local registryKey = "Kindmops_TSB_AutoM1_v1"
local bindName = registryKey .. "_Movement"
local previous = registry[registryKey]
if type(previous) == "table" and type(previous.Destroy) == "function" then
	local ok, reason = pcall(previous.Destroy)
	assert(ok, "TSB Bot: previous instance did not unload: " .. tostring(reason))
end

local function notify(message: string)
	print("[TSB Bot] " .. message)
	pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = "TSB Auto M1",
			Text = message,
			Duration = 5,
		})
	end)
end

-- A backend existing does not prove that this executor can deliver input.
-- The first actual input error pauses the bot and reports its full message.
local sendButton: ((boolean) -> ())? = nil
local backend = "unavailable"
if type(external.mouse1press) == "function" and type(external.mouse1release) == "function" then
	local press, release = external.mouse1press, external.mouse1release
	sendButton = function(down: boolean)
		if down then press() else release() end
	end
	backend = "executor mouse1press/mouse1release"
else
	local ok, virtualInput = pcall(function()
		return Input:CreateVirtualInput()
	end)
	if ok and virtualInput then
		sendButton = function(down: boolean)
			virtualInput:SendMouseButton(Input:GetMouseLocation(), Enum.UserInputType.MouseButton1, down, 0)
		end
		backend = "Roblox VirtualInput"
	end
end

type Rig = { model: Model, human: Humanoid, root: BasePart }
local state = {
	enabled = false,
	destroyed = false,
	focused = false,
	target = nil :: Player?,
	held = false,
	releaseAt = 0,
	nextClick = 0,
	nextScan = 0,
	drivenHuman = nil :: Humanoid?,
}
local connections: { RBXScriptConnection } = {}
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local ui: { [string]: any } = { connections = {}, root = nil, panel = nil, dragging = false, x = 16, y = 90 }

local function destroyUI()
	for _, connection in ui.connections do connection:Disconnect() end
	table.clear(ui.connections)
	if ui.root then ui.root:Destroy() end
	ui.root, ui.panel = nil, nil
	ui.dragging = false
end

local function pointerOverUI(): boolean
	if not ui.panel or not ui.root or not ui.root.Parent or not ui.root.Enabled then return false end
	if ui.dragging then return true end
	local position = Input:GetMouseLocation()
	for _, object in ui.root.Parent:GetGuiObjectsAtPosition(position.X, position.Y) do
		if object == ui.panel or object:IsDescendantOf(ui.panel) then return true end
	end
	return false
end

-- Identity comes from replicated data, never the avatar's name/appearance.
-- Attribute names are candidates, not a verified contract with the current TSB build.
-- A Player-only ID is explicitly a selection hint, not a confirmed active fighter.
type FighterSnapshot = {
	activeId: string?,
	selectedId: string?,
	source: string?,
	status: string,
	abilities: { string },
	playerAttributes: { [string]: any },
	characterAttributes: { [string]: any },
}
local fighter = {
	identityKeys = { "Character", "CharacterName", "Fighter", "FighterId", "Moveset", "MovesetName" },
	nextSample = 0,
	lastSummary = "",
	failed = false,
	snapshot = {
		activeId = nil,
		selectedId = nil,
		source = nil,
		status = "waiting",
		abilities = {},
		playerAttributes = {},
		characterAttributes = {},
	} :: FighterSnapshot,
}

local function cleanText(value: any): string
	return (tostring(value):gsub("%c", " "))
end

local function identityFrom(attributes: { [string]: any }): (string?, string?)
	for _, key in fighter.identityKeys do
		local value = attributes[key]
		if type(value) == "string" and value:match("%S") then
			return value, key
		end
	end
	return nil, nil
end

local function sampleFighter(): FighterSnapshot
	local model = player.Character
	if model and not model:IsDescendantOf(Workspace) then model = nil end
	local playerAttributes = player:GetAttributes()
	local characterAttributes = if model then model:GetAttributes() else {}
	local activeId, activeKey = identityFrom(characterAttributes)
	local selectedId, selectedKey = identityFrom(playerAttributes)
	if not selectedId then
		local selected = playerAttributes.SelectedCharacter
		if type(selected) == "string" and selected:match("%S") then
			selectedId, selectedKey = selected, "SelectedCharacter"
		end
	end
	local abilities: { string } = {}
	local seen: { [string]: boolean } = {}
	local function collect(container: Instance?)
		if not container then return end
		for _, child in container:GetChildren() do
			if child:IsA("Tool") and not seen[child.Name] then
				seen[child.Name] = true
				table.insert(abilities, child.Name)
			end
		end
	end
	-- During respawn the Backpack can still contain the previous kit.
	if model then
		collect(player:FindFirstChildOfClass("Backpack"))
		collect(model)
	end
	table.sort(abilities)
	local status = "unknown"
	local source: string? = nil
	if not model then
		status = "waiting_for_character"
	elseif activeId then
		status = "character_attribute"
		source = "Character." .. (activeKey or "")
	elseif selectedId then
		status = "selection_only"
		source = "Player." .. (selectedKey or "")
	end
	local snapshot: FighterSnapshot = {
		activeId = if model then activeId else nil,
		selectedId = selectedId,
		source = source,
		status = status,
		abilities = abilities,
		playerAttributes = playerAttributes,
		characterAttributes = characterAttributes,
	}
	fighter.snapshot = snapshot
	return snapshot
end

local function fighterSummary(snapshot: FighterSnapshot): string
	if snapshot.status == "waiting_for_character" then return "Fighter: waiting for respawn." end
	if snapshot.activeId then
		return "Fighter ID: " .. cleanText(snapshot.activeId) .. " [" .. (snapshot.source or "") .. "]"
	end
	if snapshot.selectedId then
		return "Selected ID: " .. cleanText(snapshot.selectedId) .. "; active fighter unconfirmed. F7: report."
	end
	return "Fighter ID unknown. F7: report with attributes and tool names."
end

local function fighterReport(): string
	local snapshot = sampleFighter()
	local lines = {
		"TSB Bot fighter report v0.3.0",
		"PlaceId: " .. tostring(game.PlaceId),
		"Status: " .. snapshot.status,
		"Active ID: " .. cleanText(snapshot.activeId or "unknown"),
		"Selected ID: " .. cleanText(snapshot.selectedId or "unknown"),
		"Source: " .. (snapshot.source or "none"),
		"Tool names (not slot bindings): " .. cleanText(table.concat(snapshot.abilities, " | ")),
	}
	local function appendAttributes(label: string, attributes: { [string]: any })
		table.insert(lines, label .. ":")
		local keys: { string } = {}
		for key in attributes do table.insert(keys, key) end
		table.sort(keys)
		if #keys == 0 then table.insert(lines, "  (none)") end
		for _, key in keys do
			table.insert(lines, "  " .. cleanText(key) .. " = " .. cleanText(attributes[key]))
		end
	end
	appendAttributes("Player attributes", snapshot.playerAttributes)
	appendAttributes("Character attributes", snapshot.characterAttributes)
	return table.concat(lines, "\n")
end

local function getRig(candidate: Player): Rig?
	local model = candidate.Character
	if not model or not model:IsDescendantOf(Workspace) then return nil end
	local human = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not human or human.Health <= 0 or not root or not root:IsA("BasePart") then return nil end
	return { model = model, human = human, root = root }
end

local function releaseMouse(): boolean
	if not state.held then return true end
	local sender = sendButton
	if not sender then return false end
	local ok, reason = pcall(sender, false)
	if not ok then
		warn("[TSB Bot] Mouse release failed; click/release LMB manually: " .. tostring(reason))
		return false
	end
	state.held = false
	return true
end

local function stopMovement()
	local human = state.drivenHuman
	state.drivenHuman = nil
	if human and human.Parent then
		pcall(function() human:Move(Vector3.zero, false) end)
	end
end

local function suspend()
	state.target = nil
	state.nextScan = 0
	releaseMouse()
	stopMovement()
end

local function pause(reason: string)
	state.enabled = false
	suspend()
	notify(reason)
end

local controller = {}
function controller.GetFighterState(): FighterSnapshot
	local snapshot = sampleFighter()
	local result = table.clone(snapshot)
	result.abilities = table.clone(snapshot.abilities)
	result.playerAttributes = table.clone(snapshot.playerAttributes)
	result.characterAttributes = table.clone(snapshot.characterAttributes)
	return result
end

function controller.Destroy()
	if state.destroyed then return end
	state.destroyed = true
	state.enabled = false
	RunService:UnbindFromRenderStep(bindName)
	for _, connection in connections do connection:Disconnect() end
	table.clear(connections)
	destroyUI()
	suspend()
	-- A transient backend error gets one immediate retry during unload.
	if state.held then releaseMouse() end
	if registry[registryKey] == controller then registry[registryKey] = nil end
end

local function toggleBot()
	if state.destroyed then return end
	if state.enabled then
		pause("Paused.")
	elseif not sendButton then
		notify("No mouse-input backend. Requires mouse1press/release or Roblox VirtualInput.")
	elseif state.held and not releaseMouse() then
		notify("Release LMB manually before enabling; input backend is failing.")
	else
		state.focused = true
		state.enabled = true
		state.nextClick = 0
		notify("Enabled. F6: pause; End: unload.")
	end
end

local function showReport()
	local ok, report = pcall(fighterReport)
	if not ok then
		notify("Fighter report failed: " .. tostring(report))
		return
	end
	print(report)
	local copied = false
	if type(external.setclipboard) == "function" then
		copied = pcall(external.setclipboard, report)
	end
	notify(if copied then "Fighter report copied and printed." else "Fighter report printed to console.")
end

local function layoutUI()
	local available = ui.container.AbsoluteSize
	if available.X <= 0 or available.Y <= 0 then return end
	local scale = math.max(0.1, math.min(1, (available.X - 24) / 292, (available.Y - 24) / 252))
	ui.scale.Scale = scale
	ui.x = math.clamp(ui.x, 8, math.max(8, available.X - 292 * scale - 8))
	ui.y = math.clamp(ui.y, 8, math.max(8, available.Y - 252 * scale - 8))
	ui.panel.Position = UDim2.fromOffset(ui.x, ui.y)
end

local function createUI()
	local parent = player:FindFirstChildOfClass("PlayerGui")
	if not parent then return end
	destroyUI()
	local screen = Instance.new("ScreenGui")
	ui.root = screen
	screen.Name = registryKey .. "_GUI"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = false
	screen.DisplayOrder = 100
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	local container = Instance.new("Frame")
	container.Name = "SafeArea"
	container.Size = UDim2.fromScale(1, 1)
	container.BackgroundTransparency = 1
	container.BorderSizePixel = 0
	container.Parent = screen
	ui.container = container
	local panel = Instance.new("Frame")
	ui.panel = panel
	panel.Name = "Panel"
	panel.Size = UDim2.fromOffset(292, 252)
	panel.Position = UDim2.fromOffset(ui.x, ui.y)
	panel.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
	panel.BorderSizePixel = 0
	panel.Active = true
	panel.Parent = container
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel
	local border = Instance.new("UIStroke")
	border.Color = Color3.fromRGB(50, 62, 81)
	border.Thickness = 1
	border.Parent = panel
	local scale = Instance.new("UIScale")
	scale.Parent = panel
	ui.scale = scale
	local function label(name: string, text: string, y: number, height: number, size: number, muted: boolean): TextLabel
		local object = Instance.new("TextLabel")
		object.Name = name
		object.Text = text
		object.Size = UDim2.new(1, -28, 0, height)
		object.Position = UDim2.fromOffset(14, y)
		object.BackgroundTransparency = 1
		object.Font = Enum.Font.Gotham
		object.TextSize = size
		object.TextColor3 = if muted then Color3.fromRGB(161, 174, 193) else Color3.fromRGB(235, 240, 248)
		object.TextXAlignment = Enum.TextXAlignment.Left
		object.TextTruncate = Enum.TextTruncate.AtEnd
		object.Parent = panel
		return object
	end
	local header = label("Header", "TSB BOT  /  v0.3", 0, 36, 15, false)
	header.Size = UDim2.new(1, -64, 0, 36)
	header.Active = true
	ui.fighterLabel = label("Fighter", "Боец: определяем...", 44, 26, 15, false)
	ui.hintLabel = label("Hint", "Отчёт поможет проверить бойца", 72, 18, 12, true)
	ui.statusLabel = label("Status", "На паузе", 98, 20, 13, false)
	label("Shortcuts", "F6: запуск   F7: отчёт   End: выход", 230, 16, 11, true)
	local function button(name: string, text: string, y: number): TextButton
		local object = Instance.new("TextButton")
		object.Name = name
		object.Text = text
		object.Size = UDim2.new(1, -24, 0, 44)
		object.Position = UDim2.fromOffset(12, y)
		object.BackgroundColor3 = Color3.fromRGB(41, 51, 68)
		object.BorderSizePixel = 0
		object.Font = Enum.Font.Gotham
		object.TextSize = 14
		object.TextColor3 = Color3.fromRGB(245, 248, 252)
		object.Parent = panel
		local rounded = Instance.new("UICorner")
		rounded.CornerRadius = UDim.new(0, 7)
		rounded.Parent = object
		return object
	end
	ui.toggleButton = button("Toggle", "Включить бота", 126)
	local reportButton = button("Report", "Отчёт о бойце [F7]", 178)
	local close = button("Close", "X", 2)
	close.Size = UDim2.fromOffset(36, 32)
	close.Position = UDim2.new(1, -40, 0, 2)
	local function connect(event: RBXScriptSignal, callback: (...any) -> ())
		table.insert(ui.connections, event:Connect(callback))
	end
	connect(ui.toggleButton.Activated, toggleBot)
	connect(reportButton.Activated, showReport)
	connect(close.Activated, function() controller.Destroy(); notify("Unloaded.") end)
	connect(header.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			ui.dragging = true
			ui.dragPointer = input
			ui.dragPosition = input.Position
			ui.dragX, ui.dragY = ui.x, ui.y
			suspend()
		end
	end)
	connect(Input.InputChanged, function(input)
		if not ui.dragging then return end
		local touch = ui.dragPointer.UserInputType == Enum.UserInputType.Touch
		if (touch and input ~= ui.dragPointer) or (not touch and input.UserInputType ~= Enum.UserInputType.MouseMovement) then return end
		local delta = input.Position - ui.dragPosition
		ui.x, ui.y = ui.dragX + delta.X, ui.dragY + delta.Y
		layoutUI()
	end)
	connect(Input.InputEnded, function(input)
		if input == ui.dragPointer or input.UserInputType == Enum.UserInputType.MouseButton1 then ui.dragging = false end
	end)
	screen.Parent = parent
	layoutUI()
end

local function updateUI()
	if not ui.root or not ui.root.Parent then createUI() end
	if not ui.root or not ui.root.Parent then return end
	layoutUI()
	local snapshot = fighter.snapshot
	if snapshot.status == "waiting_for_character" then
		ui.fighterLabel.Text = "Боец: возрождение..."
		ui.hintLabel.Text = "Ожидаем появления персонажа"
	elseif snapshot.activeId then
		ui.fighterLabel.Text = "Боец: " .. cleanText(snapshot.activeId)
		ui.hintLabel.Text = "ID найден. Подробности в отчёте"
	elseif snapshot.selectedId then
		ui.fighterLabel.Text = "Выбран: " .. cleanText(snapshot.selectedId)
		ui.hintLabel.Text = "Активный боец ещё не подтверждён"
	else
		ui.fighterLabel.Text = "Боец: не определён"
		ui.hintLabel.Text = "Нажми «Отчёт» для проверки"
	end
	ui.toggleButton.Text = if state.enabled then "Пауза [F6]" else "Включить бота [F6]"
	ui.toggleButton.BackgroundColor3 = if state.enabled then Color3.fromRGB(160, 61, 73) else Color3.fromRGB(35, 142, 102)
	if not state.enabled then
		ui.statusLabel.Text = "На паузе"
	elseif not state.focused then
		ui.statusLabel.Text = "Ожидаем возврата в игру"
	elseif Input:GetFocusedTextBox() then
		ui.statusLabel.Text = "Пауза: ввод текста"
	elseif pointerOverUI() then
		ui.statusLabel.Text = "Пауза: управление панелью"
	elseif state.target then
		ui.statusLabel.Text = "Цель: " .. cleanText(state.target.DisplayName or state.target.Name)
	else
		ui.statusLabel.Text = "Поиск противника"
	end
end

local function targetRig(candidate: Player?, own: Rig, radius: number): Rig?
	if not candidate or candidate == player or candidate.Parent ~= Players then return nil end
	local rig = getRig(candidate)
	if not rig or rig.model:FindFirstChildOfClass("ForceField") then return nil end
	local offset = rig.root.Position - own.root.Position
	if offset.Magnitude > radius or math.abs(offset.Y) > Config.MaxHeightDifference then return nil end
	rayParams.FilterDescendantsInstances = { own.model }
	local hit = Workspace:Raycast(own.root.Position, offset, rayParams)
	if hit and not hit.Instance:IsDescendantOf(rig.model) then return nil end
	return rig
end

local function acquire(own: Rig): Player?
	local nearest: Player? = nil
	local distance = Config.AcquireRadius
	for _, candidate in Players:GetPlayers() do
		local rig = targetRig(candidate, own, distance)
		if rig then
			nearest = candidate
			distance = (rig.root.Position - own.root.Position).Magnitude
		end
	end
	return nearest
end

local function update()
	if state.destroyed then return end
	local now = os.clock()
	if state.enabled and state.held and now >= state.releaseAt then
		if not releaseMouse() then
			pause("Input release failed. Click/release LMB manually; see console.")
			return
		end
	end
	if not state.enabled then return end
	if not state.focused or Input:GetFocusedTextBox() or Input.OnScreenKeyboardVisible then
		suspend()
		return
	end
	if pointerOverUI() then
		suspend()
		return
	end
	local own = getRig(player)
	if not own or own.human.PlatformStand or own.human.Sit or own.root.Anchored then
		suspend()
		return
	end
	if state.drivenHuman and state.drivenHuman ~= own.human then stopMovement() end
	local target = targetRig(state.target, own, Config.LoseRadius)
	if not target then
		state.target = nil
		if now >= state.nextScan then
			state.nextScan = now + Config.ScanInterval
			state.target = acquire(own)
			target = targetRig(state.target, own, Config.AcquireRadius)
		end
	end
	if not target then
		releaseMouse()
		stopMovement()
		return
	end
	local offset = target.root.Position - own.root.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	local distance = flat.Magnitude
	state.drivenHuman = own.human
	if distance > Config.StopDistance then
		own.human:Move(flat.Unit, false)
	else
		own.human:Move(Vector3.zero, false)
	end
	if distance > 0.01 then
		own.root.CFrame = CFrame.lookAt(own.root.Position, own.root.Position + flat)
	end
	if offset.Magnitude > Config.AttackDistance then
		releaseMouse()
		return
	end
	if not state.held and now >= state.nextClick then
		local sender = sendButton
		if not sender then
			pause("No mouse-input backend. This Xeno build is not supported by this version.")
			return
		end
		-- Mark before calling: even a partially failed down event needs cleanup.
		state.held = true
		local ok, reason = pcall(sender, true)
		if not ok then
			pause("Input rejected: " .. tostring(reason))
			return
		end
		state.releaseAt = now + Config.ClickHold
		state.nextClick = now + Config.ClickInterval
	end
end

table.insert(connections, Input.WindowFocused:Connect(function() state.focused = true end))
table.insert(connections, Input.WindowFocusReleased:Connect(function()
	state.focused = false
	ui.dragging = false
	suspend()
end))
table.insert(connections, Input.TextBoxFocused:Connect(function() suspend() end))
table.insert(connections, player.CharacterRemoving:Connect(function() suspend() end))
table.insert(connections, Input.InputBegan:Connect(function(input, processed)
	if input.KeyCode == Config.UnloadKey and not Input:GetFocusedTextBox() then
		controller.Destroy()
		notify("Unloaded.")
		return
	end
	if processed or Input:GetFocusedTextBox() then return end
	if input.KeyCode == Config.ReportKey then
		showReport()
		return
	end
	if input.KeyCode == Config.ToggleKey then
		toggleBot()
	end
end))

registry[registryKey] = controller
local bound, bindError = pcall(function()
	RunService:BindToRenderStep(bindName, Enum.RenderPriority.Character.Value + 1, function()
		local ok, reason = pcall(update)
		if not ok then pause("Runtime error: " .. tostring(reason)) end
	end)
end)
if not bound then
	controller.Destroy()
	error("TSB Bot: cannot install movement callback: " .. tostring(bindError))
end
table.insert(connections, RunService.Heartbeat:Connect(function()
	if state.destroyed or fighter.failed or os.clock() < fighter.nextSample then return end
	fighter.nextSample = os.clock() + 0.5
	local ok, snapshot = pcall(sampleFighter)
	if not ok then
		fighter.failed = true
		warn("[TSB Bot] Fighter detector stopped; M1 remains available: " .. tostring(snapshot))
		return
	end
	local summary = fighterSummary(snapshot)
	if summary ~= fighter.lastSummary then
		fighter.lastSummary = summary
		notify(summary)
	end
end))
local nextUIUpdate = 0
local uiFailed = false
table.insert(connections, RunService.Heartbeat:Connect(function()
	if state.destroyed or uiFailed or os.clock() < nextUIUpdate then return end
	nextUIUpdate = os.clock() + 0.1
	local ok, reason = pcall(updateUI)
	if not ok then
		uiFailed = true
		destroyUI()
		warn("[TSB Bot] GUI stopped; keyboard controls remain available: " .. tostring(reason))
	end
end))
notify("Loaded v0.3, paused. F6: enable; F7: fighter report; End: unload. Input: " .. backend)

