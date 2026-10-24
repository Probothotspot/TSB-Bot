--!strict
-- The Strongest Battlegrounds: M1 and optional normal-form Saitama combos.
-- F6: bot. F7: report. F8: combos. F9: skill click confirmation. End: unload.
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
	ComboKey = Enum.KeyCode.F8,
	ConfirmKey = Enum.KeyCode.F9,
	UnloadKey = Enum.KeyCode.End,
	ComboResetDelay = 1.1,
	ComboRetryDelay = 0.9,
	ComboWaitLimit = 0.9,
	SkillKeyHold = 0.06,
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

local sendSkillKey: ((number, boolean) -> ())? = nil
local skillBackend = "unavailable"
if type(external.keypress) == "function" and type(external.keyrelease) == "function" then
	local press, release = external.keypress, external.keyrelease
	sendSkillKey = function(slot: number, down: boolean)
		if down then press(0x30 + slot) else release(0x30 + slot) end
	end
	skillBackend = "executor keypress/keyrelease"
else
	local ok, virtualInput = pcall(function() return Input:CreateVirtualInput() end)
	if ok and virtualInput then
		local keys = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four }
		sendSkillKey = function(slot: number, down: boolean)
			virtualInput:SendKey(down, keys[slot], false)
		end
		skillBackend = "Roblox VirtualInput"
	end
end

-- These are local retry limits and starter timings, not measured server cooldowns.
local saitama = {
	skills = {
		["Normal Punch"] = { slot = 1, retry = 12, range = 6 },
		["Consecutive Punches"] = { slot = 2, retry = 14, range = 5 },
		["Shove"] = { slot = 3, retry = 12, range = 5 },
		["Uppercut"] = { slot = 4, retry = 14, range = 5 },
	},
	plans = {
		{
			name = "3M1 > 2 > 4 > 1",
			steps = {
				{ kind = "m1", delay = 0.48 }, { kind = "m1", delay = 0.48 }, { kind = "m1", delay = 0.48 },
				{ kind = "skill", skill = "Consecutive Punches", delay = 1.9 },
				{ kind = "skill", skill = "Uppercut", delay = 0.95 },
				{ kind = "skill", skill = "Normal Punch", delay = 1.0 },
			},
		},
		{
			name = "3M1 > 3 > 1",
			steps = {
				{ kind = "m1", delay = 0.48 }, { kind = "m1", delay = 0.48 }, { kind = "m1", delay = 0.48 },
				{ kind = "skill", skill = "Shove", delay = 0.65 },
				{ kind = "skill", skill = "Normal Punch", delay = 1.0 },
			},
		},
	},
}
local combat: { [string]: any } = {
	enabled = false, confirmClick = false, active = false, owner = nil, target = nil,
	plan = nil, index = 1, due = 0, nextStart = 0, routeCursor = 1,
	heldSlot = nil, keyReleaseAt = 0, confirmAt = nil, waitUntil = nil,
	nextUse = {}, status = "M1", lastAttempt = "none", keyAttempts = 0,
}

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
		"TSB Bot fighter report v0.4.0",
		"PlaceId: " .. tostring(game.PlaceId),
		"Status: " .. snapshot.status,
		"Active ID: " .. cleanText(snapshot.activeId or "unknown"),
		"Selected ID: " .. cleanText(snapshot.selectedId or "unknown"),
		"Source: " .. (snapshot.source or "none"),
		"M1 input: " .. backend,
		"Skill input: " .. skillBackend,
		"Combo enabled: " .. tostring(combat.enabled),
		"Skill click confirmation: " .. tostring(combat.confirmClick),
		"Combo state: " .. cleanText(combat.status),
		"Last skill input attempt: " .. cleanText(combat.lastAttempt),
		"Skill input attempts: " .. tostring(combat.keyAttempts),
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
	local function appendTools(container: Instance?)
		if not container then return end
		for _, object in container:GetChildren() do
			if object:IsA("Tool") then
				table.insert(lines, "Tool: " .. cleanText(object.Name) .. "; Enabled=" .. tostring(object.Enabled))
				appendAttributes("  Attributes", object:GetAttributes())
			end
		end
	end
	appendTools(player:FindFirstChildOfClass("Backpack"))
	appendTools(player.Character)
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

