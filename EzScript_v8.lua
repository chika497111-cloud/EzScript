-- EzScript v8 — AutoSet + Presets
-- F=Predict, G=Look, V=Serve, P=Timeskip, O=Kijo, R=Ronin, T=Tilt, End=destroy
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VIM = game:GetService("VirtualInputManager")
local HttpService = game:GetService("HttpService")
local localPlayer = Players.LocalPlayer
local camera = workspace.CurrentCamera
local mouse = localPlayer:GetMouse()

if _G.EzScriptCleanup then pcall(_G.EzScriptCleanup) end

do -- main scope (обход лимита 200 регистров)

-- ===============================================================
-- НАСТРОЙКИ
-- ===============================================================
local PREDICT_KEY  = Enum.KeyCode.F
local LOOK_KEY     = Enum.KeyCode.G
local DESTROY_KEY  = Enum.KeyCode.End

-- палитра
local C = {
	bg          = Color3.fromRGB(12, 12, 16),
	bgLight     = Color3.fromRGB(20, 20, 26),
	card        = Color3.fromRGB(24, 24, 32),
	cardHover   = Color3.fromRGB(32, 32, 42),
	cardActive  = Color3.fromRGB(20, 30, 45),
	accent      = Color3.fromRGB(80, 160, 255),
	accentDim   = Color3.fromRGB(50, 100, 180),
	accentGlow  = Color3.fromRGB(100, 180, 255),
	text        = Color3.fromRGB(220, 225, 235),
	textDim     = Color3.fromRGB(110, 115, 130),
	textMuted   = Color3.fromRGB(70, 75, 85),
	border      = Color3.fromRGB(40, 42, 52),
	borderLight = Color3.fromRGB(55, 58, 70),
	success     = Color3.fromRGB(60, 200, 120),
	red         = Color3.fromRGB(255, 70, 70),
}

-- предикт
local MAX_TIME = 6; local STEP = 1/120
local MARKER_COLOR = C.accent; local ACCENT_COLOR = C.accentGlow
local WINDOW_SIZE = 12; local MIN_SAMPLES = 4; local DIVERGENCE = 2.5
local LAND_STABLE_DIST = 2.0; local STABLE_FRAMES = 2; local MAX_WAIT_FRAMES = 20
local FADE_SPEED = 8; local PULSE_SPEED = 4
local TRAIL_SEGMENTS = 30; local TRAIL_DT = 0.05

local LINE_LENGTH = 50; local LINE_COLOR = C.red; local LINE_THICK = 0.15

-- гравитация мяча — вычисляется автоматически из траектории
local BALL_GRAV_DEFAULT = workspace.Gravity * 0.39  -- фолбэк
local function ballGravity() return BALL_GRAV_DEFAULT end

-- анимации
local TWEEN_FAST = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_MED  = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_SLOW = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

local function tween(obj, props, info)
	TweenService:Create(obj, info or TWEEN_MED, props):Play()
end

-- ===============================================================
-- ОБЩИЙ КОНТЕЙНЕР
-- ===============================================================
local rootFolder = Instance.new("Folder")
rootFolder.Name = "__EzScript_" .. tostring(math.random(100000, 999999))
rootFolder.Parent = workspace

-- ===============================================================
-- ПРЕДИКТ — маркер
-- ===============================================================
local predictFolder = Instance.new("Folder")
predictFolder.Name = "Predict"; predictFolder.Parent = rootFolder

local function makePart(parent, name, size, color, shape)
	local p = Instance.new("Part"); p.Name = name
	p.Anchored = true; p.CanCollide = false; p.CanQuery = false
	p.CanTouch = false; p.Massless = true; p.Material = Enum.Material.Neon
	p.Color = color; if shape then p.Shape = shape end
	p.Size = size; p.Transparency = 1; p.Parent = parent
	return p
end

local outerRing = makePart(predictFolder, "OuterRing", Vector3.new(0.05, 3, 3), MARKER_COLOR, Enum.PartType.Cylinder)
local midRing   = makePart(predictFolder, "MidRing",   Vector3.new(0.05, 2, 2), MARKER_COLOR, Enum.PartType.Cylinder)
local innerDot  = makePart(predictFolder, "InnerDot",  Vector3.new(0.08, 0.4, 0.4), ACCENT_COLOR, Enum.PartType.Cylinder)

local trailFolder = Instance.new("Folder"); trailFolder.Name = "Trail"; trailFolder.Parent = predictFolder
local trailSegments, trailVisible = {}, {}
for i = 1, TRAIL_SEGMENTS do
	trailSegments[i] = makePart(trailFolder, "Seg_"..i, Vector3.new(0.2, 0.2, 0.5), MARKER_COLOR)
	trailVisible[i] = false
end

local targetAlpha, currentAlpha, pulseTime = 0, 0, 0

local function placeMarker(landPos)
	local up = CFrame.new(landPos)
	outerRing.CFrame = up * CFrame.new(0, 0.03, 0) * CFrame.Angles(0, 0, math.rad(90))
	midRing.CFrame   = up * CFrame.new(0, 0.06, 0) * CFrame.Angles(0, 0, math.rad(90))
	innerDot.CFrame  = up * CFrame.new(0, 0.09, 0) * CFrame.Angles(0, 0, math.rad(90))
end

local function placeTrail(points)
	for i = 1, TRAIL_SEGMENTS do
		local seg = trailSegments[i]
		if points and i < #points then
			local a, b = points[i], points[i + 1]
			local len = (b - a).Magnitude
			if len > 0.01 then
				seg.Size = Vector3.new(0.25, 0.25, len)
				seg.CFrame = CFrame.lookAt((a + b) * 0.5, b)
				trailVisible[i] = true
			else trailVisible[i] = false end
		else trailVisible[i] = false end
	end
end

local function setPredictVisible(v) targetAlpha = v and 1 or 0 end

local function animatePredict(dt)
	currentAlpha = currentAlpha + (targetAlpha - currentAlpha) * math.min(1, dt * FADE_SPEED)
	pulseTime = pulseTime + dt * PULSE_SPEED
	local pulse = math.sin(pulseTime) * 0.5 + 0.5
	local a = currentAlpha
	if a < 0.01 then
		outerRing.Transparency = 1; midRing.Transparency = 1; innerDot.Transparency = 1
		for i = 1, TRAIL_SEGMENTS do trailSegments[i].Transparency = 1 end; return
	end
	outerRing.Transparency = 1 - a * (0.3 + pulse * 0.15)
	midRing.Transparency   = 1 - a * (0.55 + pulse * 0.2)
	innerDot.Transparency  = 1 - a * (0.9 + pulse * 0.1)
	local s = 1 + pulse * 0.08
	outerRing.Size = Vector3.new(0.05, 3*s, 3*s); midRing.Size = Vector3.new(0.05, 2*s, 2*s)
	for i = 1, TRAIL_SEGMENTS do
		local seg = trailSegments[i]
		if trailVisible[i] then
			seg.Transparency = 1 - a * (1 - i/TRAIL_SEGMENTS * 0.7) * (0.5 + pulse * 0.2)
		else seg.Transparency = 1 end
	end
end

-- ===============================================================
-- ПРЕДИКТ — логика
-- ===============================================================
local function findBallPart()
	for _, inst in ipairs(workspace:GetChildren()) do
		if inst.Name:sub(1, 12) == "CLIENT_BALL_" then
			if inst:IsA("Model") then
				local cube = inst:FindFirstChild("Cube.001")
				if cube and cube:IsA("BasePart") then return cube, inst end
				if inst.PrimaryPart then return inst.PrimaryPart, inst end
				for _, c in ipairs(inst:GetDescendants()) do
					if c:IsA("BasePart") then return c, inst end
				end
			elseif inst:IsA("BasePart") then return inst, inst end
		end
	end
	return nil, nil
end

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude; raycastParams.IgnoreWater = true

local function updateFilter(ballModel)
	local exclude = { rootFolder }
	if ballModel then table.insert(exclude, ballModel) end
	for _, n in ipairs({"BallShadowIndicator", "DebugDraw"}) do
		local f = workspace:FindFirstChild(n); if f then table.insert(exclude, f) end
	end
	local map = workspace:FindFirstChild("Map")
	if map then
		for _, n in ipairs({"BallCollideOnly", "BallNoCollide"}) do
			local f = map:FindFirstChild(n); if f then table.insert(exclude, f) end
		end
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character then table.insert(exclude, plr.Character) end
	end
	raycastParams.FilterDescendantsInstances = exclude
end

