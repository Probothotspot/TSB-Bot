--!strict
-- The Strongest Battlegrounds: M1 and cooldown-aware normal-form Saitama skills.
-- F6: bot. F7: report. F8: combos. F9: skill click. F10: targets. End: unload.
-- No downloaded code or game-specific remote payloads.

local Config = {
	AutoStart = true,
	AutoCombos = true,
	ConfirmSkillClick = true,
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
	TargetsKey = Enum.KeyCode.F10,
	UnloadKey = Enum.KeyCode.End,
	ComboRetryDelay = 0.9,
	SkillKeyHold = 0.12,
	KeyReceiptTimeout = 0.4,
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
local keyboard: { [string]: any } = {
	keys = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four },
	backends = {}, current = nil, active = nil, pending = nil,
	calls = 0, received = 0, errors = {}, lastError = "none", lastReceived = "none",
}
do
	local ok, manager = pcall(function() return game:GetService("VirtualInputManager") end)
	if ok and manager then
		table.insert(keyboard.backends, {
			name = "VirtualInputManager", kind = "engine",
			send = function(slot: number, down: boolean)
				manager:SendKeyEvent(down, keyboard.keys[slot], false, game)
			end,
		})
	end
end
-- VirtualInputManager is the only skill-key backend: confirmed in the user's v0.7 report.
if #keyboard.backends > 0 then
	skillBackend = keyboard.backends[1].name
	sendSkillKey = function(slot: number, down: boolean)
		if not down then
			local index = keyboard.active
			if index then
				keyboard.backends[index].send(slot, false)
				keyboard.active = nil
			end
			return
		end
		for index, candidate in keyboard.backends do
			if candidate.failed then continue end
			keyboard.current, keyboard.active = index, index
			skillBackend = candidate.name
			keyboard.calls += 1
			local ok, reason = pcall(candidate.send, slot, true)
			if ok then return end
			local released, releaseError = pcall(candidate.send, slot, false)
			candidate.failed = true
			keyboard.lastError = candidate.name .. ": " .. tostring(reason)
			table.insert(keyboard.errors, keyboard.lastError)
			if not released and candidate.kind == "native" then
				error(keyboard.lastError .. "; release failed: " .. tostring(releaseError))
			end
			keyboard.active = nil
		end
		error("No keyboard backend accepted the call: " .. table.concat(keyboard.errors, " | "))
	end
end

-- Readiness comes from the actual hotbar. Recovery delays only pace accepted input.
local saitama = {
	slotNames = { "Normal Punch", "Consecutive Punches", "Shove", "Uppercut" },
	priority = { 2, 3, 1 },
	skills = {
		["Normal Punch"] = { slot = 1, recovery = 1.0, range = 6 },
		["Consecutive Punches"] = { slot = 2, recovery = 1.9, range = 5 },
		["Shove"] = { slot = 3, recovery = 0.65, range = 5 },
		["Uppercut"] = { slot = 4, recovery = 0.95, range = 5 },
	},
}
local combat: { [string]: any } = {
	enabled = Config.AutoCombos, confirmClick = Config.ConfirmSkillClick, active = false, owner = nil, target = nil,
	index = 1, due = 0, nextStart = 0,
	heldSlot = nil, keyReleaseAt = 0, confirmAt = nil,
	retryAt = {}, status = "Готов к бою", lastAttempt = "none", keyAttempts = 0,
	cancelReason = "none", cancelled = 0,
	prone = false, proneSource = "not sampled", confirmRange = Config.AttackDistance,
}

type Rig = { model: Model, human: Humanoid, root: BasePart }
type CombatTarget = Player | Model
local state = {
	enabled = Config.AutoStart,
	destroyed = false,
	focused = false,
	target = nil :: CombatTarget?,
	targetMode = "all",
	held = false,
	releaseAt = 0,
	nextClick = 0,
	nextScan = 0,
	drivenHuman = nil :: Humanoid?,
}
do
	local focusProbe = external.isrbxactive or external.iswindowactive
	if type(focusProbe) == "function" then
		local ok, focused = pcall(focusProbe)
		state.focused = ok and focused == true
	end