local function releaseSkillKey(): boolean
	local slot = combat.heldSlot
	if not slot then return true end
	local sender = sendSkillKey
	if not sender then return false end
	local ok, reason = pcall(sender, slot, false)
	if not ok then
		warn("[TSB Bot] Skill key release failed; press/release " .. tostring(slot) .. " manually: " .. tostring(reason))
		return false
	end
	combat.heldSlot = nil
	return true
end

local function cancelCombat(reason: string): boolean
	local released = releaseSkillKey()
	if combat.active then releaseMouse() end
	combat.active, combat.plan, combat.target = false, nil, nil
	combat.confirmAt, combat.waitUntil = nil, nil
	combat.index = 1
	combat.nextStart = os.clock() + Config.ComboRetryDelay
	combat.status = reason
	return released
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
	cancelCombat("Ожидание")
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

function controller.GetCombatState()
	return {
		enabled = combat.enabled, active = combat.active, status = combat.status,
		index = combat.index, heldSlot = combat.heldSlot,
		confirmClick = combat.confirmClick, keyAttempts = combat.keyAttempts,
		lastAttempt = combat.lastAttempt, nextUse = table.clone(combat.nextUse),
	}
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
	if combat.heldSlot then releaseSkillKey() end
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
	elseif combat.heldSlot and not releaseSkillKey() then
		notify("Release the skill key manually before enabling; input backend is failing.")
	else
		state.focused = true
		state.enabled = true
		state.nextClick = 0
		notify("Enabled. F6: pause; End: unload.")
	end
end

local function toggleCombos()
	if combat.enabled then
		combat.enabled = false
		if not cancelCombat("M1") then pause("Skill key release failed; release it manually.") end
		notify("Saitama combos disabled. M1 mode.")
	elseif not sendSkillKey then
		notify("Skill keyboard input unavailable. M1 remains available; F7: report.")
	else
		combat.enabled = true
		cancelCombat("Комбо готовы")
		notify("Saitama combos enabled for Bald with the normal kit. F8: disable.")
	end
end

local function toggleConfirmation()
	if not cancelCombat("Режим активации изменён") then
		pause("Skill key release failed; release it manually.")
		return
	end
	combat.confirmClick = not combat.confirmClick
	notify(if combat.confirmClick then "Skill activation: number key, then LMB." else "Skill activation: number key only. Use Auto Activate in game.")
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

local function pressM1(now: number): boolean
	if state.held or now < state.nextClick then return false end
	local sender = sendButton
	if not sender then pause("No mouse-input backend."); return false end
	state.held = true
	local ok, reason = pcall(sender, true)
	if not ok then pause("Input rejected: " .. tostring(reason)); return false end
	state.releaseAt = now + Config.ClickHold
	state.nextClick = now + Config.ClickInterval
	return true
end

local function defaultSkillBindings(): boolean
	local attributes = player:GetAttributes()
	for _, key in { "HotbarLayout", "BarLayout" } do
		local value = attributes[key]
		if type(value) == "string" then
			local compact = value:gsub("%s", "")
			if compact ~= "" and compact ~= "{}" and compact ~= "[]" then return false end
		elseif type(value) == "table" and next(value) ~= nil then
			return false
		end
	end
	return true
end

local function skillTools(model: Model): { [string]: any }
	local tools: { [string]: any } = {}
	local function collect(container: Instance?)
		if not container then return end
		for _, child in container:GetChildren() do
			if child:IsA("Tool") then tools[child.Name] = child end
		end
	end
	collect(player:FindFirstChildOfClass("Backpack"))
	collect(model)
	return tools
end

local function waitCombat(now: number, reason: string): boolean
	if not combat.waitUntil then combat.waitUntil = now + Config.ComboWaitLimit end
	if now >= combat.waitUntil then
		cancelCombat(reason)
		return false
	end
	combat.status = reason
	combat.due = now + 0.05
	return true
