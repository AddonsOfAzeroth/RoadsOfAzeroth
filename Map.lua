-- Roads of Azeroth by DinX: route on the world map
-- Quest route on the world map: numbered stops in the fastest order with lines,
-- the GPS route and the arrow's target. Display only.
local _, ns = ...
local RoA = ns.RoA
local L = RoA.L
local S = RoA.Style
local IsSecret = RoA.IsSecret

local MP = RoA:NewModule("Map")

local PIN_TEMPLATE = "RoadsOfAzerothRoutePinTemplate"
local PIN_LEVEL = "PIN_FRAME_LEVEL_AREA_POI" -- known to exist (HereBeDragons uses it)
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local DOT, RING = 17, 21
local LINE_WIDTH = 2.5
local TICK = 0.1

local WMF            -- WorldMapFrame, once it exists
local provider       -- map data provider (nil = fallback mode)
local fallbackPins = {}
local lines = {}
local lineHolder
local playerLine     -- line from the player to the first stop, or nil
local playerX, playerY
local targetLine, targetPin -- white line/pin to the arrow's target (when navigation is off)
local coordsBar, border
local ticker
local fails = 0

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function db() return RoA.char and RoA.char.map end

local function on(key)
	local m = db()
	return m and m.enabled and (key == nil or m[key]) and true or false
end

-- Safe number: nil when secret or not a number
local function num(v)
	if IsSecret(v) or type(v) ~= "number" then return nil end
	return v
end

local function report(tag, err)
	fails = fails + 1
	if RoA.debug and fails <= 10 then RoA:Print("map " .. tag .. ":", tostring(err)) end
end

-- pcall wrapper for every handler
local function guard(tag, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then report(tag, err) end
	return ok
end

local function try(fn, ...)
	if not fn then return end
	local ok, a, b, c = pcall(fn, ...)
	if ok then return a, b, c end
end

local function canvas()
	if not WMF then return end
	if WMF.GetCanvas then
		local c = try(WMF.GetCanvas, WMF)
		if c then return c end
	end
	return WMF.ScrollContainer and WMF.ScrollContainer.Child
end

local function shownMapID()
	if not WMF or not WMF.GetMapID then return end
	return num(try(WMF.GetMapID, WMF))
end

local function isMaximized()
	return WMF and WMF.IsMaximized and try(WMF.IsMaximized, WMF) and true or false
end

-- Player position (0..1) on a map, or nil
local function playerPos(mapID)
	if not mapID or not C_Map or not C_Map.GetPlayerMapPosition then return end
	local pos = try(C_Map.GetPlayerMapPosition, mapID, "player")
	if not pos or not pos.GetXY then return end
	local x, y = try(pos.GetXY, pos)
	x, y = num(x), num(y)
	if not x or not y or (x == 0 and y == 0) then return end
	return x, y
end

local function questTitle(id)
	local t
	if C_QuestLog and C_QuestLog.GetTitleForQuestID then t = try(C_QuestLog.GetTitleForQuestID, id) end
	if (IsSecret(t) or type(t) ~= "string" or t == "") and QuestUtils_GetQuestName then t = try(QuestUtils_GetQuestName, id) end
	if IsSecret(t) or type(t) ~= "string" or t == "" then return "#" .. tostring(id) end
	return t
end

---------------------------------------------------------------------------
-- Route data
---------------------------------------------------------------------------
local function getRoute()
	local qp = RoA.QuestPlan
	if not qp or type(qp.GetRoute) ~= "function" then return end
	local ok, route = pcall(qp.GetRoute, qp)
	if ok and type(route) == "table" then return route end
end

-- Is parentID an ancestor of mapID?
local function isParent(mapID, parentID)
	if not C_Map or not C_Map.GetMapInfo then return false end
	local id = mapID
	for _ = 1, 8 do
		local info = try(C_Map.GetMapInfo, id)
		local p = info and num(info.parentMapID)
		if not p or p == 0 then return false end
		if p == parentID then return true end
		id = p
	end
	return false
end

-- Position of a stop on the shown map: same map, or a zone shown on its parent
local function project(stop, mapID)
	local sx, sy, smap = num(stop.x), num(stop.y), num(stop.mapID)
	if not sx or not sy or not smap then return end
	if smap == mapID then return sx, sy end
	if not C_Map or not C_Map.GetMapRectOnMap or not C_Map.GetMapInfo then return end
	local info = try(C_Map.GetMapInfo, mapID)
	local mt = info and num(info.mapType)
	local continent = Enum and Enum.UIMapType and Enum.UIMapType.Continent or 2
	if not mt or mt < continent then return end -- no world/cosmic clutter
	local x, y
	if isParent(smap, mapID) then
		-- stop on a child map (zone) shown on its parent (continent)
		local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, smap, mapID)
		minX, maxX, minY, maxY = num(minX), num(maxX), num(minY), num(maxY)
		if not ok or not minX or not maxX or not minY or not maxY or maxX <= minX or maxY <= minY then return end
		x, y = minX + sx * (maxX - minX), minY + sy * (maxY - minY)
	elseif isParent(mapID, smap) then
		-- stop on a parent map (e.g. a flight path on the continent) shown on a zone
		local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, mapID, smap)
		minX, maxX, minY, maxY = num(minX), num(maxX), num(minY), num(maxY)
		if not ok or not minX or not maxX or not minY or not maxY or maxX <= minX or maxY <= minY then return end
		x, y = (sx - minX) / (maxX - minX), (sy - minY) / (maxY - minY)
	else
		return
	end
	if x < 0 or x > 1 or y < 0 or y > 1 then return end
	return x, y