end
local connections: { RBXScriptConnection } = {}
local dummyTargets: { [Model]: boolean } = setmetatable({}, { __mode = "k" })

local function isDummy(model: Model): boolean
	local function matches(value: string): boolean
		local name = value:lower():gsub("[^%w]", "")
		return name == "weakestdummy" or name == "weakerstdammy" or name == "weakestdammy"
	end
	if matches(model.Name) then return true end
	local human = model:FindFirstChildOfClass("Humanoid")
	return human ~= nil and matches(human.DisplayName)
end

local function rememberDummy(object: Instance)
	local ancestor: Instance? = object
	while ancestor and ancestor ~= Workspace do
		if ancestor:IsA("Model") and isDummy(ancestor) then
			dummyTargets[ancestor] = true
			return
		end
		ancestor = ancestor.Parent
	end
end

local function targetName(candidate: CombatTarget?): string
	if not candidate then return "none" end
	if candidate:IsA("Player") then return candidate.DisplayName .. " [player]" end
	local human = candidate:FindFirstChildOfClass("Humanoid")
	local name = if human and human.DisplayName ~= "" then human.DisplayName else candidate.Name
	return name .. " [NPC]"
end

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

type CooldownReading = { ready: boolean?, fraction: number?, source: string, reason: string }
local function readCooldown(slot: number): CooldownReading
	local parent = player:FindFirstChildOfClass("PlayerGui")
	local hotbar = parent and parent:FindFirstChild("Hotbar")
	local backpack = hotbar and hotbar:FindFirstChild("Backpack")
	local slots = backpack and backpack:FindFirstChild("Hotbar")
	local item = slots and slots:FindFirstChild(tostring(slot))
	local base = item and item:FindFirstChild("Base")
	local source = "Hotbar.Backpack.Hotbar." .. tostring(slot) .. ".Base"
	if not base or not base:IsA("GuiObject") then
		return { ready = nil, fraction = nil, source = source, reason = "missing live slot" }
	end
	local label = base:FindFirstChild("ToolName")
	if not label or not label:IsA("TextLabel") or label.Text ~= saitama.slotNames[slot] then
		return { ready = nil, fraction = nil, source = source, reason = "skill label mismatch" }
	end
	local cooldown = base:FindFirstChild("Cooldown")
	if not cooldown then
		return { ready = true, fraction = 0, source = source .. ".Cooldown", reason = "overlay absent" }
	end
	if not cooldown:IsA("GuiObject") then
		return { ready = nil, fraction = nil, source = source .. ".Cooldown", reason = "unexpected cooldown class" }
	end
	local height = cooldown.Size.Y.Scale
	local offset = cooldown.Size.Y.Offset
	if offset ~= 0 then
		if base.AbsoluteSize.Y <= 0 then
			return { ready = nil, fraction = nil, source = source .. ".Cooldown", reason = "slot not measured" }
		end
		height += offset / base.AbsoluteSize.Y
	end
	-- TSB draws its active overlay UPWARDS: the observed Y.Scale was -0.776453793.
	local fraction = math.abs(height)
	if fraction ~= fraction or fraction == math.huge then
		return { ready = nil, fraction = nil, source = source .. ".Cooldown", reason = "invalid height" }
	end
	return { ready = fraction <= 0.0001, fraction = fraction, source = source .. ".Cooldown", reason = "live overlay height" }
end

local function cooldownText(slot: number, reading: CooldownReading): string
	local value = "?"
	if reading.ready == true then value = "готов" end
	if reading.ready == false then value = "КД" end
	return tostring(slot) .. ":" .. value
end

