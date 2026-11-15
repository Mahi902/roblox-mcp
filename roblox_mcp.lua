-- Roblox <-> MCP bridge client (for your own private game)
-- Run via loader.lua. Enter Worker URL + token in the on-screen panel.
-- Settings are saved on this device (if the executor supports writefile).

local Players         = game:GetService("Players")
local HttpService     = game:GetService("HttpService")
local VIM             = game:GetService("VirtualInputManager")
local GuiService      = game:GetService("GuiService")
local TextChatService = game:GetService("TextChatService")
local lp = Players.LocalPlayer

local req = request or http_request or (syn and syn.request) or (http and http.request)
assert(req, "This executor has no request() function")

-- stop any previous instance
getgenv().MCP_RUN = (getgenv().MCP_RUN or 0) + 1
if getgenv().MCP_GUI then pcall(function() getgenv().MCP_GUI:Destroy() end) end

----------------------------------------------------------------------
-- config
----------------------------------------------------------------------
local CONFIG_FILE = "mcp_config.json"
local BASE, KEY = "", ""

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function loadConfig()
	if isfile and readfile and isfile(CONFIG_FILE) then
		local ok, d = pcall(function() return HttpService:JSONDecode(readfile(CONFIG_FILE)) end)
		if ok and type(d) == "table" then BASE, KEY = d.base or "", d.key or "" end
	end
end

local function saveConfig()
	if writefile then pcall(writefile, CONFIG_FILE, HttpService:JSONEncode({ base = BASE, key = KEY })) end
end

-- accepts a bare worker URL or a full MCP URL (".../mcp?key=TOKEN")
local function cleanBase(s)
	s = trim(s)
	local k = s:match("[?&]key=([^&%s]+)")
	s = s:gsub("%?.*$", "")
	s = s:gsub("/mcp/?$", "")
	s = s:gsub("/+$", "")
	if s ~= "" and not s:match("^https?://") then s = "https://" .. s end
	return s, k
end

----------------------------------------------------------------------
-- http
----------------------------------------------------------------------
local function http(method, path, body)
	return req({
		Url = BASE .. path .. (KEY ~= "" and ((path:find("?") and "&" or "?") .. "key=" .. KEY) or ""),
		Method = method,
		Headers = { ["Content-Type"] = "application/json" },
		Body = body and HttpService:JSONEncode(body) or nil,
	})
end

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local WHITE = Color3.new(1, 1, 1)
local GREEN, RED, BLUE = Color3.fromRGB(34, 139, 70), Color3.fromRGB(170, 40, 40), Color3.fromRGB(40, 90, 170)

