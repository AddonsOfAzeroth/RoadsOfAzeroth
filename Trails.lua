-- Roads of Azeroth by DinX: learned paths.
-- WoW gives add-ons no data for hills, walls or water, so the arrow points in a
-- straight line. This learns from where you really walk instead: every few yards
-- your position (the same one the coordinates show) is kept as a point, and
-- points you walked between are linked. The data is account wide, so all your
-- characters learn together and use it. When following walked paths is shorter
-- than going straight over unknown ground, the arrow steers along them.
-- Read only: it never moves your character and sends nothing anywhere.
local _, ns = ...
local RoA = ns.RoA
local L = RoA.L

local T = RoA:NewModule("Trails")

local STEP = 10          -- yards between recorded points
local SNAP = 7           -- join an existing point this close
local MAX_LINK = 30      -- longer jumps (teleport, flight, loading) break the trail
local OFF_COST = 1.6     -- unknown ground counts this much longer than a walked path
local NEAR = 80          -- look for paths this far from you and from the target
local DIRECT = 40        -- closer than this: just go straight
local LOOKAHEAD = 20     -- steer to a path point at least this far ahead
local MAX_POINTS = 8000  -- per continent
local CELL = 50          -- grid cell size for finding points nearby
local RECORD_EVERY = 0.5 -- seconds
local ROUTE_EVERY = 1    -- seconds between route searches

local IsSecret = RoA.IsSecret
local sqrt, floor, huge = math.sqrt, math.floor, math.huge

local function enabled()
	return RoA.char and RoA.char.nav and RoA.char.nav.trails ~= false
end

local function store()
	RoA.db.trails = type(RoA.db.trails) == "table" and RoA.db.trails or {}
	return RoA.db.trails
end

-- one continent: { p = { [id] = { north, west, visits } }, l = { [id] = { [id2] = true } }, next = n }
local function continent(cont)
	local s = store()
	local key = tostring(cont)
	local c = s[key]
	if type(c) ~= "table" then
		c = { p = {}, l = {}, next = 1 }
		s[key] = c
	end
	return c
end

local function dist(an, aw, bn, bw)
	local dn, dw = an - bn, aw - bw
	return sqrt(dn * dn + dw * dw)
end

---------------------------------------------------------------------------
-- Grid: points by 50-yard cell, built when first needed
---------------------------------------------------------------------------
local grids = {}

local function cellKey(n, w)
	return floor(n / CELL) .. ":" .. floor(w / CELL)
end