local function fighterReport(): string
	local snapshot = sampleFighter()
	local lines = {
		"TSB Bot fighter report v0.8.0",
		"PlaceId: " .. tostring(game.PlaceId),
		"Status: " .. snapshot.status,
		"Active ID: " .. cleanText(snapshot.activeId or "unknown"),
		"Selected ID: " .. cleanText(snapshot.selectedId or "unknown"),
		"Source: " .. (snapshot.source or "none"),
		"Target mode: " .. state.targetMode,
		"Bot enabled: " .. tostring(state.enabled),
		"Window focused: " .. tostring(state.focused),
		"Current target: " .. cleanText(targetName(state.target)),
		"M1 input: " .. backend,
		"Skill input: " .. skillBackend,
		"Keyboard send calls: " .. tostring(keyboard.calls),
		"Numeric InputBegan receipts: " .. tostring(keyboard.received),
		"Last numeric key received: " .. keyboard.lastReceived,
		"Keyboard delivery error: " .. cleanText(keyboard.lastError),
		"Keyboard backend failures: " .. cleanText(table.concat(keyboard.errors, " | ")),
		"Combo enabled: " .. tostring(combat.enabled),
		"Skill click confirmation: " .. tostring(combat.confirmClick),
		"Combo state: " .. cleanText(combat.status),
		"Combo step index: " .. tostring(combat.index),
		"Last combo cancellation: " .. cleanText(combat.cancelReason),
		"Combo cancellations: " .. tostring(combat.cancelled),
		"Last skill input attempt: " .. cleanText(combat.lastAttempt),
		"Skill input attempts: " .. tostring(combat.keyAttempts),
		"Target prone: " .. tostring(combat.prone) .. " [" .. combat.proneSource .. "]",
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
	for slot = 1, 4 do
		local reading = readCooldown(slot)
		table.insert(lines, "Cooldown " .. tostring(slot) .. ": ready=" .. tostring(reading.ready)
			.. " fraction=" .. tostring(reading.fraction) .. " source=" .. reading.source .. " reason=" .. reading.reason)
	end
	local dummyNames: { string } = {}
	for model in dummyTargets do
		if model:IsDescendantOf(Workspace) then table.insert(dummyNames, model.Name) end
	end
	table.sort(dummyNames)
	table.insert(lines, "Detected training NPCs: " .. cleanText(table.concat(dummyNames, " | ")))
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

local function getRig(candidate: CombatTarget): Rig?
	local model = if candidate:IsA("Player") then candidate.Character else candidate
	if not model or not model:IsDescendantOf(Workspace) then return nil end
	local human = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart") or (human and human.RootPart)
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
	if combat.active then
		releaseMouse()
		combat.cancelReason = reason
		combat.cancelled += 1
	end
	combat.active, combat.target = false, nil
	combat.confirmAt = nil
	keyboard.pending = nil
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
		botEnabled = state.enabled, focused = state.focused,
		enabled = combat.enabled, active = combat.active, status = combat.status,
		index = combat.index, heldSlot = combat.heldSlot,
		confirmClick = combat.confirmClick, keyAttempts = combat.keyAttempts,
		lastAttempt = combat.lastAttempt, inputRetryAt = table.clone(combat.retryAt),
		cooldowns = { readCooldown(1), readCooldown(2), readCooldown(3), readCooldown(4) },
		targetProne = combat.prone, proneSource = combat.proneSource,
		keyReceipts = keyboard.received, keyboardCalls = keyboard.calls, keyboardError = keyboard.lastError,
		keyboardBackend = skillBackend,
		targetMode = state.targetMode, targetName = targetName(state.target),
	}
end

function controller.Destroy()
	if state.destroyed then return end
	state.destroyed = true
	state.enabled = false
	RunService:UnbindFromRenderStep(bindName)
	for _, connection in connections do connection:Disconnect() end
	table.clear(connections)
	table.clear(dummyTargets)
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

local function toggleTargets()
	suspend()
	if state.targetMode == "all" then
		state.targetMode = "dummy"
	elseif state.targetMode == "dummy" then
		state.targetMode = "players"
	else
		state.targetMode = "all"
	end
	notify("Targets: " .. state.targetMode .. ". F10: change.")
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

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true

