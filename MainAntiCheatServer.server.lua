--[[
    MainAntiCheatServer.server.lua  (v5 — Final)
    Location: ServerScriptService / MainAntiCheatServer.server.lua

    ═══════════════════════════════════════════════════════════════════
    SETUP — READ THIS FIRST
    ═══════════════════════════════════════════════════════════════════

    STEP 1 — Enable HTTP
      Studio → Home → Game Settings → Security
      → "Allow HTTP Requests" = ON

    STEP 2 — Folder structure (everything is created by scripts, except this):
      ReplicatedStorage/
        Modules/
          AntiCheatManager   (ModuleScript)
          PlayerTracker      (ModuleScript)
          ReplayBuffer       (ModuleScript)
          ReplayController   (ModuleScript)
          WebhookService     (ModuleScript)
      ServerScriptService/
        MainAntiCheatServer  (Script  ← this file)
      StarterPlayer/
        StarterPlayerScripts/
          AntiCheatClient    (LocalScript)

      DO NOT create any RemoteEvents manually.
      The server creates all of them automatically on startup.

    STEP 3 — Discord Alert Webhook (auto-flag notifications)
      1. In Discord: go to your alerts channel → Edit Channel
         → Integrations → Webhooks → New Webhook → Copy URL
      2. Paste it into CONFIG.WebhookURL below.

    STEP 4 — Discord Remote Commands (optional)
      This lets you type commands in a Discord channel and have them
      run in your game. It requires a Discord BOT TOKEN, NOT a webhook.

      HOW TO GET YOUR BOT TOKEN:
        1. Go to https://discord.com/developers/applications
        2. Click "New Application" → give it any name → Create
        3. Click "Bot" in the left sidebar
        4. Click "Reset Token" → copy the token that appears
           (it looks like: MTIz...ABC.xyz)
        5. Under "Privileged Gateway Intents" enable "Message Content Intent"
        6. Click "OAuth2" → "URL Generator"
           → tick "bot" scope → tick "Read Message History" + "Send Messages"
           → copy the generated URL and open it in your browser to invite the bot
        7. Paste the token below as:  "Bot MTIz...ABC.xyz"
           (keep the "Bot " prefix with a space)

      HOW TO GET YOUR CHANNEL ID:
        1. In Discord: Settings → Advanced → Developer Mode = ON
        2. Right-click the channel you want to use → "Copy Channel ID"
        3. Paste it into CONFIG.DiscordChannelId below

      HOW TO GET YOUR DISCORD USER ID:
        1. Right-click your own name anywhere in Discord → "Copy User ID"
        2. Add it (as a string) to CONFIG.DiscordAdminIds

      COMMANDS (type in the Discord channel):
        ac: freeze PlayerName
        ac: unfreeze PlayerName
        ac: kick PlayerName
        ac: whitelist PlayerName
        ac: unwhitelist PlayerName
        ac: score PlayerName
        ac: players
        ac: acstop
        ac: acstart
        ac: help

    ═══════════════════════════════════════════════════════════════════
    IN-GAME ADMIN COMMANDS (invisible in chat, only admins can use):
      !replay <name> [firstperson|thirdperson|topdown]
      !stopreplay
      !freeze <name>     !unfreeze <name>
      !whitelist <name>  !unwhitelist <name>
      !score <name>
      !kick <name>
      !players
      !acstop            !acstart
      !help
    ═══════════════════════════════════════════════════════════════════
--]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local HttpService       = game:GetService("HttpService")

-- ─────────────────────────────────────────────────────────────────────────────
-- ⚙️  CONFIGURATION  — only section you need to edit
-- ─────────────────────────────────────────────────────────────────────────────
local CONFIG = {
	-- Detection
	MaxSpeedStuds          = 32,
	MaxAirTimeSecs         = 3.5,
	TeleportThreshold      = 80,

	-- Violation scoring
	SpeedViolationScore    = 15,
	FlyViolationScore      = 20,
	TeleportViolationScore = 30,
	ViolationDecayRate     = 2,     -- pts/second passive decay
	FlagThreshold          = 60,

	-- Timing / buffer
	ReportCooldownSecs     = 30,
	BufferLengthSecs       = 60,
	TickRate               = 20,

	-- ── Discord alert webhook ─────────────────────────────────────────────────
	-- Paste the webhook URL here (from Step 3 above).
	-- Leave as "" to disable alert webhooks.
	WebhookURL     = "YOURE WEBHOOK HERE",
	WebhookEnabled = true,

	-- ── Discord remote commands ───────────────────────────────────────────────
	-- See Step 4 above for how to fill these in.
	-- Leave DiscordBotToken as "" to disable remote commands entirely.
	DiscordBotToken  = "Bot ",      -- "Bot YOUR_TOKEN_HERE"
	DiscordChannelId = "", -- "YOURE CHANNEL ID"
	DiscordPollSecs  = 5,

	-- Discord user IDs (as strings) allowed to send remote commands
	DiscordAdminIds  = {
		"YOURE DISCORD USER ID",
	},
}

-- ─────────────────────────────────────────────────────────────────────────────
-- 👑  ADMIN SETUP
--     The game OWNER is always an admin automatically (via game.CreatorId).
--     Add extra trusted Roblox UserIds below.
-- ─────────────────────────────────────────────────────────────────────────────
local ADMIN_USER_IDS = {
	-- 123456789,
}

local OWNER_ID   = game.CreatorId
local OWNER_TYPE = game.CreatorType

local function isAdmin(player)
	if RunService:IsStudio() then return true end
	if OWNER_TYPE == Enum.CreatorType.User and player.UserId == OWNER_ID then
		return true
	end
	for _, id in ipairs(ADMIN_USER_IDS) do
		if player.UserId == id then return true end
	end
	return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- MODULE REQUIRES
-- ─────────────────────────────────────────────────────────────────────────────
local Modules = ReplicatedStorage:WaitForChild("Modules", 15)
assert(Modules, "[AntiCheat] ReplicatedStorage/Modules folder not found.")

local AntiCheatManager = require(Modules:WaitForChild("AntiCheatManager"))
local ReplayController = require(Modules:WaitForChild("ReplayController"))

-- ─────────────────────────────────────────────────────────────────────────────
-- SYSTEM INIT
-- ─────────────────────────────────────────────────────────────────────────────
local manager    = AntiCheatManager.new(CONFIG)
local replayCtrl = ReplayController.new()
local whitelist  = {}   -- [userId: number] = true

manager.IsExempt = function(p) return whitelist[p.UserId] == true end

-- ─────────────────────────────────────────────────────────────────────────────
-- REMOTE EVENTS  (all created here — do not create them manually in Studio)
-- ─────────────────────────────────────────────────────────────────────────────
local function makeEvent(name)
	local e      = Instance.new("RemoteEvent")
	e.Name       = name
	e.Parent     = ReplicatedStorage
	return e
end

local evCamera   = makeEvent("AC_CameraDirection")
local evReplay   = makeEvent("AC_ReplayEvent")      -- used by ReplayController internally
local evAdminMsg = makeEvent("AC_AdminMessage")
local evCmd      = makeEvent("AC_Command")
local evHelp     = makeEvent("AC_HelpData")
local evReady    = makeEvent("AC_Ready")

-- Camera: rate-limited, server-side validation
local lastCam = {}
evCamera.OnServerEvent:Connect(function(player, look)
	if typeof(look) ~= "Vector3" then return end
	if look.Magnitude < 0.05 or look.Magnitude > 10 then return end
	local now = tick()
	if lastCam[player] and now - lastCam[player] < 0.4 then return end
	lastCam[player] = now
	local t = manager:GetTracker(player)
	if t then t:SetCameraLookVector(look) end
end)

-- Signal each client that the server is ready to receive events
local function signalReady(player)
	task.defer(function() evReady:FireClient(player) end)
end
for _, p in ipairs(Players:GetPlayers()) do signalReady(p) end
Players.PlayerAdded:Connect(signalReady)

Players.PlayerRemoving:Connect(function(p)
	lastCam[p] = nil
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- HELPERS
-- ─────────────────────────────────────────────────────────────────────────────
local function adminMsg(player, text)
	if player then evAdminMsg:FireClient(player, text) end
end

local function broadcastAdmins(text)
	for _, p in ipairs(Players:GetPlayers()) do
		if isAdmin(p) then adminMsg(p, text) end
	end
end

local function findPlayer(name)
	if not name then return nil end
	local lo = name:lower()
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Name:lower() == lo then return p end
	end
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Name:lower():sub(1, #lo) == lo then return p end
	end
	return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- COMMAND TABLE  (drives both !help GUI and Discord ac: help)
-- ─────────────────────────────────────────────────────────────────────────────
local COMMANDS = {
	{ cmd = "!replay <n> [mode]",  desc = "POV replay | modes: firstperson thirdperson topdown" },
	{ cmd = "!stopreplay",          desc = "Stop the current replay" },
	{ cmd = "!freeze <n>",          desc = "Freeze a player in place" },
	{ cmd = "!unfreeze <n>",        desc = "Unfreeze + reset violation score" },
	{ cmd = "!whitelist <n>",       desc = "Disable anti-cheat for this player" },
	{ cmd = "!unwhitelist <n>",     desc = "Re-enable anti-cheat for this player" },
	{ cmd = "!score <n>",           desc = "Show violation score and recent events" },
	{ cmd = "!kick <n>",            desc = "Kick a player from the server" },
	{ cmd = "!players",             desc = "List all online players and scores" },
	{ cmd = "!acstop",              desc = "Emergency: stop anti-cheat system" },
	{ cmd = "!acstart",             desc = "Restart anti-cheat after stop" },
	{ cmd = "!help",                desc = "Show this command panel" },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- COMMAND HANDLER
--   admin  = Player object for in-game, nil for Discord
--   reply  = function(text) — where to send the response
-- ─────────────────────────────────────────────────────────────────────────────
local cmdCooldowns = {}

local CAM_MODES = {
	firstperson = "FirstPerson",
	thirdperson = "ThirdPerson",
	topdown     = "TopDown",
}

local function handle(admin, raw, reply)
	-- Per-player rate-limit (in-game only)
	if admin then
		local now = tick()
		if cmdCooldowns[admin] and now - cmdCooldowns[admin] < 1 then return end
		cmdCooldowns[admin] = now
	end

	local parts = {}
	for t in raw:gmatch("%S+") do table.insert(parts, t:lower()) end
	if #parts == 0 then return end
	local cmd = parts[1]

	-- !help
	if cmd == "!help" then
		if admin then
			evHelp:FireClient(admin, COMMANDS)
		else
			local lines = { "**Anti-Cheat Commands (Discord prefix: `ac:`)**" }
			for _, e in ipairs(COMMANDS) do
				table.insert(lines, "`" .. e.cmd .. "` — " .. e.desc)
			end
			reply(table.concat(lines, "\n"))
		end

		-- !replay
	elseif cmd == "!replay" then
		if not admin then reply("❌ Replay is in-game only.") return end
		if replayCtrl:IsReplaying(admin) then
			reply("⚠️ Replay running. Use !stopreplay first.") return
		end
		local t = findPlayer(parts[2])
		if not t then reply("❌ Player not found: " .. tostring(parts[2])) return end
		local mode = CAM_MODES[parts[3]] or "FirstPerson"
		local tr   = manager:GetTracker(t)
		if not tr then reply("❌ No tracker for " .. t.Name) return end
		local frames = tr:GetReplaySnapshot()
		if #frames == 0 then reply("❌ No frames recorded for " .. t.Name .. " yet.") return end
		reply("▶ Replaying " .. t.Name .. " — " .. #frames .. " frames — " .. mode)
		replayCtrl:PlayReplay({
			frames     = frames,
			viewer     = admin,
			subject    = t,
			cameraMode = mode,
			onComplete = function() reply("⏹ Replay of " .. t.Name .. " ended.") end,
		})

		-- !stopreplay
	elseif cmd == "!stopreplay" then
		if not admin then reply("❌ In-game only.") return end
		replayCtrl:StopReplay(admin)
		reply("⏹ Replay stopped.")

		-- !freeze
	elseif cmd == "!freeze" then
		local t = findPlayer(parts[2])
		if not t then reply("❌ Player not found.") return end
		manager:FreezePlayer(t)
		reply("🔒 Frozen: " .. t.Name)
		if not admin then broadcastAdmins("🔒 [Discord] Froze: " .. t.Name) end

		-- !unfreeze
	elseif cmd == "!unfreeze" then
		local t = findPlayer(parts[2])
		if not t then reply("❌ Player not found.") return end
		manager:UnfreezePlayer(t)
		reply("🔓 Unfrozen: " .. t.Name)
		if not admin then broadcastAdmins("🔓 [Discord] Unfroze: " .. t.Name) end

		-- !whitelist
	elseif cmd == "!whitelist" then
		local t = findPlayer(parts[2])
		if not t then reply("❌ Player not found.") return end
		whitelist[t.UserId] = true
		manager:UnfreezePlayer(t)
		local tr = manager:GetTracker(t)
		if tr then tr:ResetScore() end
		reply("✅ Whitelisted (AC off): " .. t.Name)
		if not admin then broadcastAdmins("✅ [Discord] Whitelisted: " .. t.Name) end

		-- !unwhitelist
	elseif cmd == "!unwhitelist" then
		local t = findPlayer(parts[2])
		if not t then reply("❌ Player not found.") return end
		whitelist[t.UserId] = nil
		reply("🔄 Unwhitelisted (AC on): " .. t.Name)
		if not admin then broadcastAdmins("🔄 [Discord] Unwhitelisted: " .. t.Name) end

		-- !score
	elseif cmd == "!score" then
		local t = findPlayer(parts[2])
		if not t then reply("❌ Player not found.") return end
		local tr = manager:GetTracker(t)
		if not tr then reply(t.Name .. " has no tracker.") return end
		local score  = math.floor(tr:GetViolationScore())
		local log    = tr:GetViolationLog()
		local recent = {}
		for i = math.max(1, #log - 4), #log do
			table.insert(recent, log[i].type .. "(" .. log[i].score .. ")")
		end
		reply(string.format("📊 %s — %d/%d pts | %s",
			t.Name, score, CONFIG.FlagThreshold,
			#recent > 0 and table.concat(recent, ", ") or "clean"))

		-- !kick
	elseif cmd == "!kick" then
		local t = findPlayer(parts[2])
		if not t then reply("❌ Player not found.") return end
		if isAdmin(t) then reply("❌ Cannot kick an admin.") return end
		t:Kick("Removed by an administrator.")
		reply("👢 Kicked: " .. t.Name)
		if not admin then broadcastAdmins("👢 [Discord] Kicked: " .. t.Name) end

		-- !players
	elseif cmd == "!players" then
		local list = Players:GetPlayers()
		if #list == 0 then reply("No players online.") return end
		local lines = { "👥 " .. #list .. " player(s) online:" }
		for _, p in ipairs(list) do
			local tr    = manager:GetTracker(p)
			local score = tr and math.floor(tr:GetViolationScore()) or 0
			local wl    = whitelist[p.UserId] and " [WL]" or ""
			table.insert(lines, "  • " .. p.Name .. wl .. " — " .. score .. " pts")
		end
		reply(table.concat(lines, "\n"))

		-- !acstop
	elseif cmd == "!acstop" then
		manager:Stop()
		reply("🛑 Anti-cheat stopped.")
		if not admin then broadcastAdmins("🛑 [Discord] Anti-cheat stopped remotely.") end

		-- !acstart
	elseif cmd == "!acstart" then
		manager:Start()
		reply("✅ Anti-cheat started.")
		if not admin then broadcastAdmins("✅ [Discord] Anti-cheat started remotely.") end

	else
		reply("❓ Unknown command '" .. cmd .. "'. Type !help.")
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- IN-GAME CHAT INTERCEPTION  (invisible commands)
-- ─────────────────────────────────────────────────────────────────────────────

-- Path A: new TextChatService — client sends via AC_Command RemoteEvent
evCmd.OnServerEvent:Connect(function(player, msg)
	if type(msg) ~= "string"  then return end
	if msg:sub(1,1) ~= "!"   then return end
	if #msg > 256             then return end
	if not isAdmin(player)    then return end
	handle(player, msg, function(text) adminMsg(player, text) end)
end)

-- Path B: legacy .Chatted fallback
local function hookChat(player)
	player.Chatted:Connect(function(msg)
		if msg:sub(1,1) ~= "!" then return end
		if not isAdmin(player)  then return end
		handle(player, msg, function(text) adminMsg(player, text) end)
	end)
end
for _, p in ipairs(Players:GetPlayers()) do hookChat(p) end
Players.PlayerAdded:Connect(hookChat)
Players.PlayerRemoving:Connect(function(p) cmdCooldowns[p] = nil; lastCam[p] = nil end)

-- ─────────────────────────────────────────────────────────────────────────────
-- FLAGGED CALLBACK
-- ─────────────────────────────────────────────────────────────────────────────
manager.OnPlayerFlagged = function(player, log)
	local types = {}
	for _, v in ipairs(log or {}) do table.insert(types, v.type or "?") end
	-- Notify all online admins
	broadcastAdmins("🚨 FLAGGED: " .. player.Name .. " | " .. table.concat(types, ", "))
	-- Optional auto-kick:
	-- task.wait(5)
	-- if player and player.Parent then player:Kick("Anti-cheat violation.") end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- DISCORD REMOTE COMMANDS
--   Polls the configured channel every DiscordPollSecs seconds.
--   Processes messages starting with "ac:" from authorised Discord user IDs.
-- ─────────────────────────────────────────────────────────────────────────────

local function isDiscordAdmin(id)
	for _, v in ipairs(CONFIG.DiscordAdminIds) do
		if tostring(v) == tostring(id) then return true end
	end
	return false
end

local function discordPost(text)
	if CONFIG.DiscordBotToken == "" or CONFIG.DiscordChannelId == "" then return end
	task.spawn(function()
		pcall(HttpService.PostAsync, HttpService,
			"https://discord.com/api/v10/channels/" .. CONFIG.DiscordChannelId .. "/messages",
			HttpService:JSONEncode({ content = text }),
			Enum.HttpContentType.ApplicationJson,
			false,
			{ Authorization = CONFIG.DiscordBotToken }
		)
	end)
end

local lastDiscordId = nil

local function pollDiscord()
	local url = "https://discord.com/api/v10/channels/"
		.. CONFIG.DiscordChannelId .. "/messages?limit=10"
	if lastDiscordId then url = url .. "&after=" .. lastDiscordId end

	local ok, raw = pcall(HttpService.GetAsync, HttpService, url, false,
		{ Authorization = CONFIG.DiscordBotToken })
	if not ok then return end

	local dok, msgs = pcall(HttpService.JSONDecode, HttpService, raw)
	if not dok or type(msgs) ~= "table" then return end

	-- Process oldest first (Discord returns newest first)
	for i = #msgs, 1, -1 do
		local msg      = msgs[i]
		local id       = tostring(msg.id or "")
		local content  = (msg.content or ""):lower():match("^%s*(.-)%s*$")
		local authorId = tostring((msg.author or {}).id or "")

		if id ~= "" then lastDiscordId = id end
		if not isDiscordAdmin(authorId) then continue end
		if content:sub(1, 3) ~= "ac:" then continue end

		local rawCmd = "!" .. content:sub(4):match("^%s*(.-)%s*$")
		handle(nil, rawCmd, discordPost)
	end
end

if CONFIG.DiscordBotToken ~= "" and CONFIG.DiscordChannelId ~= "" then
	task.spawn(function()
		task.wait(3)
		-- Bootstrap: record the latest message ID so old commands aren't replayed
		local ok, raw = pcall(HttpService.GetAsync, HttpService,
			"https://discord.com/api/v10/channels/" .. CONFIG.DiscordChannelId .. "/messages?limit=1",
			false, { Authorization = CONFIG.DiscordBotToken })
		if ok then
			local dok, msgs = pcall(HttpService.JSONDecode, HttpService, raw)
			if dok and type(msgs) == "table" and msgs[1] then
				lastDiscordId = tostring(msgs[1].id)
			end
		end
		while true do
			task.wait(CONFIG.DiscordPollSecs)
			pcall(pollDiscord)
		end
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- START
-- ─────────────────────────────────────────────────────────────────────────────
manager:Start()
