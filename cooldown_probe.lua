--!strict
-- Read-only snapshot of the real hotbar and training dummy state.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer
assert(player, "Run inside Roblox.")
local lines = { "TSB cooldown and target probe v1", "PlaceId: " .. tostring(game.PlaceId) }
local function attributes(object: Instance)
	local values = object:GetAttributes()
	local keys: { string } = {}
	for key in values do table.insert(keys, key) end
	table.sort(keys)
	for _, key in keys do table.insert(lines, "  @" .. key .. "=" .. tostring(values[key])) end
end
local gui = player:FindFirstChildOfClass("PlayerGui")
if gui then
	for _, object in gui:GetDescendants() do
		local path = object:GetFullName()
		local lower = path:lower()
		if (lower:find("hotbar", 1, true) or lower:find("backpack", 1, true)) and not lower:find("kindmops", 1, true) then
			local value = path .. " [" .. object.ClassName .. "]"
			if object:IsA("GuiObject") then
				value ..= " visible=" .. tostring(object.Visible) .. " size=" .. tostring(object.Size) .. " absolute=" .. tostring(object.AbsoluteSize)
			end
			if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then value ..= " text=" .. object.Text end
			table.insert(lines, value)
			attributes(object)
		end
	end
end
for _, model in Workspace:GetDescendants() do
	if model:IsA("Model") and model.Name:lower():gsub("[^%w]", "") == "weakestdummy" then
		local human = model:FindFirstChildOfClass("Humanoid")
		if human then
			table.insert(lines, "TARGET " .. model:GetFullName())
			table.insert(lines, "  state=" .. tostring(human:GetState()) .. " platformStand=" .. tostring(human.PlatformStand) .. " floor=" .. tostring(human.FloorMaterial))
			attributes(model)
			for _, name in { "HumanoidRootPart", "Torso", "UpperTorso" } do
				local part = model:FindFirstChild(name)
				if part and part:IsA("BasePart") then table.insert(lines, "  " .. name .. ".UpY=" .. tostring(part.CFrame.UpVector.Y)) end
			end
		end
	end
end
local report = table.concat(lines, "\n")
print(report)
local external = getfenv()
if type(external.setclipboard) == "function" then
	local ok = pcall(external.setclipboard, report)
	if ok then print("[TSB] Cooldown report copied to clipboard.") end
end

