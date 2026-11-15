-- Roblox <-> MCP bridge client (for your own private game)
-- Run via loader.lua. Enter Worker URL + token in the on-screen panel.
-- Settings are saved on this device (if the executor supports writefile).

local Players         = game:GetService("Players")
local HttpService     = game:GetService("HttpService")
local VIM             = game:GetService("VirtualInputManager")
local GuiService      = game:GetService("GuiService")
local TextChatService = game:GetService("TextChatService")
local UserInputService = game:GetService("UserInputService")
local PathfindingService = game:GetService("PathfindingService")
local Stats = game:GetService("Stats")
local TeleportService = game:GetService("TeleportService")
local Lighting = game:GetService("Lighting")
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
local state = { paused = false, showLog = false, allowLua = true }

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function loadConfig()
	if isfile and readfile and isfile(CONFIG_FILE) then
		local ok, d = pcall(function() return HttpService:JSONDecode(readfile(CONFIG_FILE)) end)
		if ok and type(d) == "table" then
			BASE, KEY = d.base or "", d.key or ""
			if d.showLog ~= nil then state.showLog = d.showLog end
			if d.allowLua ~= nil then state.allowLua = d.allowLua end
		end
	end
end

local function saveConfig()
	if writefile then pcall(writefile, CONFIG_FILE, HttpService:JSONEncode({ base = BASE, key = KEY, showLog = state.showLog, allowLua = state.allowLua })) end
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
local ORANGE = Color3.fromRGB(200, 120, 20)

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
	if state.paused then text, color = "MCP: PAUSED (AI blocked)", ORANGE end
	pill.Text = text
	pill.BackgroundColor3 = color
end

-- emergency stop button (assigned later, needs handlers)
local onStopAll = function() end
local stopBtn = mk("TextButton", {
	Size = UDim2.fromOffset(28, 28), Position = UDim2.new(0.5, 126, 0, 8), BackgroundColor3 = RED,
	TextColor3 = WHITE, Font = Enum.Font.GothamBold, TextSize = 14, Text = "■",
}, gui)
mk("UICorner", { CornerRadius = UDim.new(1, 0) }, stopBtn)
stopBtn.Activated:Connect(function() onStopAll() end)

-- action log
local logFrame = mk("TextLabel", {
	Size = UDim2.fromOffset(290, 130), Position = UDim2.fromOffset(8, 44), BackgroundColor3 = Color3.fromRGB(15, 15, 18),
	BackgroundTransparency = 0.35, TextColor3 = Color3.fromRGB(210, 210, 220), Font = Enum.Font.Code, TextSize = 11,
	TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, Text = "", Visible = false,
}, gui)
mk("UICorner", { CornerRadius = UDim.new(0, 6) }, logFrame)
local logLines = {}
local function logLine(line)
	table.insert(logLines, line)
	while #logLines > 9 do table.remove(logLines, 1) end
	logFrame.Text = table.concat(logLines, "\n")
end

local panel = mk("Frame", {
	Size = UDim2.fromOffset(300, 252), Position = UDim2.new(0.5, -150, 0, 44),
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
	Size = UDim2.new(1, -20, 0, 44), Position = UDim2.fromOffset(10, 202), BackgroundTransparency = 1,
	Text = "Saved on this device. Tap the status pill to open/hide this panel. The red button stops everything the AI started. Pause AI blocks all actions.",
	TextColor3 = Color3.fromRGB(150, 150, 160), Font = Enum.Font.Gotham, TextSize = 11,
	TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
}, panel)

