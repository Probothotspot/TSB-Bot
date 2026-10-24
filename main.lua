--!strict
-- The Strongest Battlegrounds: nearest visible player, approach, M1 input.
-- F6: enable/pause. End: unload. Starts paused.
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
notify("Loaded, paused. F6: enable; End: unload. Input: " .. backend)