local function targetProne(own: Rig, target: Rig): (boolean, string)
	local attributes = target.model:GetAttributes()
	local flag: string? = nil
	for _, name in { "Ragdoll", "Ragdolled", "Downed" } do
		if attributes[name] == true then flag = name; break end
	end
	local human = target.human
	local stateName = human:GetState()
	local torso = target.model:FindFirstChild("Torso") or target.model:FindFirstChild("UpperTorso") or target.root
	local horizontal = torso:IsA("BasePart") and math.abs(torso.CFrame.UpVector.Y) < 0.55
	local physicsState = stateName == Enum.HumanoidStateType.Ragdoll
		or stateName == Enum.HumanoidStateType.FallingDown
		or stateName == Enum.HumanoidStateType.Physics
		or stateName == Enum.HumanoidStateType.PlatformStanding
	if not flag and not horizontal and not physicsState and not human.PlatformStand then return false, "upright" end
	local grounded = human.FloorMaterial ~= Enum.Material.Air
	if not grounded then
		groundParams.FilterDescendantsInstances = { own.model, target.model }
		grounded = Workspace:Raycast(torso.Position, Vector3.new(0, -2.5, 0), groundParams) ~= nil
	end
	if not grounded then return false, "airborne" end
	if flag then return true, "attribute:" .. flag .. " + ground" end
	return true, if horizontal then "horizontal torso + ground" else "humanoid physics + ground"
end

local function stepCombat(own: Rig, target: Rig, now: number, distance: number): boolean
	combat.prone, combat.proneSource = targetProne(own, target)
	if not combat.enabled then return false end
	if not sendSkillKey then combat.status = "Умения: нет ввода клавиатуры"; return false end
	if combat.owner ~= own.model then
		cancelCombat("Новый персонаж")
		combat.owner, combat.retryAt, combat.nextStart, combat.due = own.model, {}, now, 0
	end
	local attributes = own.model:GetAttributes()
	local tools = skillTools(own.model)
	local readyKit = attributes.Character == "Bald" and attributes.LoadedCharacter ~= false and attributes.Ulted ~= true
	for name in saitama.skills do if not tools[name] then readyKit = false end end
	local reason: string? = nil
	if not readyKit then reason = "M1: нужен обычный набор Сайтамы" end
	if not defaultSkillBindings() then reason = "M1: нужны стандартные кнопки 1–4" end
	if attributes.Stunned == true or attributes.Ragdolled == true or attributes.Ragdoll == true then
		reason = "Умения прерваны: оглушение"
	end
	if reason then
		if combat.active then cancelCombat(reason) else combat.status = reason end
		return false
	end
	if combat.active and combat.target ~= target.model then
		cancelCombat("Цель сменилась")
		return true
	end
	local pending = keyboard.pending
	if pending then
		if pending.echoed then
			keyboard.lastError = "none"
			-- A short input debounce, never a substitute for the live cooldown overlay.
			combat.retryAt[pending.name] = now + 0.5
			combat.due = now + pending.delay
			combat.status = "Кнопка получена: " .. pending.name
			keyboard.pending = nil
			if combat.confirmClick then combat.confirmAt = math.max(now, combat.keyReleaseAt) + 0.04 end
		elseif now >= pending.deadline then
			if not releaseSkillKey() then pause("Keyboard release failed after missing input receipt."); return true end
			local candidate = keyboard.backends[keyboard.current]
			candidate.failed = true
			keyboard.lastError = candidate.name .. ": no numeric InputBegan within " .. tostring(Config.KeyReceiptTimeout) .. "s"
			table.insert(keyboard.errors, keyboard.lastError)
			keyboard.pending = nil
			combat.enabled = false
			cancelCombat("Roblox не получил кнопки 1–4")
			notify("VirtualInputManager did not deliver numeric keys. Skill mode stopped; F7: diagnostics.")
		end
		return true
	end
	if combat.confirmAt then
		if distance > combat.confirmRange then cancelCombat("Цель ушла перед подтверждением"); return true end
		if now >= combat.confirmAt and pressM1(now) then combat.confirmAt = nil end
		return true
	end
	if combat.active then
		if now < combat.due or combat.heldSlot then return true end
		combat.active, combat.target = false, nil
	end
	if now < combat.nextStart then return false end
	local function available(slot: number): boolean
		local name = saitama.slotNames[slot]
		return tools[name].Enabled ~= false and (combat.retryAt[name] or 0) <= now and readCooldown(slot).ready == true
	end
	local chosen: number? = nil
	if combat.prone and available(4) then chosen = 4 end
	if not chosen then
		for _, slot in saitama.priority do
			if available(slot) then chosen = slot; break end
		end
	end
	if not chosen then combat.status = "M1: нет готовых умений (см. КД)"; return false end
	local name = saitama.slotNames[chosen]
	local spec = saitama.skills[name]
	if distance > spec.range then combat.status = "Подходим: " .. name; return false end
	if not releaseMouse() then pause("Mouse release failed before skill."); return true end
	combat.active, combat.target, combat.index = true, target.model, chosen
	combat.confirmRange = spec.range
	combat.heldSlot = chosen
	combat.keyReleaseAt = now + Config.SkillKeyHold
	keyboard.pending = { slot = chosen, name = name, delay = spec.recovery, deadline = now + Config.KeyReceiptTimeout, echoed = false }
	local ok, errorMessage = pcall(sendSkillKey, chosen, true)
	if not ok then
		combat.enabled = false
		local released = cancelCombat("Ошибка ввода умения")
		notify("Skill input rejected: " .. tostring(errorMessage) .. ". F7: report.")
		if not released then pause("Skill key release failed; release it manually.") end
		return true
	end
	combat.keyAttempts += 1
	combat.lastAttempt = name .. " [" .. tostring(chosen) .. "]"
	combat.status = "Ждём кнопку " .. tostring(chosen) .. ": " .. name
	return true