end

-- Navigation route (Nav.lua) when navigation is on, else nil
local function navRoute()
	local N = RoA.Nav
	if not (N and N.IsActive and N.GetRoute) then return end
	local ok, isOn = pcall(N.IsActive, N)
	if not ok or not isOn then return end
	local ok2, r = pcall(N.GetRoute, N)
	if ok2 and type(r) == "table" then return r end
	return {}
end

local GREEN = { 0.35, 0.85, 0.40 }
local KIND_NAMES = { quest = "Quest objective", turnin = "Turn-in", custom = "Waypoint", flight = "Flight" }

---------------------------------------------------------------------------
-- Pin visuals (shared by the data provider and the fallback)
---------------------------------------------------------------------------
local function circle(parent, layer, sub, size)
	local tex = parent:CreateTexture(nil, layer, nil, sub)
	tex:SetSize(size, size)
	tex:SetPoint("CENTER")
	tex:SetColorTexture(1, 1, 1, 1)
	if parent.CreateMaskTexture then
		local mask = parent:CreateMaskTexture()
		mask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
		mask:SetAllPoints(tex)
		tex:AddMaskTexture(mask)
	end
	return tex
end

local function DotOnEnter(dot)
	guard("tooltip", function()
		local stop = dot.stop
		if not stop then return end
		GameTooltip:SetOwner(dot, "ANCHOR_RIGHT")
		if stop.kind then
			-- navigation stop: use the live entry when the route still has it
			local route = navRoute()
			local live = route and stop.rank and route[stop.rank]
			if live and live.key == stop.key then stop = live end
			GameTooltip:AddLine(stop.title or L["Next stop"], 1, 1, 1)
			local kn = KIND_NAMES[stop.kind]
			if kn then
				local m = S.colors.muted
				GameTooltip:AddLine(L[kn], m[1], m[2], m[3])
			end
			if type(stop.questIDs) == "table" and #stop.questIDs > 1 then
				for _, id in ipairs(stop.questIDs) do GameTooltip:AddLine(questTitle(id), 1, 1, 1) end
			end
			local cum = num(stop.cum)
			if cum then
				local t = S.colors.text
				GameTooltip:AddLine(L["%d yd"]:format(math.floor(cum + 0.5)), t[1], t[2], t[3])
			end
			GameTooltip:Show()
			return
		end
		if stop.target then
			GameTooltip:AddLine(stop.title or L["Next stop"], 1, 1, 1)
			GameTooltip:Show()
			return
		end
		local a = S.colors.accent
		GameTooltip:AddLine(L["Stop %d"]:format(num(stop.rank) or 0), a[1], a[2], a[3])
		if type(stop.questIDs) == "table" then
			for _, id in ipairs(stop.questIDs) do
				GameTooltip:AddLine(questTitle(id), 1, 1, 1)
			end
		end
		if stop.turnIn then
			local h = S.colors.hint
			GameTooltip:AddLine(L["Ready to turn in"], h[1], h[2], h[3])
		end
		GameTooltip:Show()
	end)
