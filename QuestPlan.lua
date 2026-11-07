-- Roads of Azeroth by DinX: quest route planner
-- Data/logic only: orders the quest log for fast leveling and builds a short
-- route of stops. Display only, it never automates anything.
local _, ns = ...
local RoA = ns.RoA
local Safe = RoA.Safe
local isSecret = RoA.IsSecret

local QP = RoA:NewModule("QuestPlan")

local QL = C_QuestLog

-- Defaults and limits
local RUN_SPEED = 7          -- yd/s on foot
local RUN_SPEED_MAX = 10.5   -- samples above this are capped (mounted)
local KILL_TIME = 25         -- s per kill incl. recovery
local DROP_RATE = 0.5
local TURNIN_TIME = 10       -- s
local CLUSTER_YD = 150
local FAR_YD = 2000
local ROUTE_MAX = 25
local THROTTLE = 2           -- s between recomputes
local MOVE_YD = 50           -- recompute while moving after this many yards
local TRAVEL_UNKNOWN = 120   -- s when the player position is unknown
local TRAVEL_NOPOS = 300     -- s when the stop has no world position
local TRAVEL_CONTINENT = 900 -- s for another continent
local DROP_MAX = 80          -- learned drop rates kept

---------------------------------------------------------------------------
-- Safe helpers
---------------------------------------------------------------------------
local function num(v, default)
	v = Safe(v, nil)
	if type(v) ~= "number" or v ~= v then return default end
	return v
end

local function str(v)
	v = Safe(v, nil)
	if type(v) ~= "string" or v == "" then return nil end
	return v
end

local function flag(v)
	v = Safe(v, nil)
	return v ~= nil and v ~= false and v ~= 0
end

local function try(fn, ...)
	if not fn then return end
	local ok, a, b, c = pcall(fn, ...)
	if ok then return a, b, c end
end