end

local function layoutUI()
	local available = ui.container.AbsoluteSize
	if available.X <= 0 or available.Y <= 0 then return end
	local scale = math.max(0.1, math.min(1, (available.X - 24) / 292, (available.Y - 24) / 428))
	ui.scale.Scale = scale
	ui.x = math.clamp(ui.x, 8, math.max(8, available.X - 292 * scale - 8))
	ui.y = math.clamp(ui.y, 8, math.max(8, available.Y - 428 * scale - 8))
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
	panel.Size = UDim2.fromOffset(292, 428)
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
	local header = label("Header", "TSB BOT  /  v0.8.0", 0, 36, 15, false)
	header.Size = UDim2.new(1, -64, 0, 36)
	header.Active = true
	ui.fighterLabel = label("Fighter", "Боец: определяем...", 44, 26, 15, false)
	ui.hintLabel = label("Hint", "Отчёт поможет проверить бойца", 72, 18, 12, true)
	ui.cooldownLabel = label("Cooldowns", "КД: читаем панель…", 98, 18, 12, true)
	ui.statusLabel = label("Status", "На паузе", 118, 20, 13, false)
	label("Shortcuts", "F6: бот  F7: отчёт  F8/F9: бой  F10: цели", 406, 16, 10, true)
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
	ui.toggleButton = button("Toggle", "Включить бота", 146)
	ui.targetsButton = button("Targets", "Цели: игроки + манекен [F10]", 198)
	ui.comboButton = button("Combos", "Умения Сайтамы: выкл [F8]", 250)
	ui.confirmButton = button("Confirmation", "Умение: только клавиша [F9]", 302)
	local reportButton = button("Report", "Отчёт о бойце [F7]", 354)
	local close = button("Close", "X", 2)
	close.Size = UDim2.fromOffset(36, 32)
	close.Position = UDim2.new(1, -40, 0, 2)
	local function connect(event: RBXScriptSignal, callback: (...any) -> ())
		table.insert(ui.connections, event:Connect(callback))
	end
	connect(ui.toggleButton.Activated, toggleBot)
	connect(ui.targetsButton.Activated, toggleTargets)
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
		ui.hintLabel.Text = "Клавиш получено: " .. tostring(keyboard.received) .. " / попыток: " .. tostring(combat.keyAttempts)
	elseif snapshot.selectedId then
		ui.fighterLabel.Text = "Выбран: " .. cleanText(snapshot.selectedId)
		ui.hintLabel.Text = "Активный боец ещё не подтверждён"
	else
		ui.fighterLabel.Text = "Боец: не определён"
		ui.hintLabel.Text = "Нажми «Отчёт» для проверки"
	end
	local cdLabels = {}
	for slot = 1, 4 do table.insert(cdLabels, cooldownText(slot, readCooldown(slot))) end
	ui.cooldownLabel.Text = table.concat(cdLabels, "  ")
	ui.toggleButton.Text = if state.enabled then "Пауза [F6]" else "Включить бота [F6]"
	ui.toggleButton.BackgroundColor3 = if state.enabled then Color3.fromRGB(160, 61, 73) else Color3.fromRGB(35, 142, 102)
	ui.comboButton.Text = if combat.enabled then "Умения Сайтамы: вкл [F8]" else "Умения Сайтамы: выкл [F8]"
	ui.confirmButton.Text = if combat.confirmClick then "Умение: клавиша + ЛКМ [F9]" else "Умение: только клавиша [F9]"
	local targetsLabel = if state.targetMode == "dummy" then "только манекен" elseif state.targetMode == "players" then "только игроки" else "игроки + манекен"
	ui.targetsButton.Text = "Цели: " .. targetsLabel .. " [F10]"
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
		ui.statusLabel.Text = "Цель: " .. cleanText(targetName(state.target))
	else
		ui.statusLabel.Text = "Поиск противника"
	end