local function predictLandingAndPath(startPos, startVel, grav)
	local pos, vel = startPos, startVel
	local g = Vector3.new(0, -(grav or ballGravity()), 0)
	local t, points, nextSample = 0, { startPos }, TRAIL_DT
	while t < MAX_TIME do
		local delta = vel * STEP + 0.5 * g * STEP * STEP
		local hit = workspace:Raycast(pos, delta, raycastParams)
		if hit then table.insert(points, hit.Position); return hit.Position, points end
		pos = pos + delta; vel = vel + g * STEP; t = t + STEP
		if t >= nextSample then
			table.insert(points, pos); nextSample = nextSample + TRAIL_DT
			if #points >= TRAIL_SEGMENTS then break end
		end
	end
	return nil, points
end

local function linearFit(t, v)
	local n = #t; if n < 2 then return 0, 0 end
	local sT, sV, sTT, sTV = 0, 0, 0, 0
	for i = 1, n do sT=sT+t[i]; sV=sV+v[i]; sTT=sTT+t[i]^2; sTV=sTV+t[i]*v[i] end
	local d = n*sTT - sT^2
	if math.abs(d) < 1e-9 then return 0, sV/n end
	return (n*sTV - sT*sV)/d, (sV - ((n*sTV - sT*sV)/d)*sT)/n
end

local function quadFitY(t, y, g)
	local adj = {}; for i = 1, #y do adj[i] = y[i] + 0.5*g*t[i]^2 end
	return linearFit(t, adj)
end

-- полный квадратичный фит: Y = c + b*t + a*t²  →  g = -2*a,  vy0 = b
local function fullQuadFitY(times, ys)
	local n = #times; if n < 4 then return nil, nil end
	local sumT, sumT2, sumT3, sumT4 = 0, 0, 0, 0
	local sumY, sumTY, sumT2Y = 0, 0, 0
	for i = 1, n do
		local t = times[i]
		sumT = sumT + t; sumT2 = sumT2 + t*t; sumT3 = sumT3 + t*t*t; sumT4 = sumT4 + t*t*t*t
		sumY = sumY + ys[i]; sumTY = sumTY + t*ys[i]; sumT2Y = sumT2Y + t*t*ys[i]
	end
	local M = {
		{n, sumT, sumT2, sumY},
		{sumT, sumT2, sumT3, sumTY},
		{sumT2, sumT3, sumT4, sumT2Y},
	}
	for i = 1, 3 do
		local maxVal, maxRow = math.abs(M[i][i]), i
		for k = i+1, 3 do if math.abs(M[k][i]) > maxVal then maxVal = math.abs(M[k][i]); maxRow = k end end
		M[i], M[maxRow] = M[maxRow], M[i]
		if math.abs(M[i][i]) < 1e-12 then return nil, nil end
		for k = i+1, 3 do
			local f = M[k][i] / M[i][i]
			for j = i, 4 do M[k][j] = M[k][j] - f * M[i][j] end
		end
	end
	local a = M[3][4] / M[3][3]
	local b = (M[2][4] - M[2][3]*a) / M[2][2]
	local gFit = -2 * a
	return gFit, b  -- gravity, vy0
end

local lastBall, history = nil, {}
local trajVel, trajPos, trajTime, frozenLand, prevLandGuess
local frozenGravity = nil
local computedGravity = nil
local stableCount, framesSinceReset = 0, 0

local function resetPredict()
	history = {}; trajVel = nil; trajPos = nil; trajTime = nil
	frozenLand = nil; prevLandGuess = nil; frozenGravity = nil
	computedGravity = nil; stableCount = 0; framesSinceReset = 0
end

local function pushHistory(pos, t)
	table.insert(history, {pos=pos, time=t})
	if #history > WINDOW_SIZE then table.remove(history, 1) end
end

local function predictedPosAt(now)
	if not trajVel then return nil end
	local dt = now - trajTime
	local g = computedGravity or BALL_GRAV_DEFAULT
	return trajPos + trajVel*dt + Vector3.new(0, -0.5*g*dt^2, 0)
end

local function computeLandPos(ballPart, ballModel)
	if #history < MIN_SAMPLES then return nil end
	local sc = math.min(#history, 12); local si = #history - sc + 1
	local t0 = history[#history].time
	local ts, xs, ys, zs = {}, {}, {}, {}
	for i = si, #history do
		local idx = i-si+1; local h = history[i]
		ts[idx]=h.time-t0; xs[idx]=h.pos.X; ys[idx]=h.pos.Y; zs[idx]=h.pos.Z
	end

	-- вычисляем g из самой траектории
	local gFit, vyFit = fullQuadFitY(ts, ys)
	local g
	if gFit and gFit > 5 and gFit < 40 then
		-- g адекватная — используем её
		g = gFit
		computedGravity = gFit
	else
		-- фолбэк на последнюю удачную или дефолтную
		g = computedGravity or BALL_GRAV_DEFAULT
	end

	local vx = linearFit(ts, xs); local vz = linearFit(ts, zs)
	local vy
	if vyFit and gFit and gFit > 5 and gFit < 40 then
		vy = vyFit  -- из полного квадратичного фита
	else
		vy = quadFitY(ts, ys, g)  -- фолбэк
	end

	local vel = Vector3.new(vx, vy, vz)
	if vel.Magnitude < 1 then return nil end

	-- используем вычисленную g для симуляции
	updateFilter(ballModel)
	local landPos, path = predictLandingAndPath(ballPart.Position, vel, g)
	if not landPos then return nil end
	local br = ballPart.Size.Y*0.5; local hz = Vector3.new(vel.X, 0, vel.Z)
	if hz.Magnitude > 0.1 and vel.Magnitude > 0.1 then
		landPos = landPos - hz.Unit*(br*hz.Magnitude/vel.Magnitude)
	end
	if path and #path > 0 then path[#path] = landPos end
	return landPos, vel, path, g
end

-- ===============================================================
-- ЛИНИИ ВЗГЛЯДА
-- ===============================================================
local lookFolder = Instance.new("Folder"); lookFolder.Name = "Look"; lookFolder.Parent = rootFolder
local lines = {}

local function makeLookLine()
	local p = Instance.new("Part"); p.Anchored = true; p.CanCollide = false
	p.CanQuery = false; p.CanTouch = false; p.Massless = true
	p.Material = Enum.Material.Neon; p.Color = LINE_COLOR
	p.Size = Vector3.new(LINE_THICK, LINE_THICK, LINE_LENGTH)
	p.Transparency = 1; p.Parent = lookFolder; return p
end

local lookEnabled = false
local function updateLookLines()
	if not lookEnabled then return end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= localPlayer then
			local char = plr.Character; local head = char and char:FindFirstChild("Head")
			if head then
				local line = lines[plr] or makeLookLine(); lines[plr] = line
				local s = head.Position; local e = s + head.CFrame.LookVector * LINE_LENGTH
				line.CFrame = CFrame.lookAt((s+e)*0.5, e)
				line.Size = Vector3.new(LINE_THICK, LINE_THICK, LINE_LENGTH)
				line.Transparency = 0.3
			elseif lines[plr] then lines[plr]:Destroy(); lines[plr] = nil end
		end
	end
	for plr in pairs(lines) do if not plr.Parent then lines[plr]:Destroy(); lines[plr]=nil end end
end

local function hideAllLookLines() for _, l in pairs(lines) do l.Transparency = 1 end end

-- ===============================================================
-- TIMESKIP
-- ===============================================================
local tsEnabled, tsConn = false, nil
local function tsForce()
	local ch = localPlayer.Character; if ch and tsEnabled then ch:SetAttribute("Jumping", true) end
end
local function tsStart() if tsConn then return end; tsConn = RunService.Heartbeat:Connect(function() if tsEnabled then pcall(tsForce) end end) end
local function tsStop() if tsConn then tsConn:Disconnect(); tsConn = nil end end

-- ===============================================================
-- KIJO SANJU
-- ===============================================================
local kijoEnabled = false
local kijoFolder = Instance.new("Folder"); kijoFolder.Name = "Kijo"; kijoFolder.Parent = rootFolder
local kijoData = {}
local KIJO_ARROW_COLOR = Color3.fromRGB(255, 200, 50)
local KIJO_ARROW_LENGTH = 20; local KIJO_ARROW_THICK = 0.5; local KIJO_MIN_ANGLE = 1.0

local function updateKijo()
	if not kijoEnabled then return end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr == localPlayer then continue end
		local char = plr.Character
		if not char then
			if kijoData[plr] then kijoData[plr].arrow:Destroy(); kijoData[plr] = nil end
			continue
		end
		local head = char:FindFirstChild("Head")
		local hrp = char:FindFirstChild("HumanoidRootPart")
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not head or not hrp or not hum then
			if kijoData[plr] then kijoData[plr].arrow:Destroy(); kijoData[plr] = nil end
			continue
		end
		if not kijoData[plr] then
			local a = Instance.new("Part"); a.Anchored = true; a.CanCollide = false
			a.CanQuery = false; a.CanTouch = false; a.Massless = true
			a.Material = Enum.Material.Neon; a.Color = KIJO_ARROW_COLOR
			a.Size = Vector3.new(KIJO_ARROW_THICK, KIJO_ARROW_THICK, KIJO_ARROW_LENGTH)
			a.Transparency = 1; a.Parent = kijoFolder
			kijoData[plr] = {
				neutralDir = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z).Unit,
				arrow = a, wasInAir = false,
			}
		end
		local data = kijoData[plr]
		local state = hum:GetState()
		local inAir = (state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall)
		if not inAir then
			data.neutralDir = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z).Unit
			data.arrow.Transparency = 1
			continue
		end
		local currentDir = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z).Unit
		local dot = currentDir:Dot(data.neutralDir)
		local cross = data.neutralDir:Cross(currentDir).Y
		local angleDeg = math.deg(math.acos(math.clamp(dot, -1, 1)))
		if angleDeg < KIJO_MIN_ANGLE then data.arrow.Transparency = 1; continue end
		local neutralRight = Vector3.new(-data.neutralDir.Z, 0, data.neutralDir.X)
		local arrowDir = cross > 0 and neutralRight or -neutralRight
		local intensity = math.clamp((angleDeg - KIJO_MIN_ANGLE) / 6, 0, 1)
		local alpha = 0.3 - intensity * 0.25
		local arrowStart = head.Position + arrowDir * 1.5
		local arrowEnd = arrowStart + arrowDir * KIJO_ARROW_LENGTH
		data.arrow.Size = Vector3.new(KIJO_ARROW_THICK, KIJO_ARROW_THICK, KIJO_ARROW_LENGTH)
		data.arrow.CFrame = CFrame.lookAt((arrowStart + arrowEnd) * 0.5, arrowEnd)
		data.arrow.Transparency = alpha
		data.arrow.Color = Color3.fromRGB(255, math.floor(200 - intensity * 120), math.floor(50 - intensity * 50))
	end
	for plr in pairs(kijoData) do
		if not plr.Parent then kijoData[plr].arrow:Destroy(); kijoData[plr] = nil end
	end