end

local function DotOnLeave(dot)
	if GameTooltip:IsOwned(dot) then GameTooltip:Hide() end
end

-- pin = 1x1 anchor frame; pin.dot = the visible, hoverable circle
local function BuildPin(pin)
	pin:SetSize(1, 1)
	local dot = CreateFrame("Frame", nil, pin)
	dot:SetSize(RING, RING)
	dot:SetPoint("CENTER")
	dot:EnableMouse(true)
	dot:SetScript("OnEnter", DotOnEnter)
	dot:SetScript("OnLeave", DotOnLeave)
	-- let map clicks through (protected in combat, so only outside it)
	if dot.SetPassThroughButtons and not InCombatLockdown() then
		pcall(dot.SetPassThroughButtons, dot, "LeftButton", "RightButton")
	end
	dot.ring = circle(dot, "BACKGROUND", 0, RING)
	dot.ring:SetVertexColor(0, 0, 0, 0.9)
	dot.fill = circle(dot, "ARTWORK", 0, DOT)
	dot.text = S:Font(dot, 11)
	dot.text:SetPoint("CENTER", 0, 0)
	dot.sub = S:Font(dot, 9)
	dot.sub:SetPoint("CENTER", dot, "BOTTOMRIGHT", -1, 2)
	pin.dot = dot
end

local function PaintPin(pin, stop)
	local dot = pin.dot
	dot.stop = stop
	local rank = num(stop.rank) or 0
	-- the current navigation stop gets a white ring
	if stop.kind and rank == 1 then
		dot.ring:SetVertexColor(1, 1, 1, 1)
	else
		dot.ring:SetVertexColor(0, 0, 0, 0.9)
	end
	if stop.target then
		dot.fill:SetVertexColor(1, 1, 1, 1)
		dot.text:SetText("")
		dot.sub:Hide()
	elseif stop.kind == "landing" then
		local p = S.colors.proc
		dot.fill:SetVertexColor(p[1], p[2], p[3], 0.8)
		dot.text:SetText("")
		dot.sub:Hide()
	elseif stop.kind == "flight" then
		local p = S.colors.proc
		dot.fill:SetVertexColor(p[1], p[2], p[3], 1)
		dot.text:SetText("F")
		dot.sub:SetText(rank)
		dot.sub:Show()
	elseif stop.kind == "custom" then
		dot.fill:SetVertexColor(GREEN[1], GREEN[2], GREEN[3], 1)
		dot.text:SetText(rank)
		dot.sub:Hide()
	elseif stop.turnIn or stop.kind == "turnin" then
		local h = S.colors.hint
		dot.fill:SetVertexColor(h[1], h[2], h[3], 1)
		dot.text:SetText("?")
		dot.sub:SetText(rank)
		dot.sub:Show()
	else
		local a = S.colors.accent
		dot.fill:SetVertexColor(a[1], a[2], a[3], 1)
		dot.text:SetText(rank)
		dot.sub:Hide()
	end
	dot:Show()
end

