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

-- the list: { id, title, level, mapID, x, y, dist, line }
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
	-- Questie: the quests it marks as available (names and levels; no spot)
	local QLd = _G.QuestieLoader
	if type(QLd) == "table" and QLd.ImportModule then
		local okQ, QQ = pcall(QLd.ImportModule, QLd, "QuestieQuest")
		local okD, DB = pcall(QLd.ImportModule, QLd, "QuestieDB")
		local avail = okQ and type(QQ) == "table" and type(QQ.availableQuests) == "table" and QQ.availableQuests
		if avail and okD and type(DB) == "table" and DB.QueryQuestSingle then
			local n = 0
			for id in pairs(avail) do
				n = n + 1
				if n > 80 then break end
				local okN, name = pcall(DB.QueryQuestSingle, id, "name")
				local okL, lv = pcall(DB.QueryQuestSingle, id, "questLevel")
				add({ id = id, title = okN and name or nil, level = okL and num(lv) or nil })
			end
		end
	end
	table.sort(out, function(a, b)
		if (a.dist ~= nil) ~= (b.dist ~= nil) then return a.dist ~= nil end
		if a.dist and b.dist and a.dist ~= b.dist then return a.dist < b.dist end
		return (a.level or 0) > (b.level or 0)
	end)
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
			r.text:SetText((e.level and ("[" .. e.level .. "] ") or "") .. (e.title or "?"))
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