end

local function hideAllKijo()
	for _, d in pairs(kijoData) do d.arrow.Transparency = 1 end
end

-- ===============================================================
-- RONIN CHARGE — максимальный заряд через State
-- ===============================================================
local roninEnabled = false
local roninConn = nil
local roninState = nil

-- загружаем State модуль
pcall(function()
	roninState = require(ReplicatedStorage.Common.State)
end)

local function roninStart()
	if roninConn then return end
	roninConn = RunService.Heartbeat:Connect(function()
		if not roninEnabled then return end
		pcall(function()
			if roninState then
				roninState.set(localPlayer, roninState.Id.Special, "SamuraiChargeTimestamp", workspace:GetServerTimeNow() - 10)
			end
		end)
	end)
	-- перезапуск каждые 3 сек на случай сброса
	task.spawn(function()
		while roninEnabled do
			task.wait(3)
			if roninEnabled and roninConn then
				roninConn:Disconnect()
				roninConn = RunService.Heartbeat:Connect(function()
					if not roninEnabled then return end
					pcall(function()
						if roninState then
							roninState.set(localPlayer, roninState.Id.Special, "SamuraiChargeTimestamp", workspace:GetServerTimeNow() - 10)
						end
					end)
				end)
			end
		end
	end)
end

local function roninStop()
	if roninConn then roninConn:Disconnect(); roninConn = nil end
	pcall(function()
		if roninState then
			roninState.set(localPlayer, roninState.Id.Special, "SamuraiChargeTimestamp", nil)
		end
	end)
end

-- ===============================================================
-- PERFECT SERVE — подмена power на 1 через hookmetamethod
-- ===============================================================
local serveEnabled = false
local serveOldHook = nil
local serveRF = nil

pcall(function()
	serveRF = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.GameService.RF.Serve
end)

local function serveStart()
	if serveOldHook then return end
	if not serveRF then return end
	serveOldHook = hookmetamethod(game, "__namecall", function(self, ...)
		local method = getnamecallmethod()
		if serveEnabled and method == "InvokeServer" and self == serveRF then
			local args = {...}
			args[2] = 1
			return serveOldHook(self, unpack(args))
		end
		return serveOldHook(self, ...)
	end)
end

local function serveStop()
	-- hookmetamethod нельзя "отключить" — просто serveEnabled = false
	-- хук проверяет флаг и пропускает если выключен
end

-- ===============================================================
-- KIJO TILT — мгновенная максимальная закрутка через A/D
-- ===============================================================
local kijoTiltEnabled = false
local kijoTiltGC = nil
local kijoTiltConns = {}

pcall(function()
	local Knit = require(ReplicatedStorage.Packages.Knit)
	kijoTiltGC = Knit.GetController("GameController")
end)

local function kijoTiltStart()
	if #kijoTiltConns > 0 then return end
	if not kijoTiltGC then return end

	-- мгновенно при нажатии
	table.insert(kijoTiltConns, UserInputService.InputBegan:Connect(function(input, gp)
		if not kijoTiltEnabled or gp then return end
		if input.KeyCode == Enum.KeyCode.A then
			kijoTiltGC.Values.TiltDirection = Vector3.new(1, 1, 0)
		elseif input.KeyCode == Enum.KeyCode.D then
			kijoTiltGC.Values.TiltDirection = Vector3.new(-1, 1, 0)
		end
	end))

	-- держим каждый кадр
	table.insert(kijoTiltConns, RunService.Heartbeat:Connect(function()
		if not kijoTiltEnabled then return end
		local left = UserInputService:IsKeyDown(Enum.KeyCode.A)
		local right = UserInputService:IsKeyDown(Enum.KeyCode.D)
		if left and not right then
			kijoTiltGC.Values.TiltDirection = Vector3.new(1, 1, 0)
		elseif right and not left then
			kijoTiltGC.Values.TiltDirection = Vector3.new(-1, 1, 0)
		end
	end))
end

local function kijoTiltStop()
	for _, c in ipairs(kijoTiltConns) do c:Disconnect() end
	kijoTiltConns = {}
end

-- ===============================================================
-- AUTOSET
-- ===============================================================
local autoSetEnabled = false
local autoSetEditMode = true
local autoSetSelected = nil
local autoSetCharge = nil
local autoSetWPressed = false
local autoSetKeysReleased = false
local autoSetWasInAir = false
local autoSetJustSet = false
local autoSetMarkers = {}
local autoSetFolder = Instance.new("Folder")
autoSetFolder.Name = "AutoSet"; autoSetFolder.Parent = rootFolder

local InteractRF_AS = nil
pcall(function()
	InteractRF_AS = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RF.Interact
end)

for i = 1, 5 do
	local p = Instance.new("Part")
	p.Name = "ASMarker_" .. i
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(2, 2, 2)
	p.Anchored = true; p.CanCollide = false; p.CanQuery = false
	p.CanTouch = false; p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(80, 160, 255)
	p.Transparency = 1; p.Parent = autoSetFolder

	local bg = Instance.new("BillboardGui")
	bg.Size = UDim2.new(0, 30, 0, 30)
	bg.StudsOffset = Vector3.new(0, 2, 0)
	bg.AlwaysOnTop = true; bg.Parent = p

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = tostring(i)
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextSize = 20; label.Font = Enum.Font.GothamBold
	label.Parent = bg

	autoSetMarkers[i] = {part = p, position = nil}
end

local function autoSetGetPos()
	if autoSetSelected and autoSetMarkers[autoSetSelected].position then
		return autoSetMarkers[autoSetSelected].position
	end
	return nil
end

local function autoSetHighlight()
	for i, m in ipairs(autoSetMarkers) do
		if m.position then
			m.part.Color = (i == autoSetSelected) and Color3.fromRGB(255, 60, 60) or Color3.fromRGB(80, 160, 255)
			m.part.Size = (i == autoSetSelected) and Vector3.new(2.5, 2.5, 2.5) or Vector3.new(2, 2, 2)
		end
	end
end

