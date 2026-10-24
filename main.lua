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
		"TSB Bot fighter report v0.2.0",
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
	suspend()
	-- A transient backend error gets one immediate retry during unload.
	if state.held then releaseMouse() end
	if registry[registryKey] == controller then registry[registryKey] = nil end
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
		return
	end
	if input.KeyCode == Config.ToggleKey then
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
notify("Loaded v0.2, paused. F6: enable; F7: fighter report; End: unload. Input: " .. backend)