---------------------------------------------------------------------------
-- Lines (on a holder on the canvas, so they pan and zoom with the map)
---------------------------------------------------------------------------
local function canvasScale()
	local s = WMF and WMF.GetCanvasScale and num(try(WMF.GetCanvasScale, WMF))
	if not s and WMF and WMF.ScrollContainer and WMF.ScrollContainer.GetCanvasScale then
		s = num(try(WMF.ScrollContainer.GetCanvasScale, WMF.ScrollContainer))
	end
	if not s or s <= 0 then s = 1 end
	return s
end

local function ensureHolder()
	local c = canvas()
	if not c then return end
	if not lineHolder then
		lineHolder = CreateFrame("Frame", nil, c)
		lineHolder:SetAllPoints(c)
		lineHolder:EnableMouse(false)
	end
	return lineHolder.CreateLine and lineHolder
end

local function hideLines()
	for _, ln in ipairs(lines) do
		ln:Hide()
		ln:ClearAllPoints()
	end
	playerLine, playerX, playerY = nil, nil, nil
	targetLine = nil
	if targetPin then targetPin:Hide() end
end

local function updateThickness()
	local s = canvasScale()
	local t = LINE_WIDTH / s
	for _, ln in ipairs(lines) do ln:SetThickness(t) end
	for _, pin in ipairs(fallbackPins) do if pin.dot then pin.dot:SetScale(1 / s) end end
	if targetPin and targetPin.dot then targetPin.dot:SetScale(1 / s) end
end

local function getLine(i, color, alpha)
	local ln = lines[i]
	if not ln then
		ln = lineHolder:CreateLine(nil, "ARTWORK")
		lines[i] = ln
	end
	local a = color or S.colors.accent
	ln:SetColorTexture(a[1], a[2], a[3], alpha or 0.75)
	ln:SetThickness(LINE_WIDTH / canvasScale())
	ln:Show()
	return ln
end

-- Move the start of the player line to the player's current spot
local function placePlayerLine(x, y)
	local c = canvas()
	if not (playerLine or targetLine) or not c then return end
	local w, h = num(c:GetWidth()), num(c:GetHeight())
	if not w or not h then return end
	if playerLine then playerLine:SetStartPoint("TOPLEFT", c, x * w, -y * h) end
	if targetLine then targetLine:SetStartPoint("TOPLEFT", c, x * w, -y * h) end
	playerX, playerY = x, y
end

-- pins: array of { pin, stop }, in route order (only stops on this map)
local function drawLines(pins, route, mapID)
	hideLines()
	if #pins == 0 or not ensureHolder() then return end
	local low
	for _, p in ipairs(pins) do
		local lv = p.pin:GetFrameLevel()
		if not low or lv < low then low = lv end
	end
	lineHolder:SetFrameLevel(math.max(1, (low or 2) - 1))
	lineHolder:Show()
	local n = 0
	-- player to the first route stop, when both are on this map
	if pins[1].stop == route[1] then
		local px, py = playerPos(mapID)
		if px then
			n = n + 1
			playerLine = getLine(n)
			playerLine:SetEndPoint("CENTER", pins[1].pin, 0, 0)
			placePlayerLine(px, py)
		end
	end
	-- consecutive stops (by route order) that are both shown
	for i = 2, #pins do
		local a, b = pins[i - 1], pins[i]
		if b.index == a.index + 1 then
			n = n + 1
			local ln = getLine(n)
			ln:SetStartPoint("CENTER", a.pin, 0, 0)
			ln:SetEndPoint("CENTER", b.pin, 0, 0)
		end
	end
end

