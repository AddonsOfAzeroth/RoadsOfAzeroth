-- Roads of Azeroth by DinX: learned paths on the world map, as a heatmap.
-- A small "Paths" button on the map turns it on or off. Lines between the points
-- you walked, coloured by how often: blue = once or twice, yellow = often,
-- red = your main roads. Display only.
local _, ns = ...
local RoA = ns.RoA
local L = RoA.L
local S = RoA.Style

local TM = RoA:NewModule("TrailsMap")

local WIDTH = 3          -- line width in screen pixels
local MAX_LINES = 6000
local HOT = 25           -- visits for full red
local MARGIN = 0.02      -- keep lines just outside the visible map

local WMF, holder, button, ticker
local lines, used = {}, 0
local lastScale
local status = "" -- why nothing is drawn (shown in the button's tooltip)

local function num(v)
	if RoA.IsSecret(v) then return end
	return type(v) == "number" and v or nil
end

local function try(fn, ...)
	if not fn then return end
	local ok, a, b = pcall(fn, ...)
	if ok then return a, b end
end

local function shown()
	local m = RoA.char and RoA.char.map
	return m and m.trails and true or false
end

local function canvas()
	if WMF.GetCanvas then
		local c = try(WMF.GetCanvas, WMF)
		if c then return c end
	end
	return WMF.ScrollContainer and WMF.ScrollContainer.Child
end

local function canvasScale()
	local s = WMF.GetCanvasScale and num(try(WMF.GetCanvasScale, WMF))
	if not s and WMF.ScrollContainer and WMF.ScrollContainer.GetCanvasScale then
		s = num(try(WMF.ScrollContainer.GetCanvasScale, WMF.ScrollContainer))
	end
	if not s or s <= 0 then s = 1 end
	return s
end

-- blue -> yellow -> red by visits
local function heat(v)
	local t = math.min(1, math.log(math.max(1, v)) / math.log(HOT))
	if t < 0.5 then
		local k = t * 2
		return 0.25 + 0.75 * k, 0.6 + 0.3 * k, 1 - 0.9 * k
	end
	local k = (t - 0.5) * 2
	return 1, 0.9 - 0.75 * k, 0.1
end

local function hideAll()
	for i = 1, used do lines[i]:Hide() end
	used = 0
end

local function line()
	used = used + 1
	local ln = lines[used]
	if not ln then
		ln = holder:CreateLine(nil, "BORDER")
		lines[used] = ln
	end
	ln:Show()
	return ln
end

-- continent (world instance) of a map, as Trails.lua stores it
local function continentOf(mapID)
	if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
	local cont = try(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(0.5, 0.5))
	return num(cont)
end

-- map position (0..1) of world points, cached per map until the data grows
local projCache = {}
local function project(mapID, cont, c)
	local count = c.next or 0
	local pc = projCache[mapID]
	if pc and pc.count == count then return pc.pos end
	local pos = {}
	if C_Map.GetMapPosFromWorldPos then
		local v = CreateVector2D(0, 0)
		for id, pt in pairs(c.p) do
			v:SetXY(pt[1], pt[2])
			local _, mp = try(C_Map.GetMapPosFromWorldPos, cont, v, mapID)
			if mp and mp.GetXY then
				local x, y = mp:GetXY()
				x, y = num(x), num(y)
				if x and y and x > -MARGIN and x < 1 + MARGIN and y > -MARGIN and y < 1 + MARGIN then
					pos[id] = { x, y }
				end
			end
		end
	end
	projCache[mapID] = { count = count, pos = pos }
	return pos
end

local function draw()
	hideAll()
	status = ""
	if not (shown() and WMF and WMF:IsShown() and RoA.Trails) then return end
	local c0 = canvas()
	if not c0 then status = "no canvas" return end
	if not holder then
		holder = CreateFrame("Frame", nil, c0)
		holder:SetAllPoints(c0)
		holder:EnableMouse(false)
	end
	-- above the map tiles, below the pins
	holder:SetFrameLevel(c0:GetFrameLevel() + 20)
	local mapID = WMF.GetMapID and num(try(WMF.GetMapID, WMF))
	local cont = mapID and continentOf(mapID)
	if not cont then status = "map " .. tostring(mapID) .. ": no continent" return end
	local c = RoA.Trails:Data(cont)
	if not c then status = "no paths on continent " .. tostring(cont) return end
	local pos = project(mapID, cont, c)
	local onMap = 0
	for _ in pairs(pos) do onMap = onMap + 1 end
	status = ("%d points on this map"):format(onMap)
	local w, h = c0:GetWidth(), c0:GetHeight()
	local t = WIDTH / canvasScale()
	lastScale = canvasScale()
	for a, nbs in pairs(c.l) do
		local pa = pos[a]
		if pa then
			for b in pairs(nbs) do
				if a < b and pos[b] then
					if used >= MAX_LINES then return end
					local pb = pos[b]
					local va, vb = c.p[a][3] or 1, c.p[b][3] or 1
					local r, g, bl = heat(math.min(va, vb))
					local ln = line()
					ln:SetColorTexture(r, g, bl, 0.8)
					ln:SetThickness(t)
					ln:SetStartPoint("TOPLEFT", c0, pa[1] * w, -pa[2] * h)
					ln:SetEndPoint("TOPLEFT", c0, pb[1] * w, -pb[2] * h)
				end
			end
		end
	end
end

local function refresh()
	if button then button:SetBackdropBorderColor(unpack(shown() and S.colors.accent or { 0, 0, 0, 1 })) end
	local ok, err = pcall(draw)
	if not ok then status = "error: " .. tostring(err) end
end
TM.Refresh = refresh

local function makeButton()
	local b = CreateFrame("Button", nil, WMF.ScrollContainer or WMF, "BackdropTemplate")
	b:SetSize(64, 20)
	b:SetPoint("BOTTOMLEFT", WMF.ScrollContainer or WMF, "BOTTOMLEFT", 8, 8)
	b:SetFrameStrata("HIGH")
	S:Backdrop(b, 0.85)
	local t = S:Font(b, 11)
	t:SetPoint("CENTER")
	t:SetText(L["Paths"])
	b:SetScript("OnClick", function()
		RoA.char.map.trails = not shown()
		refresh()
	end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(L["Learned paths"], 1, 1, 1)
		GameTooltip:AddLine(L["Where you (all your characters) walked. Blue: once or twice, yellow: often, red: your main roads."], 0.6, 0.65, 0.71, true)
		local n = RoA.Trails and RoA.Trails:Stats() or 0
		GameTooltip:AddLine(L["%d points learned."]:format(n), 0.6, 0.65, 0.71)
		if shown() then GameTooltip:AddLine(status .. (used > 0 and (", " .. used .. " lines") or ""), 0.6, 0.65, 0.71) end
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return b
end

local function setup()
	if WMF or not WorldMapFrame then return end
	WMF = WorldMapFrame
	button = makeButton()
	if WMF.OnMapChanged then hooksecurefunc(WMF, "OnMapChanged", refresh) end
	WMF:HookScript("OnShow", refresh)
	-- keep the line width constant while zooming (only runs while the map is shown)
	ticker = CreateFrame("Frame", nil, WMF)
	local wait = 0
	ticker:SetScript("OnUpdate", function(_, elapsed)
		wait = wait - elapsed
		if wait > 0 or used == 0 then return end
		wait = 0.2
		local s = canvasScale()
		if s ~= lastScale then
			lastScale = s
			local th = WIDTH / s
			for i = 1, used do lines[i]:SetThickness(th) end
		end
	end)
	refresh()
end

function TM:OnEnable()
	if WorldMapFrame then
		pcall(setup)
	else
		RoA:On("ADDON_LOADED", function(_, name)
			if name == "Blizzard_WorldMap" then pcall(setup) end
		end)
	end
end

RoA:Listen("SETTINGS", function(group)
	if group == "map" and WMF then refresh() end
end)