end

local function stepCombat(own: Rig, target: Rig, now: number, distance: number): boolean
	if not combat.enabled then return false end
	if combat.owner ~= own.model then
		cancelCombat("Новый персонаж")
		combat.owner = own.model
		combat.nextUse = {}
	end
	local attributes = own.model:GetAttributes()
	local tools = skillTools(own.model)
	local readyKit = attributes.Character == "Bald" and attributes.LoadedCharacter ~= false and attributes.Ulted ~= true
	for name in saitama.skills do if not tools[name] then readyKit = false end end
	local reason: string? = nil
	if not readyKit then reason = "M1: нужен обычный набор Сайтамы" end
	if not defaultSkillBindings() then reason = "M1: нужны стандартные кнопки 1–4" end
	if attributes.Stunned == true or attributes.Ragdolled == true or attributes.Ragdoll == true then
		reason = "Комбо прервано: оглушение"
	end
	if reason then
		if combat.active then cancelCombat(reason) else combat.status = reason end
		return false
	end
	if combat.active and combat.target ~= target.model then
		cancelCombat("Цель сменилась")
		return true
	end
	if not combat.active then
		if now < combat.nextStart or distance > Config.AttackDistance then return false end
		local chosen = nil
		for offset = 0, #saitama.plans - 1 do
			local candidateIndex = (combat.routeCursor - 1 + offset) % #saitama.plans + 1
			local candidate = saitama.plans[candidateIndex]
			local available = true
			for _, action in candidate.steps do
				if action.kind == "skill" then
					local name = action.skill
					if (combat.nextUse[name] or 0) > now or tools[name].Enabled == false then available = false end
				end
			end
			if available then
				chosen = candidate
				combat.routeCursor = candidateIndex % #saitama.plans + 1
				break
			end
		end
		if not chosen then combat.status = "M1: ожидание умений"; return false end
		if not releaseMouse() then pause("Mouse release failed before combo."); return true end
		combat.active, combat.plan, combat.target = true, chosen, target.model
		combat.index, combat.due = 1, now + Config.ComboResetDelay
		combat.waitUntil = nil
		combat.status = "Подготовка: " .. chosen.name
		return true
	end
	if combat.confirmAt then
		if distance > Config.AttackDistance then
			cancelCombat("Цель ушла перед подтверждением")
			return true
		end
		if now >= combat.confirmAt then
			if pressM1(now) then combat.confirmAt = nil end
		end
		return true
	end
	if now < combat.due or combat.heldSlot then return true end
	local plan = combat.plan
	local action = plan.steps[combat.index]
	if not action then
		cancelCombat("Последовательность завершена")
		return false
	end
	local maxRange = if action.kind == "skill" then saitama.skills[action.skill].range else Config.AttackDistance
	if distance > maxRange then return waitCombat(now, "Ожидание дистанции") end
	if action.kind == "m1" then
		if attributes.M1Ready == false then return waitCombat(now, "Ожидание M1") end
		if not pressM1(now) then return true end
		combat.status = "Комбо: M1 " .. tostring(combat.index) .. "/3"
	else
		local name = action.skill
		local tool = tools[name]
		if not tool or tool.Enabled == false or (combat.nextUse[name] or 0) > now then
			return waitCombat(now, "Ожидание: " .. name)
		end
		if not releaseMouse() then pause("Mouse release failed before skill."); return true end
		local sender = sendSkillKey
		if not sender then
			combat.enabled = false
			cancelCombat("Нет ввода клавиш")
			return false
		end
		local spec = saitama.skills[name]
		combat.heldSlot = spec.slot
		combat.keyReleaseAt = now + Config.SkillKeyHold
		local ok, errorMessage = pcall(sender, spec.slot, true)
		if not ok then
			combat.enabled = false
			local released = cancelCombat("Ошибка ввода умения")
			notify("Skill input rejected: " .. tostring(errorMessage) .. ". F7: report.")
			if not released then pause("Skill key release failed; release it manually.") end
			return true
		end
		combat.keyAttempts += 1
		combat.lastAttempt = name .. " [" .. tostring(spec.slot) .. "]"
		combat.nextUse[name] = now + spec.retry
		combat.status = "Комбо: " .. name
		if combat.confirmClick then combat.confirmAt = now + Config.SkillKeyHold + 0.04 end
	end
	combat.waitUntil = nil
	combat.index += 1
	combat.due = now + action.delay
	return true
