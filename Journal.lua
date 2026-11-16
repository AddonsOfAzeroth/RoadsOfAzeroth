-- Roads of Azeroth by DinX: travel journal.
-- Keeps a compact log of where each of your characters went, so an outside
-- tool can draw maps, heatmaps, a replay and the time spent per zone.
-- Read only: it only reads your own position and state, never moves anything
-- and sends nothing anywhere. Hidden (secret) values are skipped, not saved.
--
-- RoadsOfAzerothDB.journal = { version = 1,
--   chars = { [playerGUID] = { name, class, pts = { "t,m,x,y,w,wy,wx,f", ... } } },
--   maps  = { [uiMapID] = { n = name, p = parent, k = mapType, w = continent,
--                           r = { y1, x1, y2, x2 } } } }
-- t = time(), m = uiMapID, x/y = map position 0..1 (empty when the map has none),
-- w = continent or instance id, wy/wx = world yards (UnitPosition order),
-- f = flags: t taxi, m mounted, c combat, d dead or ghost, s swimming,
-- g gap (first point after a load screen, teleport or a jump: no line to it).
local _, ns = ...
local RoA = ns.RoA

local J = RoA:NewModule("Journal")

local VERSION = 1
local TICK = 0.5        -- seconds between checks
local EVERY = 2         -- seconds between points while moving
local MOVE = 4          -- yards moved before a new point
local MOVE_FAST = 30    -- yards moved: a point now (fast travel stays connected)
local JUMP = 40         -- longer jumps between points start a new line
local MAX_POINTS = 60000 -- per character
local DROP = 1000       -- oldest points dropped at once when full
local MAX_PARENTS = 10

local IsSecret = RoA.IsSecret
local floor, sqrt, fmt = math.floor, math.sqrt, string.format

local function enabled()
	return RoA.char and RoA.char.journal and RoA.char.journal.enabled ~= false
end

-- A plain number, or nil when missing or secret.
local function num(v)
	if v == nil or IsSecret(v) or type(v) ~= "number" then return nil end
	return v
end

-- true/false, or nil when the call fails or the answer is hidden.
local function ask(fn, ...)
	if not fn then return false end
	local ok, v = pcall(fn, ...)
	if not ok or IsSecret(v) then return nil end
	return v and true or false
end

local function round1(v) return floor(v * 10 + 0.5) / 10 end

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------
local function store()
	local j = RoA.db.journal
	if type(j) ~= "table" then
		j = {}
		RoA.db.journal = j
	end
	j.version = VERSION
	if type(j.chars) ~= "table" then j.chars = {} end
	if type(j.maps) ~= "table" then j.maps = {} end
	return j
end

local me -- this character's entry

local function charEntry()
	if me then return me end
	local guid = UnitGUID and UnitGUID("player")
	if type(guid) ~= "string" or IsSecret(guid) then return end
	local chars = store().chars
	local c = chars[guid]
	if type(c) ~= "table" then
		c = {}
		chars[guid] = c
	end
	if type(c.pts) ~= "table" then c.pts = {} end
	local name = UnitName and UnitName("player")
	if type(name) == "string" and not IsSecret(name) then c.name = name end
	local class
	if UnitClass then _, class = UnitClass("player") end
	if type(class) == "string" and not IsSecret(class) then c.class = class end
	me = c
	return c
end

local function addPoint(s)
	local c = charEntry()
	if not c then return end
	local pts = c.pts
	local n = #pts
	if n >= MAX_POINTS then -- full: drop the oldest in one go
		local drop = n - MAX_POINTS + DROP
		for i = 1, n - drop do pts[i] = pts[i + drop] end
		for i = n - drop + 1, n do pts[i] = nil end
		n = n - drop
	end
	pts[n + 1] = s
end

---------------------------------------------------------------------------
-- Positions
---------------------------------------------------------------------------
local function worldPosRaw(mapID, x, y)
	local cont, pos = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(x, y))
	if not pos or IsSecret(pos) then return end
	local a, b = pos:GetXY()
	cont, a, b = num(cont), num(a), num(b)
	if cont and a and b then return cont, a, b end
end

local function worldPos(mapID, x, y)
	if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
	local ok, cont, a, b = pcall(worldPosRaw, mapID, x, y)
	if ok and cont then return cont, a, b end
end

-- uiMapID, map x and y (nil when the map has none), continent, world y and x.
local function readPosRaw()
	if not (C_Map and C_Map.GetBestMapForUnit) then return end
	local m = num(C_Map.GetBestMapForUnit("player"))
	if not m then return end
	local x, y
	local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(m, "player")
	if pos and not IsSecret(pos) then
		x, y = pos:GetXY()
		x, y = num(x), num(y)
		if not (x and y) or (x == 0 and y == 0) then x, y = nil, nil end
	end
	local w, wy, wx
	if x then w, wy, wx = worldPos(m, x, y) end
	if not w and UnitPosition then -- no map position (dungeons): raw world position
		local ok, a, b, _, inst = pcall(UnitPosition, "player")
		if ok then
			a, b, inst = num(a), num(b), num(inst)
			if a and b and inst then w, wy, wx = inst, a, b end
		end
	end
	if not w then return end
	return m, x, y, w, wy, wx