local function mk(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	o.Parent = parent
	return o
end

local gui = mk("ScreenGui", { Name = "MCPStatus", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 999 }, nil)
local okp = pcall(function() gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
if not okp or not gui.Parent then gui.Parent = lp:WaitForChild("PlayerGui") end
getgenv().MCP_GUI = gui

local pill = mk("TextButton", {
	Size = UDim2.fromOffset(240, 28), Position = UDim2.new(0.5, -120, 0, 8),
	BackgroundTransparency = 0.15, TextColor3 = WHITE, Font = Enum.Font.GothamBold,
	TextSize = 13, Text = "MCP: not configured", BackgroundColor3 = BLUE, AutoButtonColor = false,
}, gui)
mk("UICorner", { CornerRadius = UDim.new(1, 0) }, pill)

local function setStatus(text, color)
	pill.Text = text
	pill.BackgroundColor3 = color
end

local panel = mk("Frame", {
	Size = UDim2.fromOffset(300, 214), Position = UDim2.new(0.5, -150, 0, 44),
	BackgroundColor3 = Color3.fromRGB(28, 28, 32), Visible = false,
}, gui)
mk("UICorner", { CornerRadius = UDim.new(0, 10) }, panel)
mk("TextLabel", {
	Size = UDim2.new(1, -20, 0, 24), Position = UDim2.fromOffset(10, 8), BackgroundTransparency = 1,
	Text = "Roblox MCP Bridge", TextColor3 = WHITE, Font = Enum.Font.GothamBold, TextSize = 15,
	TextXAlignment = Enum.TextXAlignment.Left,
}, panel)

local function box(y, placeholder)
	local b = mk("TextBox", {
		Size = UDim2.new(1, -20, 0, 32), Position = UDim2.fromOffset(10, y),
		BackgroundColor3 = Color3.fromRGB(45, 45, 52), TextColor3 = WHITE,
		PlaceholderText = placeholder, PlaceholderColor3 = Color3.fromRGB(140, 140, 150),
		Text = "", ClearTextOnFocus = false, Font = Enum.Font.Gotham, TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
	}, panel)
	mk("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
	mk("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, b)
	return b
end

local urlBox = box(40, "Worker URL (https://...workers.dev)")
local keyBox = box(80, "Token (optional)")

local connectBtn = mk("TextButton", {
	Size = UDim2.new(1, -20, 0, 34), Position = UDim2.fromOffset(10, 124),
	BackgroundColor3 = GREEN, TextColor3 = WHITE, Font = Enum.Font.GothamBold, TextSize = 14,
	Text = "Save & Connect",
}, panel)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, connectBtn)

mk("TextLabel", {
	Size = UDim2.new(1, -20, 0, 40), Position = UDim2.fromOffset(10, 166), BackgroundTransparency = 1,
	Text = "Saved on this device. Tap the status pill to open or hide this panel.",
	TextColor3 = Color3.fromRGB(150, 150, 160), Font = Enum.Font.Gotham, TextSize = 11,
	TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
}, panel)

pill.Activated:Connect(function() panel.Visible = not panel.Visible end)

----------------------------------------------------------------------
-- command handlers
----------------------------------------------------------------------
local function hum()
	local c = lp.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end
local function root()
	local c = lp.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function r1(n) return math.floor(n * 10 + 0.5) / 10 end

local function guiList()
	local out = {}
	local pg = lp:FindFirstChildOfClass("PlayerGui")
	if not pg then return out end
	for _, o in ipairs(pg:GetDescendants()) do
		if o:IsA("TextButton") or o:IsA("ImageButton") or o:IsA("TextLabel") then
			local visible, sg = o.Visible, nil
			local p = o.Parent
			while visible and p and p ~= pg do
				if p:IsA("GuiObject") and not p.Visible then visible = false end
				if p:IsA("ScreenGui") then
					sg = p
					if not p.Enabled then visible = false end
					break
				end
				p = p.Parent
			end
			local text = (o:IsA("ImageButton") and "") or o.Text
			if visible and sg and o.AbsoluteSize.X > 0 and (o:IsA("GuiButton") or text ~= "") then
				local inset = sg.IgnoreGuiInset and Vector2.zero or GuiService:GetGuiInset()
				local c = o.AbsolutePosition + o.AbsoluteSize / 2 + inset
				table.insert(out, {
					name = o.Name, class = o.ClassName, text = text,
					x = math.floor(c.X), y = math.floor(c.Y),
				})
				if #out >= 80 then break end
			end
		end
	end
	return out
end

local function stringify(v)
	local ok, s = pcall(HttpService.JSONEncode, HttpService, v)
	if ok then return s end
	return tostring(v)
end

local H = {}

function H.get_state()
	local cam, r, h = workspace.CurrentCamera, root(), hum()
	local others = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= lp then table.insert(others, p.Name) end
	end
	return {
		player = lp.Name,
		placeId = game.PlaceId,
		position = r and { x = r1(r.Position.X), y = r1(r.Position.Y), z = r1(r.Position.Z) } or nil,
		health = h and h.Health or nil,
		walkSpeed = h and h.WalkSpeed or nil,
		viewport = { x = cam.ViewportSize.X, y = cam.ViewportSize.Y },
		players = others,
		gui = guiList(),
	}
end

function H.click(a)
	local btn = (a.button == "right") and 1 or 0
	VIM:SendMouseMoveEvent(a.x, a.y, game)
	task.wait(0.03)
	VIM:SendMouseButtonEvent(a.x, a.y, btn, true, game, 1)
	task.wait(0.05)
	VIM:SendMouseButtonEvent(a.x, a.y, btn, false, game, 1)
	return "clicked"
end

function H.mouse_move(a)
	VIM:SendMouseMoveEvent(a.x, a.y, game)
	return "moved"
end

function H.scroll(a)
	VIM:SendMouseWheelEvent(a.x, a.y, a.direction == "up", game)
	return "scrolled"
end

function H.press_key(a)
	local code = Enum.KeyCode[a.key]
	assert(code, "unknown key " .. tostring(a.key))
	VIM:SendKeyEvent(true, code, false, game)
	task.wait(a.seconds or 0.05)
	VIM:SendKeyEvent(false, code, false, game)
	return "pressed"
end

function H.move_to(a)
	local h = assert(hum(), "no humanoid")
	local done, reached = false, false
	local conn = h.MoveToFinished:Connect(function(r) done, reached = true, r end)
	h:MoveTo(Vector3.new(a.x, a.y, a.z))
	local t0 = os.clock()
	while not done and os.clock() - t0 < (a.timeout or 10) do task.wait(0.1) end
	conn:Disconnect()
	return { reached = reached }
end

function H.jump()
	local h = assert(hum(), "no humanoid")
	h.Jump = true
	return "jumped"
end

function H.chat(a)
	local channels = TextChatService:FindFirstChild("TextChannels")
	local general = channels and channels:FindFirstChild("RBXGeneral")
	if general then
		general:SendAsync(a.message)
	else
		game:GetService("ReplicatedStorage").DefaultChatSystemChatEvents.SayMessageRequest:FireServer(a.message, "All")
	end
	return "sent"
end

function H.run_lua(a)
	local f, err = loadstring(a.code)
	if not f then error(err, 0) end
	local res = table.pack(f())
	if res.n == 0 then return "done" end
	local parts = {}
	for i = 1, res.n do parts[i] = typeof(res[i]) == "string" and res[i] or stringify(res[i]) end
	return table.concat(parts, "\t")
end

local function exec(cmd)
	setStatus("MCP: " .. tostring(cmd.action), BLUE)
	local h = H[cmd.action]
	local ok, res
	if h then ok, res = pcall(h, cmd.args or {}) else ok, res = false, "unknown action " .. tostring(cmd.action) end
	pcall(http, "POST", "/result", {
		id = cmd.id,
		ok = ok,
		result = ok and res or nil,
		error = (not ok) and tostring(res) or nil,
	})
	if ok then setStatus("MCP: connected", GREEN) else setStatus("MCP: error - " .. tostring(cmd.action), RED) end
end

----------------------------------------------------------------------
-- connection loop
----------------------------------------------------------------------
local function start()
	getgenv().MCP_RUN = (getgenv().MCP_RUN or 0) + 1
	local myRun = getgenv().MCP_RUN
	setStatus("MCP: connecting...", BLUE)

	task.spawn(function()
		local connected = false
		while getgenv().MCP_RUN == myRun do
			if not connected then
				local ok, r = pcall(http, "GET", "/")
				local code = ok and r and r.StatusCode
				if code == 200 then
					connected = true
					setStatus("MCP: connected", GREEN)
				else
					setStatus("MCP: disconnected (" .. tostring(code or "no response") .. ")", RED)
					task.wait(3)
				end
			else
				local ok, r = pcall(http, "GET", "/poll")
				if ok and r and r.StatusCode == 200 then
					local ok2, cmds = pcall(HttpService.JSONDecode, HttpService, r.Body)
					if ok2 then
						for _, c in ipairs(cmds) do task.spawn(exec, c) end
					end
					task.wait(0.05)
				else
					connected = false
				end
			end
		end
	end)
end

connectBtn.Activated:Connect(function()
	local b, k = cleanBase(urlBox.Text)
	local key = trim(keyBox.Text)
	if key == "" and k then key = k end
	if b == "" then
		setStatus("MCP: enter Worker URL", RED)
		return
	end
	BASE, KEY = b, key
	urlBox.Text, keyBox.Text = b, key
	saveConfig()
	panel.Visible = false
	start()
end)

loadConfig()
if BASE ~= "" then
	urlBox.Text, keyBox.Text = BASE, KEY
	start()
else
	panel.Visible = true
end