end

local function layoutUI()
	local available = ui.container.AbsoluteSize
	if available.X <= 0 or available.Y <= 0 then return end
	local scale = math.max(0.1, math.min(1, (available.X - 24) / 292, (available.Y - 24) / 356))
	ui.scale.Scale = scale
	ui.x = math.clamp(ui.x, 8, math.max(8, available.X - 292 * scale - 8))
	ui.y = math.clamp(ui.y, 8, math.max(8, available.Y - 356 * scale - 8))
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
	panel.Size = UDim2.fromOffset(292, 356)
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
	local header = label("Header", "TSB BOT  /  v0.4", 0, 36, 15, false)
	header.Size = UDim2.new(1, -64, 0, 36)
	header.Active = true
	ui.fighterLabel = label("Fighter", "Боец: определяем...", 44, 26, 15, false)
	ui.hintLabel = label("Hint", "Отчёт поможет проверить бойца", 72, 18, 12, true)
	ui.statusLabel = label("Status", "На паузе", 98, 20, 13, false)
	label("Shortcuts", "F6: бот  F7: отчёт  F8: комбо  F9: ЛКМ", 334, 16, 10, true)
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
	ui.comboButton = button("Combos", "Комбо Сайтамы: выкл [F8]", 178)
	ui.confirmButton = button("Confirmation", "Умение: только клавиша [F9]", 230)
	local reportButton = button("Report", "Отчёт о бойце [F7]", 282)
	local close = button("Close", "X", 2)
	close.Size = UDim2.fromOffset(36, 32)
	close.Position = UDim2.new(1, -40, 0, 2)
	local function connect(event: RBXScriptSignal, callback: (...any) -> ())
		table.insert(ui.connections, event:Connect(callback))
	end
	connect(ui.toggleButton.Activated, toggleBot)
	connect(ui.comboButton.Activated, toggleCombos)
	connect(ui.confirmButton.Activated, toggleConfirmation)
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
		local displayName = if snapshot.activeId == "Bald" then "Сайтама" elseif snapshot.activeId == "Hunter" then "Гароу" else cleanText(snapshot.activeId)
		ui.fighterLabel.Text = "Боец: " .. displayName
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
	ui.comboButton.Text = if combat.enabled then "Комбо Сайтамы: вкл [F8]" else "Комбо Сайтамы: выкл [F8]"
	ui.confirmButton.Text = if combat.confirmClick then "Умение: клавиша + ЛКМ [F9]" else "Умение: только клавиша [F9]"
	if not state.enabled then
		ui.statusLabel.Text = "На паузе"
	elseif not state.focused then
		ui.statusLabel.Text = "Ожидаем возврата в игру"
	elseif Input:GetFocusedTextBox() then
		ui.statusLabel.Text = "Пауза: ввод текста"
	elseif pointerOverUI() then
		ui.statusLabel.Text = "Пауза: управление панелью"
	elseif combat.enabled then
		ui.statusLabel.Text = combat.status
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
	if state.enabled and combat.heldSlot and now >= combat.keyReleaseAt then
		if not releaseSkillKey() then
			combat.enabled = false
			pause("Skill key release failed; press/release the digit manually.")
			return
		end
	end
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
		if combat.active then cancelCombat("Поиск противника") end
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
	if stepCombat(own, target, now, offset.Magnitude) then return end
	if offset.Magnitude > Config.AttackDistance then
		releaseMouse()
		return
	end
	pressM1(now)
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
	if input.KeyCode == Config.ComboKey then toggleCombos(); return end
	if input.KeyCode == Config.ConfirmKey then toggleConfirmation(); return end
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
notify("Loaded v0.4, paused. F6: bot; F7: report; F8: combos; F9: skill click. Input: " .. backend)