local function autoSetPlaceMarker(num)
	local hitPos = mouse.Hit.Position + Vector3.new(0, 3, 0)
	local char = localPlayer.Character
	if char and char:FindFirstChild("HumanoidRootPart") then
		local myPos = char.HumanoidRootPart.Position
		local dir = (myPos - hitPos)
		local flatDir = Vector3.new(dir.X, 0, dir.Z)
		if flatDir.Magnitude > 0.1 then
			hitPos = hitPos + flatDir.Unit * 3
		end
	end
	autoSetMarkers[num].position = hitPos
	autoSetMarkers[num].part.Position = hitPos
	autoSetMarkers[num].part.Transparency = 0.4
end

local function autoSetSelectMarker(num)
	if autoSetMarkers[num].position then
		autoSetSelected = num
		autoSetHighlight()
	end
end

-- AutoSet Heartbeat
local autoSetConn = nil
local function autoSetStart()
	if autoSetConn then return end
	autoSetConn = RunService.Heartbeat:Connect(function()
		local mp = autoSetGetPos()
		if not mp or autoSetEditMode or not autoSetEnabled then return end
		local char = localPlayer.Character
		if not char then return end
		local hum = char:FindFirstChildOfClass("Humanoid")
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not hum or not hrp then return end
		local state = hum:GetState()
		local inAir = (state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall)

		if inAir then
			local targetFlat = Vector3.new(mp.X, camera.CFrame.Position.Y, mp.Z)
			camera.CFrame = CFrame.lookAt(camera.CFrame.Position, targetFlat)

			local dist = (Vector3.new(mp.X, 0, mp.Z) - Vector3.new(hrp.Position.X, 0, hrp.Position.Z)).Magnitude
			autoSetCharge = math.clamp(dist / 40, 0, 1)

			if not autoSetKeysReleased then
				autoSetKeysReleased = true
				pcall(function()
					VIM:SendKeyEvent(false, Enum.KeyCode.A, false, game)
					VIM:SendKeyEvent(false, Enum.KeyCode.D, false, game)
					VIM:SendKeyEvent(false, Enum.KeyCode.S, false, game)
				end)
			end

			if not autoSetWPressed then
				autoSetWPressed = true
				pcall(function() VIM:SendKeyEvent(true, Enum.KeyCode.W, false, game) end)
			end
		else
			if autoSetWPressed then
				autoSetWPressed = false
				autoSetKeysReleased = false
				pcall(function() VIM:SendKeyEvent(false, Enum.KeyCode.W, false, game) end)
			end
		end
		autoSetWasInAir = inAir
	end)
end

local function autoSetStop()
	if autoSetConn then autoSetConn:Disconnect(); autoSetConn = nil end
	if autoSetWPressed then
		autoSetWPressed = false
		pcall(function() VIM:SendKeyEvent(false, Enum.KeyCode.W, false, game) end)
	end
end

-- AutoSet hookmetamethod для Charge
local autoSetHook = nil
local function autoSetHookStart()
	if autoSetHook then return end
	if not InteractRF_AS then return end
	autoSetHook = hookmetamethod(game, "__namecall", function(self, ...)
		local method = getnamecallmethod()
		if method == "InvokeServer" and self == InteractRF_AS then
			if autoSetEnabled and autoSetCharge and not autoSetEditMode and autoSetSelected then
				local args = {...}
				if typeof(args[1]) == "table" and args[1].Move == "JumpSet" then
					args[1].Charge = autoSetCharge
					autoSetJustSet = true
				end
			end
		end
		return autoSetHook(self, ...)
	end)
end

-- ===============================================================
-- SKIN CHANGER
-- ===============================================================
local jerseyFolder = ReplicatedStorage:FindFirstChild("Assets") and ReplicatedStorage.Assets:FindFirstChild("Jersey")

local function listJerseys()
	local r = {}; if not jerseyFolder then return r end
	for _, j in ipairs(jerseyFolder:GetChildren()) do
		local cl = {}; for _, c in ipairs(j:GetChildren()) do table.insert(cl, c.Name) end
		if #cl > 0 then table.insert(r, {name=j.Name, colors=cl}) end
	end; return r
end

local jerseysList = listJerseys()
local currentJersey = jerseysList[1] and jerseysList[1].name or "None"
local currentColor  = jerseysList[1] and jerseysList[1].colors[1] or "None"
local activeJersey, activeColor = nil, nil
local shirtConn, pantsConn, charConn = nil, nil, nil
local applying = false

local function doApply(jn, cn)
	local ch = localPlayer.Character; if not ch or not jerseyFolder then return end
	local jm = jerseyFolder:FindFirstChild(jn); if not jm then return end
	local cm = jm:FindFirstChild(cn); if not cm then return end
	applying = true
	local ss = cm:FindFirstChildOfClass("Shirt"); local ds = ch:FindFirstChildOfClass("Shirt")
	if ss and ds then ds.ShirtTemplate = ss.ShirtTemplate end
	local sp = cm:FindFirstChildOfClass("Pants"); local dp = ch:FindFirstChildOfClass("Pants")
	if sp and dp then dp.PantsTemplate = sp.PantsTemplate end
	task.delay(0.1, function() applying = false end)
end

local function reapply() if activeJersey and activeColor then doApply(activeJersey, activeColor) end end

local function hookChar(ch)
	if shirtConn then shirtConn:Disconnect() end; if pantsConn then pantsConn:Disconnect() end
	local s = ch:FindFirstChildOfClass("Shirt"); local p = ch:FindFirstChildOfClass("Pants")
	if s then shirtConn = s:GetPropertyChangedSignal("ShirtTemplate"):Connect(function()
		if applying then return end; task.wait(0.05); reapply()
	end) end
	if p then pantsConn = p:GetPropertyChangedSignal("PantsTemplate"):Connect(function()
		if applying then return end; task.wait(0.05); reapply()
	end) end
	task.wait(0.2); reapply()
end

charConn = localPlayer.CharacterAdded:Connect(function(ch)
	task.wait(0.5); hookChar(ch)
	if tsEnabled then pcall(tsForce) end
end)
if localPlayer.Character then hookChar(localPlayer.Character) end

local function applyAndLock(j, c) activeJersey = j; activeColor = c; doApply(j, c) end

-- ===============================================================
-- MAIN LOOP
-- ===============================================================
local predictEnabled = false

local function predictStep(dt)
	animatePredict(dt)
	if not predictEnabled then setPredictVisible(false); return end
	local bp, bm = findBallPart()
	if not bp then setPredictVisible(false); lastBall=nil; resetPredict(); return end
	local now, pos = os.clock(), bp.Position
	if bp ~= lastBall then lastBall=bp; resetPredict(); pushHistory(pos,now); setPredictVisible(false); return end
	if trajVel then
		local exp = predictedPosAt(now)
		if exp and (pos-exp).Magnitude > DIVERGENCE then resetPredict(); pushHistory(pos,now); setPredictVisible(false); return end
	end
	pushHistory(pos, now); framesSinceReset = framesSinceReset + 1
	if frozenLand then
		setPredictVisible(true); placeMarker(frozenLand)
		local g = frozenGravity or computedGravity or BALL_GRAV_DEFAULT
		local lv = trajVel + Vector3.new(0, -g*(now-trajTime), 0)
		updateFilter(bm); local _, lp = predictLandingAndPath(pos, lv, g)
		if lp and #lp > 0 then lp[#lp] = frozenLand end; placeTrail(lp); return
	end
	local lp, vel, path, gUsed = computeLandPos(bp, bm)
	if not lp then setPredictVisible(false); return end
	if prevLandGuess then
		if (lp-prevLandGuess).Magnitude < LAND_STABLE_DIST then stableCount=stableCount+1 else stableCount=0 end
	end; prevLandGuess = lp
	if stableCount < STABLE_FRAMES and framesSinceReset < MAX_WAIT_FRAMES then setPredictVisible(false); return end
	frozenLand=lp; trajVel=vel; trajPos=pos; trajTime=now; frozenGravity=gUsed
	setPredictVisible(true); placeMarker(frozenLand); placeTrail(path)
end

local function mainStep(dt)
	local ok, e = pcall(predictStep, dt); if not ok then warn("[Ez]", e) end
	pcall(updateLookLines)
	pcall(updateKijo)
end
local mainConn = RunService.Heartbeat:Connect(mainStep)

-- ===============================================================
-- UI
-- ===============================================================
local gui = Instance.new("ScreenGui"); gui.Name = "EzScriptGUI"
gui.ResetOnSpawn = false; gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 999999
local ok = pcall(function() gui.Parent = game:GetService("CoreGui") end)
if not ok then gui.Parent = localPlayer:WaitForChild("PlayerGui") end