local refreshers = {}
local function toggleBtn(x, getText, onClick)
	local b = mk("TextButton", {
		Size = UDim2.fromOffset(88, 30), Position = UDim2.fromOffset(x, 164), BackgroundColor3 = Color3.fromRGB(55, 55, 64),
		TextColor3 = WHITE, Font = Enum.Font.Gotham, TextSize = 12, Text = "",
	}, panel)
	mk("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
	local function refresh() b.Text = getText() end
	b.Activated:Connect(function()
		onClick()
		refresh()
	end)
	table.insert(refreshers, refresh)
	refresh()
end

toggleBtn(10, function() return state.showLog and "Log: on" or "Log: off" end, function()
	state.showLog = not state.showLog
	logFrame.Visible = state.showLog
	saveConfig()
end)
toggleBtn(105, function() return state.allowLua and "Lua: on" or "Lua: off" end, function()
	state.allowLua = not state.allowLua
	saveConfig()
end)
toggleBtn(200, function() return state.paused and "Resume AI" or "Pause AI" end, function()
	state.paused = not state.paused
	if state.paused then onStopAll() end
	setStatus("MCP: connected", GREEN)
end)

pill.Activated:Connect(function() panel.Visible = not panel.Visible end)


----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------
local RunService = game:GetService("RunService")
local AssetService = game:GetService("AssetService")
local CaptureService = game:GetService("CaptureService")

local function hum()
	local c = lp.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end
local function root()
	local c = lp.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function cam() return workspace.CurrentCamera end
local function r1(n) return math.floor(n * 10 + 0.5) / 10 end
local function vec(v) return { x = r1(v.X), y = r1(v.Y), z = r1(v.Z) } end

local function screenOf(pos)
	local p, on = cam():WorldToViewportPoint(pos)
	return { x = math.floor(p.X), y = math.floor(p.Y), onScreen = (on and p.Z > 0) or false }
end

local function posOf(inst)
	if inst:IsA("BasePart") then return inst.Position end
	if inst:IsA("Model") then return inst:GetPivot().Position end
	if inst:IsA("Attachment") then return inst.WorldPosition end
	return nil
end

local function byPath(path)
	local cur = game
	for seg in tostring(path):gmatch("[^%.]+") do
		local nxt = cur:FindFirstChild(seg)
		if not nxt and cur == game then pcall(function() nxt = game:GetService(seg) end) end
		if not nxt then return nil end
		cur = nxt
	end
	return cur
end

local function stringify(v)
	local ok, s = pcall(HttpService.JSONEncode, HttpService, v)
	if ok then return s end
	return tostring(v)
end

local function guiList(limit)
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
				if #out >= (limit or 80) then break end
			end
		end
	end
	return out
end

----------------------------------------------------------------------
-- screen capture
----------------------------------------------------------------------
----------------------------------------------------------------------
-- PNG encoder (uncompressed deflate) + base64, pure Luau
----------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local crcTable

local function crc32(t)
	if not crcTable then
		crcTable = {}
		for i = 0, 255 do
			local c = i
			for _ = 1, 8 do
				if bit32.band(c, 1) == 1 then
					c = bit32.bxor(0xEDB88320, bit32.rshift(c, 1))
				else
					c = bit32.rshift(c, 1)
				end
			end
			crcTable[i] = c
		end
	end
	local c = 0xFFFFFFFF
	for i = 1, #t do
		c = bit32.bxor(crcTable[bit32.band(bit32.bxor(c, t[i]), 255)], bit32.rshift(c, 8))
	end
	return bit32.bxor(c, 0xFFFFFFFF)
end

local function push32(t, n)
	t[#t + 1] = bit32.band(bit32.rshift(n, 24), 255)
	t[#t + 1] = bit32.band(bit32.rshift(n, 16), 255)
	t[#t + 1] = bit32.band(bit32.rshift(n, 8), 255)
	t[#t + 1] = bit32.band(n, 255)
end

local function chunk(out, ctype, data)
	push32(out, #data)
	local tmp = {}
	for i = 1, #ctype do tmp[#tmp + 1] = ctype:byte(i) end
	for i = 1, #data do tmp[#tmp + 1] = data[i] end
	for i = 1, #tmp do out[#out + 1] = tmp[i] end
	push32(out, crc32(tmp))
end

local function encodePNG(w, h, rgb)
	local raw, idx = {}, 1
	for _ = 0, h - 1 do
		raw[#raw + 1] = 0
		for _ = 1, w * 3 do
			raw[#raw + 1] = rgb[idx]
			idx = idx + 1
		end
	end
	local z = { 0x78, 0x01 }
	local n, pos = #raw, 1
	while pos <= n do
		local len = math.min(65535, n - pos + 1)
		local nl = 65535 - len
		z[#z + 1] = (pos + len > n) and 1 or 0
		z[#z + 1] = len % 256
		z[#z + 1] = math.floor(len / 256)
		z[#z + 1] = nl % 256
		z[#z + 1] = math.floor(nl / 256)
		for i = pos, pos + len - 1 do z[#z + 1] = raw[i] end
		pos = pos + len
	end
	local a, b = 1, 0
	for i = 1, n do
		a = (a + raw[i]) % 65521
		b = (b + a) % 65521
	end
	push32(z, b * 65536 + a)

	local out = { 137, 80, 78, 71, 13, 10, 26, 10 }
	local ihdr = {}
	push32(ihdr, w)
	push32(ihdr, h)
	for _, v in ipairs({ 8, 2, 0, 0, 0 }) do ihdr[#ihdr + 1] = v end
	chunk(out, "IHDR", ihdr)
	chunk(out, "IDAT", z)
	chunk(out, "IEND", {})
	return out
end

local function toBase64(t)
	local parts, n = {}, #t
	for i = 1, n, 3 do
		local v = t[i] * 65536 + (t[i + 1] or 0) * 256 + (t[i + 2] or 0)
		local c1, c2 = math.floor(v / 262144), math.floor(v / 4096) % 64
		local c3, c4 = math.floor(v / 64) % 64, v % 64
		parts[#parts + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
			.. (i + 1 <= n and B64:sub(c3 + 1, c3 + 1) or "=")
			.. (i + 2 <= n and B64:sub(c4 + 1, c4 + 1) or "=")
	end
	return table.concat(parts)
end

local function capture(width)
	local contentId
	CaptureService:CaptureScreenshot(function(id) contentId = id end)
	local t0 = os.clock()
	while not contentId and os.clock() - t0 < 6 do task.wait() end
	assert(contentId, "screenshot timed out (CaptureService unavailable?)")

	local ei, err
	local ok = pcall(function() ei = AssetService:CreateEditableImageAsync(Content.fromUri(contentId)) end)
	if not ok or not ei then
		ok, err = pcall(function() ei = AssetService:CreateEditableImageAsync(contentId) end)
	end
	assert(ei, "EditableImage unavailable in this executor: " .. tostring(err))

	local full = ei.Size
	local w = math.clamp(math.floor(width or 320), 64, 640)
	local h = math.max(1, math.floor(w * full.Y / full.X))

	local rgb, n = {}, 0
	local resized = pcall(function() ei:Resize(Vector2.new(w, h)) end)
	if resized then
		local buf = ei:ReadPixelsBuffer(Vector2.zero, Vector2.new(w, h))
		for i = 0, w * h - 1 do
			local o = i * 4
			rgb[n + 1], rgb[n + 2], rgb[n + 3] = buffer.readu8(buf, o), buffer.readu8(buf, o + 1), buffer.readu8(buf, o + 2)
			n = n + 3
		end
	else
		local fw, fh = full.X, full.Y
		local buf = ei:ReadPixelsBuffer(Vector2.zero, full)
		for y = 0, h - 1 do
			local sy = math.min(fh - 1, math.floor((y + 0.5) * fh / h))
			for x = 0, w - 1 do
				local sx = math.min(fw - 1, math.floor((x + 0.5) * fw / w))
				local o = (sy * fw + sx) * 4
				rgb[n + 1], rgb[n + 2], rgb[n + 3] = buffer.readu8(buf, o), buffer.readu8(buf, o + 1), buffer.readu8(buf, o + 2)
				n = n + 3
			end
		end
	end
	pcall(function() ei:Destroy() end)
	return { image = toBase64(encodePNG(w, h, rgb)), width = w, height = h }
end

local feedRun = 0
local pathRunId, followRun = 0, 0

----------------------------------------------------------------------
-- command handlers
----------------------------------------------------------------------
local H = {}

-- observation ---------------------------------------------------------
function H.get_state()
	local c, r, h = cam(), root(), hum()
	local others = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= lp then table.insert(others, p.Name) end
	end
	return {
		player = lp.Name,
		placeId = game.PlaceId,
		position = r and vec(r.Position) or nil,
		health = h and h.Health or nil,
		walkSpeed = h and h.WalkSpeed or nil,
		onGround = h and h.FloorMaterial ~= Enum.Material.Air or nil,
		viewport = { x = c.ViewportSize.X, y = c.ViewportSize.Y },
		camera = { position = vec(c.CFrame.Position), look = vec(c.CFrame.LookVector), type = c.CameraType.Name },
		players = others,
		gui = guiList(),
	}
end

function H.describe_scene(a)
	local r = assert(root(), "no character")
	local radius, limit = a.radius or 60, a.limit or 40
	local params = OverlapParams.new()
	params.FilterDescendantsInstances = { lp.Character }
	params.FilterType = Enum.RaycastFilterType.Exclude
	local seen, list = {}, {}
	for _, p in ipairs(workspace:GetPartBoundsInRadius(r.Position, radius, params)) do
		if not p:IsA("Terrain") then
			local top = p
			while top.Parent and top.Parent ~= workspace and top.Parent:IsA("Model") do top = top.Parent end
			if not seen[top] then
				seen[top] = true
				local pos = posOf(top)
				if pos then
					table.insert(list, {
						name = top.Name, class = top.ClassName, path = top:GetFullName(),
						dist = r1((pos - r.Position).Magnitude), pos = vec(pos), screen = screenOf(pos),
					})
				end
			end
		end
	end
	table.sort(list, function(x, y) return x.dist < y.dist end)
	while #list > limit do table.remove(list) end
	local plrs = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local pr = p ~= lp and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		if pr then
			table.insert(plrs, { name = p.Name, dist = r1((pr.Position - r.Position).Magnitude), pos = vec(pr.Position), screen = screenOf(pr.Position) })
		end
	end
	local c = cam()
	return {
		you = { pos = vec(r.Position), screen = screenOf(r.Position) },
		camera = { pos = vec(c.CFrame.Position), look = vec(c.CFrame.LookVector) },
		objects = list, players = plrs,
	}
end

function H.find_objects(a)
	local r = root()
	local q = a.query and string.lower(a.query) or nil
	local cls = a.class
	local limit = a.limit or 25
	local list, count = {}, 0
	for _, d in ipairs(workspace:GetDescendants()) do
		count = count + 1
		if count % 3000 == 0 then task.wait() end
		if (not q or string.find(string.lower(d.Name), q, 1, true)) and (not cls or d:IsA(cls)) then
			local pos = posOf(d)
			if pos or not (cls == nil) then
				local dist = (pos and r) and (pos - r.Position).Magnitude or nil
				if not a.radius or (dist and dist <= a.radius) then
					table.insert(list, {
						name = d.Name, class = d.ClassName, path = d:GetFullName(),
						dist = dist and r1(dist) or nil, pos = pos and vec(pos) or nil,
						screen = pos and screenOf(pos) or nil,
					})
				end
			end
		end
	end
	table.sort(list, function(x, y) return (x.dist or 1e9) < (y.dist or 1e9) end)
	while #list > limit do table.remove(list) end
	return list
end

function H.screenshot(a)
	return capture(a.width)
end

function H.set_feed(a)
	feedRun = feedRun + 1
	local id = feedRun
	if not a.enabled then return { enabled = false } end
	local interval = math.clamp(a.interval or 1.5, 0.5, 30)
	local width = a.width or 320
	local untilT = os.clock() + math.clamp(a.seconds or 60, 5, 600)
	local first = capture(width) -- fail loudly if capture is unsupported
	pcall(http, "POST", "/frame", first)
	task.spawn(function()
		local fails = 0
		while feedRun == id and getgenv().MCP_RUN and os.clock() < untilT do
			task.wait(interval)
			if feedRun ~= id then break end
			local ok, res = pcall(capture, width)
			if ok then
				fails = 0
				pcall(http, "POST", "/frame", res)
			else
				fails = fails + 1
				if fails >= 3 then break end
			end
		end
	end)
	return { enabled = true, interval = interval, width = first.width, height = first.height, seconds = math.floor(untilT - os.clock()) }
end

-- input ----------------------------------------------------------------
function H.click(a)
	local btn = (a.button == "right") and 1 or 0
	VIM:SendMouseMoveEvent(a.x, a.y, game)
	task.wait(0.03)
	VIM:SendMouseButtonEvent(a.x, a.y, btn, true, game, 1)
	task.wait(0.05)
	VIM:SendMouseButtonEvent(a.x, a.y, btn, false, game, 1)
	return "clicked"
end

function H.click_world(a)
	local s = screenOf(Vector3.new(a.x, a.y, a.z))
	assert(s.onScreen, "that world position is not on screen")
	return H.click({ x = s.x, y = s.y, button = a.button })
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

-- character --------------------------------------------------------------
function H.move_to(a)
	local h = assert(hum(), "no humanoid")
	local done, reached = false, false
	local conn = h.MoveToFinished:Connect(function(r) done, reached = true, r end)
	h:MoveTo(Vector3.new(a.x, a.y, a.z))
	local t0 = os.clock()
	while not done and os.clock() - t0 < (a.timeout or 10) do task.wait(0.1) end
	conn:Disconnect()
	return { reached = reached, position = root() and vec(root().Position) or nil }
end

function H.walk(a)
	local h = assert(hum(), "no humanoid")
	local d = string.lower(a.direction or "forward")
	local v = Vector3.zero
	if d:find("forward") then v = v + Vector3.new(0, 0, -1) end
	if d:find("back") then v = v + Vector3.new(0, 0, 1) end
	if d:find("left") then v = v + Vector3.new(-1, 0, 0) end
	if d:find("right") then v = v + Vector3.new(1, 0, 0) end
	assert(v.Magnitude > 0, "direction must contain forward/back/left/right")
	local rel = a.relative ~= false
	local t0, secs = os.clock(), math.clamp(a.seconds or 1, 0.1, 30)
	while os.clock() - t0 < secs do
		h:Move(v.Unit, rel)
		RunService.Heartbeat:Wait()
	end
	h:Move(Vector3.zero, true)
	return { position = root() and vec(root().Position) or nil }
end

function H.stop()
	pathRunId = pathRunId + 1
	followRun = followRun + 1
	local h, r = hum(), root()
	if h then
		h:Move(Vector3.zero, true)
		if r then h:MoveTo(r.Position) end
	end
	return "stopped"
end

function H.jump()
	local h = assert(hum(), "no humanoid")
	h.Jump = true
	return "jumped"
end

function H.teleport(a)
	local r = assert(root(), "no character")
	r.CFrame = CFrame.new(a.x, a.y, a.z)
	return vec(r.Position)
end

function H.face(a)
	local r = assert(root(), "no character")
	r.CFrame = CFrame.lookAt(r.Position, Vector3.new(a.x, r.Position.Y, a.z))
	return "facing"
end

function H.look_at(a)
	local c = cam()
	c.CameraType = Enum.CameraType.Scriptable
	c.CFrame = CFrame.lookAt(c.CFrame.Position, Vector3.new(a.x, a.y, a.z))
	return "camera locked (use release_camera to restore)"
end

function H.rotate_camera(a)
	local c = cam()
	local cf = c.CFrame
	local p = cf.Position
	c.CameraType = Enum.CameraType.Scriptable
	c.CFrame = CFrame.new(p) * CFrame.Angles(0, math.rad(a.yaw or 0), 0) * (cf - p) * CFrame.Angles(math.rad(a.pitch or 0), 0, 0)
	return "camera rotated (use release_camera to restore)"
end

function H.release_camera()
	local c = cam()
	c.CameraType = Enum.CameraType.Custom
	local h = hum()
	if h then c.CameraSubject = h end
	return "camera released"
end

function H.set_humanoid(a)
	local h = assert(hum(), "no humanoid")
	if a.walkSpeed then h.WalkSpeed = a.walkSpeed end
	if a.jumpPower then h.UseJumpPower = true; h.JumpPower = a.jumpPower end
	if a.jumpHeight then h.UseJumpPower = false; h.JumpHeight = a.jumpHeight end
	if a.hipHeight then h.HipHeight = a.hipHeight end
	return { walkSpeed = h.WalkSpeed, jumpPower = h.JumpPower, jumpHeight = h.JumpHeight, hipHeight = h.HipHeight }
end

function H.change_state(a)
	local h = assert(hum(), "no humanoid")
	local s = Enum.HumanoidStateType[a.state]
	assert(s, "unknown state " .. tostring(a.state))
	h:ChangeState(s)
	return "state " .. a.state
end

-- tools & interaction --------------------------------------------------
function H.list_tools()
	local out = {}
	local function scan(parent, equipped)
		if parent then
			for _, t in ipairs(parent:GetChildren()) do
				if t:IsA("Tool") then table.insert(out, { name = t.Name, equipped = equipped }) end
			end
		end
	end
	scan(lp:FindFirstChildOfClass("Backpack"), false)
	scan(lp.Character, true)
	return out
end

function H.equip_tool(a)
	local h = assert(hum(), "no humanoid")
	local bp = lp:FindFirstChildOfClass("Backpack")
	local tool = bp and bp:FindFirstChild(a.name)
	assert(tool and tool:IsA("Tool"), "tool not in backpack: " .. tostring(a.name))
	h:EquipTool(tool)
	return "equipped " .. a.name
end

function H.unequip_tool()
	local h = assert(hum(), "no humanoid")
	h:UnequipTools()
	return "unequipped"
end

function H.use_tool(a)
	local tool = lp.Character and lp.Character:FindFirstChildOfClass("Tool")
	assert(tool, "no tool equipped")
	tool:Activate()
	task.wait(a.seconds or 0.1)
	tool:Deactivate()
	return "used " .. tool.Name
end

local lastPrompts = {}

function H.find_prompts(a)
	local r = assert(root(), "no character")
	local radius = a.radius or 20
	lastPrompts = {}
	local out = {}
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Parent then
			local pos = posOf(d.Parent)
			if pos then
				local dist = (pos - r.Position).Magnitude
				if dist <= radius then
					table.insert(lastPrompts, d)
					table.insert(out, {
						index = #lastPrompts, path = d:GetFullName(), action = d.ActionText,
						object = d.ObjectText, hold = d.HoldDuration, enabled = d.Enabled, dist = r1(dist),
					})
				end
			end
		end
	end
	return out
end

function H.fire_prompt(a)
	local p = (a.index and lastPrompts[a.index]) or (a.path and byPath(a.path))
	assert(p and p:IsA("ProximityPrompt"), "prompt not found (call find_prompts first)")
	if fireproximityprompt then
		fireproximityprompt(p)
		return "fired"
	end
	local code = p.KeyboardKeyCode ~= Enum.KeyCode.Unknown and p.KeyboardKeyCode or Enum.KeyCode.E
	VIM:SendKeyEvent(true, code, false, game)
	task.wait(p.HoldDuration + 0.15)
	VIM:SendKeyEvent(false, code, false, game)
	return "held " .. code.Name
end

function H.click_detector(a)
	assert(fireclickdetector, "this executor has no fireclickdetector")
	local d = byPath(a.path)
	assert(d, "not found: " .. tostring(a.path))
	local cd = d:IsA("ClickDetector") and d or d:FindFirstChildWhichIsA("ClickDetector", true)
	assert(cd, "no ClickDetector at that path")
	fireclickdetector(cd)
	return "clicked"
end

-- coordinates, macros & path recording ----------------------------------
function H.get_position()
	local r = assert(root(), "no character")
	return { position = vec(r.Position), look = vec(r.CFrame.LookVector), placeId = game.PlaceId }
end

function H.distance_to(a)
	local r = assert(root(), "no character")
	local d = Vector3.new(a.x, a.y, a.z) - r.Position
	return {
		distance = r1(d.Magnitude), horizontal = r1(Vector3.new(d.X, 0, d.Z).Magnitude),
		dx = r1(d.X), dy = r1(d.Y), dz = r1(d.Z),
	}
end

local macroRun = 0
local macroInfo = { running = false }

function H.run_steps(a)
	local steps = a.steps or {}
	local reps = math.clamp(math.floor(a["repeat"] or 1), 1, 1000)
	macroRun = macroRun + 1
	local id = macroRun
	local info = { name = a.name or "adhoc", running = true, step = 0, total = #steps, iteration = 0, repeats = reps }
	macroInfo = info

	local function run()
		for it = 1, reps do
			info.iteration = it
			for i, s in ipairs(steps) do
				if macroRun ~= id then return end
				info.step = i
				setStatus(string.format("MCP: macro %s %d/%d", info.name, i, #steps), BLUE)
				local f = H[s.tool]
				local ok, err = true, nil
				if not f or s.tool == "run_steps" then
					ok, err = false, "bad step tool " .. tostring(s.tool)
				else
					ok, err = pcall(f, s.args or {})
				end
				if not ok then
					info.error = string.format("step %d (%s): %s", i, tostring(s.tool), tostring(err))
					if not a.continueOnError then
						info.running = false
						setStatus("MCP: macro error", RED)
						return
					end
				end
				if a.delay and a.delay > 0 then task.wait(a.delay) end
			end
		end
		info.running, info.done = false, true
		setStatus("MCP: connected", GREEN)
	end

	if a.background == false then
		run()
		return info
	end
	task.spawn(run)
	return { started = true, name = info.name, steps = #steps, repeats = reps }
end

function H.stop_macro()
	macroRun = macroRun + 1
	macroInfo.running = false
	H.stop()
	setStatus("MCP: connected", GREEN)
	return "macro stopped"
end

function H.macro_status()
	return macroInfo
end

local pathRec = nil

function H.path_record_start(a)
	assert(root(), "no character")
	if pathRec then pathRec.stop = true end
	local rec = { points = {}, stop = false, jumped = false }
	pathRec = rec
	local h = hum()
	local conn
	if h then
		conn = h.StateChanged:Connect(function(_, new)
			if new == Enum.HumanoidStateType.Jumping then rec.jumped = true end
		end)
	end
	local interval = math.clamp(a.interval or 0.5, 0.1, 5)
	task.spawn(function()
		while not rec.stop and #rec.points < 2000 do
			local r = root()
			if r then
				table.insert(rec.points, { x = r1(r.Position.X), y = r1(r.Position.Y), z = r1(r.Position.Z), jump = rec.jumped or nil })
				rec.jumped = false
			end
			task.wait(interval)
		end
		if conn then conn:Disconnect() end
	end)
	return { recording = true, interval = interval }
end

function H.path_record_stop()
	local rec = assert(pathRec, "not recording a path")
	rec.stop = true
	pathRec = nil
	return { points = rec.points }
end

-- pathfinding & following -------------------------------------------------
function H.path_to(a)
	local h = assert(hum(), "no humanoid")
	local r = assert(root(), "no character")
	pathRunId = pathRunId + 1
	local myId = pathRunId
	local dest = Vector3.new(a.x, a.y, a.z)
	local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, AgentCanClimb = true })
	local ok, err = pcall(function() path:ComputeAsync(r.Position, dest) end)
	assert(ok, "path error: " .. tostring(err))
	assert(path.Status == Enum.PathStatus.Success, "no path found: " .. path.Status.Name)
	local wps = path:GetWaypoints()
	local deadline = os.clock() + math.clamp(a.timeout or 20, 3, 20)
	for i, wp in ipairs(wps) do
		if i > 1 then
			if pathRunId ~= myId then return { reached = false, cancelled = true } end
			if os.clock() > deadline then break end
			if wp.Action == Enum.PathWaypointAction.Jump then h.Jump = true end
			local done, reached = false, false
			local conn = h.MoveToFinished:Connect(function(ok2) done, reached = true, ok2 end)
			h:MoveTo(wp.Position)
			local t0 = os.clock()
			while not done and os.clock() - t0 < 4 and pathRunId == myId do task.wait(0.05) end
			conn:Disconnect()
			if not reached then h.Jump = true task.wait(0.3) end
		end
	end
	local rr = root()
	local d = rr and (rr.Position - dest).Magnitude or math.huge
	return { reached = d <= (a.tolerance or 6), distance = r1(d), waypoints = #wps, position = rr and vec(rr.Position) or nil }
end

function H.follow_player(a)
	assert(hum(), "no humanoid")
	local name = string.lower(tostring(a.name))
	local target
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= lp and (string.lower(p.Name) == name or string.lower(p.DisplayName) == name) then target = p end
	end
	assert(target, "player not found: " .. tostring(a.name))
	followRun = followRun + 1
	local id = followRun
	local gap = a.distance or 6
	local untilT = os.clock() + math.clamp(a.seconds or 60, 1, 600)
	task.spawn(function()
		while followRun == id and os.clock() < untilT do
			local tr = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
			local r, h = root(), hum()
			if tr and r and h and (tr.Position - r.Position).Magnitude > gap then h:MoveTo(tr.Position) end
			task.wait(0.25)
		end
	end)
	return { following = target.Name, seconds = math.floor(untilT - os.clock()) }
end

function H.stop_follow()
	return H.stop()
end

-- events & triggers ---------------------------------------------------------
for _, c in ipairs(getgenv().MCP_CONNS or {}) do pcall(function() c:Disconnect() end) end
local conns = {}
getgenv().MCP_CONNS = conns

local events, eventSeq, triggers = {}, 0, {}

local function runPlain(steps)
	for _, s in ipairs(steps) do
		local f = H[s.tool]
		if f and s.tool ~= "run_steps" then pcall(f, s.args or {}) end
	end
end

local function fireTriggers(kind, data)
	for _, t in pairs(triggers) do
		if t.event == kind and not t.busy and os.clock() - t.last >= t.cooldown then
			if not t.contains or string.find(string.lower(stringify(data)), string.lower(t.contains), 1, true) then
				t.busy, t.last = true, os.clock()
				task.spawn(function()
					runPlain(t.steps)
					t.busy = false
				end)
			end
		end
	end
end

local function pushEvent(kind, data)
	eventSeq = eventSeq + 1
	table.insert(events, { id = eventSeq, t = os.time(), type = kind, data = data })
	if #events > 200 then table.remove(events, 1) end
	fireTriggers(kind, data)
end

local function hookChar(char)
	local h = char:WaitForChild("Humanoid", 10)
	if not h then return end
	local last = h.Health
	table.insert(conns, h.HealthChanged:Connect(function(hp)
		if hp < last then pushEvent("damaged", { health = r1(hp), damage = r1(last - hp) }) end
		last = hp
	end))
	table.insert(conns, h.Died:Connect(function() pushEvent("died", {}) end))
end

pcall(function()
	table.insert(conns, Players.PlayerAdded:Connect(function(p) pushEvent("player_joined", { name = p.Name }) end))
	table.insert(conns, Players.PlayerRemoving:Connect(function(p) pushEvent("player_left", { name = p.Name }) end))
	table.insert(conns, lp.CharacterAdded:Connect(function(c)
		pushEvent("respawned", {})
		task.spawn(hookChar, c)
	end))
	if lp.Character then task.spawn(hookChar, lp.Character) end
	if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
		table.insert(conns, TextChatService.MessageReceived:Connect(function(m)
			pushEvent("chat", { from = m.TextSource and m.TextSource.Name or "system", text = m.Text })
		end))
	else
		local function hookP(p)
			table.insert(conns, p.Chatted:Connect(function(msg) pushEvent("chat", { from = p.Name, text = msg }) end))
		end
		for _, p in ipairs(Players:GetPlayers()) do hookP(p) end
		table.insert(conns, Players.PlayerAdded:Connect(hookP))
	end
end)

function H.get_events(a)
	local since, limit = a.since or 0, a.limit or 50
	local types
	if type(a.types) == "table" then
		types = {}
		for _, k in ipairs(a.types) do types[k] = true end
	end
	local function collect()
		local out = {}
		for _, e in ipairs(events) do
			if e.id > since and (not types or types[e.type]) then table.insert(out, e) end
		end
		while #out > limit do table.remove(out, 1) end
		return out
	end
	local deadline = os.clock() + math.clamp(a.wait or 0, 0, 20)
	local out = collect()
	while #out == 0 and os.clock() < deadline do
		task.wait(0.2)
		out = collect()
	end
	return { events = out, last = eventSeq }
end

function H.add_trigger(a)
	assert(a.name and a.event and a.steps, "name, event and steps are required")
	triggers[a.name] = { event = a.event, contains = a.contains, steps = a.steps, cooldown = a.cooldown or 2, last = -1e9 }
	return { added = a.name }
end

function H.list_triggers()
	local out = {}
	for n, t in pairs(triggers) do table.insert(out, { name = n, event = t.event, contains = t.contains, steps = #t.steps }) end
	return out
end

function H.remove_trigger(a)
	local had = triggers[a.name] ~= nil
	triggers[a.name] = nil
	return had and "removed" or "no such trigger"
end

local afkConn
function H.anti_afk(a)
	if afkConn then afkConn:Disconnect() afkConn = nil end
	if a.enabled == false then return { enabled = false } end
	afkConn = lp.Idled:Connect(function()
		pcall(function()
			local vu = game:GetService("VirtualUser")
			vu:CaptureController()
			vu:ClickButton2(Vector2.new())
		end)
	end)
	table.insert(conns, afkConn)
	return { enabled = true }
end

-- GUI helpers ---------------------------------------------------------------
function H.click_gui(a)
	assert(a.text or a.name, "give text and/or name")
	local q = a.text and string.lower(a.text)
	local found = {}
	for _, g in ipairs(guiList(1000)) do
		local ok = true
		if q then
			local tx = string.lower(g.text)
			ok = a.exact and tx == q or (not a.exact and string.find(tx, q, 1, true) ~= nil)
		end
		if ok and a.name and g.name ~= a.name then ok = false end
		if ok then table.insert(found, g) end
	end
	local g = found[a.index or 1]
	assert(g, "no visible GUI element matched")
	H.click({ x = g.x, y = g.y, button = a.button })
	return { clicked = g, matches = #found }
end

function H.type_text(a)
	local box = a.path and byPath(a.path) or UserInputService:GetFocusedTextBox()
	assert(box and box:IsA("TextBox"), "no TextBox: focus one in-game or pass its path")
	box.Text = a.text
	if a.submit then
		pcall(function() box:CaptureFocus() end)
		pcall(function() box:ReleaseFocus(true) end)
	end
	return "typed"
end

-- players, inspection, stats -----------------------------------------------
local function ser(v)
	local t = typeof(v)
	if t == "Vector3" then return vec(v) end
	if t == "Vector2" then return { x = r1(v.X), y = r1(v.Y) } end
	if t == "Color3" then return { r = math.floor(v.R * 255 + 0.5), g = math.floor(v.G * 255 + 0.5), b = math.floor(v.B * 255 + 0.5) } end
	if t == "CFrame" then return { pos = vec(v.Position) } end
	if t == "Instance" then return v:GetFullName() end
	if t == "number" or t == "string" or t == "boolean" or t == "nil" then return v end
	return tostring(v)
end

local function coerce(cur, v)
	local t = typeof(cur)
	if type(v) == "table" then
		if t == "Vector3" then return Vector3.new(v.x, v.y, v.z) end
		if t == "Vector2" then return Vector2.new(v.x, v.y) end
		if t == "Color3" then return Color3.fromRGB(v.r, v.g, v.b) end
	end
	if t == "EnumItem" and type(v) == "string" then return cur.EnumType[v] end
	return v
end

function H.list_players()
	local me = root()
	local out = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local c = p.Character
		local r = c and c:FindFirstChild("HumanoidRootPart")
		local h = c and c:FindFirstChildOfClass("Humanoid")
		local tool = c and c:FindFirstChildOfClass("Tool")
		local stats = {}
		local ls = p:FindFirstChild("leaderstats")
		if ls then
			for _, v in ipairs(ls:GetChildren()) do
				if v:IsA("ValueBase") then stats[v.Name] = ser(v.Value) end
			end
		end
		table.insert(out, {
			name = p.Name, displayName = p.DisplayName, userId = p.UserId, you = p == lp,
			team = p.Team and p.Team.Name or nil, leaderstats = stats,
			health = h and r1(h.Health) or nil, tool = tool and tool.Name or nil,
			position = r and vec(r.Position) or nil,
			dist = (r and me and p ~= lp) and r1((r.Position - me.Position).Magnitude) or nil,
		})
	end
	return out
end

function H.inspect(a)
	local i = assert(byPath(a.path), "not found: " .. tostring(a.path))
	local props = {}
	local function add(list)
		for _, p in ipairs(list) do
			local ok, v = pcall(function() return i[p] end)
			if ok then props[p] = ser(v) end
		end
	end
	if i:IsA("BasePart") then add({ "Position", "Size", "Anchored", "CanCollide", "Transparency", "Material", "Color" }) end
	if i:IsA("Humanoid") then add({ "Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "HipHeight" }) end
	if i:IsA("GuiObject") then add({ "Visible", "AbsolutePosition", "AbsoluteSize", "ZIndex" }) end
	if i:IsA("TextLabel") or i:IsA("TextButton") or i:IsA("TextBox") then add({ "Text" }) end
	if i:IsA("ValueBase") then add({ "Value" }) end
	if i:IsA("ProximityPrompt") then add({ "ActionText", "ObjectText", "HoldDuration", "Enabled", "MaxActivationDistance" }) end
	if i:IsA("Model") then props.Pivot = vec(i:GetPivot().Position) end
	local attrs = {}
	for k, v in pairs(i:GetAttributes()) do attrs[k] = ser(v) end
	local kids, all = {}, i:GetChildren()
	for n, c in ipairs(all) do
		if n > 60 then break end
		table.insert(kids, { name = c.Name, class = c.ClassName })
	end
	return { name = i.Name, class = i.ClassName, path = i:GetFullName(), properties = props, attributes = attrs, children = kids, childCount = #all }
end

function H.get_property(a)
	local i = assert(byPath(a.path), "not found: " .. tostring(a.path))
	return ser(i[a.property])
end

function H.set_property(a)
	local i = assert(byPath(a.path), "not found: " .. tostring(a.path))
	i[a.property] = coerce(i[a.property], a.value)
	return ser(i[a.property])
end

function H.get_stats()
	local n, t0 = 0, os.clock()
	local c = RunService.Heartbeat:Connect(function() n = n + 1 end)
	task.wait(0.5)
	c:Disconnect()
	return {
		fps = r1(n / (os.clock() - t0)),
		pingMs = r1(lp:GetNetworkPing() * 1000),
		memoryMb = r1(Stats:GetTotalMemoryUsageMb()),
		players = #Players:GetPlayers(),
		jobId = game.JobId, placeId = game.PlaceId, gameId = game.GameId,
		gravity = workspace.Gravity, serverTime = r1(workspace:GetServerTimeNow()),
	}
end

function H.wait_until(a)
	local cond = a.condition
	local timeout = math.clamp(a.timeout or 20, 1, 20)
	local t0 = os.clock()
	local function check()
		local r, h = root(), hum()
		if cond == "near" then
			if not r then return false end
			local d = (Vector3.new(a.x, a.y, a.z) - r.Position).Magnitude
			return d <= (a.radius or 5), { distance = r1(d) }
		elseif cond == "gui_text" then
			local q = string.lower(a.text or "")
			for _, g in ipairs(guiList(1000)) do
				if string.find(string.lower(g.text), q, 1, true) then return true, g end
			end
			return false
		elseif cond == "object" then
			local q = string.lower(a.name or "")
			for _, d in ipairs(workspace:GetDescendants()) do
				if string.lower(d.Name) == q then return true, { path = d:GetFullName() } end
			end
			return false
		elseif cond == "health_below" then
			return (h ~= nil and h.Health < a.value), h and { health = r1(h.Health) } or nil
		elseif cond == "health_above" then
			return (h ~= nil and h.Health > a.value), h and { health = r1(h.Health) } or nil
		end
		error("unknown condition " .. tostring(cond) .. " (near, gui_text, object, health_below, health_above)")
	end
	repeat
		local ok, info = check()
		if ok then return { met = true, info = info, waited = r1(os.clock() - t0) } end
		task.wait(cond == "object" and 0.6 or 0.25)
	until os.clock() - t0 >= timeout
	return { met = false, waited = r1(os.clock() - t0) }
end

-- overlays, markers, highlights ---------------------------------------------
local COLORS = {
	red = Color3.fromRGB(235, 64, 52), green = Color3.fromRGB(52, 199, 89), blue = Color3.fromRGB(10, 132, 255),
	yellow = Color3.fromRGB(255, 214, 10), orange = Color3.fromRGB(255, 149, 0), purple = Color3.fromRGB(175, 82, 222),
	cyan = Color3.fromRGB(90, 200, 250), white = Color3.fromRGB(255, 255, 255), pink = Color3.fromRGB(255, 105, 180),
}
local function col(c, default)
	if type(c) == "string" and COLORS[string.lower(c)] then return COLORS[string.lower(c)] end
	if type(c) == "table" then return Color3.fromRGB(c.r or 255, c.g or 255, c.b or 255) end
	return default or COLORS.yellow
end

local markerFolder
local function folder()
	if not markerFolder or not markerFolder.Parent then
		local old = workspace:FindFirstChild("__MCP_Markers")
		if old then old:Destroy() end
		markerFolder = Instance.new("Folder")
		markerFolder.Name = "__MCP_Markers"
		markerFolder.Parent = workspace
	end
	return markerFolder
end

local toast
function H.show_message(a)
	if toast then toast:Destroy() end
	local lbl = mk("TextLabel", {
		Size = UDim2.new(0.8, 0, 0, 44), AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -70),
		BackgroundColor3 = Color3.fromRGB(20, 20, 24), BackgroundTransparency = 0.15, TextColor3 = col(a.color, WHITE),
		Font = Enum.Font.GothamMedium, TextSize = 16, Text = tostring(a.text), TextWrapped = true,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(0, 10) }, lbl)
	toast = lbl
	task.delay(math.clamp(a.seconds or 4, 1, 30), function()
		if lbl.Parent then lbl:Destroy() end
	end)
	return "shown"
end

function H.draw_marker(a)
	local f = folder()
	local old = f:FindFirstChild("m_" .. tostring(a.name))
	if old then old:Destroy() end
	local c = col(a.color)
	local p = Instance.new("Part")
	p.Name = "m_" .. tostring(a.name or "marker")
	p.Shape = Enum.PartType.Ball
	p.Material = Enum.Material.Neon
	p.Color = c
	p.Size = Vector3.new(1.6, 1.6, 1.6)
	p.Transparency = 0.2
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
	p.Position = Vector3.new(a.x, a.y, a.z)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(170, 30)
	bb.StudsOffset = Vector3.new(0, 3, 0)
	bb.AlwaysOnTop = true
	bb.Parent = p
	mk("TextLabel", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, TextColor3 = c, TextStrokeTransparency = 0,
		Font = Enum.Font.GothamBold, TextSize = 15, Text = tostring(a.label or a.name or ""),
	}, bb)
	p.Parent = f
	return "marker " .. tostring(a.name)
end

function H.draw_markers(a)
	if a.clear then H.clear_markers({}) end
	for _, m in ipairs(a.markers or {}) do H.draw_marker(m) end
	return { drawn = #(a.markers or {}) }
end

function H.clear_markers(a)
	local f = folder()
	local n = 0
	for _, c in ipairs(f:GetChildren()) do
		if c:IsA("Part") and (not a.name or c.Name == "m_" .. a.name) then
			c:Destroy()
			n = n + 1
		end
	end
	return { cleared = n }
end

function H.highlight(a)
	local targets = {}
	if a.path then
		local i = byPath(a.path)
		if i then targets[1] = i end
	elseif a.query then
		local q = string.lower(a.query)
		for _, d in ipairs(workspace:GetDescendants()) do
			if (d:IsA("Model") or d:IsA("BasePart")) and string.find(string.lower(d.Name), q, 1, true) then
				table.insert(targets, d)
				if #targets >= 20 then break end
			end
		end
	end
	assert(#targets > 0, "nothing matched")
	for _, t in ipairs(targets) do
		local hl = Instance.new("Highlight")
		hl.Name = "hl"
		hl.Adornee = t
		hl.FillColor = col(a.color)
		hl.OutlineColor = hl.FillColor
		hl.FillTransparency = 0.6
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.Parent = folder()
		if a.seconds then task.delay(a.seconds, function() hl:Destroy() end) end
	end
	return { highlighted = #targets }
end

function H.clear_highlights()
	local n = 0
	for _, c in ipairs(folder():GetChildren()) do
		if c:IsA("Highlight") then
			c:Destroy()
			n = n + 1
		end
	end
	return { cleared = n }
end

-- spatial queries -------------------------------------------------------------
function H.what_is_at(a)
	local c = cam()
	local x = a.x or c.ViewportSize.X / 2
	local y = a.y or c.ViewportSize.Y / 2
	local ray = c:ViewportPointToRay(x, y)
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { lp.Character }
	params.FilterType = Enum.RaycastFilterType.Exclude
	local res = workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	if not res then return { hit = false } end
	local inst = res.Instance
	local model = inst:FindFirstAncestorOfClass("Model")
	return {
		hit = true, name = inst.Name, class = inst.ClassName, path = inst:GetFullName(), model = model and model.Name or nil,
		position = vec(res.Position), distance = r1(res.Distance), material = res.Material.Name,
	}
end

function H.raycast(a)
	local r = assert(root(), "no character")
	local from = (a.from == "camera") and cam().CFrame.Position or (r.Position + Vector3.new(0, 1.5, 0))
	local target = Vector3.new(a.x, a.y, a.z)
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { lp.Character }
	params.FilterType = Enum.RaycastFilterType.Exclude
	local res = workspace:Raycast(from, target - from, params)
	if not res then return { clear = true, distance = r1((target - from).Magnitude) } end
	return {
		clear = false, distance = r1(res.Distance),
		blockedBy = { name = res.Instance.Name, path = res.Instance:GetFullName(), position = vec(res.Position) },
	}
end

-- camera ----------------------------------------------------------------------
function H.set_fov(a)
	cam().FieldOfView = math.clamp(a.fov, 1, 120)
	return { fov = cam().FieldOfView }
end

function H.set_zoom(a)
	if a.distance then
		lp.CameraMinZoomDistance = math.max(a.distance, 0.5)
		lp.CameraMaxZoomDistance = math.max(a.distance, 0.5)
	else
		lp.CameraMinZoomDistance, lp.CameraMaxZoomDistance = 0.5, 128
	end
	return { min = lp.CameraMinZoomDistance, max = lp.CameraMaxZoomDistance }
end

function H.first_person(a)
	lp.CameraMode = (a.enabled == false) and Enum.CameraMode.Classic or Enum.CameraMode.LockFirstPerson
	return lp.CameraMode.Name
end

-- sandbox / dev movement -----------------------------------------------------
function H.fly_to(a)
	local r = assert(root(), "no character")
	local h = hum()
	local dest = Vector3.new(a.x, a.y, a.z)
	local speed = math.clamp(a.speed or 50, 5, 300)
	local timeout = math.clamp(a.timeout or 15, 1, 20)
	pathRunId = pathRunId + 1
	local id = pathRunId
	local t0, done = os.clock(), false
	if h then h.PlatformStand = true end
	local conn = RunService.Heartbeat:Connect(function(dt)
		local rr = root()
		if not rr or pathRunId ~= id or os.clock() - t0 > timeout then
			done = true
			return
		end
		local d = dest - rr.Position
		local step = speed * dt
		rr.AssemblyLinearVelocity = Vector3.zero
		if d.Magnitude <= math.max(step, 1) then
			rr.CFrame = CFrame.new(dest) * (rr.CFrame - rr.CFrame.Position)
			done = true
		else
			rr.CFrame = rr.CFrame + d.Unit * step
		end
	end)
	while not done do task.wait() end
	conn:Disconnect()
	if h then h.PlatformStand = false end
	local rr = root()
	return { reached = rr ~= nil and (rr.Position - dest).Magnitude <= 2, position = rr and vec(rr.Position) or nil }
end

local noclipConn
function H.noclip(a)
	if noclipConn then noclipConn:Disconnect() noclipConn = nil end
	if a.enabled == false then return { noclip = false } end
	noclipConn = RunService.Stepped:Connect(function()
		local c = lp.Character
		if c then
			for _, p in ipairs(c:GetDescendants()) do
				if p:IsA("BasePart") then p.CanCollide = false end
			end
		end
	end)
	table.insert(conns, noclipConn)
	return { noclip = true }
end

function H.freeze(a)
	local r = assert(root(), "no character")
	r.Anchored = a.enabled ~= false
	return { frozen = r.Anchored }
end

function H.set_gravity(a)
	workspace.Gravity = a.value or 196.2
	return { gravity = workspace.Gravity }
end

function H.sit(a)
	local h = assert(hum(), "no humanoid")
	h.Sit = a.enabled ~= false
	return { sit = h.Sit }
end

function H.set_lighting(a)
	if a.clockTime then Lighting.ClockTime = a.clockTime end
	if a.brightness then Lighting.Brightness = a.brightness end
	if a.fogEnd then Lighting.FogEnd = a.fogEnd end
	return { clockTime = Lighting.ClockTime, brightness = Lighting.Brightness, fogEnd = Lighting.FogEnd }
end

-- extra input -----------------------------------------------------------------
function H.drag(a)
	local btn = (a.button == "right") and 1 or 0
	local dur = math.clamp(a.duration or 0.4, 0.1, 5)
	local steps = math.clamp(math.floor(dur / 0.02), 2, 120)
	VIM:SendMouseMoveEvent(a.x1, a.y1, game)
	task.wait(0.03)
	VIM:SendMouseButtonEvent(a.x1, a.y1, btn, true, game, 1)
	for i = 1, steps do
		local f = i / steps
		VIM:SendMouseMoveEvent(a.x1 + (a.x2 - a.x1) * f, a.y1 + (a.y2 - a.y1) * f, game)
		task.wait(dur / steps)
	end
	VIM:SendMouseButtonEvent(a.x2, a.y2, btn, false, game, 1)
	return "dragged"
end

function H.key_down(a)
	local code = Enum.KeyCode[a.key]
	assert(code, "unknown key " .. tostring(a.key))
	VIM:SendKeyEvent(true, code, false, game)
	return "down " .. a.key
end

function H.key_up(a)
	local code = Enum.KeyCode[a.key]
	assert(code, "unknown key " .. tostring(a.key))
	VIM:SendKeyEvent(false, code, false, game)
	return "up " .. a.key
end

function H.tap(a)
	if a.method ~= "mouse" then
		local ok = pcall(function()
			VIM:SendTouchEvent(1, Enum.UserInputState.Begin.Value, a.x, a.y)
			task.wait(0.05)
			VIM:SendTouchEvent(1, Enum.UserInputState.End.Value, a.x, a.y)
		end)
		if ok then return "tapped (touch)" end
	end
	H.click({ x = a.x, y = a.y })
	return "tapped (mouse)"
end

-- animations --------------------------------------------------------------------
function H.emote(a)
	local h = assert(hum(), "no humanoid")
	local ok, res = pcall(function() return h:PlayEmote(a.name) end)
	if ok and res then return "emote " .. a.name end
	H.chat({ message = "/e " .. a.name })
	return "sent /e " .. a.name
end

function H.play_animation(a)
	local h = assert(hum(), "no humanoid")
	local animator = assert(h:FindFirstChildOfClass("Animator"), "no Animator")
	local anim = Instance.new("Animation")
	anim.AnimationId = "rbxassetid://" .. (tostring(a.id):gsub("%D", ""))
	local track = animator:LoadAnimation(anim)
	track.Looped = a.looped == true
	track:Play(0.1, 1, a.speed or 1)
	return { playing = true, length = r1(track.Length) }
end

function H.stop_animations()
	local h = assert(hum(), "no humanoid")
	local animator = h:FindFirstChildOfClass("Animator")
	local n = 0
	if animator then
		for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
			t:Stop()
			n = n + 1
		end
	end
	return { stopped = n }
end

-- session ---------------------------------------------------------------------------
function H.rejoin()
	task.delay(0.6, function() TeleportService:Teleport(game.PlaceId, lp) end)
	return "rejoining - re-run the loader after the game loads (or use your executor's autoexec)"
end

function H.teleport_place(a)
	assert(a.placeId, "placeId required")
	task.delay(0.6, function()
		if a.jobId then
			TeleportService:TeleportToPlaceInstance(a.placeId, a.jobId, lp)
		else
			TeleportService:Teleport(a.placeId, lp)
		end
	end)
	return "teleporting - re-run the loader after the game loads"
end

-- misc -------------------------------------------------------------------
function H.wait(a)
	task.wait(math.clamp(a.seconds or 1, 0, 30))
	return "waited"
end

function H.run_lua(a)
	assert(state.allowLua, "run_lua is switched off in the in-game panel (Lua: off)")
	local f, err = loadstring(a.code)
	if not f then error(err, 0) end
	local res = table.pack(f())
	if res.n == 0 then return "done" end
	local parts = {}
	for i = 1, res.n do parts[i] = typeof(res[i]) == "string" and res[i] or stringify(res[i]) end
	return table.concat(parts, "\t")
end

local READONLY = {
	get_state = true, describe_scene = true, find_objects = true, screenshot = true, get_position = true,
	distance_to = true, get_events = true, list_players = true, inspect = true, get_property = true, get_stats = true,
	list_tools = true, find_prompts = true, macro_status = true, list_triggers = true, wait_until = true,
	what_is_at = true, raycast = true, set_feed = true,
}

local function exec(cmd)
	local act = tostring(cmd.action)
	local h = H[cmd.action]
	local ok, res
	if state.paused and not READONLY[act] then
		ok, res = false, "AI control is paused by the user (Pause AI in the in-game panel)"
	else
		setStatus("MCP: " .. act, BLUE)
		if h then ok, res = pcall(h, cmd.args or {}) else ok, res = false, "unknown action " .. act end
	end
	pcall(http, "POST", "/result", {
		id = cmd.id,
		ok = ok,
		result = ok and res or nil,
		error = (not ok) and tostring(res) or nil,
	})
	logLine(string.format("%s %s %s", ok and "+" or "x", act, string.sub(ok and stringify(cmd.args or {}) or tostring(res), 1, 44)))
	if ok then setStatus("MCP: connected", GREEN) else setStatus("MCP: error - " .. act, RED) end
end

onStopAll = function()
	macroRun = macroRun + 1
	feedRun = feedRun + 1
	for k in pairs(triggers) do triggers[k] = nil end
	if noclipConn then noclipConn:Disconnect() noclipConn = nil end
	pcall(H.stop)
	pcall(H.stop_animations)
	logLine("! stopped everything")
	setStatus("MCP: connected", GREEN)
end

----------------------------------------------------------------------
-- connection loop
----------------------------------------------------------------------
local function start()
	getgenv().MCP_RUN = (getgenv().MCP_RUN or 0) + 1
	local myRun = getgenv().MCP_RUN
	feedRun = feedRun + 1
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
logFrame.Visible = state.showLog
for _, f in ipairs(refreshers) do f() end
if BASE ~= "" then
	urlBox.Text, keyBox.Text = BASE, KEY
	start()
else
	panel.Visible = true
end