end

local function targetRig(candidate: CombatTarget?, own: Rig, radius: number): Rig?
	if not candidate or candidate == player then return nil end
	if candidate:IsA("Player") then
		if state.targetMode == "dummy" or candidate.Parent ~= Players then return nil end
	else
		if state.targetMode == "players" or not isDummy(candidate) or Players:GetPlayerFromCharacter(candidate) then return nil end
	end
	local rig = getRig(candidate)
	if not rig or rig.model == own.model or rig.model:FindFirstChildOfClass("ForceField") then return nil end
	local offset = rig.root.Position - own.root.Position
	if offset.Magnitude > radius or math.abs(offset.Y) > Config.MaxHeightDifference then return nil end
	rayParams.FilterDescendantsInstances = { own.model }
	local hit = Workspace:Raycast(own.root.Position, offset, rayParams)
	if hit and not hit.Instance:IsDescendantOf(rig.model) then return nil end
	return rig
end

local function acquire(own: Rig): CombatTarget?
	local nearest: CombatTarget? = nil
	local distance = Config.AcquireRadius
	local function consider(candidate: CombatTarget)
		local rig = targetRig(candidate, own, distance)
		if rig then
			nearest = candidate
			distance = (rig.root.Position - own.root.Position).Magnitude
		end
	end
	if state.targetMode ~= "dummy" then
		for _, candidate in Players:GetPlayers() do consider(candidate) end
	end
	if state.targetMode ~= "players" then
		for model in dummyTargets do consider(model) end
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
	state.focused = true
	local pending = keyboard.pending
	if pending and not pending.echoed and input.KeyCode == keyboard.keys[pending.slot] and os.clock() <= pending.deadline then
		pending.echoed = true
		keyboard.received += 1
		keyboard.lastReceived = tostring(pending.slot) .. " via " .. skillBackend
	end
	if input.KeyCode == Config.UnloadKey and not Input:GetFocusedTextBox() then
		controller.Destroy()
		notify("Unloaded.")
		return
	end
	if processed or Input:GetFocusedTextBox() then return end
	if input.KeyCode == Config.TargetsKey then toggleTargets(); return end
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
table.insert(connections, Workspace.DescendantAdded:Connect(rememberDummy))
table.insert(connections, Workspace.DescendantRemoving:Connect(function(object)
	if object:IsA("Model") then dummyTargets[object] = nil end
end))
for _, object in Workspace:GetDescendants() do rememberDummy(object) end
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
notify("Loaded v0.8.0: live cooldowns; priority 2 > 3 > 1, 4 on prone targets. F6: pause; End: unload.")