local FULL_W, FULL_H, HEADER_H = 240, 300, 38

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, FULL_W, 0, FULL_H)
frame.Position = UDim2.new(0, 30, 0.5, -FULL_H/2)
frame.BackgroundColor3 = C.bg; frame.BackgroundTransparency = 0
frame.BorderSizePixel = 0; frame.Active = true; frame.ClipsDescendants = true
frame.Parent = gui

Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 12)

local borderStroke = Instance.new("UIStroke"); borderStroke.Color = C.border
borderStroke.Thickness = 1; borderStroke.Transparency = 0.3; borderStroke.Parent = frame

-- header
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, HEADER_H)
header.BackgroundColor3 = C.bgLight; header.BorderSizePixel = 0
header.ZIndex = 3; header.Parent = frame
Instance.new("UICorner", header).CornerRadius = UDim.new(0, 12)

local hFix = Instance.new("Frame")
hFix.Size = UDim2.new(1, 0, 0, 14); hFix.Position = UDim2.new(0, 0, 1, -14)
hFix.BackgroundColor3 = C.bgLight; hFix.BorderSizePixel = 0; hFix.ZIndex = 3; hFix.Parent = header

local logo = Instance.new("TextLabel")
logo.Size = UDim2.new(0, 20, 0, 20); logo.Position = UDim2.new(0, 14, 0.5, -10)
logo.BackgroundColor3 = C.accent; logo.Text = "E"
logo.Font = Enum.Font.GothamBold; logo.TextSize = 11; logo.TextColor3 = C.bg
logo.ZIndex = 4; logo.Parent = header
Instance.new("UICorner", logo).CornerRadius = UDim.new(0, 5)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -90, 1, 0); title.Position = UDim2.new(0, 42, 0, 0)
title.BackgroundTransparency = 1; title.Text = "EzScript"
title.Font = Enum.Font.GothamBold; title.TextSize = 15
title.TextColor3 = C.text; title.TextXAlignment = Enum.TextXAlignment.Left
title.ZIndex = 4; title.Parent = header

local ver = Instance.new("TextLabel")
ver.Size = UDim2.new(0, 30, 0, 14); ver.Position = UDim2.new(0, 110, 0.5, -5)
ver.BackgroundColor3 = C.card; ver.Text = "v5"
ver.Font = Enum.Font.Gotham; ver.TextSize = 9; ver.TextColor3 = C.textDim
ver.ZIndex = 4; ver.Parent = header
Instance.new("UICorner", ver).CornerRadius = UDim.new(0, 4)

-- minimize
local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.new(0, 28, 0, 28); minBtn.Position = UDim2.new(1, -38, 0.5, -14)
minBtn.BackgroundColor3 = C.card; minBtn.BorderSizePixel = 0
minBtn.Text = "–"; minBtn.Font = Enum.Font.GothamBold; minBtn.TextSize = 16
minBtn.TextColor3 = C.textDim; minBtn.AutoButtonColor = false
minBtn.ZIndex = 5; minBtn.Parent = header
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 6)

local isMinimized = false
local function toggleMinimize()
	isMinimized = not isMinimized
	if isMinimized then
		tween(frame, {Size = UDim2.new(0, FULL_W, 0, HEADER_H)}, TWEEN_SLOW)
		tween(minBtn, {TextColor3 = C.accent}); minBtn.Text = "+"
		tween(borderStroke, {Color = C.accent, Transparency = 0.5})
	else
		tween(frame, {Size = UDim2.new(0, FULL_W, 0, FULL_H)}, TWEEN_SLOW)
		tween(minBtn, {TextColor3 = C.textDim}); minBtn.Text = "–"
		tween(borderStroke, {Color = C.border, Transparency = 0.3})
	end
end
minBtn.MouseButton1Click:Connect(toggleMinimize)
minBtn.MouseEnter:Connect(function() tween(minBtn, {BackgroundColor3 = C.cardHover}, TWEEN_FAST) end)
minBtn.MouseLeave:Connect(function() tween(minBtn, {BackgroundColor3 = C.card}, TWEEN_FAST) end)

-- drag handle
local dragHandle = Instance.new("TextButton")
dragHandle.Size = UDim2.new(1, -40, 1, 0)
dragHandle.Position = UDim2.new(0, 0, 0, 0)
dragHandle.BackgroundTransparency = 1
dragHandle.Text = ""; dragHandle.ZIndex = 6; dragHandle.Parent = header

local dragging, dragStart, startPos = false, nil, nil
dragHandle.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true; dragStart = input.Position; startPos = frame.Position
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local d = input.Position - dragStart
		frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
	end
end)

-- divider
local divider = Instance.new("Frame")
divider.Size = UDim2.new(1, -28, 0, 1); divider.Position = UDim2.new(0, 14, 0, HEADER_H)
divider.BackgroundColor3 = C.border; divider.BackgroundTransparency = 0.5
divider.BorderSizePixel = 0; divider.ZIndex = 2; divider.Parent = frame

-- ===============================================================
-- ВКЛАДКИ
-- ===============================================================
local TAB_Y = HEADER_H + 8
local tabsFrame = Instance.new("Frame")
tabsFrame.Size = UDim2.new(1, -28, 0, 28); tabsFrame.Position = UDim2.new(0, 14, 0, TAB_Y)
tabsFrame.BackgroundColor3 = C.bgLight; tabsFrame.BorderSizePixel = 0
tabsFrame.ZIndex = 2; tabsFrame.Parent = frame
Instance.new("UICorner", tabsFrame).CornerRadius = UDim.new(0, 7)

local tabNames = {"Main", "Styles", "Skins", "AutoSet"}
local tabBtns, tabContents = {}, {}
local currentTab = "Main"

local CONTENT_Y = TAB_Y + 36
local CONTENT_H = FULL_H - CONTENT_Y - 8

for i, name in ipairs(tabNames) do
	local t = Instance.new("TextButton")
	t.Size = UDim2.new(1/#tabNames, -4, 1, -6); t.Position = UDim2.new((i-1)/#tabNames, 3, 0, 3)
	t.BackgroundTransparency = 1; t.BorderSizePixel = 0
	t.Font = Enum.Font.GothamMedium; t.TextSize = 11; t.TextColor3 = C.textMuted
	t.Text = name; t.AutoButtonColor = false; t.ZIndex = 3; t.Parent = tabsFrame
	Instance.new("UICorner", t).CornerRadius = UDim.new(0, 5)
	tabBtns[name] = t

	local content = Instance.new("ScrollingFrame")
	content.Size = UDim2.new(1, 0, 0, CONTENT_H); content.Position = UDim2.new(0, 0, 0, CONTENT_Y)
	content.BackgroundTransparency = 1; content.BorderSizePixel = 0
	content.ScrollBarThickness = 2; content.ScrollBarImageColor3 = C.accent
	content.ScrollBarImageTransparency = 0.5
	content.CanvasSize = UDim2.new(0, 0, 0, 0); content.Visible = (name == "Main")
	content.ZIndex = 2; content.Parent = frame
	tabContents[name] = content
end

local function setTab(tab)
	currentTab = tab
	for name, btn in pairs(tabBtns) do
		if name == tab then
			tween(btn, {BackgroundTransparency = 0, BackgroundColor3 = C.card, TextColor3 = C.accent}, TWEEN_FAST)
		else
			tween(btn, {BackgroundTransparency = 1, TextColor3 = C.textMuted}, TWEEN_FAST)
		end
	end
	for name, content in pairs(tabContents) do content.Visible = (name == tab) end
end

for name, btn in pairs(tabBtns) do
	btn.MouseButton1Click:Connect(function() setTab(name) end)
end

-- ===============================================================
-- TOGGLE КНОПКА
-- ===============================================================
local function makeToggle(parent, order, label, key)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, -28, 0, 36); btn.Position = UDim2.new(0, 14, 0, (order-1) * 44)
	btn.BackgroundColor3 = C.card; btn.BorderSizePixel = 0
	btn.Text = ""; btn.AutoButtonColor = false; btn.ZIndex = 3; btn.Parent = parent
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)

	local indicator = Instance.new("Frame")
	indicator.Size = UDim2.new(0, 3, 0.5, 0); indicator.Position = UDim2.new(0, 0, 0.25, 0)
	indicator.BackgroundColor3 = C.textMuted; indicator.BorderSizePixel = 0
	indicator.ZIndex = 4; indicator.Parent = btn
	Instance.new("UICorner", indicator).CornerRadius = UDim.new(1, 0)

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(0.55, 0, 1, 0); lbl.Position = UDim2.new(0, 16, 0, 0)
	lbl.BackgroundTransparency = 1; lbl.Font = Enum.Font.GothamMedium; lbl.TextSize = 12
	lbl.TextColor3 = C.text; lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = label; lbl.ZIndex = 4; lbl.Parent = btn

	local badge = Instance.new("TextLabel")
	badge.Size = UDim2.new(0, 38, 0, 18); badge.Position = UDim2.new(1, -48, 0.5, -9)
	badge.BackgroundColor3 = C.bgLight; badge.Font = Enum.Font.Gotham; badge.TextSize = 10
	badge.TextColor3 = C.textDim; badge.Text = key; badge.ZIndex = 4; badge.Parent = btn
	Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 4)

	btn.MouseEnter:Connect(function() tween(btn, {BackgroundColor3 = C.cardHover}, TWEEN_FAST) end)
	btn.MouseLeave:Connect(function()
		local isOn = indicator.BackgroundColor3 == C.accent
		tween(btn, {BackgroundColor3 = isOn and C.cardActive or C.card}, TWEEN_FAST)
	end)

	return btn, indicator, badge