local function grid(cont)
	local key = tostring(cont)
	local g = grids[key]
	if g then return g end
	g = {}
	for id, pt in pairs(continent(cont).p) do
		local k = cellKey(pt[1], pt[2])
		g[k] = g[k] or {}
		g[k][#g[k] + 1] = id
	end
	grids[key] = g
	return g
end

local function addToGrid(cont, id, pt)
	local g = grid(cont)
	local k = cellKey(pt[1], pt[2])
	g[k] = g[k] or {}
	g[k][#g[k] + 1] = id
end

-- calls fn(id, pt, d) for every point within r yards
local function around(cont, n, w, r, fn)
	local c = continent(cont)
	local g = grid(cont)
	local n0, n1 = floor((n - r) / CELL), floor((n + r) / CELL)
	local w0, w1 = floor((w - r) / CELL), floor((w + r) / CELL)
	for a = n0, n1 do
		for b = w0, w1 do
			local list = g[a .. ":" .. b]
			if list then
				for i = 1, #list do
					local id = list[i]
					local pt = c.p[id]
					if pt then
						local d = dist(n, w, pt[1], pt[2])
						if d <= r then fn(id, pt, d) end
					end
				end
			end
		end
	end
end

local function nearest(cont, n, w, r)
	local best, bestD
	around(cont, n, w, r, function(id, _, d)
		if not bestD or d < bestD then best, bestD = id, d end
	end)
	return best, bestD
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------
local prev, prevCont, prevN, prevW

local function breakTrail()
	prev, prevCont, prevN, prevW = nil, nil, nil, nil
end

local function canRecord()
	if not enabled() then return false end
	if IsInInstance and select(1, IsInInstance()) then return false end
	if UnitOnTaxi and UnitOnTaxi("player") then return false end
	if IsFlying and IsFlying() then return false end
	if UnitInVehicle and UnitInVehicle("player") then return false end
	return true
end

local function link(c, a, b)
	c.l[a] = c.l[a] or {}
	c.l[b] = c.l[b] or {}
	c.l[a][b] = true
	c.l[b][a] = true
end

local function record()
	if not canRecord() then return breakTrail() end
	local AR = RoA.Arrow
	if not (AR and AR.PlayerPos) then return breakTrail() end
	local cont, n, w = AR.PlayerPos() -- (no "a and f()": that keeps only the first value)
	if not cont then return breakTrail() end
	if cont ~= prevCont then breakTrail() end
	if prevN and dist(n, w, prevN, prevW) < STEP then return end
	local c = continent(cont)
	local id = nearest(cont, n, w, SNAP)
	if id then
		local pt = c.p[id]
		pt[3] = (pt[3] or 1) + 1
	else
		if c.next > MAX_POINTS * 1.5 then return end -- full: stop growing
		id = c.next
		c.next = id + 1
		local pt = { floor(n + 0.5), floor(w + 0.5), 1 }
		c.p[id] = pt
		addToGrid(cont, id, pt)
	end
	if prev and prev ~= id and prevCont == cont then
		local a = c.p[prev]
		local b = c.p[id]
		if a and b and dist(a[1], a[2], b[1], b[2]) <= MAX_LINK then link(c, prev, id) end
	end
	prev, prevCont, prevN, prevW = id, cont, n, w
end

---------------------------------------------------------------------------
-- Route search (Dijkstra with a small binary heap)
---------------------------------------------------------------------------
local function heapPush(h, id, cost)
	local i = #h + 1
	h[i] = { id, cost }
	while i > 1 do
		local p = floor(i / 2)
		if h[p][2] <= h[i][2] then break end
		h[p], h[i] = h[i], h[p]
		i = p
	end
end

local function heapPop(h)
	local top = h[1]
	if not top then return end
	local last = table.remove(h)
	if #h > 0 then
		h[1] = last
		local i = 1
		while true do
			local l, r, m = i * 2, i * 2 + 1, i
			if h[l] and h[l][2] < h[m][2] then m = l end
			if h[r] and h[r][2] < h[m][2] then m = r end
			if m == i then break end
			h[i], h[m] = h[m], h[i]
			i = m
		end
	end
	return top[1], top[2]
end

-- Best way from (pn, pw) to (tn, tw): a list of point ids, the real length
-- in yards, or nil when going straight is as good.
local function search(cont, pn, pw, tn, tw)
	local straight = dist(pn, pw, tn, tw)
	if straight < DIRECT then return end
	local c = continent(cont)
	local cost, from, real = {}, {}, {}
	local heap = {}
	local any = false
	around(cont, pn, pw, NEAR, function(id, _, d)
		cost[id] = d * OFF_COST
		real[id] = d
		heapPush(heap, id, cost[id])
		any = true
	end)
	if not any then return end
	local goals = {}
	local anyGoal = false
	around(cont, tn, tw, NEAR, function(id, _, d)
		goals[id] = d
		anyGoal = true
	end)
	if not anyGoal then return end

	local limit = straight * OFF_COST
	local best, bestCost, bestReal = nil, limit * 0.95, nil
	local done = {}
	while true do
		local id, k = heapPop(heap)
		if not id or k >= bestCost then break end
		if not done[id] then
			done[id] = true
			local g = goals[id]
			if g then
				local total = k + g * OFF_COST
				if total < bestCost then best, bestCost, bestReal = id, total, real[id] + g end
			end
			local a = c.p[id]
			for nb in pairs(c.l[id] or {}) do
				local b = c.p[nb]
				if b and not done[nb] then
					local step = dist(a[1], a[2], b[1], b[2])
					local nk = k + step
					if not cost[nb] or nk < cost[nb] then
						cost[nb], from[nb], real[nb] = nk, id, real[id] + step
						heapPush(heap, nb, nk)
					end
				end
			end
		end
	end
	if not best then return end
	local path = {}
	local id = best
	while id do
		table.insert(path, 1, id)
		id = from[id]
	end
	return path, bestReal
end

---------------------------------------------------------------------------
-- Steering: where the arrow should point now
---------------------------------------------------------------------------
local cache = { at = 0 }

-- Returns the point to steer to (north, west) and the path length in yards,
-- or nil to go straight to the target.
function T:Steer(cont, pn, pw, tn, tw)
	if not enabled() or not cont then return end
	local now = GetTime()
	local moved = cache.pn and dist(pn, pw, cache.pn, cache.pw) or huge
	local sameTarget = cache.cont == cont and cache.tn == tn and cache.tw == tw
	if not (sameTarget and now - cache.at < ROUTE_EVERY and moved < 5) then
		local ok, path, length = pcall(search, cont, pn, pw, tn, tw)
		if not ok then path = nil end
		cache.cont, cache.tn, cache.tw, cache.pn, cache.pw, cache.at = cont, tn, tw, pn, pw, now
		cache.path, cache.length = path, length
	end
	local path = cache.path
	if not path then return end
	local c = continent(cont)
	-- the path point closest to you, then the first one far enough ahead
	local k, kd = 1, huge
	for i, id in ipairs(path) do
		local pt = c.p[id]
		if pt then
			local d = dist(pn, pw, pt[1], pt[2])
			if d < kd then k, kd = i, d end
		end
	end
	for i = k, #path do
		local pt = c.p[path[i]]
		if pt and dist(pn, pw, pt[1], pt[2]) >= LOOKAHEAD then
			return pt[1], pt[2], cache.length
		end
	end
	-- end of the path: the target is next
end

-- The learned data of one continent (read only), or nil when there is none.
function T:Data(cont)
	local c = store()[tostring(cont)]
	if type(c) == "table" and type(c.p) == "table" and type(c.l) == "table" then return c end
end

function T:Stats()
	local points, conts = 0, 0
	for _, c in pairs(store()) do
		if type(c) == "table" and type(c.p) == "table" then
			conts = conts + 1
			for _ in pairs(c.p) do points = points + 1 end
		end
	end
	return points, conts
end

function T:Clear()
	RoA.db.trails = {}
	wipe(grids)
	breakTrail()
	cache = { at = 0 }
end

function T:OnEnable()
	store()
	local f = CreateFrame("Frame")
	local wait = 0
	f:SetScript("OnUpdate", function(_, elapsed)
		wait = wait - elapsed
		if wait > 0 then return end
		wait = RECORD_EVERY
		local ok, err = pcall(record)
		if not ok and RoA.debug then RoA:Print("trails: " .. tostring(err)) end
	end)
	RoA:On("PLAYER_ENTERING_WORLD", breakTrail)
end
