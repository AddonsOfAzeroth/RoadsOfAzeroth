-- Roads of Azeroth by DinX: quests to pick up near you. A small, folded line
-- under the quest list ("Pick up (3)"); open it for the nearest quests you
-- don't have yet, click one to make it a GPS stop. Sources: the quest lines
-- Blizzard shows on the map, and Questie's list of available quests when
-- Questie is loaded. Display and a GPS stop only: nothing is accepted for you.
local _, ns = ...
local RoA = ns.RoA
local L = RoA.L
local S = RoA.Style
local Safe = RoA.Safe

local P = RoA:NewModule("Pickup")

local MAX_ROWS, ROW_H = 6, 16

local function num(v) v = Safe(v, nil) return type(v) == "number" and v or nil end

-- yards between you and a spot on a map (world positions are in yards)
local function world(mapID, x, y)
	if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
	local ok, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(x, y))
	if not ok or type(pos) ~= "table" or not pos.GetXY then return end
	local wx, wy = pos:GetXY()
	return cont, wx, wy
end

local function playerWorld()
	local m = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	m = num(m)
	if not m then return end
	local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(m, "player")
	if not pos then return end
	local ok, x, y = pcall(pos.GetXY, pos)
	if not ok or not num(x) then return end
	return m, world(m, x, y)
end

local function haveQuest(id)
	if C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
		local i = C_QuestLog.GetLogIndexForQuestID(id)
		if i and i > 0 then return true end
	end
	if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(id) then return true end
end

local function questLevel(id)
	if C_QuestLog and C_QuestLog.GetQuestDifficultyLevel then
		local ok, lv = pcall(C_QuestLog.GetQuestDifficultyLevel, id)
		lv = ok and num(lv)
		if lv and lv > 0 then return lv end
	end
end