end

local function setToggleState(btn, indicator, badge, on)
	if on then
		tween(indicator, {BackgroundColor3 = C.accent, Size = UDim2.new(0, 3, 0.6, 0)}, TWEEN_FAST)
		tween(btn, {BackgroundColor3 = C.cardActive}, TWEEN_FAST)
		tween(badge, {BackgroundColor3 = C.accentDim, TextColor3 = C.accentGlow}, TWEEN_FAST)
	else
		tween(indicator, {BackgroundColor3 = C.textMuted, Size = UDim2.new(0, 3, 0.5, 0)}, TWEEN_FAST)
		tween(btn, {BackgroundColor3 = C.card}, TWEEN_FAST)
		tween(badge, {BackgroundColor3 = C.bgLight, TextColor3 = C.textDim}, TWEEN_FAST)
	end
end

-- ===============================================================
-- MAIN TAB
-- ===============================================================
local mainC = tabContents["Main"]
local pBtn, pInd, pBdg = makeToggle(mainC, 1, "Ball Predict", "F")
local lBtn, lInd, lBdg = makeToggle(mainC, 2, "Look Line", "G")
local svBtn, svInd, svBdg = makeToggle(mainC, 3, "Perfect Serve", "V")
mainC.CanvasSize = UDim2.new(0, 0, 0, 3 * 44 + 10)

-- ===============================================================
-- STYLES TAB
-- ===============================================================
local stylesC = tabContents["Styles"]
local tsBtn2, tsInd, tsBdg = makeToggle(stylesC, 1, "Timeskip Shoyo", "P")
local kjBtn, kjInd, kjBdg = makeToggle(stylesC, 2, "Kijo Sanju", "O")
local rnBtn, rnInd, rnBdg = makeToggle(stylesC, 3, "Ronin Charge", "R")
local ktBtn, ktInd, ktBdg = makeToggle(stylesC, 4, "Kijo Tilt", "T")
stylesC.CanvasSize = UDim2.new(0, 0, 0, 4 * 44 + 10)

-- ===============================================================
-- SKINS TAB + POPUP (do block для экономии регистров)
-- ===============================================================
do
local skinsC = tabContents["Skins"]

local function makeSelector(parent, order, labelText, getValue)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, -28, 0, 36); btn.Position = UDim2.new(0, 14, 0, (order-1) * 44)
	btn.BackgroundColor3 = C.card; btn.BorderSizePixel = 0
	btn.Text = ""; btn.AutoButtonColor = false; btn.ZIndex = 3; btn.Parent = parent
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(0.3, 0, 1, 0); lbl.Position = UDim2.new(0, 14, 0, 0)
	lbl.BackgroundTransparency = 1; lbl.Font = Enum.Font.Gotham; lbl.TextSize = 11
	lbl.TextColor3 = C.textDim; lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = labelText; lbl.ZIndex = 4; lbl.Parent = btn

	local val = Instance.new("TextLabel"); val.Name = "Value"
	val.Size = UDim2.new(0.6, -20, 1, 0); val.Position = UDim2.new(0.35, 0, 0, 0)
	val.BackgroundTransparency = 1; val.Font = Enum.Font.GothamMedium; val.TextSize = 12
	val.TextColor3 = C.accent; val.TextXAlignment = Enum.TextXAlignment.Right
	val.TextTruncate = Enum.TextTruncate.AtEnd; val.Text = getValue()
	val.ZIndex = 4; val.Parent = btn

	local arrow = Instance.new("TextLabel")
	arrow.Size = UDim2.new(0, 16, 1, 0); arrow.Position = UDim2.new(1, -20, 0, 0)
	arrow.BackgroundTransparency = 1; arrow.Font = Enum.Font.GothamBold
	arrow.TextSize = 14; arrow.TextColor3 = C.textMuted; arrow.Text = "›"
	arrow.ZIndex = 4; arrow.Parent = btn

	btn.MouseEnter:Connect(function() tween(btn, {BackgroundColor3 = C.cardHover}, TWEEN_FAST) end)
	btn.MouseLeave:Connect(function() tween(btn, {BackgroundColor3 = C.card}, TWEEN_FAST) end)

	return btn, val
end

local jSelBtn, jSelVal = makeSelector(skinsC, 1, "Jersey", function() return currentJersey end)
local cSelBtn, cSelVal = makeSelector(skinsC, 2, "Color",  function() return currentColor end)

local applyBtn = Instance.new("TextButton")
applyBtn.Size = UDim2.new(1, -28, 0, 34); applyBtn.Position = UDim2.new(0, 14, 0, 2 * 44 + 8)
applyBtn.BackgroundColor3 = C.accent; applyBtn.BorderSizePixel = 0
applyBtn.Font = Enum.Font.GothamBold; applyBtn.TextSize = 12
applyBtn.TextColor3 = C.bg; applyBtn.Text = "APPLY"
applyBtn.AutoButtonColor = false; applyBtn.ZIndex = 3; applyBtn.Parent = skinsC
Instance.new("UICorner", applyBtn).CornerRadius = UDim.new(0, 8)

applyBtn.MouseEnter:Connect(function() tween(applyBtn, {BackgroundColor3 = C.accentGlow}, TWEEN_FAST) end)
applyBtn.MouseLeave:Connect(function() tween(applyBtn, {BackgroundColor3 = C.accent}, TWEEN_FAST) end)
applyBtn.MouseButton1Click:Connect(function()
	applyAndLock(currentJersey, currentColor)
	tween(applyBtn, {BackgroundColor3 = C.success}, TWEEN_FAST)
	task.delay(0.3, function() tween(applyBtn, {BackgroundColor3 = C.accent}, TWEEN_MED) end)
end)

skinsC.CanvasSize = UDim2.new(0, 0, 0, 2 * 44 + 50)

-- ===============================================================
-- POPUP
local popupOverlay = Instance.new("Frame")
popupOverlay.Size = UDim2.new(1, 0, 1, 0); popupOverlay.BackgroundColor3 = Color3.new(0,0,0)
popupOverlay.BackgroundTransparency = 1; popupOverlay.BorderSizePixel = 0
popupOverlay.Visible = false; popupOverlay.ZIndex = 10; popupOverlay.Parent = gui

local popupFrame = Instance.new("Frame")
popupFrame.Size = UDim2.new(0, 260, 0, 320)
popupFrame.Position = UDim2.new(0.5, -130, 0.5, -160)
popupFrame.BackgroundColor3 = C.bg; popupFrame.BorderSizePixel = 0
popupFrame.ZIndex = 11; popupFrame.Parent = popupOverlay
Instance.new("UICorner", popupFrame).CornerRadius = UDim.new(0, 12)
local pStroke = Instance.new("UIStroke"); pStroke.Color = C.border; pStroke.Thickness = 1; pStroke.Parent = popupFrame

local popupTitle = Instance.new("TextLabel")
popupTitle.Size = UDim2.new(1, -50, 0, 36); popupTitle.Position = UDim2.new(0, 16, 0, 4)
popupTitle.BackgroundTransparency = 1; popupTitle.Font = Enum.Font.GothamBold
popupTitle.TextSize = 14; popupTitle.TextColor3 = C.text
popupTitle.TextXAlignment = Enum.TextXAlignment.Left; popupTitle.Text = "Select"
popupTitle.ZIndex = 12; popupTitle.Parent = popupFrame