-- Collect the stops of the route that land on the shown map
local function stopsOnMap(mapID)
	local route = getRoute()
	if not route or not mapID then return end
	local list = {}
	for i, stop in ipairs(route) do
		if type(stop) == "table" then
			local x, y = project(stop, mapID)
			if x then list[#list + 1] = { stop = stop, x = x, y = y, index = i } end
		end
	end
	return list, route
end

---------------------------------------------------------------------------
-- Data provider (preferred): pins scale and pan with the map
---------------------------------------------------------------------------
local function setupProvider()
	-- disabled: writing WMF.pinPools / adding a provider taints the map (blocked actions)
	if true then return false end
	if not (WMF and WMF.AddDataProvider and WMF.pinPools and WMF.AcquirePin and WMF.RemoveAllPinsByTemplate
		and MapCanvasDataProviderMixin and MapCanvasPinMixin and CreateFromMixins and Mixin) then
		return false
	end
	local pool
	if CreateUnsecuredRegionPoolInstance then
		pool = CreateUnsecuredRegionPoolInstance(PIN_TEMPLATE)
	elseif CreateFramePool then
		pool = CreateFramePool("FRAME")
	end
	if not pool then return false end

	local pinMixin = CreateFromMixins(MapCanvasPinMixin)
	function pinMixin:OnLoad()
		pcall(self.UseFrameLevelType, self, PIN_LEVEL)
		pcall(self.SetScalingLimits, self, 1, 1.0, 1.2)
	end
	function pinMixin:OnAcquired(stop, x, y)
		guard("pin", function()
			pcall(self.UseFrameLevelType, self, PIN_LEVEL)
			self:SetPosition(x, y)
			PaintPin(self, stop)
		end)
	end
	function pinMixin:OnReleased()
		if self.dot then self.dot.stop = nil end
	end
	-- the map calls this in combat on new pins (protected since 10.1.5)
	pinMixin.SetPassThroughButtons = function() end

	pool.createFunc = function()
		local pin = CreateFrame("Frame", nil, canvas())
		BuildPin(pin)
		return Mixin(pin, pinMixin)
	end
	pool.resetFunc = function(_, pin)
		pin:Hide()
		pin:ClearAllPoints()
		pcall(pin.OnReleased, pin)
		pin.pinTemplate = nil
		pin.owningMap = nil
	end
	pool.creationFunc = pool.createFunc -- older pool API
	pool.resetterFunc = pool.resetFunc

	local p = CreateFromMixins(MapCanvasDataProviderMixin)
	function p:RemoveAllData()
		hideLines()
		local map = self:GetMap()
		if map then pcall(map.RemoveAllPinsByTemplate, map, PIN_TEMPLATE) end
	end
	function p:RefreshAllData()
		guard("refresh", function()
			self:RemoveAllData()
			if not on("route") then return end
			local map = self:GetMap()
			local mapID = map and num(map:GetMapID())
			local list, route = stopsOnMap(mapID)
			if not list or #list == 0 then return end
			local pins = {}
			for _, s in ipairs(list) do
				local pin = map:AcquirePin(PIN_TEMPLATE, s.stop, s.x, s.y)
				if pin then pins[#pins + 1] = { pin = pin, stop = s.stop, index = s.index } end
			end
			drawLines(pins, route, mapID)
		end)
	end
	function p:OnCanvasScaleChanged()
		guard("scale", updateThickness)
	end

	WMF.pinPools[PIN_TEMPLATE] = pool
	WMF:AddDataProvider(p)
	provider = p
	return true
end

---------------------------------------------------------------------------
-- Fallback: own frames on the scroll child, placed by normalised x, y
---------------------------------------------------------------------------
local function fallbackPin(i, c)
	local pin = fallbackPins[i]
	if not pin then
		pin = CreateFrame("Frame", nil, c)
		BuildPin(pin)
		fallbackPins[i] = pin
	end
	pin:SetFrameLevel(math.min(9500, c:GetFrameLevel() + 6000))
	pin.dot:SetScale(1 / canvasScale())
	return pin
end

-- Navigation route: numbered stops, flight legs dashed in purple
local function drawNav(route)
	local c = canvas()
	local mapID = shownMapID()
	if not c or not mapID or #route == 0 then return end
	local w, h = num(c:GetWidth()), num(c:GetHeight())
	if not w or not h then return end
	local count = 0
	local function place(stop, x, y)
		count = count + 1
		local pin = fallbackPin(count, c)
		pin:ClearAllPoints()
		pin:SetPoint("CENTER", c, "TOPLEFT", x * w, -y * h)
		PaintPin(pin, stop)
		pin:Show()
		return pin
	end
	local recs = {}
	for i, e in ipairs(route) do
		local rec = { e = e }
		local x, y = project(e, mapID)
		if x then rec.pin, rec.x, rec.y = place(e, x, y), x, y end
		if e.kind == "flight" and e.toMapID then
			local lx, ly = project({ mapID = e.toMapID, x = e.toX, y = e.toY }, mapID)
			if lx then
				rec.land, rec.lx, rec.ly = place({ kind = "landing", title = e.toName, rank = 0 }, lx, ly), lx, ly
			end
		end
		recs[i] = rec
	end
	if count == 0 or not ensureHolder() then return end
	lineHolder:SetFrameLevel(math.min(9500, c:GetFrameLevel() + 5999))
	lineHolder:Show()
	local n = 0
	-- player to the current stop
	local first = recs[1]
	if first and first.pin then
		local px, py = playerPos(mapID)
		if px then
			n = n + 1
			playerLine = getLine(n)
			playerLine:SetEndPoint("CENTER", first.pin, 0, 0)
			placePlayerLine(px, py)
		end
	end
	local s = canvasScale()
	for i, rec in ipairs(recs) do
		-- flight leg: dashes from the flight master to the landing
		if rec.pin and rec.land then
			local x0, y0, x1, y1 = rec.x * w, rec.y * h, rec.lx * w, rec.ly * h
			local len = ((x1 - x0) ^ 2 + (y1 - y0) ^ 2) ^ 0.5
			local dashes = math.max(4, math.min(60, math.floor(len * s / 18)))
			for k = 0, dashes - 1 do
				local t0, t1 = k / dashes, (k + 0.55) / dashes
				n = n + 1
				local ln = getLine(n, S.colors.proc, 0.9)
				ln:SetStartPoint("TOPLEFT", c, x0 + (x1 - x0) * t0, -(y0 + (y1 - y0) * t0))
				ln:SetEndPoint("TOPLEFT", c, x0 + (x1 - x0) * t1, -(y0 + (y1 - y0) * t1))
			end
		end
		-- to the next stop (after a flight: from the landing)
		local nxt = recs[i + 1]
		if nxt and nxt.pin then
			local from
			if rec.e.kind == "flight" then from = rec.land else from = rec.pin end
			if from then
				n = n + 1
				local ln = getLine(n)
				ln:SetStartPoint("CENTER", from, 0, 0)
				ln:SetEndPoint("CENTER", nxt.pin, 0, 0)
			end
		end
	end
end

local function drawFallback()
	for _, pin in ipairs(fallbackPins) do pin:Hide() end
	hideLines()
	if not on("route") then return end
	local nav = navRoute()
	if nav then return drawNav(nav) end
	local c = canvas()
	local mapID = shownMapID()
	local list, route = stopsOnMap(mapID)
	if not c or not list or #list == 0 then return end
	local w, h = num(c:GetWidth()), num(c:GetHeight())
	if not w or not h then return end
	local pins = {}
	for i, s in ipairs(list) do
		local pin = fallbackPin(i, c)
		pin:ClearAllPoints()
		pin:SetPoint("CENTER", c, "TOPLEFT", s.x * w, -s.y * h)
		PaintPin(pin, s.stop)
		pin:Show()
		pins[#pins + 1] = { pin = pin, stop = s.stop, index = s.index }
	end
	drawLines(pins, route, mapID)
end

-- The arrow's target (a quest picked in the list): white pin with a line from you
local function drawTarget()
	local A = RoA.Arrow
	local c = canvas()
	if not (A and A.GetTarget and c and on("route")) or navRoute() then return end
	local m, tx, ty, title = A:GetTarget()
	local mapID = shownMapID()
	if not (m and mapID) then return end
	local x, y = project({ mapID = m, x = tx, y = ty }, mapID)
	if not x then return end
	local w, h = num(c:GetWidth()), num(c:GetHeight())
	if not w or not h or not ensureHolder() then return end
	if not targetPin then
		targetPin = CreateFrame("Frame", nil, c)
		BuildPin(targetPin)
	end
	targetPin:SetFrameLevel(math.min(9500, c:GetFrameLevel() + 6001))
	targetPin.dot:SetScale(1 / canvasScale())
	targetPin:ClearAllPoints()
	targetPin:SetPoint("CENTER", c, "TOPLEFT", x * w, -y * h)
	PaintPin(targetPin, { target = true, title = title, mapID = m, x = tx, y = ty })
	targetPin:Show()
	local px, py = playerPos(mapID)
	if not px then return end
	lineHolder:SetFrameLevel(math.min(9500, c:GetFrameLevel() + 5999))
	lineHolder:Show()
	local idx = #lines + 1
	for i, l in ipairs(lines) do
		if not l:IsShown() then idx = i break end
	end
	local ln = getLine(idx)
	ln:SetColorTexture(1, 1, 1, 0.85)
	ln:SetEndPoint("CENTER", targetPin, 0, 0)
	targetLine = ln
	placePlayerLine(px, py)
end

function MP:Refresh()
	if not WMF then return end
	if provider then
		provider:RefreshAllData()
	else
		guard("fallback", drawFallback)
	end
	guard("target", drawTarget)
end

---------------------------------------------------------------------------
-- Ticker: one OnUpdate on a child of the map, so it only runs while shown.
-- Keeps the player line on the player and the line width constant.
---------------------------------------------------------------------------
local elapsedTotal = 0
local tickFails = 0
local lastScale

local function tick(elapsed)
	elapsedTotal = elapsedTotal + elapsed
	if elapsedTotal < TICK then return end
	elapsedTotal = 0
	if playerLine or targetLine then
		local px, py = playerPos(shownMapID())
		if px and (px ~= playerX or py ~= playerY) then placePlayerLine(px, py) end
	end
	-- fallback mode has no scale callback: keep line width constant
	if not provider and lines[1] then
		local s = canvasScale()
		if s ~= lastScale then
			lastScale = s
			updateThickness()
		end
	end
end

local function onUpdate(_, elapsed)
	local ok, err = pcall(tick, elapsed)
	if not ok then
		tickFails = tickFails + 1
		report("update", err)
		if tickFails >= 3 and ticker then ticker:SetScript("OnUpdate", nil) end
	end
end

function MP:Apply()
	if ticker then
		if on() then
			tickFails = 0
			ticker:SetScript("OnUpdate", onUpdate)
		else
			ticker:SetScript("OnUpdate", nil)
		end
	end
	self:Refresh()
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
local function setup()
	if WMF or not WorldMapFrame then return end
	WMF = WorldMapFrame

	local ok, res = pcall(setupProvider)
	if not ok then
		report("provider", res)
		provider = nil
	end
	if not provider and WMF.OnMapChanged then
		hooksecurefunc(WMF, "OnMapChanged", function() MP:Refresh() end)
	end

	ticker = CreateFrame("Frame", nil, WMF)
	WMF:HookScript("OnShow", function() MP:Refresh() end)
	MP:Apply()
end

function MP:OnEnable()
	if WorldMapFrame then
		guard("setup", setup)
	else
		RoA:On("ADDON_LOADED", function(_, name)
			if name == "Blizzard_WorldMap" then guard("setup", setup) end
		end)
	end
end

RoA:Listen("QUESTPLAN", function()
	if WMF and WMF:IsShown() then MP:Refresh() end
end)

RoA:Listen("NAV", function()
	if WMF and WMF:IsShown() then MP:Refresh() end
end)

RoA:Listen("ARROW_TARGET", function()
	if WMF and WMF:IsShown() then MP:Refresh() end
end)

RoA:Listen("SETTINGS", function(group)
	if group == "map" and WMF then MP:Apply() end
end)
