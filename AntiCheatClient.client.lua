--[[
    AntiCheatClient.client.lua  (v6)
    Location: StarterPlayer / StarterPlayerScripts / AntiCheatClient.client.lua

    CHANGES vs v5:
      • Replay camera is now THIRD PERSON — follows behind/above the rig
        like the normal Roblox follow camera, instead of POV.
      • HUD now shows a 📷 camera mode badge next to the frame counter.
      • hideself() is skipped when the local player is the subject.
--]]

local Players          = game:GetService("Players")
local ReplicatedStorage= game:GetService("ReplicatedStorage")
local RunService       = game:GetService("RunService")
local TextChatService  = game:GetService("TextChatService")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local cam         = workspace.CurrentCamera

-- Third person offsets (studs)
local CAM_DISTANCE = 12   -- how far behind the rig
local CAM_HEIGHT   = 5    -- how far above the rig's root

-- ─────────────────────────────────────────────────────────────────────────────
-- Wait for RemoteEvents
-- ─────────────────────────────────────────────────────────────────────────────
local RS = ReplicatedStorage

local function waitEv(name)
	return RS:WaitForChild(name, 20)
end

local evCamera   = waitEv("AC_CameraDirection")
local evReplay   = waitEv("AC_ReplayEvent")
local evAdminMsg = waitEv("AC_AdminMessage")
local evCmd      = waitEv("AC_Command")
local evHelp     = waitEv("AC_HelpData")
local evReady    = waitEv("AC_Ready")

if not evCamera or not evReplay or not evAdminMsg or not evCmd then
	warn("[AntiCheat] Core RemoteEvents not found. Server script may not be running.")
	return
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SERVER-READY GATE
-- ─────────────────────────────────────────────────────────────────────────────
local serverReady = false

if evReady then
	evReady.OnClientEvent:Connect(function() serverReady = true end)