local popupClose = Instance.new("TextButton")
popupClose.Size = UDim2.new(0, 28, 0, 28); popupClose.Position = UDim2.new(1, -36, 0, 8)
popupClose.BackgroundColor3 = C.card; popupClose.BorderSizePixel = 0
popupClose.Font = Enum.Font.GothamBold; popupClose.TextSize = 14
popupClose.TextColor3 = C.textDim; popupClose.Text = "×"
popupClose.AutoButtonColor = false; popupClose.ZIndex = 12; popupClose.Parent = popupFrame
Instance.new("UICorner", popupClose).CornerRadius = UDim.new(0, 6)

local popupScroll = Instance.new("ScrollingFrame")
popupScroll.Size = UDim2.new(1, -24, 1, -52); popupScroll.Position = UDim2.new(0, 12, 0, 44)
popupScroll.BackgroundTransparency = 1; popupScroll.BorderSizePixel = 0
popupScroll.ScrollBarThickness = 3; popupScroll.ScrollBarImageColor3 = C.accent
popupScroll.CanvasSize = UDim2.new(0, 0, 0, 0); popupScroll.ZIndex = 11; popupScroll.Parent = popupFrame
local pLayout = Instance.new("UIListLayout"); pLayout.Padding = UDim.new(0, 4)
pLayout.SortOrder = Enum.SortOrder.LayoutOrder; pLayout.Parent = popupScroll

local function openPopup(titleText, items, onSelect)
	for _, c in ipairs(popupScroll:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
	popupTitle.Text = titleText
	for i, item in ipairs(items) do
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(1, -4, 0, 34); b.BackgroundColor3 = C.card; b.BorderSizePixel = 0
		b.Font = Enum.Font.GothamMedium; b.TextSize = 12; b.TextColor3 = C.text
		b.Text = "  " .. item; b.TextXAlignment = Enum.TextXAlignment.Left
		b.AutoButtonColor = false; b.LayoutOrder = i; b.ZIndex = 12; b.Parent = popupScroll
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
		b.MouseEnter:Connect(function() tween(b, {BackgroundColor3 = C.cardHover}, TWEEN_FAST) end)
		b.MouseLeave:Connect(function() tween(b, {BackgroundColor3 = C.card}, TWEEN_FAST) end)
		b.MouseButton1Click:Connect(function()
			onSelect(item)
			tween(popupOverlay, {BackgroundTransparency = 1}, TWEEN_FAST)
			tween(popupFrame, {Position = UDim2.new(0.5, -130, 0.5, -140)}, TWEEN_FAST)
			task.delay(0.15, function() popupOverlay.Visible = false end)
		end)
	end
	popupScroll.CanvasSize = UDim2.new(0, 0, 0, pLayout.AbsoluteContentSize.Y + 10)
	popupOverlay.Visible = true; popupOverlay.BackgroundTransparency = 1
	popupFrame.Position = UDim2.new(0.5, -130, 0.5, -140)
	tween(popupOverlay, {BackgroundTransparency = 0.5}, TWEEN_FAST)
	tween(popupFrame, {Position = UDim2.new(0.5, -130, 0.5, -160)}, TWEEN_MED)
end

popupClose.MouseButton1Click:Connect(function()
	tween(popupOverlay, {BackgroundTransparency = 1}, TWEEN_FAST)
	task.delay(0.15, function() popupOverlay.Visible = false end)
end)
popupClose.MouseEnter:Connect(function() tween(popupClose, {BackgroundColor3 = C.cardHover}, TWEEN_FAST) end)
popupClose.MouseLeave:Connect(function() tween(popupClose, {BackgroundColor3 = C.card}, TWEEN_FAST) end)

jSelBtn.MouseButton1Click:Connect(function()
	local items = {}; for _, j in ipairs(jerseysList) do table.insert(items, j.name) end
	openPopup("Select Jersey", items, function(name)
		currentJersey = name; jSelVal.Text = name
		local found = false
		for _, j in ipairs(jerseysList) do
			if j.name == name then
				for _, cc in ipairs(j.colors) do if cc == currentColor then found = true; break end end
				if not found and j.colors[1] then currentColor = j.colors[1]; cSelVal.Text = currentColor end
				break
			end
		end
	end)
end)

cSelBtn.MouseButton1Click:Connect(function()
	local colors = {}
	for _, j in ipairs(jerseysList) do if j.name == currentJersey then colors = j.colors; break end end
	openPopup("Select Color", colors, function(name)
		currentColor = name; cSelVal.Text = name
	end)
end)

end -- do POPUP

-- ===============================================================
-- AUTOSET TAB
-- ===============================================================
do
local asC = tabContents["AutoSet"]

-- Mode toggle: РАССТАНОВКА / ИГРА
local modeBtn = Instance.new("TextButton")
modeBtn.Size = UDim2.new(1, -28, 0, 34); modeBtn.Position = UDim2.new(0, 14, 0, 0)
modeBtn.BackgroundColor3 = C.accent; modeBtn.BorderSizePixel = 0
modeBtn.Font = Enum.Font.GothamBold; modeBtn.TextSize = 12
modeBtn.TextColor3 = C.bg; modeBtn.Text = "MODE: PLACE"
modeBtn.AutoButtonColor = false; modeBtn.ZIndex = 3; modeBtn.Parent = asC
Instance.new("UICorner", modeBtn).CornerRadius = UDim.new(0, 8)

modeBtn.MouseButton1Click:Connect(function()
	autoSetEditMode = not autoSetEditMode
	modeBtn.Text = autoSetEditMode and "MODE: PLACE" or "MODE: PLAY"
	modeBtn.BackgroundColor3 = autoSetEditMode and C.accent or C.success
end)

-- 5 marker buttons
local markerBtns = {}
for i = 1, 5 do
	local mb = Instance.new("TextButton")
	mb.Size = UDim2.new(0.18, -2, 0, 30); mb.Position = UDim2.new((i-1) * 0.2, 14 + (i-1)*2, 0, 42)
	mb.BackgroundColor3 = C.card; mb.BorderSizePixel = 0
	mb.Font = Enum.Font.GothamBold; mb.TextSize = 14
	mb.TextColor3 = C.text; mb.Text = tostring(i)
	mb.AutoButtonColor = false; mb.ZIndex = 3; mb.Parent = asC
	Instance.new("UICorner", mb).CornerRadius = UDim.new(0, 6)

	mb.MouseButton1Click:Connect(function()
		if autoSetEditMode then
			autoSetPlaceMarker(i)
			mb.BackgroundColor3 = C.accentDim
			task.delay(0.3, function() mb.BackgroundColor3 = C.card end)
		else
			autoSetSelectMarker(i)
			for j, b in ipairs(markerBtns) do
				b.BackgroundColor3 = (j == i) and C.cardActive or C.card
				b.TextColor3 = (j == i) and C.accent or C.text
			end
		end
	end)

	mb.MouseEnter:Connect(function() tween(mb, {BackgroundColor3 = C.cardHover}, TWEEN_FAST) end)
	mb.MouseLeave:Connect(function()
		local isActive = (i == autoSetSelected and not autoSetEditMode)
		tween(mb, {BackgroundColor3 = isActive and C.cardActive or C.card}, TWEEN_FAST)
	end)

	markerBtns[i] = mb
end

-- ON/OFF toggle
local asTogBtn, asTogInd, asTogBdg = makeToggle(asC, 3, "AutoSet", "X")
asTogBtn.Position = UDim2.new(0, 14, 0, 82)

-- Preset section label
local presetLabel = Instance.new("TextLabel")
presetLabel.Size = UDim2.new(1, -28, 0, 20); presetLabel.Position = UDim2.new(0, 14, 0, 126)
presetLabel.BackgroundTransparency = 1; presetLabel.Font = Enum.Font.Gotham
presetLabel.TextSize = 10; presetLabel.TextColor3 = C.textDim
presetLabel.TextXAlignment = Enum.TextXAlignment.Left
presetLabel.Text = "PRESETS (hold to save)"; presetLabel.ZIndex = 3; presetLabel.Parent = asC

-- 5 preset buttons
local presetBtns = {}
for i = 1, 5 do
	local pb = Instance.new("TextButton")
	pb.Size = UDim2.new(0.18, -2, 0, 30); pb.Position = UDim2.new((i-1) * 0.2, 14 + (i-1)*2, 0, 148)
	pb.BackgroundColor3 = C.card; pb.BorderSizePixel = 0
	pb.Font = Enum.Font.GothamBold; pb.TextSize = 14
	pb.TextColor3 = C.textDim; pb.Text = tostring(i)
	pb.AutoButtonColor = false; pb.ZIndex = 3; pb.Parent = asC
	Instance.new("UICorner", pb).CornerRadius = UDim.new(0, 6)

	local holdStart = 0
	pb.MouseButton1Down:Connect(function() holdStart = os.clock() end)
	pb.MouseButton1Up:Connect(function()
		local held = os.clock() - holdStart
		if held > 1 then
			-- long press = save
			_G.EzSavePreset(i)
			tween(pb, {BackgroundColor3 = C.success}, TWEEN_FAST)
			task.delay(0.5, function() tween(pb, {BackgroundColor3 = C.card}, TWEEN_MED) end)
		else
			-- tap = load
			_G.EzLoadPreset(i)
			for j, b in ipairs(presetBtns) do
				b.TextColor3 = (j == i) and C.accent or C.textDim
			end
		end
	end)

	pb.MouseEnter:Connect(function() tween(pb, {BackgroundColor3 = C.cardHover}, TWEEN_FAST) end)
	pb.MouseLeave:Connect(function() tween(pb, {BackgroundColor3 = C.card}, TWEEN_FAST) end)

	presetBtns[i] = pb
end

asC.CanvasSize = UDim2.new(0, 0, 0, 190)

end -- do AutoSet tab

-- ===============================================================
-- TOGGLES
-- ===============================================================
local function togglePredict()
	predictEnabled = not predictEnabled
	if not predictEnabled then setPredictVisible(false); resetPredict(); lastBall = nil end
	setToggleState(pBtn, pInd, pBdg, predictEnabled)
end

local function toggleLook()
	lookEnabled = not lookEnabled
	if not lookEnabled then hideAllLookLines() end
	setToggleState(lBtn, lInd, lBdg, lookEnabled)
end

local function toggleTS()
	tsEnabled = not tsEnabled
	if tsEnabled then tsStart(); pcall(tsForce) else tsStop() end
	setToggleState(tsBtn2, tsInd, tsBdg, tsEnabled)
end

local function toggleKijo()
	kijoEnabled = not kijoEnabled
	if not kijoEnabled then hideAllKijo() end
	setToggleState(kjBtn, kjInd, kjBdg, kijoEnabled)
end

local function toggleRonin()
	roninEnabled = not roninEnabled
	if roninEnabled then roninStart() else roninStop() end
	setToggleState(rnBtn, rnInd, rnBdg, roninEnabled)
end

local function toggleKijoTilt()
	kijoTiltEnabled = not kijoTiltEnabled
	if kijoTiltEnabled then kijoTiltStart() else kijoTiltStop() end
	setToggleState(ktBtn, ktInd, ktBdg, kijoTiltEnabled)
end

local function toggleAutoSet()
	autoSetEnabled = not autoSetEnabled
	if autoSetEnabled then
		autoSetHookStart()
		autoSetStart()
	else
		autoSetStop()
	end
end

local function toggleServe()
	serveEnabled = not serveEnabled
	if serveEnabled then serveStart() end
	setToggleState(svBtn, svInd, svBdg, serveEnabled)
end

pBtn.MouseButton1Click:Connect(togglePredict)
lBtn.MouseButton1Click:Connect(toggleLook)
tsBtn2.MouseButton1Click:Connect(toggleTS)
kjBtn.MouseButton1Click:Connect(toggleKijo)
rnBtn.MouseButton1Click:Connect(toggleRonin)
ktBtn.MouseButton1Click:Connect(toggleKijoTilt)
svBtn.MouseButton1Click:Connect(toggleServe)

-- ===============================================================
-- PRESET SYSTEM
-- ===============================================================
do
local PRESET_FOLDER = "EzScript"
local PRESET_FILE = PRESET_FOLDER .. "/presets.json"

pcall(function()
	if not isfolder(PRESET_FOLDER) then makefolder(PRESET_FOLDER) end
end)

local function getToggleStates()
	return {
		predict = predictEnabled,
		look = lookEnabled,
		timeskip = tsEnabled,
		kijo = kijoEnabled,
		ronin = roninEnabled,
		kijoTilt = kijoTiltEnabled,
		serve = serveEnabled,
		autoSet = autoSetEnabled,
	}
end

local function getMarkerData()
	local data = {}
	for i, m in ipairs(autoSetMarkers) do
		if m.position then
			data[tostring(i)] = {x = m.position.X, y = m.position.Y, z = m.position.Z}
		end
	end
	return data
end

_G.EzSavePreset = function(slot)
	slot = slot or 1
	local all = {}
	pcall(function()
		if isfile(PRESET_FILE) then
			all = HttpService:JSONDecode(readfile(PRESET_FILE))
		end
	end)
	all[tostring(slot)] = {
		toggles = getToggleStates(),
		markers = getMarkerData(),
	}
	pcall(function()
		writefile(PRESET_FILE, HttpService:JSONEncode(all))
	end)
	print("[Preset] Saved slot " .. slot)
end

_G.EzLoadPreset = function(slot)
	slot = slot or 1
	local all = {}
	pcall(function()
		if isfile(PRESET_FILE) then
			all = HttpService:JSONDecode(readfile(PRESET_FILE))
		end
	end)
	local data = all[tostring(slot)]
	if not data then print("[Preset] Slot " .. slot .. " empty"); return end

	if data.markers then
		for i, m in ipairs(autoSetMarkers) do
			local md = data.markers[tostring(i)]
			if md then
				m.position = Vector3.new(md.x, md.y, md.z)
				m.part.Position = m.position
				m.part.Transparency = 0.4
			else
				m.position = nil
				m.part.Transparency = 1
			end
		end
	end

	if data.toggles then
		if data.toggles.predict ~= predictEnabled then togglePredict() end
		if data.toggles.look ~= lookEnabled then toggleLook() end
		if data.toggles.timeskip ~= tsEnabled then toggleTS() end
		if data.toggles.kijo ~= kijoEnabled then toggleKijo() end
		if data.toggles.ronin ~= roninEnabled then toggleRonin() end
		if data.toggles.kijoTilt ~= kijoTiltEnabled then toggleKijoTilt() end
		if data.toggles.serve ~= serveEnabled then toggleServe() end
		if data.toggles.autoSet ~= autoSetEnabled then toggleAutoSet() end
	end

	print("[Preset] Loaded slot " .. slot)
end
end -- do presets

local inputConn = UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == PREDICT_KEY then togglePredict()
	elseif input.KeyCode == LOOK_KEY then toggleLook()
	elseif input.KeyCode == Enum.KeyCode.P then toggleTS()
	elseif input.KeyCode == Enum.KeyCode.O then toggleKijo()
	elseif input.KeyCode == Enum.KeyCode.R then toggleRonin()
	elseif input.KeyCode == Enum.KeyCode.T then toggleKijoTilt()
	elseif input.KeyCode == Enum.KeyCode.V then toggleServe()
	elseif input.KeyCode == DESTROY_KEY then
		if _G.EzScriptCleanup then _G.EzScriptCleanup() end
	end
end)