end

local function readPos()
	local ok, m, x, y, w, wy, wx = pcall(readPosRaw)
	if ok and m then return m, x, y, w, wy, wx end
end

---------------------------------------------------------------------------
-- Maps: name, parent, type and world corners, for every map visited
---------------------------------------------------------------------------
local CONTINENT = Enum and Enum.UIMapType and Enum.UIMapType.Continent or 2

local function noteMap(mapID)
	if not (C_Map and C_Map.GetMapInfo) then return end
	local maps = store().maps
	for _ = 1, MAX_PARENTS do
		if not mapID or mapID <= 0 or maps[mapID] then return end
		local ok, info = pcall(C_Map.GetMapInfo, mapID)
		if not ok or type(info) ~= "table" then return end
		local e = {
			n = type(info.name) == "string" and not IsSecret(info.name) and info.name or nil,
			p = num(info.parentMapID),
			k = num(info.mapType),
		}
		local w1, y1, x1 = worldPos(mapID, 0, 0)
		local w2, y2, x2 = worldPos(mapID, 1, 1)
		if w1 and w2 and w1 == w2 then
			e.w = w1
			e.r = { round1(y1), round1(x1), round1(y2), round1(x2) }
		end
		maps[mapID] = e
		if e.k and e.k <= CONTINENT then return end -- continent reached
		mapID = e.p
	end
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------
local lastT, lastM, lastW, lastY, lastX, lastF, lastTaxi
local gap = true    -- next point starts a new line
local forced = false -- next readable sample is saved (death)
local flagState = { t = false, m = false, c = false, d = false, s = false }

-- The flags string; a hidden answer keeps the last known state.
local function readFlags()
	local v
	v = ask(UnitOnTaxi, "player") if v ~= nil then flagState.t = v end
	v = ask(IsMounted) if v ~= nil then flagState.m = v end
	v = ask(UnitAffectingCombat, "player") if v ~= nil then flagState.c = v end
	v = ask(UnitIsDeadOrGhost, "player") if v ~= nil then flagState.d = v end
	v = ask(IsSwimming) if v ~= nil then flagState.s = v end
	return (flagState.t and "t" or "") .. (flagState.m and "m" or "")
		.. (flagState.c and "c" or "") .. (flagState.d and "d" or "")
		.. (flagState.s and "s" or "")
end

local function sample()
	if not enabled() then
		gap = true
		return
	end
	local m, x, y, w, wy, wx = readPos()
	if not m then return end -- hidden or unknown: skip, try again next tick
	local flags = readFlags()
	local now = GetTime()
	local taxi = flagState.t
	local d
	if lastW == w then
		local dy, dx = wy - lastY, wx - lastX
		d = sqrt(dy * dy + dx * dx)
	end
	local due = forced or gap or not d or m ~= lastM or flags ~= lastF
		or d >= MOVE_FAST or (d >= MOVE and now - lastT >= EVERY)
	if not due then return end
	if not d or (d > JUMP and not (taxi or lastTaxi)) then gap = true end
	local f = gap and flags .. "g" or flags
	local xs = x and fmt("%.4f", x) or ""
	local ys = y and fmt("%.4f", y) or ""
	addPoint(fmt("%d,%d,%s,%s,%d,%.1f,%.1f,%s", time(), m, xs, ys, floor(w), wy, wx, f))
	noteMap(m)
	lastT, lastM, lastW, lastY, lastX, lastF, lastTaxi = now, m, w, wy, wx, flags, taxi
	gap, forced = false, false
end

local function safeSample()
	local ok, err = pcall(sample)
	if not ok and RoA.debug then RoA:Print("journal: " .. tostring(err)) end
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------
-- Points and characters in the journal.
function J:Stats()
	local points, chars = 0, 0
	for _, c in pairs(store().chars) do
		if type(c) == "table" and type(c.pts) == "table" then
			chars = chars + 1
			points = points + #c.pts
		end
	end
	return points, chars
end

function J:OnEnable()
	store()
	charEntry()
	local f = CreateFrame("Frame")
	local wait = 0
	f:SetScript("OnUpdate", function(_, elapsed)
		wait = wait - elapsed
		if wait > 0 then return end
		wait = TICK
		safeSample()
	end)
	RoA:On("PLAYER_ENTERING_WORLD", function() gap = true end)
	RoA:On("PLAYER_DEAD", function()
		forced = true
		safeSample()
	end)
end