-- Report the first error once, then stay quiet (no error floods).
local reported = false
local function guard(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		if RoA.debug then RoA:Print("QuestPlan:", tostring(err)) end
		if not reported then
			reported = true
			local handler = geterrorhandler and geterrorhandler()
			if handler then pcall(handler, err) end
		end
	end
end

local function now() return GetTime() end

local function learn()
	local t = RoA.char and RoA.char.questLearn
	if type(t) ~= "table" then
		if not RoA.char then return {} end
		t = {}
		RoA.char.questLearn = t
	end
	if type(t.drop) ~= "table" then t.drop = {} end
	return t
end

local function ema(old, sample, alpha)
	if not old then return sample end
	return old + (sample - old) * alpha
end

local function clamp(v, lo, hi)
	if v < lo then return lo elseif v > hi then return hi end
	return v
end

---------------------------------------------------------------------------
-- Map helpers
---------------------------------------------------------------------------
local ZONE = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3

-- Continent and world yards for a map position, or nil.
local function worldPos(mapID, x, y)
	if not (mapID and x and y and C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
	local vec = try(CreateVector2D, x, y)
	if not vec then return end
	local ok, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, mapID, vec)
	if not ok or type(pos) ~= "table" or not pos.GetXY then return end
	local ok2, wx, wy = pcall(pos.GetXY, pos)
	if not ok2 then return end
	cont, wx, wy = num(cont), num(wx), num(wy)
	if not (cont and wx and wy) then return end
	return cont, wx, wy
end

-- mapID, x, y, continent, worldX, worldY (later values nil when unknown, e.g. instances)
local function playerPos()
	if not (C_Map and C_Map.GetBestMapForUnit) then return end
	local m = num(try(C_Map.GetBestMapForUnit, "player"))
	if not m then return end
	local pos = C_Map.GetPlayerMapPosition and try(C_Map.GetPlayerMapPosition, m, "player")
	if type(pos) ~= "table" or not pos.GetXY then return m end
	local ok, x, y = pcall(pos.GetXY, pos)
	if not ok then return m end
	x, y = num(x), num(y)
	if not (x and y) or (x == 0 and y == 0) then return m end
	local c, wx, wy = worldPos(m, x, y)
	return m, x, y, c, wx, wy
end

local mapInfoCache = {}
local function mapInfo(m)
	local info = mapInfoCache[m]
	if info == nil then
		info = C_Map and C_Map.GetMapInfo and try(C_Map.GetMapInfo, m)
		if type(info) ~= "table" then info = false end
		mapInfoCache[m] = info
	end
	return info or nil
end

-- Walks up from dungeon/micro maps to the zone map.
local function zoneOf(m)
	for _ = 1, 6 do
		local info = m and mapInfo(m)
		if not info then return m end
		local t, parent = num(info.mapType), num(info.parentMapID)
		if not t or t <= ZONE or not parent or parent == 0 then return m end
		m = parent
	end
	return m
end

local function dist(c1, x1, y1, c2, x2, y2)
	if not (c1 and c2 and x1 and x2) or c1 ~= c2 then return nil end
	local dx, dy = x1 - x2, y1 - y2
	return math.sqrt(dx * dx + dy * dy)
end

---------------------------------------------------------------------------
-- Learned values
---------------------------------------------------------------------------
local fight = { start = nil, kills = 0, xpKills = 0 }
local pending        -- finished fight waiting for its recovery time
local killsTotal = 0 -- kills by the player this session
local recentXP = {}  -- recent plain kill XP at this level
local itemTrack = {} -- [questID:index] = { have, kills }

local function runSpeed()
	return clamp(num(learn().runSpeed, RUN_SPEED), 3, RUN_SPEED_MAX)
end

local providerRate -- defined below (optional add-on rates)
local function killTime()
	local v = providerRate and providerRate("GetKillTime")
	if v then return clamp(v, 8, 120) end
	return clamp(num(learn().killTime, KILL_TIME), 8, 120)
end

-- "Red Bandana: 3/10" and "3/10 Red Bandana" share the key "red bandana".
local function dropKey(text)
	if not text then return end
	local k = text:gsub("%d+%s*/%s*%d+", ""):gsub("[:%(%)]", ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
	if k == "" then return end
	return k
end

local function dropRate(text)
	local v = providerRate and providerRate("GetDropRate", text)
	if v then return clamp(v, 0.05, 1) end
	local k = dropKey(text)
	local d = k and learn().drop[k]
	return clamp(type(d) == "table" and num(d.r, DROP_RATE) or DROP_RATE, 0.05, 1)
end

local function storeDrop(text, sample)
	local k = dropKey(text)
	if not k then return end
	local drops = learn().drop
	local d = drops[k]
	if type(d) ~= "table" then d = {} drops[k] = d end
	d.r = clamp(ema(num(d.r), sample, 0.3), 0.05, 1)
	d.t = time()
	-- keep it small: drop the oldest entries
	local n = 0
	for _ in pairs(drops) do n = n + 1 end
	if n > DROP_MAX then
		local list = {}
		for key, v in pairs(drops) do list[#list + 1] = { key, type(v) == "table" and num(v.t, 0) or 0 } end
		table.sort(list, function(a, b) return a[2] < b[2] end)
		for i = 1, n - DROP_MAX + 10 do drops[list[i][1]] = nil end
	end
end

-- Classic grey level (same as Leveling.lua).
local function grayLevel(pl)
	if pl <= 5 then return 0 elseif pl <= 39 then return pl - 5 - math.floor(pl / 10) end
	return pl - 1 - math.floor(pl / 5)
end

-- Average XP per kill at the player's level: this session, then measured, then formula.
local function avgKillXP(pl)
	if #recentXP > 0 then
		local s = 0
		for _, v in ipairs(recentXP) do s = s + v end
		return s / #recentXP
	end
	-- mob XP learned by Casters of Azeroth's leveling helper, when it is loaded
	local lv = RoA.char.leveling or (RoA:Casters() and RoA:Casters().char.leveling)
	local mobXP = lv and lv.mobXP
	if type(mobXP) == "table" then
		local suffix = ":" .. pl
		local s, n = 0, 0
		for key, v in pairs(mobXP) do
			if type(key) == "string" and type(v) == "number" and v > 0 and key:sub(-#suffix) == suffix then
				s, n = s + v, n + 1
			end
		end
		if n > 0 then return s / n end
	end
	return pl * 5 + 45
end

local function addKill()
	killsTotal = killsTotal + 1
	if fight.start then fight.kills = fight.kills + 1 end
end

local function finishPending(gap)
	local p = pending
	pending = nil
	if not p then return end
	local kills = p.kills
	if kills <= 0 then return end
	local sample = (p.dur + math.min(gap, 45)) / kills
	local t = learn()
	t.killTime = clamp(ema(num(t.killTime), clamp(sample, 8, 120), 0.2), 8, 120)
end

local function onCombatStart()
	local t = now()
	if pending then finishPending(t - pending.stop) end
	fight.start, fight.kills, fight.xpKills = t, 0, 0
end

local function onCombatEnd()
	if not fight.start then return end
	local t = now()
	local kills = fight.xpKills
	pending = { dur = t - fight.start, kills = kills, stop = t }
	fight.start = nil
	local mine = pending
	C_Timer.After(90, function()
		if pending == mine then guard(finishPending, 10) end
	end)
end

local XP_PATTERN = "dies, you gain (%d+) experience"

local function onXPMessage(msg)
	if isSecret(msg) or type(msg) ~= "string" then return end
	local amount = tonumber(msg:match(XP_PATTERN))
	if not amount then return end
	local bonus = tonumber(msg:match("%+(%d+) exp [Rr]ested bonus")) or tonumber(msg:match("%((%d+) exp [Rr]ested bonus")) or 0
	local plain = amount - bonus
	if plain > 0 then
		recentXP[#recentXP + 1] = plain
		if #recentXP > 10 then table.remove(recentXP, 1) end
	end
	if fight.start then fight.xpKills = fight.xpKills + 1 end
	addKill()
end

-- Run speed from GetUnitSpeed (or position deltas), out of combat on the ground only.
local lastSample
local function sampleSpeed(m, cont, wx, wy)
	if InCombatLockdown() or flag(try(UnitOnTaxi, "player")) or (IsFlying and flag(try(IsFlying))) then
		lastSample = nil
		return
	end
	local speed
	if GetUnitSpeed then speed = num((try(GetUnitSpeed, "player"))) end
	local t = now()
	if not speed and cont and lastSample and lastSample.cont == cont then
		local d = dist(cont, wx, wy, lastSample.cont, lastSample.wx, lastSample.wy)
		local dt = t - lastSample.t
		if d and dt > 0.5 then speed = d / dt end
	end
	lastSample = cont and { cont = cont, wx = wx, wy = wy, t = t } or nil
	if speed and speed > 1 and speed < 60 then
		local l = learn()
		l.runSpeed = clamp(ema(num(l.runSpeed), math.min(speed, RUN_SPEED_MAX), 0.05), 3, RUN_SPEED_MAX)
	end
end

---------------------------------------------------------------------------
-- Quest log reading
---------------------------------------------------------------------------
local function logCount()
	if QL and QL.GetNumQuestLogEntries then return num((try(QL.GetNumQuestLogEntries)), 0) end
	return 0
end

local function rewardXP(questID)
	if not GetQuestLogRewardXP then return nil end
	return num((try(GetQuestLogRewardXP, questID)), nil)
end

local function isElite(questID)
	if QL and QL.GetQuestTagInfo then
		local info = try(QL.GetQuestTagInfo, questID)
		if type(info) == "table" then return flag(info.isElite) end
	end
	return false
end

local function isGrey(level, pl)
	if level <= grayLevel(pl) then return true end
	if GetQuestDifficultyColor and QuestDifficultyColors and QuestDifficultyColors.trivial then
		local c = try(GetQuestDifficultyColor, level)
		if c and c == QuestDifficultyColors.trivial then return true end
	end
	return false
end

local function readyForTurnIn(questID)
	if QL and QL.ReadyForTurnIn and flag(try(QL.ReadyForTurnIn, questID)) then return true end
	if QL and QL.IsComplete and flag(try(QL.IsComplete, questID)) then return true end
	return false
end

-- Reads objectives: kills, work seconds and progress; learns drop rates on the way.
local function readObjectives(q)
	local kills, work, have, need = 0, 0, 0, 0
	local list = QL and QL.GetQuestObjectives and try(QL.GetQuestObjectives, q.questID)
	if type(list) == "table" then
		for idx, o in ipairs(list) do
			if type(o) == "table" then
				local text, kind, done = str(o.text), str(o.type), flag(o.finished)
				local got, req = num(o.numFulfilled), num(o.numRequired)
				if req and req > 0 then
					got = clamp(got or 0, 0, req)
				elseif kind == "progressbar" and GetQuestProgressBarPercent then
					got, req = num((try(GetQuestProgressBarPercent, q.questID)), done and 100 or 0), 100
				else
					got, req = done and 1 or 0, 1
				end
				if done then got = req end
				have, need = have + got / req, need + 1
				local left = req - got

				-- drop rate: item count went up since the last increase
				if kind == "item" and text then
					local key = q.questID .. ":" .. idx
					local tr = itemTrack[key]
					if tr and got > tr.have then
						local since = killsTotal - tr.kills
						if since > 0 and since <= 30 then storeDrop(text, clamp((got - tr.have) / since, 0.05, 1)) end
						tr.have, tr.kills = got, killsTotal
					elseif not tr or got < tr.have then
						itemTrack[key] = { have = got, kills = killsTotal }
					end
				end

				if left > 0 and not done then
					if kind == "monster" then
						kills = kills + left
					elseif kind == "item" then
						kills = kills + left / dropRate(text)
					elseif kind == "object" then
						work = work + left * 15
					elseif kind == "progressbar" then
						kills = kills + math.ceil(left / 10)
					else
						work = work + 60
					end
				end
			end
		end
	end
	q.kills = kills
	q.work = work
	q.progress = need > 0 and have / need or 0
end

---------------------------------------------------------------------------
-- Stops
---------------------------------------------------------------------------
local poiCache = {}

-- questID -> {x, y} for quests with a POI on that map (cached per recompute).
local function poisOn(mapID)
	if not mapID or mapID <= 0 then return {} end
	local c = poiCache[mapID]
	if c then return c end
	c = {}
	local list = QL and QL.GetQuestsOnMap and try(QL.GetQuestsOnMap, mapID)
	if type(list) == "table" then
		for _, info in ipairs(list) do
			if type(info) == "table" then
				local id, x, y = num(info.questID), num(info.x), num(info.y)
				if id and x and y then c[id] = { x = x, y = y } end
			end
		end
	end
	poiCache[mapID] = c
	return c
end

local function waypoint(questID)
	if not (QL and QL.GetNextWaypoint) then return end
	local m, x, y = try(QL.GetNextWaypoint, questID)
	m, x, y = num(m), num(x), num(y)
	if m and m > 0 and x and y then return { mapID = m, x = x, y = y } end
end

local function poiStop(questID, maps)
	for _, m in ipairs(maps) do
		local p = poisOn(m)[questID]
		if p then return { mapID = m, x = p.x, y = p.y } end
	end
	local qm = GetQuestUiMapID and num((try(GetQuestUiMapID, questID, true)))
	if qm and qm > 0 then
		local p = poisOn(qm)[questID]
		if p then return { mapID = qm, x = p.x, y = p.y } end
	end
end

local function findStop(q, maps)
	if q.turnIn then
		return waypoint(q.questID) or poiStop(q.questID, maps)
	end
	return poiStop(q.questID, maps) or waypoint(q.questID)
end

---------------------------------------------------------------------------
-- Route: clusters, greedy, then 2-opt on value-weighted finish time
---------------------------------------------------------------------------
local function travelTime(a, b, speed)
	-- a may be the player (nil fields when unknown)
	if not b.cont then return TRAVEL_NOPOS end
	if not a or not a.cont then return TRAVEL_UNKNOWN end
	if a.cont ~= b.cont then return TRAVEL_CONTINENT end
	return dist(a.cont, a.wx, a.wy, b.cont, b.wx, b.wy) / speed
end

-- Sum of value * finish time over the order (lower = XP arrives sooner).
local function orderCost(order, start, speed)
	local t, cost, prev = 0, 0, start
	for _, n in ipairs(order) do
		t = t + travelTime(prev, n, speed) + n.work
		cost = cost + n.value * t
		prev = n
	end
	return cost
end

local function twoOpt(order, start, speed)
	local n = #order
	if n < 3 then return order end
	local best = orderCost(order, start, speed)
	for _ = 1, 3 do
		local improved = false
		for i = 1, n - 1 do
			for j = i + 1, n do
				-- reverse order[i..j]
				local a, b = i, j
				while a < b do order[a], order[b] = order[b], order[a]; a, b = a + 1, b - 1 end
				local c = orderCost(order, start, speed)
				if c < best * 0.999 then
					best, improved = c, true
				else
					a, b = i, j
					while a < b do order[a], order[b] = order[b], order[a]; a, b = a + 1, b - 1 end
				end
			end
		end
		if not improved then break end
	end
	return order
end

local function buildNodes(quests)
	local nodes, noStop = {}, {}
	for _, q in ipairs(quests) do
		if not q.skip then
			local placed
			if q.stop and q.cont then
				for _, n in ipairs(nodes) do
					if n.cont == q.cont and dist(n.cont, n.wx, n.wy, q.cont, q.wx, q.wy) <= CLUSTER_YD then
						placed = n
						break
					end
				end
			end
			if placed then
				placed.quests[#placed.quests + 1] = q
				placed.value = placed.value + q.value
				placed.work = placed.work + q.taskWork
				placed.turnIn = placed.turnIn or q.turnIn
			else
				local n = { quests = { q }, value = q.value, work = q.taskWork, turnIn = q.turnIn,
					stop = q.stop, cont = q.cont, wx = q.wx, wy = q.wy }
				if q.stop then nodes[#nodes + 1] = n else noStop[#noStop + 1] = n end
			end
		end
	end
	return nodes, noStop
end

-- The stop we are heading to stays first unless another one is clearly better,
-- so the route doesn't flip between quests while you walk around.
local STICKY = 1.5
local heading -- { id = questID, turnIn = bool } of the current first stop

local function holds(n, h)
	for _, q in ipairs(n.quests) do
		if q.questID == h.id and (q.turnIn and true or false) == h.turnIn then return true end
	end
end

-- Locked route: the stop order is saved as quest keys ("id:t" turn-in, "id:o"
-- objectives) and reused on every recompute until the player recalculates.
local function qkey(q) return q.questID .. (q.turnIn and ":t" or ":o") end

local function routeLocked()
	local c = RoA.char and RoA.char.quests
	return c and c.lockRoute ~= false
end

local function freeze(order)
	local keys = {}
	for _, n in ipairs(order) do
		for _, q in ipairs(n.quests) do keys[#keys + 1] = qkey(q) end
	end
	RoA.char.quests.frozenRoute = keys
end

-- Nodes in the saved order; stops that are new since then go last, in planned order.
local function applyFrozen(order, keys)
	local pos = {}
	for i, k in ipairs(keys) do pos[k] = pos[k] or i end
	local big = #keys + 1
	local rank = {}
	for i, n in ipairs(order) do
		local best
		for _, q in ipairs(n.quests) do
			local p = pos[qkey(q)]
			if p and (not best or p < best) then best = p end
		end
		rank[n] = best or (big + i)
	end
	table.sort(order, function(a, b) return rank[a] < rank[b] end)
	return order
end

-- Route strategies (button in the tracker header):
--   balanced  best XP per minute, turn-ins and objectives mixed (default)
--   turnin    hand in everything that is ready first, then quest on
--   quest     work on objectives first, hand in at the end
--   nearest   always the closest stop
-- Optional add-on priority (RoA.EpicProvider.GetPriority: 1 highest .. 5 lowest)
-- nudges a quest's routing value a little; nothing changes without the add-on.
local PRIORITY_WEIGHT = { 1.15, 1.07, 1, 0.95, 0.9 }
local function providerOnHold(questID)
	local p = RoA.EpicProvider
	local fn = type(p) == "table" and p.IsOnHold
	if type(fn) ~= "function" then return false end
	local ok, v = pcall(fn, p, questID)
	return ok and v == true
end
-- learned rates from the add-on (nil until it has enough samples)
function providerRate(name, ...)
	local p = RoA.EpicProvider
	local fn = type(p) == "table" and p[name]
	if type(fn) ~= "function" then return end
	local ok, v = pcall(fn, p, ...)
	return ok and num(v) or nil
end
local function priorityWeight(questID)
	local p = RoA.EpicProvider
	local fn = type(p) == "table" and p.GetPriority
	if type(fn) ~= "function" then return end
	local ok, pr = pcall(fn, p, questID)
	pr = ok and num(pr) or nil
	return pr and PRIORITY_WEIGHT[pr]
end

local STRATEGIES = { "balanced", "turnin", "quest", "nearest" }
QP.STRATEGIES = STRATEGIES

local function strategy()
	local c = RoA.char and RoA.char.quests
	local s = c and c.routeStrategy
	for _, k in ipairs(STRATEGIES) do if k == s then return s end end
	return "balanced"
end

local function hasTurnIn(n)
	for _, q in ipairs(n.quests) do if q.turnIn then return true end end
end

local function hasObjective(n)
	for _, q in ipairs(n.quests) do if not q.turnIn then return true end end
end

-- greedy from cur over nodes; returns the order and the last node
local function greedy(nodes, cur, speed, nearest)
	local order, left = {}, nodes
	while #left > 0 do
		local bi, bs
		for i, n in ipairs(left) do
			local t = travelTime(cur, n, speed)
			local s = nearest and 1 / (t + 1) or n.value / (t + n.work + 5)
			if not bs or s > bs then bi, bs = i, s end
		end
		local n = table.remove(left, bi)
		order[#order + 1] = n
		cur = n
	end
	return order, cur
end

local function planRoute(quests, start, speed)
	local nodes, noStop = buildNodes(quests)
	local mode = strategy()
	local order
	if mode == "turnin" or mode == "quest" then
		-- two groups, each planned on its own; the second starts where the first ends
		local first, second = {}, {}
		for _, n in ipairs(nodes) do
			local early = (mode == "turnin") and hasTurnIn(n) or (mode == "quest" and hasObjective(n))
			if early then first[#first + 1] = n else second[#second + 1] = n end
		end
		local a, last = greedy(first, start, speed)
		twoOpt(a, start, speed)
		last = a[#a] or start
		local b = greedy(second, last, speed)
		twoOpt(b, last, speed)
		order = a
		for _, n in ipairs(b) do order[#order + 1] = n end
	else
		order = greedy(nodes, start, speed, mode == "nearest")
		if mode ~= "nearest" then twoOpt(order, start, speed) end
	end
	if heading and #order > 1 and not holds(order[1], heading) then
		for i = 2, #order do
			if holds(order[i], heading) then
				local function score(n) return n.value / (travelTime(start, n, speed) + n.work + 5) end
				if score(order[1]) < score(order[i]) * STICKY then
					table.insert(order, 1, table.remove(order, i))
				end
				break
			end
		end
	end
	local first = order[1] and order[1].quests[1]
	heading = first and { id = first.questID, turnIn = first.turnIn and true or false } or nil
	-- quests without a stop: by value per work second
	table.sort(noStop, function(a, b)
		return a.value / (a.work + TRAVEL_UNKNOWN) > b.value / (b.work + TRAVEL_UNKNOWN)
	end)
	return order, noStop
end

---------------------------------------------------------------------------
-- Recompute
---------------------------------------------------------------------------
local quests = {}     -- current quest records
local smartOrder = {} -- quest records in "smart" order
local route = {}
local modeCache = {}
local signature
local lastPlan = { t = 0 }
local computed = false

local sorters = {
	distance = function(a, b)
		if (a.distance ~= nil) ~= (b.distance ~= nil) then return a.distance ~= nil end
		if a.distance and a.distance ~= b.distance then return a.distance < b.distance end
		return a.smartRank < b.smartRank
	end,
	xp = function(a, b)
		if (a.xp ~= nil) ~= (b.xp ~= nil) then return a.xp ~= nil end
		if a.xp and a.xp ~= b.xp then return a.xp > b.xp end
		return a.smartRank < b.smartRank
	end,
	xpmin = function(a, b)
		if (a.xpPerHour ~= nil) ~= (b.xpPerHour ~= nil) then return a.xpPerHour ~= nil end
		if a.xpPerHour and a.xpPerHour ~= b.xpPerHour then return a.xpPerHour > b.xpPerHour end
		return a.smartRank < b.smartRank
	end,
	level = function(a, b)
		if a.level ~= b.level then return a.level < b.level end
		return a.smartRank < b.smartRank
	end,
	progress = function(a, b)
		if a.turnIn ~= b.turnIn then return a.turnIn end
		if a.progress ~= b.progress then return a.progress > b.progress end
		return a.smartRank < b.smartRank
	end,
	zone = function(a, b)
		if a.zoneMatch ~= b.zoneMatch then return a.zoneMatch end
		if (a.distance ~= nil) ~= (b.distance ~= nil) then return a.distance ~= nil end
		if a.distance and a.distance ~= b.distance then return a.distance < b.distance end
		return a.smartRank < b.smartRank
	end,
}

function QP:Recompute()
	wipe(poiCache)
	wipe(modeCache)
	local pl = num(UnitLevel("player"), 1)
	local m, _, _, pc, pwx, pwy = playerPos()
	local playerZone = m and zoneOf(m)
	local solo = not (IsInGroup and flag(try(IsInGroup)))
	local speed, kt, kxp = runSpeed(), killTime(), avgKillXP(pl)
	local start = pc and { cont = pc, wx = pwx, wy = pwy } or nil
	lastPlan.t, lastPlan.cont, lastPlan.wx, lastPlan.wy, lastPlan.map = now(), pc, pwx, pwy, m

	-- maps to look for objective POIs: the player's map and its zone
	local maps = {}
	if m then
		maps[1] = m
		if playerZone and playerZone ~= m then maps[2] = playerZone end
	end

	wipe(quests)
	local count = math.min(logCount(), 60)
	for i = 1, count do
		local info = QL and QL.GetInfo and try(QL.GetInfo, i)
		if type(info) == "table" and not flag(info.isHeader) and not flag(info.isHidden) and not flag(info.isBounty) then
			local id, title = num(info.questID), str(info.title)
			if id and title and #quests < 25 then
				local level = num(info.difficultyLevel, 0)
				if level <= 0 then level = num(info.level, 0) end
				if level <= 0 then level = pl end
				local q = { questID = id, title = title, level = level, group = num(info.suggestedGroup, 0) }
				q.turnIn = readyForTurnIn(id)
				readObjectives(q)
				if q.turnIn then q.kills, q.work, q.progress = 0, 0, 1 end

				-- stop and distance
				q.stop = findStop(q, maps)
				if q.stop then
					q.cont, q.wx, q.wy = worldPos(q.stop.mapID, q.stop.x, q.stop.y)
					q.distance = start and dist(pc, pwx, pwy, q.cont, q.wx, q.wy) or nil
					q.zoneMatch = playerZone ~= nil and zoneOf(q.stop.mapID) == playerZone
				else
					q.zoneMatch = false
				end

				-- value
				local reward = rewardXP(id)
				local killXP = q.kills * kxp
				if reward or killXP > 0 then q.xp = math.floor((reward or 0) + killXP + 0.5) end
				q.taskWork = q.kills * kt + q.work + (q.turnIn and TURNIN_TIME or 0)

				-- time
				if q.distance then
					local secs = q.distance / speed + q.taskWork + (q.turnIn and 0 or TURNIN_TIME)
					q.minutes = math.max(0.1, secs / 60)
					if q.xp then q.xpPerHour = math.floor(q.xp / (q.minutes / 60) + 0.5) end
				end

				-- skip suggestions (ready turn-ins only get "far")
				local farAway = start and q.cont and (q.cont ~= pc or (q.distance and q.distance > FAR_YD))
				if not q.turnIn then
					if isGrey(level, pl) then
						q.skip = "grey"
					elseif solo and (q.group > 1 or isElite(id)) then
						q.skip = "elite"
					elseif level >= pl + 3 then
						q.skip = "red"
					end
				end
				if not q.skip and farAway then q.skip = "far" end
				-- an add-on can put a quest on hold: it leaves the route like a skipped one
				if providerOnHold(id) then q.skip = "hold" end

				-- routing value: objectives add a 20% bonus as they make the quest ready
				local v = (q.xp or 0)
				if not q.turnIn then v = v * 1.2 end
				if level >= pl + 3 then v = v * 0.6 end
				q.value = math.max(1, v)
				local pw = priorityWeight(id)
				if pw then q.value = q.value * pw end
				quests[#quests + 1] = q
			end
		end
	end

	-- "smart": routed nodes, then quests without a stop, then skipped ones
	local order, noStop = planRoute(quests, start, speed)
	if routeLocked() then
		local keys = RoA.char.quests.frozenRoute
		if type(keys) == "table" and #keys > 0 and not self.recalculating then
			applyFrozen(order, keys)
		else
			freeze(order)
		end
	end
	self.recalculating = nil
	wipe(smartOrder)
	wipe(route)
	local function addNode(n, toRoute)
		table.sort(n.quests, function(a, b) return a.value > b.value end)
		local ids = {}
		for _, q in ipairs(n.quests) do
			smartOrder[#smartOrder + 1] = q
			ids[#ids + 1] = q.questID
		end
		if toRoute and #route < ROUTE_MAX then
			route[#route + 1] = { mapID = n.stop.mapID, x = n.stop.x, y = n.stop.y, questIDs = ids,
				rank = #route + 1, turnIn = n.turnIn and true or false }
		end
	end
	for _, n in ipairs(order) do addNode(n, true) end
	for _, n in ipairs(noStop) do addNode(n, false) end
	local skipped = {}
	for _, q in ipairs(quests) do
		if q.skip then skipped[#skipped + 1] = q end
	end
	table.sort(skipped, function(a, b)
		return a.value / (a.taskWork + TRAVEL_UNKNOWN) > b.value / (b.taskWork + TRAVEL_UNKNOWN)
	end)
	for _, q in ipairs(skipped) do smartOrder[#smartOrder + 1] = q end
	for i, q in ipairs(smartOrder) do q.smartRank = i end
	computed = true

	-- tell listeners when the plan changed
	local parts = {}
	for _, q in ipairs(smartOrder) do
		parts[#parts + 1] = ("%d:%s:%s:%s:%d"):format(q.questID, q.turnIn and 1 or 0, q.skip or "",
			q.xp or -1, q.distance and math.floor(q.distance / 50) or -1)
	end
	local sig = table.concat(parts, ",")
	if sig ~= signature then
		signature = sig
		RoA:Fire("QUESTPLAN")
	end
end

-- Throttled request: at most one recompute every THROTTLE seconds.
local scheduled = false
function QP:Request()
	if scheduled then return end
	scheduled = true
	local wait = math.max(0, lastPlan.t + THROTTLE - now())
	C_Timer.After(wait, function()
		scheduled = false
		guard(QP.Recompute, QP)
	end)
end

-- Plan a fresh route from where you stand now and keep it (button in the tracker).
function QP:Recalculate()
	heading = nil
	self.recalculating = true
	guard(QP.Recompute, QP)
	RoA:Fire("QUESTPLAN_RECALC") -- e.g. an add-on starting a new sprint
end

-- Saved stop order of the locked route (quest keys "id:t" / "id:o"), as a copy; nil when none.
function QP:GetFrozenRoute()
	local keys = RoA.char and RoA.char.quests and RoA.char.quests.frozenRoute
	if type(keys) ~= "table" then return nil end
	local out = {}
	for i, k in ipairs(keys) do out[i] = k end
	return out
end

-- Replace the saved stop order (sprint planning in an add-on) and plan again.
-- An empty list makes the next recompute freeze the whole route again.
function QP:SetFrozenRoute(keys)
	if not (RoA.char and RoA.char.quests and type(keys) == "table") then return end
	local out = {}
	for _, k in ipairs(keys) do
		if type(k) == "string" then out[#out + 1] = k end
	end
	RoA.char.quests.frozenRoute = out
	guard(QP.Recompute, QP)
end

function QP:IsLocked() return routeLocked() end

function QP:Strategy() return strategy() end

function QP:SetStrategy(key)
	RoA.char.quests.routeStrategy = key
	self:Recalculate()
end

local function ensure()
	if not computed and RoA.char then guard(QP.Recompute, QP) end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
local FIELDS = { "questID", "title", "level", "xp", "minutes", "xpPerHour", "distance", "zoneMatch", "turnIn", "skip" }

local function export(q, rank)
	local e = { rank = rank }
	for _, k in ipairs(FIELDS) do e[k] = q[k] end
	e.zoneMatch = e.zoneMatch and true or false
	e.turnIn = e.turnIn and true or false
	if q.stop then e.stop = { mapID = q.stop.mapID, x = q.stop.x, y = q.stop.y } end
	return e
end

-- Entries for every quest in the log, ordered for the mode.
function QP:Get(mode)
	ensure()
	mode = mode or (RoA.char and RoA.char.quests and RoA.char.quests.sortMode) or "smart"
	if mode ~= "smart" and not sorters[mode] then mode = "smart" end
	local cached = modeCache[mode]
	if cached then return cached end
	local list = {}
	for i, q in ipairs(smartOrder) do list[i] = q end
	if mode ~= "smart" then table.sort(list, sorters[mode]) end
	local out = {}
	for i, q in ipairs(list) do out[i] = export(q, i) end
	modeCache[mode] = out
	return out
end

-- The "smart" route as clustered stops (at most ROUTE_MAX).
function QP:GetRoute()
	ensure()
	local out = {}
	for i, r in ipairs(route) do
		local ids = {}
		for j, id in ipairs(r.questIDs) do ids[j] = id end
		out[i] = { mapID = r.mapID, x = r.x, y = r.y, questIDs = ids, rank = r.rank, turnIn = r.turnIn }
	end
	return out
end

function QP:NextStop()
	return self:GetRoute()[1]
end

-- Localized reason for a skip code.
function QP:SkipText(code)
	local Lc = RoA.L
	if code == "grey" then return Lc["Low level, little XP"]
	elseif code == "elite" then return Lc["Group quest"]
	elseif code == "red" then return Lc["Level too high"]
	elseif code == "far" then return Lc["Far away"] end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local function request() QP:Request() end

-- Every second: learn run speed; every 3 s replan when moved > 50 yd.
local ticks = 0
local function tick()
	if not RoA.char then return end
	local m, _, _, c, wx, wy = playerPos()
	sampleSpeed(m, c, wx, wy)
	ticks = ticks + 1
	if ticks % 3 ~= 0 then return end
	if m ~= lastPlan.map then return request() end
	local d = dist(c, wx, wy, lastPlan.cont, lastPlan.wx, lastPlan.wy)
	if (d and d > MOVE_YD) or (c and c ~= lastPlan.cont) then request() end
end

function QP:OnEnable()
	learn()
	for _, ev in ipairs({ "QUEST_LOG_UPDATE", "QUEST_WATCH_LIST_CHANGED", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD" }) do
		RoA:On(ev, function() guard(request) end)
	end
	RoA:On("PLAYER_LEVEL_UP", function()
		wipe(recentXP)
		guard(request)
	end)
	RoA:On("PLAYER_REGEN_DISABLED", function() guard(onCombatStart) end)
	RoA:On("PLAYER_REGEN_ENABLED", function() guard(onCombatEnd) end)
	RoA:On("CHAT_MSG_COMBAT_XP_GAIN", function(_, msg) guard(onXPMessage, msg) end)

	-- no combat log: registering COMBAT_LOG_EVENT_UNFILTERED is forbidden for
	-- addons in this client; kills are counted from the XP messages instead

	C_Timer.NewTicker(1, function() guard(tick) end)
	guard(request)
end