setTab("Main")

-- анимация появления
frame.BackgroundTransparency = 1; borderStroke.Transparency = 1
frame.Position = UDim2.new(0, 30, 0.5, -FULL_H/2 + 20)
task.delay(0.05, function()
	tween(frame, {
		BackgroundTransparency = 0,
		Position = UDim2.new(0, 30, 0.5, -FULL_H/2),
	}, TWEEN_SLOW)
	tween(borderStroke, {Transparency = 0.3}, TWEEN_SLOW)
end)

-- ===============================================================
-- CLEANUP
-- ===============================================================
_G.EzScriptCleanup = function()
	tween(frame, {BackgroundTransparency = 1, Position = UDim2.new(0, 30, 0.5, -FULL_H/2 + 20)}, TWEEN_FAST)
	tween(borderStroke, {Transparency = 1}, TWEEN_FAST)
	task.delay(0.2, function()
		if mainConn then mainConn:Disconnect() end
		if inputConn then inputConn:Disconnect() end
		if charConn then charConn:Disconnect() end
		if shirtConn then shirtConn:Disconnect() end
		if pantsConn then pantsConn:Disconnect() end
		tsStop()
		roninStop()
		kijoTiltStop()
		autoSetStop()
		for plr in pairs(kijoData) do kijoData[plr].arrow:Destroy(); kijoData[plr] = nil end
		if rootFolder then rootFolder:Destroy() end
		if gui then gui:Destroy() end
		for plr in pairs(lines) do lines[plr] = nil end
		_G.EzScriptCleanup = nil
	end)
end

print("[EzScript v8] F=Predict, G=Look, V=Serve, P=Timeskip, O=Kijo, R=Ronin, T=Tilt, End=destroy")

end -- do main scope