else
	task.delay(4, function() serverReady = true end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. COMMAND INTERCEPTION
-- ─────────────────────────────────────────────────────────────────────────────
pcall(function()
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then return end
	TextChatService.SendingMessage:Connect(function(msg)
		local text = msg.Text or ""
		if text:sub(1,1) ~= "!" then return end
		if serverReady then evCmd:FireServer(text) end
		return Enum.TextChatMessageStatus.Sending
	end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. CAMERA DIRECTION REPORTING
-- ─────────────────────────────────────────────────────────────────────────────
local lastCamSend = 0
RunService.RenderStepped:Connect(function()
	if not serverReady then return end
	local now = tick()
	if now - lastCamSend < 0.5 then return end
	lastCamSend = now
	local look = cam.CFrame.LookVector
	if look.Magnitude > 0.1 then evCamera:FireServer(look) end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. REPLAY
-- ─────────────────────────────────────────────────────────────────────────────

local replayActive = false
local savedCamType = Enum.CameraType.Custom
local currentFrame = nil   -- latest { cf, look } from server
local hudGui       = nil
local frameLabel   = nil
local camBadge     = nil   -- the 📷 badge TextLabel

local hiddenOthers = {}
local hiddenSelf   = {}
local hiddenRig    = {}

local function hideParts(list, storage)
	for _, part in ipairs(list) do
		if part:IsA("BasePart") or part:IsA("Decal") then
			table.insert(storage, { p = part, v = part.LocalTransparencyModifier })
			part.LocalTransparencyModifier = 1
		end
	end
end

local function restoreParts(storage)
	for _, entry in ipairs(storage) do
		if entry.p and entry.p.Parent then
			entry.p.LocalTransparencyModifier = entry.v
		end
	end
	table.clear(storage)
end

local function hideOtherPlayers()
	for _, p in ipairs(Players:GetPlayers()) do
		if p == localPlayer then continue end
		if p.Character then hideParts(p.Character:GetDescendants(), hiddenOthers) end
	end
end

local function hideself()
	local char = localPlayer.Character
	if char then hideParts(char:GetDescendants(), hiddenSelf) end
end

local function hideRig()
	local rig = workspace:FindFirstChild("__AC_ReplayDummy__")
	if not rig then return end
	for _, desc in ipairs(rig:GetDescendants()) do
		if desc:IsA("BasePart") or desc:IsA("Decal") then
			local already = false
			for _, e in ipairs(hiddenRig) do
				if e.p == desc then already = true; break end
			end
			if not already then
				table.insert(hiddenRig, { p = desc, v = desc.LocalTransparencyModifier })
			end
			desc.LocalTransparencyModifier = 1
		end
		if desc:IsA("BillboardGui") or desc:IsA("Highlight") then
			desc.Enabled = false
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- THIRD PERSON CAMERA
-- Runs every RenderStepped during replay.
-- Places the camera CAM_DISTANCE studs behind the rig and CAM_HEIGHT above,
-- looking at the rig's head — exactly like Roblox's default follow camera.
-- ─────────────────────────────────────────────────────────────────────────────
RunService.RenderStepped:Connect(function()
	if not replayActive then return end
	if not currentFrame  then return end

	local cf   = currentFrame.cf    -- rig's HumanoidRootPart CFrame this frame
	local look = currentFrame.look  -- the direction the subject was looking

	-- Use the subject's recorded look direction to orient the camera behind them.
	-- Fall back to the rig's own facing direction if look is invalid.
	local facing
	if look and look.Magnitude > 0.05 then
		facing = look.Unit
	else
		facing = cf.LookVector
	end

	-- Target point: the rig's upper body (eye level)
	local target = cf.Position + Vector3.new(0, CAM_HEIGHT * 0.4, 0)

	-- Camera origin: behind and above the rig along its facing direction
	local origin = target
	- facing * CAM_DISTANCE
		+ Vector3.new(0, CAM_HEIGHT, 0)

	-- Look from origin toward target (smooth, no roll)
	cam.CFrame = CFrame.lookAt(origin, target)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- REPLAY HUD
-- ─────────────────────────────────────────────────────────────────────────────
local function buildHUD(subjectName, totalFrames, cameraMode)
	if hudGui then hudGui:Destroy() end

	local gui             = Instance.new("ScreenGui")
	gui.Name              = "AC_ReplayHUD"
	gui.IgnoreGuiInset    = true
	gui.ResetOnSpawn      = false
	gui.Parent            = localPlayer.PlayerGui

	-- Main badge panel
	local badge                   = Instance.new("Frame")
	badge.Size                    = UDim2.new(0, 360, 0, 56)
	badge.Position                = UDim2.new(0, 12, 0, 12)
	badge.BackgroundColor3        = Color3.fromRGB(8, 8, 8)
	badge.BackgroundTransparency  = 0.2
	badge.BorderSizePixel         = 0
	badge.Parent                  = gui
	Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 6)

	-- Red left accent stripe
	local accent              = Instance.new("Frame")
	accent.Size               = UDim2.new(0, 3, 1, 0)
	accent.BackgroundColor3   = Color3.fromRGB(255, 45, 30)
	accent.BorderSizePixel    = 0
	accent.Parent             = badge

	-- Title row: "⬤  POV REPLAY — PlayerName"
	local top                     = Instance.new("TextLabel")
	top.Size                      = UDim2.new(1, -14, 0, 24)
	top.Position                  = UDim2.new(0, 12, 0, 4)
	top.BackgroundTransparency    = 1
	top.Font                      = Enum.Font.GothamBold
	top.TextColor3                = Color3.fromRGB(255, 45, 30)
	top.TextSize                  = 14
	top.TextXAlignment            = Enum.TextXAlignment.Left
	top.Text                      = "⬤  REPLAY — " .. (subjectName or "?")
	top.Parent                    = badge

	-- Bottom row container (frame counter + camera badge side by side)
	local bottomRow               = Instance.new("Frame")
	bottomRow.Size                = UDim2.new(1, -14, 0, 20)
	bottomRow.Position            = UDim2.new(0, 12, 0, 30)
	bottomRow.BackgroundTransparency = 1
	bottomRow.Parent              = badge

	-- Frame counter label (left side of bottom row)
	local counter                 = Instance.new("TextLabel")
	counter.Name                  = "Counter"
	counter.Size                  = UDim2.new(0.62, 0, 1, 0)
	counter.BackgroundTransparency= 1
	counter.Font                  = Enum.Font.Gotham
	counter.TextColor3            = Color3.fromRGB(150, 150, 150)
	counter.TextSize              = 11
	counter.TextXAlignment        = Enum.TextXAlignment.Left
	counter.Text                  = "0 / " .. tostring(totalFrames or 0)
		.. "  •  !stopreplay to exit"
	counter.Parent                = bottomRow

	-- 📷 Camera mode badge (right side of bottom row)
	local badge2                  = Instance.new("Frame")
	badge2.Size                   = UDim2.new(0.36, 0, 1, 0)
	badge2.Position               = UDim2.new(0.64, 0, 0, 0)
	badge2.BackgroundColor3       = Color3.fromRGB(30, 30, 35)
	badge2.BackgroundTransparency = 0.1
	badge2.BorderSizePixel        = 0
	badge2.Parent                 = bottomRow
	Instance.new("UICorner", badge2).CornerRadius = UDim.new(0, 4)

	local camLbl                  = Instance.new("TextLabel")
	camLbl.Name                   = "CamBadge"
	camLbl.Size                   = UDim2.new(1, 0, 1, 0)
	camLbl.BackgroundTransparency = 1
	camLbl.Font                   = Enum.Font.GothamBold
	camLbl.TextColor3             = Color3.fromRGB(100, 200, 255)
	camLbl.TextSize               = 11
	camLbl.Text                   = "📷 " .. (cameraMode or "ThirdPerson")
	camLbl.Parent                 = badge2

	hudGui    = gui
	camBadge  = camLbl
	return counter
end

local function destroyHUD()
	if hudGui then hudGui:Destroy(); hudGui = nil end
	camBadge = nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. HELP GUI
-- ─────────────────────────────────────────────────────────────────────────────
local helpGui = nil

local function buildHelpGui(commandList)
	if helpGui and helpGui.Parent then helpGui:Destroy() end

	local pg = localPlayer.PlayerGui

	local sg            = Instance.new("ScreenGui")
	sg.Name             = "AC_HelpGui"
	sg.IgnoreGuiInset   = true
	sg.ResetOnSpawn     = false
	sg.ZIndexBehavior   = Enum.ZIndexBehavior.Sibling
	sg.Parent           = pg

	local rowH    = 30
	local panelH  = 48 + (#commandList * (rowH + 2)) + 10

	local panel                   = Instance.new("Frame")
	panel.Name                    = "Panel"
	panel.Size                    = UDim2.new(0, 460, 0, panelH)
	panel.Position                = UDim2.new(0.5, -230, 0.5, -(panelH // 2))
	panel.BackgroundColor3        = Color3.fromRGB(12, 12, 15)
	panel.BackgroundTransparency  = 0.04
	panel.BorderSizePixel         = 0
	panel.ClipsDescendants        = true
	panel.Parent                  = sg
	Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 8)

	local stripe              = Instance.new("Frame")
	stripe.Size               = UDim2.new(0, 3, 1, 0)
	stripe.BackgroundColor3   = Color3.fromRGB(255, 45, 30)
	stripe.BorderSizePixel    = 0
	stripe.Parent             = panel

	local titleBar                = Instance.new("Frame")
	titleBar.Name                 = "TitleBar"
	titleBar.Size                 = UDim2.new(1, 0, 0, 40)
	titleBar.BackgroundColor3     = Color3.fromRGB(18, 18, 22)
	titleBar.BorderSizePixel      = 0
	titleBar.Parent               = panel

	local titleLbl                = Instance.new("TextLabel")
	titleLbl.Size                 = UDim2.new(1, -50, 1, 0)
	titleLbl.Position             = UDim2.new(0, 14, 0, 0)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Font                 = Enum.Font.GothamBold
	titleLbl.TextColor3           = Color3.fromRGB(255, 45, 30)
	titleLbl.TextSize             = 14
	titleLbl.TextXAlignment       = Enum.TextXAlignment.Left
	titleLbl.Text                 = "🛡  Anti-Cheat — Admin Commands"
	titleLbl.Parent               = titleBar

	local closeBtn                = Instance.new("TextButton")
	closeBtn.Size                 = UDim2.new(0, 30, 0, 30)
	closeBtn.Position             = UDim2.new(1, -36, 0, 5)
	closeBtn.BackgroundColor3     = Color3.fromRGB(190, 35, 25)
	closeBtn.BackgroundTransparency = 0.15
	closeBtn.BorderSizePixel      = 0
	closeBtn.Font                 = Enum.Font.GothamBold
	closeBtn.TextColor3           = Color3.fromRGB(255, 255, 255)
	closeBtn.TextSize             = 15
	closeBtn.Text                 = "✕"
	closeBtn.Parent               = titleBar
	Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)
	closeBtn.MouseButton1Click:Connect(function() sg:Destroy(); helpGui = nil end)
	closeBtn.MouseEnter:Connect(function() closeBtn.BackgroundTransparency = 0 end)
	closeBtn.MouseLeave:Connect(function() closeBtn.BackgroundTransparency = 0.15 end)

	local div             = Instance.new("Frame")
	div.Size              = UDim2.new(1, -6, 0, 1)
	div.Position          = UDim2.new(0, 3, 0, 40)
	div.BackgroundColor3  = Color3.fromRGB(45, 45, 50)
	div.BorderSizePixel   = 0
	div.Parent            = panel

	local list          = Instance.new("Frame")
	list.Size           = UDim2.new(1, -12, 0, panelH - 52)
	list.Position       = UDim2.new(0, 8, 0, 46)
	list.BackgroundTransparency = 1
	list.Parent         = panel
	local layout        = Instance.new("UIListLayout")
	layout.SortOrder    = Enum.SortOrder.LayoutOrder
	layout.Padding      = UDim.new(0, 2)
	layout.Parent       = list

	for i, entry in ipairs(commandList) do
		local row                   = Instance.new("Frame")
		row.Size                    = UDim2.new(1, 0, 0, rowH)
		row.BackgroundColor3        = i % 2 == 0
			and Color3.fromRGB(20, 20, 24) or Color3.fromRGB(16, 16, 19)
		row.BackgroundTransparency  = 0.05
		row.BorderSizePixel         = 0
		row.LayoutOrder             = i
		row.Parent                  = list
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, 4)

		local cmdL                  = Instance.new("TextLabel")
		cmdL.Size                   = UDim2.new(0.44, 0, 1, 0)
		cmdL.Position               = UDim2.new(0, 8, 0, 0)
		cmdL.BackgroundTransparency = 1
		cmdL.Font                   = Enum.Font.GothamBold
		cmdL.TextColor3             = Color3.fromRGB(255, 100, 80)
		cmdL.TextSize               = 12
		cmdL.TextXAlignment         = Enum.TextXAlignment.Left
		cmdL.Text                   = entry.cmd
		cmdL.Parent                 = row

		local descL                 = Instance.new("TextLabel")
		descL.Size                  = UDim2.new(0.55, 0, 1, 0)
		descL.Position              = UDim2.new(0.44, 0, 0, 0)
		descL.BackgroundTransparency= 1
		descL.Font                  = Enum.Font.Gotham
		descL.TextColor3            = Color3.fromRGB(145, 145, 150)
		descL.TextSize              = 11
		descL.TextXAlignment        = Enum.TextXAlignment.Left
		descL.TextTruncate          = Enum.TextTruncate.AtEnd
		descL.Text                  = entry.desc
		descL.Parent                = row
	end

	local dragging, dragStart, panelStart = false, nil, nil
	titleBar.InputBegan:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging   = true
			dragStart  = inp.Position
			panelStart = panel.Position
		end
	end)
	titleBar.InputEnded:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(inp)
		if not dragging then return end
		if inp.UserInputType ~= Enum.UserInputType.MouseMovement then return end
		local d = inp.Position - dragStart
		panel.Position = UDim2.new(
			panelStart.X.Scale, panelStart.X.Offset + d.X,
			panelStart.Y.Scale, panelStart.Y.Offset + d.Y)
	end)

	helpGui = sg
end

if evHelp then
	evHelp.OnClientEvent:Connect(buildHelpGui)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. ADMIN TOAST MESSAGES
-- ─────────────────────────────────────────────────────────────────────────────
local function showToast(text)
	local pg     = localPlayer.PlayerGui
	local msgGui = pg:FindFirstChild("AC_MsgGui") or (function()
		local g              = Instance.new("ScreenGui")
		g.Name               = "AC_MsgGui"
		g.IgnoreGuiInset     = true
		g.ResetOnSpawn       = false
		g.Parent             = pg
		return g
	end)()

	local kids = msgGui:GetChildren()
	if #kids >= 6 then kids[1]:Destroy() end
	local yOff = #msgGui:GetChildren() * 36

	local f                   = Instance.new("Frame")
	f.Size                    = UDim2.new(0, 480, 0, 30)
	f.Position                = UDim2.new(0, 12, 1, -(80 + yOff))
	f.BackgroundColor3        = Color3.fromRGB(8, 8, 10)
	f.BackgroundTransparency  = 0.12
	f.BorderSizePixel         = 0
	f.Parent                  = msgGui
	Instance.new("UICorner", f).CornerRadius = UDim.new(0, 4)

	local bar             = Instance.new("Frame")
	bar.Size              = UDim2.new(0, 3, 1, 0)
	bar.BackgroundColor3  = Color3.fromRGB(255, 45, 30)
	bar.BorderSizePixel   = 0
	bar.Parent            = f

	local lbl                 = Instance.new("TextLabel")
	lbl.Size                  = UDim2.new(1, -14, 1, 0)
	lbl.Position              = UDim2.new(0, 10, 0, 0)
	lbl.BackgroundTransparency= 1
	lbl.Font                  = Enum.Font.Gotham
	lbl.TextColor3            = Color3.fromRGB(215, 215, 215)
	lbl.TextSize              = 13
	lbl.TextXAlignment        = Enum.TextXAlignment.Left
	lbl.TextTruncate          = Enum.TextTruncate.AtEnd
	lbl.Text                  = text
	lbl.Parent                = f

	task.delay(5, function()
		if not f or not f.Parent then return end
		TweenService:Create(f,   TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
		TweenService:Create(lbl, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
		task.wait(0.55)
		if f and f.Parent then f:Destroy() end
	end)
end

evAdminMsg.OnClientEvent:Connect(showToast)

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. REPLAY EVENT HANDLER
-- ─────────────────────────────────────────────────────────────────────────────
evReplay.OnClientEvent:Connect(function(evType, data)
	data = data or {}

	if evType == "StartReplay" then
		replayActive   = true
		savedCamType   = cam.CameraType
		cam.CameraType = Enum.CameraType.Scriptable
		currentFrame   = nil

		hideOtherPlayers()

		-- Only hide self if we are NOT the subject being replayed
		local isSelf = (data.subjectUserId == localPlayer.UserId)
		if not isSelf then
			hideself()
		end

		-- The rig is shown in third person so we do NOT hide it here.
		-- We still hide the BillboardGui and Highlight so the screen
		-- isn't cluttered — the rig body itself stays visible.
		task.defer(function()
			local rig = workspace:FindFirstChild("__AC_ReplayDummy__")
			if not rig then return end
			for _, desc in ipairs(rig:GetDescendants()) do
				if desc:IsA("BillboardGui") or desc:IsA("Highlight") then
					desc.Enabled = false
				end
			end
		end)

		frameLabel = buildHUD(data.subjectName, data.frameCount, data.cameraMode)

	elseif evType == "Frame" then
		if not replayActive then return end
		currentFrame = { cf = data.cf, look = data.look }

		if frameLabel and frameLabel.Parent then
			frameLabel.Text = tostring(data.idx) .. " / " .. tostring(data.total)
				.. "  •  !stopreplay to exit"
		end

	elseif evType == "EndReplay" then
		replayActive   = false
		currentFrame   = nil
		cam.CameraType = savedCamType
		savedCamType   = Enum.CameraType.Custom

		restoreParts(hiddenOthers)
		restoreParts(hiddenSelf)
		restoreParts(hiddenRig)
		destroyHUD()
		frameLabel = nil

	elseif evType == "HideRig" then
		task.defer(function()
			local rig = workspace:FindFirstChild(data.rigName or "__AC_ReplayDummy__")
			if not rig then return end
			for _, p in ipairs(rig:GetDescendants()) do
				if p:IsA("BasePart") then p.LocalTransparencyModifier = 1 end
			end
		end)

	elseif evType == "ShowRig" then
		local rig = workspace:FindFirstChild(data.rigName or "__AC_ReplayDummy__")
		if rig then
			for _, p in ipairs(rig:GetDescendants()) do
				if p:IsA("BasePart") then p.LocalTransparencyModifier = 0 end
			end
		end
	end
end)