-- where Questie says a quest's giver stands, nearest spawn on your continent
-- (Questie spots are 0..100 on its zone ids; cached, they don't move)
local giverCache = {}
function P:GiverSpot(id, DB, mod, pc, pwx, pwy)
	local cached = giverCache[id]
	if cached == false then return end
	if not cached then
		cached = {}
		local ZDB = mod("ZoneDB")
		local okS, by = pcall(DB.QueryQuestSingle, id, "startedBy")
		local npcs = okS and type(by) == "table" and by[1]
		if type(npcs) == "table" and DB.QueryNPCSingle and ZDB and ZDB.GetUiMapIdByAreaId then
			for k, v in pairs(npcs) do
				local npc = type(v) == "number" and v or k
				local okP, spawns = pcall(DB.QueryNPCSingle, npc, "spawns")
				if okP and type(spawns) == "table" then
					for area, list in pairs(spawns) do
						local okM, map = pcall(ZDB.GetUiMapIdByAreaId, ZDB, area)
						if okM and map and type(list) == "table" then
							for _, xy in ipairs(list) do
								if type(xy) == "table" and xy[1] and xy[2] then
									local x, y = xy[1] / 100, xy[2] / 100
									local c, wx, wy = world(map, x, y)
									if c and wx then cached[#cached + 1] = { map, x, y, c, wx, wy, npc } end
								end
							end
						end
					end
				end
			end
		end
		if #cached == 0 then giverCache[id] = false return end
		giverCache[id] = cached
	end
	local best, bestD
	for _, sp in ipairs(cached) do
		if sp[4] == pc then
			local d = (sp[5] - pwx) ^ 2 + (sp[6] - pwy) ^ 2
			if not bestD or d < bestD then best, bestD = sp, d end
		end
	end
	return best
end

local adviceCache = {}
-- what Questie knows about a quest you don't have: XP, chain, objectives
function P:Advice(e, DB, mod)
	local QX = mod("QuestXP")
	if QX and QX.GetQuestLogRewardXP then
		local ok, xp = pcall(QX.GetQuestLogRewardXP, QX, e.id)
		if ok and num(xp) and xp > 0 then e.xp = xp end
	end
	-- chain and objective don't change: worked out once per quest
	local known = adviceCache[e.id]
	if known then e.chain, e.objective = known.chain, known.objective return end
	-- the chain this quest starts (follow nextQuestInChain, at most 10)
	local steps, id = 0, e.id
	for _ = 1, 10 do
		local ok, nxt = pcall(DB.QueryQuestSingle, id, "nextQuestInChain")
		nxt = ok and num(nxt)
		if not nxt or nxt == 0 then break end
		steps, id = steps + 1, nxt
	end
	e.chain = steps > 0 and steps or nil
	local okO, obj = pcall(DB.QueryQuestSingle, e.id, "objectivesText")
	if okO and type(obj) == "table" and type(obj[1]) == "string" then e.objective = obj[1] end
	adviceCache[e.id] = { chain = e.chain, objective = e.objective }
end

-- XP per minute: walking there (about 7 yards a second) plus a few minutes to
-- do it; a chain and more quests at the same giver make it worth more
function P:Score(e)
	if not e.xp then return end
	local walk = e.dist and e.dist / 7 / 60 or 3
	local value = e.xp * (e.chain and (1 + math.min(e.chain, 4) * 0.15) or 1)
	return value / (walk / math.max(1, e.atGiver or 1) + 6)
end

-- the list: { id, title, level, mapID, x, y, dist, line, xp, chain, atGiver, best }
function P:Collect()
	local out, seen = {}, {}
	local m, pc, pwx, pwy = playerWorld()
	local pl = num(UnitLevel("player")) or 1
	local function add(e)
		if not e.id or seen[e.id] or haveQuest(e.id) then return end
		if e.level and (e.level > pl + 2 or e.level < pl - 7) then return end -- too high, or grey
		seen[e.id] = true
		if e.mapID and e.x and pc then
			local c, wx, wy = world(e.mapID, e.x, e.y)
			if c == pc and wx then e.dist = math.sqrt((wx - pwx) ^ 2 + (wy - pwy) ^ 2) end
		end
		out[#out + 1] = e
	end
	-- Blizzard: quest lines that start on this map
	if m and C_QuestLine and C_QuestLine.GetAvailableQuestLines then
		if C_QuestLine.RequestQuestLinesForMap then pcall(C_QuestLine.RequestQuestLinesForMap, m) end
		local ok, lines = pcall(C_QuestLine.GetAvailableQuestLines, m)
		if ok and type(lines) == "table" then
			for _, q in ipairs(lines) do
				if type(q) == "table" and not Safe(q.isHidden, false) then
					local id = num(q.questID)
					add({ id = id, title = Safe(q.questName, nil), line = Safe(q.questLineName, nil),
						level = id and questLevel(id), mapID = m, x = num(q.x), y = num(q.y) })
				end
			end
		end
	end
	-- Questie: the quests it marks as available, with the nearest quest giver
	local QLd = _G.QuestieLoader
	if type(QLd) == "table" and QLd.ImportModule then
		local function mod(name)
			local ok, m2 = pcall(QLd.ImportModule, QLd, name)
			return ok and type(m2) == "table" and m2 or nil
		end
		local AQ, QQ, DB = mod("AvailableQuests"), mod("QuestieQuest"), mod("QuestieDB")
		local avail = (AQ and type(AQ.__availableQuests) == "table" and AQ.__availableQuests)
			or (QQ and type(QQ.availableQuests) == "table" and QQ.availableQuests)
		if avail and DB and DB.QueryQuestSingle then
			local n = 0
			for id in pairs(avail) do
				n = n + 1
				if n > 400 then break end
				if type(id) == "number" and not seen[id] then
					local okN, name = pcall(DB.QueryQuestSingle, id, "name")
					local okL, lv = pcall(DB.QueryQuestSingle, id, "questLevel")
					local e = { id = id, title = okN and name or nil, level = okL and num(lv) or nil }
					local spot = pc and P:GiverSpot(id, DB, mod, pc, pwx, pwy)
					if spot then e.mapID, e.x, e.y, e.giver = spot[1], spot[2], spot[3], spot[7] end
					P:Advice(e, DB, mod)
					add(e)
				end
			end
		end
	end
	-- quests at the same giver: one walk for several
	local perGiver = {}
	for _, e in ipairs(out) do if e.giver then perGiver[e.giver] = (perGiver[e.giver] or 0) + 1 end end
	for _, e in ipairs(out) do
		e.atGiver = e.giver and perGiver[e.giver] or 1
		e.score = P:Score(e)
	end
	-- best value first (XP per minute of walking there plus doing it), else nearest
	table.sort(out, function(a, b)
		if (a.score ~= nil) ~= (b.score ~= nil) then return a.score ~= nil end
		if a.score and b.score and a.score ~= b.score then return a.score > b.score end
		if (a.dist ~= nil) ~= (b.dist ~= nil) then return a.dist ~= nil end
		if a.dist and b.dist and a.dist ~= b.dist then return a.dist < b.dist end
		return (a.level or 0) > (b.level or 0)
	end)
	-- the best three get a mark
	for i = 1, math.min(3, #out) do if out[i].score then out[i].best = true end end
	return out
end

---------------------------------------------------------------------------
-- The folded line under the quest list
---------------------------------------------------------------------------
function P:Build()
	local panel = RoA.Quests and RoA.Quests.panel
	if not panel then return end
	local f = CreateFrame("Frame", nil, panel)
	f:SetPoint("TOPLEFT", panel, "BOTTOMLEFT", 0, -2)
	f:SetPoint("TOPRIGHT", panel, "BOTTOMRIGHT", 0, -2)
	f:SetHeight(ROW_H)
	local head = CreateFrame("Button", nil, f)
	head:SetPoint("TOPLEFT")
	head:SetPoint("TOPRIGHT")
	head:SetHeight(ROW_H)
	head.text = S:Font(head, 11)
	head.text:SetPoint("LEFT", 4, 0)
	head.text:SetTextColor(unpack(S.colors.muted))
	head:SetScript("OnClick", function()
		RoA.char.quests.pickupOpen = not RoA.char.quests.pickupOpen
		P:Render()
	end)
	head:SetScript("OnEnter", function(b) b.text:SetTextColor(unpack(S.colors.accent)) end)
	head:SetScript("OnLeave", function(b) b.text:SetTextColor(unpack(S.colors.muted)) end)
	f.head = head
	f.rows = {}
	for i = 1, MAX_ROWS do
		local r = CreateFrame("Button", nil, f)
		r:SetHeight(ROW_H)
		r:SetPoint("TOPLEFT", 0, -i * ROW_H)
		r:SetPoint("TOPRIGHT", 0, -i * ROW_H)
		r.text = S:Font(r, 11)
		r.text:SetPoint("LEFT", 12, 0)
		r.text:SetPoint("RIGHT", -56, 0)
		r.text:SetJustifyH("LEFT")
		r.text:SetWordWrap(false)
		r.dist = S:Font(r, 10)
		r.dist:SetPoint("RIGHT", -4, 0)
		r.dist:SetTextColor(unpack(S.colors.muted))
		r:SetScript("OnClick", function(self)
			local e = self.entry
			if e and e.mapID and e.x then RoA.Nav:Add(e.mapID, e.x, e.y, e.title or L["Quest"], "quest") end
		end)
		r:SetScript("OnEnter", function(self)
			local e = self.entry
			if not e then return end
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			GameTooltip:SetText(e.title or "?", 1, 0.82, 0)
			if e.line then GameTooltip:AddLine(e.line, 0.8, 0.8, 0.8) end
			if e.best then GameTooltip:AddLine(L["One of the best picks here."], 1, 0.82, 0.25) end
			if e.xp then GameTooltip:AddLine(L["%s XP"]:format(e.xp), 0.9, 0.9, 0.9) end
			if e.chain then GameTooltip:AddLine(L["Starts a chain: %d more quests after this one."]:format(e.chain), 0.41, 0.8, 0.94) end
			if e.atGiver and e.atGiver > 1 then GameTooltip:AddLine(L["%d quests at this quest giver: pick them up together."]:format(e.atGiver), 0.41, 0.8, 0.94) end
			if e.objective then GameTooltip:AddLine(e.objective, 0.75, 0.75, 0.75, true) end
			GameTooltip:AddLine(e.x and L["Click: add the quest giver as a GPS stop."] or L["From Questie: no spot known."], 0.6, 0.65, 0.71, true)
			GameTooltip:Show()
		end)
		r:SetScript("OnLeave", function() GameTooltip:Hide() end)
		f.rows[i] = r
	end
	self.frame = f
end

function P:Render()
	local f = self.frame
	if not f then return end
	local cfg = RoA.char.quests
	if cfg.enabled == false or cfg.pickup == false then return f:Hide() end
	local list = self:Collect()
	local open = cfg.pickupOpen
	f.head.text:SetText((open and "- " or "+ ") .. L["Pick up nearby (%d)"]:format(#list))
	local n = 0
	for i, r in ipairs(f.rows) do
		local e = open and list[i]
		if e then
			n = i
			r.entry = e
			r.text:SetText((e.best and "|cffffd100+|r " or "") .. (e.level and ("[" .. e.level .. "] ") or "") .. (e.title or "?"))
			r.text:SetTextColor(unpack(e.best and S.colors.text or S.colors.muted))
			r.dist:SetText(e.dist and L["%d yd"]:format(math.floor(e.dist + 0.5)) or "")
			r:Show()
		else
			r:Hide()
		end
	end
	f:SetHeight(ROW_H * (n + 1))
	f:SetShown(#list > 0)
end

function P:OnEnable()
	C_Timer.After(2, function()
		pcall(P.Build, P)
		pcall(P.Render, P)
	end)
	-- quest log updates come in bursts: redraw at most once a second
	local pending = false
	local function later()
		if pending then return end
		pending = true
		C_Timer.After(1, function() pending = false pcall(P.Render, P) end)
	end
	RoA:On("QUEST_LOG_UPDATE", later)
	RoA:On("ZONE_CHANGED_NEW_AREA", later)
	RoA:On("QUESTLINE_UPDATE", later)
	C_Timer.NewTicker(15, function() pcall(P.Render, P) end)
end
