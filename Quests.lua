-- Roads of Azeroth by DinX: quest tracker
local _, ns = ...
local RoA = ns.RoA
local L = RoA.L
local S = RoA.Style
local Safe = RoA.Safe

local Q = RoA:NewModule("Quests")

local QL = C_QuestLog
local PAD, INDENT, GAP, BAR = 6, 10, 2, 3
local GREEN = { 0.30, 0.90, 0.30 }
local RED = { 1.00, 0.25, 0.25 }
local ORANGE = { 1.00, 0.55, 0.25 }

-- Sort modes in click order, with their label keys
local MODES = { "smart", "distance", "xp", "xpmin", "level", "progress", "zone" }
local MODE_NAMES = {
	smart = "Smart route", distance = "Distance", xp = "XP reward", xpmin = "XP per minute",
	level = "Level", progress = "Almost done", zone = "Zone",
}

local STRATEGY_NAMES = { balanced = "Balanced", turnin = "Turn in first", quest = "Quest first", nearest = "Nearest" }
local STRATEGY_TIPS = {
	balanced = "Most XP per minute",
	turnin = "Hand in what's ready, then quest",
	quest = "Objectives first, hand in at the end",
	nearest = "Always the closest stop",
}

-- Skip suggestions from the plan: tag text and tooltip (label keys)
local SKIP = {
	grey = { "Skip?", "Gives little XP at your level." },
	elite = { "Skip?", "Group or elite quest: hard solo." },
	far = { "Skip?", "Far away or on another continent." },
	red = { "Later", "Much higher level: come back later." },
}


---------------------------------------------------------------------------
-- Small safe helpers: values that are secret or of the wrong type become default
---------------------------------------------------------------------------
local function num(v, default)
	v = Safe(v, nil)
	if type(v) ~= "number" then return default end
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

-- pcall wrapper that returns up to three results, or nil on error
local function try(fn, ...)
	if not fn then return end
	local ok, a, b, c = pcall(fn, ...)
	if ok then return a, b, c end
end

-- Report the first error once, then stay quiet (no error floods).
local reported = false
local function guard(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok and not reported then
		reported = true
		local handler = geterrorhandler and geterrorhandler()
		if handler then handler(err) end
	end
end

local function setFont(fs, size)
	if fs.ckSize ~= size then
		S:ApplyFont(fs, size)
		fs.ckSize = size
	end
end

---------------------------------------------------------------------------
-- Optional epic provider (RoA.EpicProvider, set by an add-on such as Scrum of
-- Azeroth). Without it every call returns nil and the tracker works as always.
---------------------------------------------------------------------------
local function provider()
	local p = RoA.EpicProvider
	if type(p) == "table" then return p end
end

local function ask(name, ...)
	local p = provider()
	local fn = p and p[name]
	if type(fn) ~= "function" then return end
	local ok, a, b = pcall(fn, p, ...)
	if ok then return a, b end
end

local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t "

---------------------------------------------------------------------------
-- Quest log reading (C_QuestLog first, classic functions as fallback)
---------------------------------------------------------------------------
local function logCounts()
	local entries, quests
	if QL and QL.GetNumQuestLogEntries then
		entries, quests = try(QL.GetNumQuestLogEntries)
	elseif GetNumQuestLogEntries then
		entries, quests = try(GetNumQuestLogEntries)
	end
	return num(entries, 0), num(quests, 0)
end

-- Returns a plain table for log line i, or nil.
local entry = {}
local function readEntry(i)
	wipe(entry)
	if QL and QL.GetInfo then
		local info = try(QL.GetInfo, i)
		if type(info) ~= "table" then return end
		entry.title = str(info.title)
		entry.level = num(info.difficultyLevel, 0) > 0 and num(info.difficultyLevel, 0) or num(info.level, 0)
		entry.showLevel = num(info.level, 0)
		entry.isHeader = flag(info.isHeader)
		entry.questID = num(info.questID)
		entry.skip = flag(info.isHidden) or flag(info.isBounty)
		entry.onMap = flag(info.isOnMap)
		entry.group = num(info.suggestedGroup, 0)
		return entry
	elseif GetQuestLogTitle then
		local title, level, tag, isHeader, _, isComplete, _, questID = try(GetQuestLogTitle, i)
		entry.title = str(title)
		entry.level = num(level, 0)
		entry.showLevel = entry.level
		entry.isHeader = flag(isHeader)
		entry.questID = num(questID)
		entry.tag = str(tag)
		entry.classicComplete = num(isComplete)
		return entry
	end
end

local function isWatched(questID, index)
	if QL and QL.GetQuestWatchType then
		local ok, w = pcall(QL.GetQuestWatchType, questID)
		if ok then return Safe(w, nil) ~= nil end
	end
	if IsQuestWatched then
		return flag(try(IsQuestWatched, index))
	end
	return false
end

-- Tag text such as "Dungeon", and whether the quest is elite.
local function questTag(questID, classicTag)
	local name, elite
	if QL and QL.GetQuestTagInfo then
		local info = try(QL.GetQuestTagInfo, questID)
		if type(info) == "table" then
			name = str(info.tagName)
			elite = flag(info.isElite)
		end
	elseif GetQuestTagInfo then
		local _, tagName = try(GetQuestTagInfo, questID)
		name = str(tagName)
	end
	name = name or classicTag
	if name and (name == ELITE or name == "Elite") then
		name, elite = nil, true
	end
	return name, elite
end

-- "Red Leather Bandana: 4/15" (classic) becomes "4/15 Red Leather Bandana".
local function objectiveText(text, have, need)
	if not text then return "", have, need end
	local name, a, b = text:match("^(.-):%s*(%d+)%s*/%s*(%d+)$")
	if name and name ~= "" then
		return a .. "/" .. b .. " " .. name, have or tonumber(a), need or tonumber(b)
	end
	local a2, b2 = text:match("^(%d+)%s*/%s*(%d+)")
	if a2 then return text, have or tonumber(a2), need or tonumber(b2) end
	return text, have, need
end

local function addObjective(q, text, done, have, need, pct)
	local shown
	shown, have, need = objectiveText(text, have, need)
	q.numObj = q.numObj + 1
	local o = q.objectives[q.numObj] or {}
	q.objectives[q.numObj] = o
	o.text, o.done, o.have, o.need, o.pct = shown, done, have, need, pct
end

local function readObjectives(q)
	q.numObj = 0
	if QL and QL.GetQuestObjectives then
		local list = try(QL.GetQuestObjectives, q.id)
		if type(list) ~= "table" then return end
		for _, o in ipairs(list) do
			if type(o) == "table" then
				local pct
				if Safe(o.type, nil) == "progressbar" and GetQuestProgressBarPercent then
					pct = num(try(GetQuestProgressBarPercent, q.id))
				end
				addObjective(q, str(o.text), flag(o.finished), num(o.numFulfilled), num(o.numRequired), pct)
			end
		end
	elseif GetNumQuestLeaderBoards and GetQuestLogLeaderBoard then
		for j = 1, num(try(GetNumQuestLeaderBoards, q.index), 0) do
			local text, _, finished = try(GetQuestLogLeaderBoard, j, q.index)
			addObjective(q, str(text), flag(finished))
		end
	end
end

local function questState(q, classicComplete)
	local complete, failed
	if QL and QL.IsComplete then complete = flag(try(QL.IsComplete, q.id)) end
	if not complete and QL and QL.ReadyForTurnIn then complete = flag(try(QL.ReadyForTurnIn, q.id)) end
	if QL and QL.IsFailed then failed = flag(try(QL.IsFailed, q.id)) end
	if classicComplete == 1 then complete = true end
	if classicComplete == -1 then failed = true end
	return complete and not failed, failed
end

local function currentZones()
	local z = str(GetZoneText and try(GetZoneText))
	local m = C_Map and C_Map.GetBestMapForUnit and num(try(C_Map.GetBestMapForUnit, "player"))
	local info = m and C_Map.GetMapInfo and try(C_Map.GetMapInfo, m)
	return z, type(info) == "table" and str(info.name) or nil
end

---------------------------------------------------------------------------
-- Collect and sort
---------------------------------------------------------------------------
local list, spare = {}, {}

local function sorter(a, b)
	if a.complete ~= b.complete then return a.complete end
	if a.zone ~= b.zone then return a.zone end
	if a.level ~= b.level then return a.level < b.level end
	if a.title ~= b.title then return a.title < b.title end
	return a.id < b.id
end

-- Route plan (QuestPlan.lua): every call is guarded, nil means "use the built-in sort"
local function planList(mode)
	local QP = RoA.QuestPlan
	if not (QP and QP.Get) then return end
	Q.inPlan = true
	local ok, res = pcall(QP.Get, QP, mode)
	Q.inPlan = false
	if ok and type(res) == "table" then return res end
end

local function nextStop()
	local QP = RoA.QuestPlan
	if not (QP and QP.NextStop) then return end
	Q.inPlan = true
	local ok, res = pcall(QP.NextStop, QP)
	Q.inPlan = false
	if ok and type(res) == "table" then return res end
end

-- Plan order first; quests the plan does not know follow in the built-in order.
local function planSorter(a, b)
	local pa, pb = a.planPos, b.planPos
	if pa and pb then return pa < pb end
	if pa or pb then return pa ~= nil end
	return sorter(a, b)
end

-- Links each quest in `list` to its plan entry; returns true when a plan was used.
local planIndex = {}
local function applyPlan(mode)
	local plan = planList(mode)
	if not plan then return false end
	wipe(planIndex)
	for pos, e in ipairs(plan) do
		local id = type(e) == "table" and num(e.questID) or nil
		if id and not planIndex[id] then planIndex[id] = pos end
	end
	for _, q in ipairs(list) do
		local pos = planIndex[q.id]
		q.planPos, q.plan = pos, pos and plan[pos] or nil
	end
	return true
end

-- Fills `list`; returns number of quests in the log and how many are tracked.
function Q:Collect()
	for i = #list, 1, -1 do
		spare[#spare + 1] = list[i]
		list[i] = nil
	end
	local cfg = RoA.char.quests
	local entries, total = logCounts()
	local zone1, zone2 = currentZones()
	local header
	local anyWatched = false
	local playerLevel = num(UnitLevel("player"), 1)

	for i = 1, entries do
		local e = readEntry(i)
		if e then
			if e.isHeader then
				header = e.title
			elseif e.questID and e.title and not e.skip then
				local q = table.remove(spare) or { objectives = {} }
				q.id, q.index, q.title = e.questID, i, e.title
				q.level = e.level > 0 and e.level or playerLevel
				q.showLevel = e.showLevel > 0 and e.showLevel or q.level
				q.watched = isWatched(e.questID, i)
				q.complete, q.failed = questState(q, e.classicComplete)
				q.tag, q.elite = questTag(e.questID, e.tag)
				if not q.tag and (e.group or 0) > 1 then q.tag = L["Group"] .. " " .. e.group end
				q.zone = cfg.zoneFirst and ((header ~= nil and (header == zone1 or header == zone2)) or e.onMap) or false
				q.zone = q.zone and true or false
				readObjectives(q)
				if q.watched then anyWatched = true end
				list[#list + 1] = q
			end
		end
	end

	-- Watched quests only, when the player watches any
	if anyWatched then
		for i = #list, 1, -1 do
			if not list[i].watched then
				spare[#spare + 1] = table.remove(list, i)
			end
		end
	end
	for _, q in ipairs(list) do q.planPos, q.plan = nil, nil end
	self.usingPlan = applyPlan(cfg.sortMode or "smart")
	table.sort(list, self.usingPlan and planSorter or sorter)
	-- optional provider: quests sharing the same mobs stay next to each other
	if provider() then
		local i = 1
		while i < #list do
			local partner = num(ask("SharedWith", list[i].id))
			if partner and list[i + 1].id ~= partner then
				for j = i + 2, #list do
					if list[j].id == partner then table.insert(list, i + 1, table.remove(list, j)) break end
				end
			end
			i = i + 1
		end
	end
	if total < #list then total = #list end
	self:BuildGroups()
	return total, #list
end

-- Epic groups from the optional provider, for the quests that will be shown.
-- A group takes the place of its first quest, so with the route sort epics
-- follow their earliest stop. self.groups stays nil without provider or epics.
function Q:BuildGroups()
	self.groups = nil
	if not ask("GroupingEnabled") then return end
	local maxQ = num(RoA.char.quests.maxQuests, 12)
	local byKey, out, loose, anyEpic = {}, {}, nil, false
	for qi = 1, math.min(#list, maxQ) do
		local q = list[qi]
		local e = ask("GetEpic", q.id)
		local key = type(e) == "table" and str(e.key) or nil
		local g
		if key then
			g = byKey[key]
			if not g then
				g = { key = key, epic = e, quests = {} }
				byKey[key] = g
				out[#out + 1] = g
			end
			anyEpic = true
		else
			if not loose then
				loose = { key = "loose", loose = true, quests = {} }
				out[#out + 1] = loose
			end
			g = loose
		end
		g.quests[#g.quests + 1] = q
	end
	if not anyEpic then return end -- no questline data: plain list as always
	if loose then
		local info = ask("LooseGroup")
		loose.epic = type(info) == "table" and info or { name = "Loose tasks" }
		loose.key = type(info) == "table" and str(info.key) or "loose"
		if type(info) == "table" and info.header == false then
			-- no header: the loose quests follow the epics
			loose.noHeader = true
			for i, g in ipairs(out) do
				if g == loose then table.remove(out, i) break end
			end
			out[#out + 1] = loose
		end
	end
	self.groups = out
end

-- Folded state of an epic group; loose tasks start folded.
local function groupFolded(g)
	local c = RoA.char.quests.collapsed
	if g.loose then return c[g.key] ~= false end
	return c[g.key] and true or false
end

---------------------------------------------------------------------------
-- Actions on a quest title
---------------------------------------------------------------------------
local function openQuest(questID, index)
	if InCombatLockdown() then return end
	if QuestMapFrame_OpenToQuestDetails then
		try(QuestMapFrame_OpenToQuestDetails, questID)
	elseif QuestLog_OpenToQuest and index then
		try(QuestLog_OpenToQuest, index)
	else
		if index and SelectQuestLogEntry then try(SelectQuestLogEntry, index) end
		if ShowQuestLog then try(ShowQuestLog)
		elseif OpenQuestLog then try(OpenQuestLog, questID)
		elseif ToggleQuestLog then try(ToggleQuestLog) end
	end
end

-- Position of a quest from Blizzard's map data.
local function questPosition(questID)
	if QL and QL.GetNextWaypoint then
		local m, x, y = try(QL.GetNextWaypoint, questID)
		m, x, y = num(m), num(x), num(y)
		if m and m > 0 and x and y then return m, x, y end
	end
	if not (QL and QL.GetQuestsOnMap) then return end
	local playerMap = C_Map and C_Map.GetBestMapForUnit and num(try(C_Map.GetBestMapForUnit, "player"))
	local questMap = GetQuestUiMapID and num(try(GetQuestUiMapID, questID, true))
	for _, mapID in ipairs({ playerMap or 0, questMap or 0 }) do
		if mapID > 0 then
			local pins = try(QL.GetQuestsOnMap, mapID)
			if type(pins) == "table" then
				for _, info in ipairs(pins) do
					if num(info.questID) == questID and num(info.x) and num(info.y) then
						return mapID, info.x, info.y
					end
				end
			end
		end
	end
end

-- Navigation (Nav.lua) on: it owns the arrow; the tracker hands it quests.
local function nav()
	local N = RoA.Nav
	if N and N.OwnsArrow then
		local ok, owns = pcall(N.OwnsArrow, N)
		if ok and owns then return N end
	end
end

local function questKind(questID)
	if QL and QL.ReadyForTurnIn and flag(try(QL.ReadyForTurnIn, questID)) then return "turnin" end
	if QL and QL.IsComplete and flag(try(QL.IsComplete, questID)) then return "turnin" end
	return "quest"
end

-- Ctrl-click: add the quest to the navigation route.
local function addToRoute(questID, title)
	local N = RoA.Nav
	if not (N and N.AddQuest) then return end
	local m, x, y = questPosition(questID)
	pcall(N.AddQuest, N, questID, title, m, x, y)
end

-- Click: point the arrow at this quest (stays until arrival or cleared).
local function setWaypoint(questID, title)
	local N = nav()
	if N then
		local m, x, y = questPosition(questID)
		if m then
			local ok, set = pcall(N.SetOverride, N, m, x, y, title, questKind(questID), questID)
			if ok and set then
				Q.manualArrow = true
				Q.arrowKey = nil
				Q.selected = questID
			end
		end
		return
	end
	local A = RoA.Arrow
	if not (A and A.SetTarget) then return end
	local m, x, y = questPosition(questID)
	if m then
		local ok = pcall(A.SetTarget, A, m, x, y, title)
		if ok then
			Q.manualArrow = true
			Q.arrowKey = nil
			Q.selected = questID
		end
	end
end

-- Keep the arrow on the plan's next stop (display only).
function Q:UpdateArrow()
	local A = RoA.Arrow
	if not (A and A.SetTarget and A.Clear) then return end
	-- navigation decides where the arrow points; only keep the selection in sync
	local N = nav()
	if N then
		self.arrowKey = nil
		if self.manualArrow and not (N.HasOverride and N:HasOverride()) then
			self.manualArrow = false
			self.selected = nil
		end
		return
	end
	-- a target the player picked with right-click wins until reached or cleared
	if self.manualArrow then
		local m = A.GetTarget and try(A.GetTarget, A)
		if m then return end
		self.manualArrow = false
		self.selected = nil
	end
	local cfg = RoA.char.quests
	local stop = cfg.enabled and cfg.arrow and nextStop()
	local m, x, y = stop and num(stop.mapID), stop and num(stop.x), stop and num(stop.y)
	if not (m and x and y) then
		if self.arrowKey then
			pcall(A.Clear, A)
			self.arrowKey = nil
		end
		return
	end
	local key = string.format("%d:%.4f:%.4f", m, x, y)
	if key == self.arrowKey then return end
	local title
	local ids = stop.questIDs
	local first = type(ids) == "table" and num(ids[1]) or nil
	if first then
		for _, q in ipairs(list) do
			if q.id == first then title = q.title break end
		end
		if not title and QL and QL.GetTitleForQuestID then title = str(try(QL.GetTitleForQuestID, first)) end
		if title and #ids > 1 then title = title .. " (+" .. (#ids - 1) .. ")" end
	end
	if pcall(A.SetTarget, A, m, x, y, title or L["Next stop"]) then
		self.arrowKey = key
	end
end

---------------------------------------------------------------------------
-- Frames (pooled: created once, re-used on every redraw)
---------------------------------------------------------------------------
local titles, lines = {}, {}

local function onTitleClick(self, button)
	guard(function()
		local id = self.questID
		if not id then return end
		if IsControlKeyDown and IsControlKeyDown() and button == "LeftButton" and RoA.Nav then
			addToRoute(id, self.questTitle)
		elseif IsShiftKeyDown() then
			openQuest(id, self.logIndex)
		elseif IsAltKeyDown and IsAltKeyDown() then
			ask("OnQuestClick", id) -- optional provider (e.g. Scrum of Azeroth's quest details)
		elseif button == "RightButton" then
			local c = RoA.char.quests.collapsed
			c[id] = not c[id] or nil
			Q:Redraw()
		else
			-- a plain click only selects the quest as the target (arrow/GPS)
			Q:ClickQuest(id, self.questTitle)
		end
	end)
end

-- Same as a left-click on a quest title: select it (arrow/GPS), or back to the
-- route when it is already selected. Also used by add-ons (quest board).
function Q:ClickQuest(id, title)
	if not id then return end
	if Q.selected == id then
		Q.selected, Q.manualArrow, Q.arrowKey = nil, false, nil
		local N = nav()
		if N then
			pcall(N.ClearOverride, N)
		elseif RoA.Arrow and RoA.Arrow.Clear then
			pcall(RoA.Arrow.Clear, RoA.Arrow)
		end
	else
		setWaypoint(id, title)
	end
	Q:Redraw()
end

function Q:OpenQuest(id, index) openQuest(id, index) end
function Q:AddToRoute(id, title) addToRoute(id, title) end

-- Epic header rows (only with an epic provider): click selects the epic's next
-- quest, right-click folds, hover lists the steps (tooltip from the provider).
local epicRows = {}

local function onEpicClick(self, button)
	guard(function()
		local g = self.group
		if not g then return end
		if button == "RightButton" then
			local c = RoA.char.quests.collapsed
			if g.loose then
				if c[g.key] ~= false then c[g.key] = false else c[g.key] = true end
			else
				c[g.key] = not c[g.key] or nil
			end
			Q:Redraw()
		else
			local q = g.quests[1]
			if q then Q:ClickQuest(q.id, q.title) end
		end
	end)
end

local function onEpicEnter(self)
	guard(function()
		if not (GameTooltip and self.group) then return end
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		if not ask("EpicTooltip", GameTooltip, self.group.key, self.group.epic) then
			GameTooltip:SetText(str(self.group.epic and self.group.epic.name) or "?", 1, 0.82, 0)
		end
		GameTooltip:Show()
	end)
end

function Q:EpicRow(i)
	local r = epicRows[i]
	if r then return r end
	r = CreateFrame("Button", nil, self.content)
	r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	r:SetScript("OnClick", onEpicClick)
	r:SetScript("OnEnter", onEpicEnter)
	r:SetScript("OnLeave", function(btn)
		if GameTooltip and GameTooltip:IsOwned(btn) then GameTooltip:Hide() end
	end)
	local hl = r:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.06)
	r.chev = r:CreateTexture(nil, "ARTWORK")
	r.chev:SetSize(10, 10)
	r.chev:SetPoint("LEFT", 0, 0)
	r.count = S:Font(r, 10)
	r.count:SetPoint("RIGHT", 0, 0)
	r.count:SetTextColor(unpack(S.colors.muted))
	r.bar = S:StatusBar(r)
	r.bar:SetHeight(BAR)
	r.bar:SetPoint("RIGHT", r.count, "LEFT", -4, 0)
	r.text = S:Font(r, 12)
	r.text:SetPoint("LEFT", r.chev, "RIGHT", 3, 0)
	r.text:SetPoint("RIGHT", r.bar, "LEFT", -4, 0)
	r.text:SetJustifyH("LEFT")
	r.text:SetWordWrap(false)
	epicRows[i] = r
	return r
end

-- Tooltip on a skip suggestion
local function onTitleEnter(self)
	guard(function()
		local s = self.skip and SKIP[self.skip]
		if not (s and GameTooltip) then return end
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText(L[s[1]], 1, 0.82, 0)
		GameTooltip:AddLine(L[s[2]], 1, 1, 1, true)
		GameTooltip:Show()
	end)
end

local function onTitleLeave(self)
	guard(function()
		if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
	end)
end

function Q:TitleRow(i)
	local t = titles[i]
	if t then return t end
	t = CreateFrame("Button", nil, self.content)
	t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	t:SetScript("OnClick", onTitleClick)
	local hl = t:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.06)
	t:SetScript("OnEnter", onTitleEnter)
	t:SetScript("OnLeave", onTitleLeave)
	t.tag = S:Font(t, 10)
	t.tag:SetPoint("RIGHT", -12, 0)
	t.text = S:Font(t, 12)
	t.text:SetPoint("LEFT", 0, 0)
	t.text:SetPoint("RIGHT", t.tag, "LEFT", -3, 0)
	t.text:SetJustifyH("LEFT")
	t.text:SetWordWrap(false)
	t.mark = S:Font(t, 12)
	t.mark:SetPoint("RIGHT", 0, 0)
	t.mark:SetTextColor(unpack(S.colors.muted))
	titles[i] = t
	return t
end

-- Lines under a title select that quest as the target, like the title;
-- Shift-click or right-click opens it in the quest log
local function onLineClick(self, button)
	guard(function()
		local id = self.questID
		if not id then return end
		if button == "RightButton" or IsShiftKeyDown() then
			openQuest(id, self.logIndex)
		else
			Q:ClickQuest(id, self.questTitle)
		end
	end)
end

function Q:LineRow(i)
	local o = lines[i]
	if o then return o end
	o = CreateFrame("Button", nil, self.content)
	o:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	o:SetScript("OnClick", onLineClick)
	local hl = o:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.06)
	o.text = S:Font(o, 12)
	o.text:SetPoint("TOPLEFT", 0, 0)
	o.text:SetJustifyH("LEFT")
	o.bar = S:StatusBar(o, S.colors.accent)
	o.bar:SetHeight(BAR)
	o.bar:SetPoint("TOPLEFT", o.text, "BOTTOMLEFT", 0, -1)
	o.bar:SetPoint("RIGHT", o, "RIGHT", 0, 0)
	lines[i] = o
	return o
end

function Q:CreatePanel()
	local p = CreateFrame("Frame", "RoadsOfAzerothQuests", UIParent, "BackdropTemplate")
	p:SetFrameStrata("LOW")
	p:SetSize(RoA.char.quests.width or 260, 40)
	S:Backdrop(p)
	self.panel = p

	local h = CreateFrame("Button", nil, p)
	h:RegisterForClicks("LeftButtonUp")
	h:SetPoint("TOPLEFT", PAD, -PAD)
	h:SetPoint("TOPRIGHT", -PAD, -PAD)
	h:SetScript("OnClick", function()
		guard(function()
			local cfg = RoA.char.quests
			cfg.allCollapsed = not cfg.allCollapsed or nil
			Q:Redraw()
		end)
	end)
	h.text = S:Font(h, 12)
	h.text:SetPoint("LEFT", 0, 0)
	h.text:SetTextColor(unpack(S.colors.accent))
	h.mark = S:Font(h, 12)
	h.mark:SetPoint("RIGHT", 0, 0)
	h.mark:SetTextColor(unpack(S.colors.muted))
	self.header = h

	-- Sort mode label in the header: left-click cycles the mode
	local m = CreateFrame("Button", nil, h)
	m:RegisterForClicks("LeftButtonUp")
	m:SetPoint("LEFT", h.text, "RIGHT", 4, 0)
	local mhl = m:CreateTexture(nil, "HIGHLIGHT")
	mhl:SetAllPoints()
	mhl:SetColorTexture(1, 1, 1, 0.06)
	m.text = S:Font(m, 10)
	m.text:SetPoint("LEFT", 0, 0)
	m.text:SetTextColor(unpack(S.colors.muted))
	m:SetScript("OnClick", function()
		guard(function()
			local cfg = RoA.char.quests
			local cur = 1
			for i, mode in ipairs(MODES) do
				if mode == cfg.sortMode then cur = i end
			end
			cfg.sortMode = MODES[cur % #MODES + 1]
			RoA:Fire("SETTINGS", "quests")
		end)
	end)
	m:SetScript("OnEnter", function(btn)
		guard(function()
			if not GameTooltip then return end
			GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
			GameTooltip:SetText(L["Sort by"], 1, 0.82, 0)
			GameTooltip:AddLine(L["Click to change the sort order."], 1, 1, 1, true)
			GameTooltip:Show()
		end)
	end)
	m:SetScript("OnLeave", function(btn)
		guard(function()
			if GameTooltip and GameTooltip:IsOwned(btn) then GameTooltip:Hide() end
		end)
	end)
	self.modeButton = m

	-- Route strategy (smart route only): click cycles, the route is planned again
	local st = CreateFrame("Button", nil, h)
	st:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	st:SetPoint("LEFT", m, "RIGHT", 2, 0)
	local sthl = st:CreateTexture(nil, "HIGHLIGHT")
	sthl:SetAllPoints()
	sthl:SetColorTexture(1, 1, 1, 0.06)
	st.text = S:Font(st, 10)
	st.text:SetPoint("LEFT", 0, 0)
	st.text:SetTextColor(unpack(S.colors.accent))
	st:SetScript("OnClick", function(_, button)
		guard(function()
			local P = RoA.QuestPlan
			if not (P and P.STRATEGIES) then return end
			local list, cur = P.STRATEGIES, 1
			for i, k in ipairs(list) do if k == P:Strategy() then cur = i end end
			local step = button == "RightButton" and -1 or 1
			local key = list[(cur - 1 + step) % #list + 1]
			P:SetStrategy(key)
			RoA:Print(L["Route: %s"]:format(L[STRATEGY_NAMES[key]]))
		end)
	end)
	st:SetScript("OnEnter", function(btn)
		guard(function()
			GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
			GameTooltip:SetText(L["Route strategy"], 1, 0.82, 0)
			local P = RoA.QuestPlan
			local cur = P and P.Strategy and P:Strategy()
			for _, k in ipairs(P and P.STRATEGIES or {}) do
				local on = k == cur
				GameTooltip:AddDoubleLine((on and "> " or "  ") .. L[STRATEGY_NAMES[k]], L[STRATEGY_TIPS[k]],
					on and 0.41 or 1, on and 0.8 or 1, on and 0.94 or 1, 0.6, 0.65, 0.71)
			end
			GameTooltip:AddLine(L["Click: next, right-click: previous. The route is planned again."], 0.6, 0.65, 0.71, true)
			GameTooltip:Show()
		end)
	end)
	st:SetScript("OnLeave", function(btn) if GameTooltip:IsOwned(btn) then GameTooltip:Hide() end end)
	self.strategyButton = st

	-- Recalculate the route (it stays as it is until you click this)
	local rc = CreateFrame("Button", nil, h)
	rc:SetSize(14, 14)
	rc:SetPoint("RIGHT", h.mark, "LEFT", -6, 0)
	rc.icon = rc:CreateTexture(nil, "ARTWORK")
	rc.icon:SetAllPoints()
	rc.icon:SetTexture("Interface\\Buttons\\UI-RefreshButton")
	rc.icon:SetVertexColor(unpack(S.colors.muted))
	rc:RegisterForClicks("LeftButtonUp")
	rc:SetScript("OnClick", function()
		guard(function()
			local P = RoA.QuestPlan
			if P and P.Recalculate then
				P:Recalculate()
				RoA:Print(L["Route recalculated from where you are now."])
			end
		end)
	end)
	rc:SetScript("OnEnter", function(btn)
		guard(function()
			btn.icon:SetVertexColor(unpack(S.colors.accent))
			GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
			GameTooltip:SetText(L["Recalculate route"], 1, 0.82, 0)
			local P = RoA.QuestPlan
			if P and P.IsLocked and P:IsLocked() then
				GameTooltip:AddLine(L["The route stays as it is until you click here. Finished stops drop off, new quests go last."], 1, 1, 1, true)
			else
				GameTooltip:AddLine(L["The route follows you as you move (turn on 'Keep the route' under Quests to lock it)."], 1, 1, 1, true)
			end
			GameTooltip:Show()
		end)
	end)
	rc:SetScript("OnLeave", function(btn)
		btn.icon:SetVertexColor(unpack(S.colors.muted))
		if GameTooltip:IsOwned(btn) then GameTooltip:Hide() end
	end)
	self.recalcButton = rc

	-- Board icon (only when an epic provider offers a board): three small columns
	local bb = CreateFrame("Button", nil, h)
	bb:SetSize(14, 14)
	bb:SetPoint("RIGHT", rc, "LEFT", -4, 0)
	bb:RegisterForClicks("LeftButtonUp")
	bb.cols = {}
	for i, hgt in ipairs({ 12, 8, 10 }) do
		local t = bb:CreateTexture(nil, "ARTWORK")
		t:SetSize(3, hgt)
		t:SetPoint("TOPLEFT", (i - 1) * 5 + 1, -1)
		t:SetColorTexture(1, 1, 1, 1)
		t:SetVertexColor(unpack(S.colors.muted))
		bb.cols[i] = t
	end
	local function tintBoard(c) for _, t in ipairs(bb.cols) do t:SetVertexColor(c[1], c[2], c[3]) end end
	bb:SetScript("OnClick", function() guard(function() ask("ToggleBoard") end) end)
	bb:SetScript("OnEnter", function(btn)
		guard(function()
			tintBoard(S.colors.accent)
			GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
			if not ask("BoardTooltip", GameTooltip) then GameTooltip:SetText("Board", 1, 0.82, 0) end
			GameTooltip:Show()
		end)
	end)
	bb:SetScript("OnLeave", function(btn)
		tintBoard(S.colors.muted)
		if GameTooltip:IsOwned(btn) then GameTooltip:Hide() end
	end)
	bb:Hide()
	self.boardButton = bb

	-- Sprint line under the header (only when the provider reports a sprint)
	local sl = CreateFrame("Button", nil, p)
	sl:RegisterForClicks("LeftButtonUp")
	sl.text = S:Font(sl, 10)
	sl.text:SetPoint("LEFT", 0, 0)
	sl.text:SetJustifyH("LEFT")
	sl.text:SetWordWrap(false)
	sl.text:SetTextColor(unpack(S.colors.muted))
	sl:SetScript("OnClick", function() guard(function() ask("ToggleBoard") end) end)
	sl:SetScript("OnEnter", function(btn)
		guard(function()
			GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
			if ask("SprintTooltip", GameTooltip) then GameTooltip:Show() else GameTooltip:Hide() end
		end)
	end)
	sl:SetScript("OnLeave", function(btn) if GameTooltip:IsOwned(btn) then GameTooltip:Hide() end end)
	sl:Hide()
	self.sprintLine = sl

	-- Accent bar left of the next stop
	local bar = p:CreateTexture(nil, "ARTWORK")
	local a = S.colors.accent
	bar:SetColorTexture(a[1], a[2], a[3], 0.7)
	bar:SetWidth(2)
	bar:Hide()
	self.nextBar = bar

	-- Rows live on a scrolling content frame under the header
	local sc = CreateFrame("ScrollFrame", nil, p)
	sc:EnableMouseWheel(true)
	local content = CreateFrame("Frame", nil, sc)
	content:SetSize(10, 10)
	sc:SetScrollChild(content)
	sc:SetScript("OnMouseWheel", function(frame, delta)
		local max = frame:GetVerticalScrollRange() or 0
		local v = math.max(0, math.min(max, (frame:GetVerticalScroll() or 0) - delta * 40))
		frame:SetVerticalScroll(v)
		Q:UpdateScrollbar()
	end)
	local thumb = p:CreateTexture(nil, "OVERLAY")
	thumb:SetColorTexture(a[1], a[2], a[3], 0.6)
	thumb:SetWidth(2)
	thumb:Hide()
	self.scroll, self.content, self.thumb = sc, content, thumb
	bar:SetParent(content)

	S:RegisterMover(p, "quests", L["Quests"], function(f)
		-- under the minimap
		f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -10, -230)
	end, true)
end

function Q:UpdateScrollbar()
	local sc, thumb = self.scroll, self.thumb
	local max = sc:GetVerticalScrollRange() or 0
	local h = sc:GetHeight() or 0
	if max <= 1 or h <= 0 then
		thumb:Hide()
		return
	end
	local th = math.max(16, h * h / (h + max))
	local pos = (sc:GetVerticalScroll() or 0) / max
	thumb:ClearAllPoints()
	thumb:SetPoint("TOPRIGHT", sc, "TOPRIGHT", -1, -(h - th) * pos)
	thumb:SetHeight(th)
	thumb:Show()
end

local function titleString(q)
	local lvl = "[" .. q.showLevel .. (q.elite and "+" or "") .. "] "
	local s = lvl .. q.title
	if q.tag then s = s .. " (" .. q.tag .. ")" end
	return s
end

local function levelColor(level)
	local fn = GetQuestDifficultyColor or GetCreatureDifficultyColor
	local c = fn and try(fn, level)
	if type(c) == "table" and c.r then return c.r, c.g, c.b end
	return 1, 0.82, 0
end

local function hex(c)
	return string.format("%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255)
end

-- 12345 -> "12,345" (separator from the locale)
local function groupDigits(n)
	local s = tostring(math.floor(n + 0.5))
	local sign, digits = s:match("^(-?)(%d+)$")
	if not digits then return s end
	local sep = L["thousands"]
	local out = digits:reverse():gsub("(%d%d%d)", "%1" .. sep):reverse()
	if out:sub(1, #sep) == sep then out = out:sub(#sep + 1) end
	return sign .. out
end

-- 4200 -> "4.2k", 950 -> "950"
local function shortNum(n)
	local suffix, v = "", n
	if n >= 999950 then
		suffix, v = "M", n / 1000000
	elseif n >= 100000 then
		return groupDigits(n / 1000) .. "k"
	elseif n >= 1000 then
		suffix, v = "k", n / 1000
	else
		return groupDigits(n)
	end
	local s = string.format("%.1f", v):gsub("%.0$", "")
	s = s:gsub("%.", L["decimal"])
	return s .. suffix
end

-- "~6 min · 4.2k XP/h · 120 yd" from a plan entry; nil when nothing is known
local parts = {}
local function estimateString(e)
	wipe(parts)
	local m = num(e.minutes)
	if m and m > 0 and m < 100000 then
		if m < 1 then
			parts[#parts + 1] = "<1 min"
		elseif m < 60 then
			parts[#parts + 1] = "~" .. math.floor(m + 0.5) .. " min"
		else
			local r = math.floor(m + 0.5)
			parts[#parts + 1] = "~" .. string.format(L["%dh%02d"], math.floor(r / 60), r % 60)
		end
	end
	local xph = num(e.xpPerHour)
	if xph and xph > 0 and xph < 1e9 then
		parts[#parts + 1] = string.format(L["%s XP/h"], shortNum(xph))
	end
	local d = num(e.distance)
	if d and d >= 0 and d < 1e6 then
		parts[#parts + 1] = groupDigits(d) .. " yd"
	end
	if #parts == 0 then return end
	return table.concat(parts, " · ")
end

-- One text line under a quest; returns the new y.
local lineCount = 0
local lineQuest -- quest the next lines belong to
local extraIndent = 0 -- quests under an epic header sit one level deeper
local function placeLine(self, y, inner, size, text, color, have, need, pct)
	lineCount = lineCount + 1
	local o = self:LineRow(lineCount)
	o.questID, o.logIndex, o.questTitle = lineQuest and lineQuest.id, lineQuest and lineQuest.index, lineQuest and lineQuest.title
	setFont(o.text, size)
	local w = inner - INDENT - extraIndent
	o.text:SetWidth(w)
	o.text:SetText(text)
	o.text:SetTextColor(color[1], color[2], color[3])
	local h = o.text:GetStringHeight() or size
	local barH = 0
	if pct then
		o.bar:SetMinMaxValues(0, 100)
		o.bar:SetValue(math.max(0, math.min(100, pct)))
		barH = BAR + 2
	elseif have and need and need > 1 then
		o.bar:SetMinMaxValues(0, need)
		o.bar:SetValue(math.max(0, math.min(need, have)))
		barH = BAR + 2
	end
	if barH > 0 then
		local done = color == GREEN
		local c = done and GREEN or S.colors.accent
		o.bar:SetStatusBarColor(c[1], c[2], c[3])
		o.bar:Show()
	else
		o.bar:Hide()
	end
	o:ClearAllPoints()
	o:SetPoint("TOPLEFT", self.content, "TOPLEFT", PAD + INDENT + extraIndent, y - self.y0)
	o:SetSize(w, h + barH)
	o:Show()
	return y - (h + barH + GAP)
end

function Q:Render(total, tracked)
	local cfg = RoA.char.quests
	local p = self.panel
	local size = num(cfg.fontSize, 12)
	local width = num(cfg.width, 260)
	local maxQ = num(cfg.maxQuests, 12)
	local inner = width - PAD * 2
	cfg.collapsed = cfg.collapsed or {}
	p:SetWidth(width)

	local h = self.header
	setFont(h.text, size)
	setFont(h.mark, size)
	h.text:SetText(L["Quests"] .. "  " .. tracked .. "/" .. total)
	h.mark:SetText(cfg.allCollapsed and "+" or "-")
	h:SetHeight(size + 4)
	local mode = cfg.sortMode or "smart"
	local mb = self.modeButton
	setFont(mb.text, math.max(8, size - 2))
	mb.text:SetText("· " .. L[MODE_NAMES[mode] or MODE_NAMES.smart])
	mb:SetSize((mb.text:GetStringWidth() or 40) + 4, size + 4)
	local stb = self.strategyButton
	local P = RoA.QuestPlan
	if stb and mode == "smart" and P and P.Strategy then
		setFont(stb.text, math.max(8, size - 2))
		stb.text:SetText("· " .. L[STRATEGY_NAMES[P:Strategy()] or "Balanced"])
		stb:SetSize((stb.text:GetStringWidth() or 40) + 4, size + 4)
		stb:Show()
	elseif stb then
		stb:Hide()
	end
	local small = math.max(8, size - 2)
	local y = -PAD - (size + 6)
	-- optional add-on hooks: board icon in the header, sprint line under it
	local bb = self.boardButton
	if bb then
		local pr = provider()
		bb:SetShown(pr ~= nil and type(pr.ToggleBoard) == "function")
	end
	-- keep the sort / strategy labels clear of the header icons (truncate with "...")
	local icons = 26 + (h.mark:GetStringWidth() or 8) + ((bb and bb:IsShown()) and 18 or 0)
	local room = inner - (h.text:GetStringWidth() or 60) - 4 - icons
	for _, btn in ipairs({ mb, stb }) do
		if btn and btn:IsShown() then
			local fs = btn.text
			local w = ((fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth()) or fs:GetStringWidth() or 40) + 4
			if w > room then w = math.max(room, 12) end
			btn.text:SetWordWrap(false)
			btn.text:SetWidth(w - 4)
			btn:SetWidth(w)
			room = room - w - 2
		end
	end
	local sl = self.sprintLine
	if sl then
		local line = ask("SprintLine")
		if type(line) == "string" and line ~= "" then
			setFont(sl.text, small)
			sl.text:SetText(line)
			sl:ClearAllPoints()
			sl:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, y + 2)
			sl:SetSize(inner, small + 2)
			sl.text:SetWidth(inner)
			sl:Show()
			y = y - (small + 4)
		else
			sl:Hide()
		end
	end
	self.y0 = y
	local content = self.content

	local smart = mode == "smart" and self.usingPlan
	local accentHex = hex(S.colors.accent)
	self.nextBar:Hide()

	local ti, ei
	ti, ei, lineCount = 0, 0, 0
	local groups = self.groups
	local text = S.colors.text

	local function renderQuest(q)
		local plan = q.plan
		local top = y
		ti = ti + 1
		local t = self:TitleRow(ti)
		setFont(t.text, size)
		setFont(t.mark, size)
		setFont(t.tag, small)
		t.questID, t.logIndex, t.questTitle = q.id, q.index, q.title
		lineQuest = q
		local rank = smart and plan and num(plan.rank)
		local s = titleString(q)
		if rank then s = "|cff" .. accentHex .. rank .. ".|r " .. s end
		if provider() then
			local marker = ask("PriorityMarker", q.id)
			if type(marker) == "string" then s = marker .. s end
			if num(ask("SharedWith", q.id)) then s = s .. " |cff" .. accentHex .. "&|r" end -- shares mobs with a neighbour
		end
		if self.selected == q.id then s = "|cff" .. accentHex .. ">|r " .. s end
		t.text:SetText(s)
		t.text:SetTextColor(levelColor(q.level))
		local skip = plan and Safe(plan.skip, nil)
		t.skip = SKIP[skip] and skip or nil
		t.timed = RoA:QuestTimeLeft(q.id) and q.id or nil
		if t.timed then
			Q:PaintTimer(t)
		elseif t.skip then
			t.tag:SetText(L[SKIP[t.skip][1]])
			local c = t.skip == "red" and ORANGE or S.colors.muted
			t.tag:SetTextColor(c[1], c[2], c[3])
		else
			t.tag:SetText("")
		end
		local collapsed = cfg.collapsed[q.id]
		t.mark:SetText(collapsed and "+" or "")
		t:ClearAllPoints()
		t:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + extraIndent, y - self.y0)
		t:SetSize(inner - extraIndent, size + 4)
		t:Show()
		y = y - (size + 4)

		if not collapsed and plan and cfg.showEstimates then
			local est = estimateString(plan)
			if est then y = placeLine(self, y, inner, small, est, S.colors.muted) end
		end

		if not collapsed then
			if q.failed then
				y = placeLine(self, y, inner, size, L["Failed"], RED)
			elseif q.complete then
				y = placeLine(self, y, inner, size, L["Ready to turn in"], GREEN)
			else
				for oi = 1, q.numObj do
					local o = q.objectives[oi]
					if not (o.done and cfg.hideDone) and o.text ~= "" then
						local ot = (groups and o.done) and (CHECK .. o.text) or o.text
						y = placeLine(self, y, inner, size, ot, o.done and GREEN or text, o.have, o.need, o.pct)
					end
				end
			end
		end
		-- the next stop of the smart route gets an accent bar on the left
		if smart and q == list[1] then
			local bar = self.nextBar
			bar:ClearAllPoints()
			bar:SetPoint("TOPLEFT", content, "TOPLEFT", PAD - 4 + extraIndent, top - self.y0)
			bar:SetHeight(math.max(1, top - y - GAP))
			bar:Show()
		end
		y = y - GAP * 2
	end

	local function renderEpic(g)
		ei = ei + 1
		local r = self:EpicRow(ei)
		r.group = g
		local e = g.epic or {}
		setFont(r.text, size)
		setFont(r.count, small)
		local folded = groupFolded(g)
		r.chev:SetTexture(folded and "Interface\Buttons\UI-PlusButton-Up" or "Interface\Buttons\UI-MinusButton-Up")
		local c = type(e.color) == "table" and e.color or S.colors.muted
		local name = str(e.name) or "?"
		local tag = str(e.tag)
		r.text:SetText(tag and (name .. " |cff999999" .. tag .. "|r") or name)
		r.text:SetTextColor(num(c[1], 1), num(c[2], 1), num(c[3], 1))
		local done, total = num(e.done), num(e.total)
		if g.loose then
			r.count:SetText(#g.quests)
			r.bar:SetWidth(1)
			r.bar:Hide()
		elseif done and total and total > 0 then
			r.count:SetText(done .. "/" .. total)
			r.bar:SetWidth(math.min(70, math.floor(inner * 0.25)))
			r.bar:SetMinMaxValues(0, total)
			r.bar:SetValue(math.max(0, math.min(total, done)))
			r.bar:SetStatusBarColor(num(c[1], 1), num(c[2], 1), num(c[3], 1))
			r.bar:Show()
		else
			r.count:SetText("")
			r.bar:SetWidth(1)
			r.bar:Hide()
		end
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y - self.y0)
		r:SetSize(inner, size + 4)
		r:Show()
		y = y - (size + 4 + GAP)
		return folded
	end

	if not cfg.allCollapsed then
		if groups then
			for _, g in ipairs(groups) do
				local folded = false
				extraIndent = 0
				if not g.noHeader then
					folded = renderEpic(g)
					extraIndent = INDENT
				end
				if not folded then
					for _, q in ipairs(g.quests) do renderQuest(q) end
				end
			end
			extraIndent = 0
		else
			for qi = 1, math.min(#list, maxQ) do renderQuest(list[qi]) end
		end
	end

	for i = ti + 1, #titles do titles[i]:Hide() end
	for i = lineCount + 1, #lines do lines[i]:Hide() end
	for i = ei + 1, #epicRows do epicRows[i]:Hide() end

	-- fit on screen: the list scrolls when it would run off the bottom
	local contentH = math.max(1, self.y0 - y - GAP * 2)
	local full = -self.y0 + contentH + PAD
	local top = p:GetTop()
	local room = top and (top - 10) or full
	local height = math.min(full, math.max(room, -self.y0 + PAD + 20))
	local sc = self.scroll
	content:SetSize(width, contentH)
	sc:ClearAllPoints()
	sc:SetPoint("TOPLEFT", p, "TOPLEFT", 0, self.y0)
	sc:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", 0, PAD)
	p:SetHeight(height)
	local max = math.max(0, contentH - (height + self.y0 - PAD))
	if (sc:GetVerticalScroll() or 0) > max then sc:SetVerticalScroll(max) end
	sc:EnableMouseWheel(max > 0) -- otherwise the wheel keeps zooming the camera
	if sc.UpdateScrollChildRect then sc:UpdateScrollChildRect() end
	self:UpdateScrollbar()
	-- old saved positions were anchored by their centre: switch to the top edge once
	local pt = RoA.char.points.quests
	if pt and pt[1] ~= "TOPLEFT" and pt[1] ~= "TOPRIGHT" then S:AnchorTop(p, "quests") end
end

---------------------------------------------------------------------------
-- Hiding Blizzard's and Questie's trackers. Only Hide() on show: re-parenting
-- the tracker taints Edit Mode's frame layout (blocked actions).
---------------------------------------------------------------------------
local function keepHidden(frame)
	if not frame or not frame.Hide then return end
	if not frame.ckQuestHidden then
		frame.ckQuestHidden = true
		frame:HookScript("OnShow", function(f)
			if f.ckQuestHidden then RoA.HideBlizzardFrame(f) end
		end)
	end
	RoA.HideBlizzardFrame(frame)
end

local BLIZZARD = { "ObjectiveTrackerFrame", "QuestWatchFrame", "WatchFrame" }
local QUESTIE = { "Questie_BaseFrame" }

function Q:ApplyHiding()
	local cfg = RoA.char.quests
	local wantBlizz = cfg.enabled and cfg.hideBlizzard
	local wantQuestie = cfg.enabled and cfg.hideQuestieTracker
	-- turned off after hiding: Blizzard/Questie must rebuild their own frames
	if (self.hidBlizzard and not wantBlizz) or (self.hidQuestie and not wantQuestie) then
		if not self.askedReload then
			self.askedReload = true
			RoA:Print(L["Type /reload to bring back the other quest trackers."])
		end
		return
	end
	if not (wantBlizz or wantQuestie) then return end
	RoA:OutOfCombat("quests-hide", function()
		guard(function()
			if wantBlizz then
				for _, name in ipairs(BLIZZARD) do
					if _G[name] then
						keepHidden(_G[name])
						self.hidBlizzard = true
					end
				end
			end
			if wantQuestie then
				for _, name in ipairs(QUESTIE) do
					if _G[name] then
						keepHidden(_G[name])
						self.hidQuestie = true
					end
				end
			end
		end)
	end)
end

-- Questie builds its tracker some seconds after login; check until found.
function Q:QuestieMissing()
	local cfg = RoA.char.quests
	if not (cfg.enabled and cfg.hideQuestieTracker) then return false end
	for _, name in ipairs(QUESTIE) do
		local f = _G[name]
		if f and not f.ckQuestHidden then return true end
	end
	return false
end

---------------------------------------------------------------------------
-- Updates
---------------------------------------------------------------------------
-- "4:30" in orange, red in the last minute; ticks every second (see OnEnable)
function Q:PaintTimer(t)
	local left = RoA:QuestTimeLeft(t.timed)
	if not left then
		t.timed = nil
		t.tag:SetText("")
		return Q:Redraw()
	end
	local m, s = math.floor(left / 60), math.floor(left % 60)
	t.tag:SetText(m >= 60 and ("%d:%02d:%02d"):format(m / 60, m % 60, s) or ("%d:%02d"):format(m, s))
	local c = left < 60 and RED or ORANGE
	t.tag:SetTextColor(c[1], c[2], c[3])
end

function Q:Redraw()
	if not self.panel then return end
	local cfg = RoA.char.quests
	if not cfg.enabled then
		self.panel:Hide()
		guard(self.UpdateArrow, self)
		return
	end
	guard(function()
		local total, tracked = self:Collect()
		self:Render(total, tracked)
		self.panel:Show()
	end)
	guard(self.UpdateArrow, self)
	guard(self.UpdateItems, self)
	if self:QuestieMissing() then self:ApplyHiding() end
end

-- At most one redraw every 0.2 s.
function Q:Schedule()
	if self.pending then return end
	self.pending = true
	if C_Timer and C_Timer.After then
		C_Timer.After(0.2, function()
			self.pending = false
			self:Redraw()
		end)
	else
		self.pending = false
		self:Redraw()
	end
end

function Q:Refresh()
	if not self.panel then return end
	S:ApplyPoint(self.panel, "quests")
	self:ApplyHiding()
	self:Redraw()
end

---------------------------------------------------------------------------
-- Quest item buttons ("fill the vial" etc.): secure buttons left of the list.
-- Placed on UIParent at a fixed spot and only changed out of combat.
---------------------------------------------------------------------------
local itemButtons, itemHolder = {}, nil
local MAX_ITEMS, ITEM_SIZE = 8, 30

local function itemButton(i)
	local b = itemButtons[i]
	if b then return b end
	b = CreateFrame("Button", "RoadsOfAzerothQuestItem" .. i, itemHolder, "SecureActionButtonTemplate")
	b:SetSize(ITEM_SIZE, ITEM_SIZE)
	b:RegisterForClicks("AnyUp", "AnyDown")
	b:SetAttribute("type", "item")
	S:Backdrop(b)
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetPoint("TOPLEFT", 1, -1)
	b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
	b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
	b.cd:SetAllPoints(b.icon)
	b.count = S:Font(b, 10)
	b.count:SetPoint("BOTTOMRIGHT", -2, 2)
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(b.icon)
	hl:SetColorTexture(1, 1, 1, 0.15)
	b:SetScript("OnEnter", function(self)
		guard(function()
			if not (GameTooltip and self.link) then return end
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			GameTooltip:SetHyperlink(self.link)
			if self.questTitle then GameTooltip:AddLine(self.questTitle, 1, 0.82, 0) end
			GameTooltip:Show()
		end)
	end)
	b:SetScript("OnLeave", function(self)
		guard(function()
			if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
		end)
	end)
	itemButtons[i] = b
	return b
end

-- Quests with a usable item, in the order of the list.
local function questItems()
	local out = {}
	if not GetQuestLogSpecialItemInfo then return out end
	local function add(index, id, title, complete)
		if #out >= MAX_ITEMS or not index then return end
		local ok, link, tex, charges, showComplete = pcall(GetQuestLogSpecialItemInfo, index)
		if not ok then return end
		link, tex = str(link), Safe(tex, nil)
		if not link or not tex then return end
		if complete and not flag(showComplete) then return end
		for _, o in ipairs(out) do if o.link == link then return end end
		out[#out + 1] = { link = link, tex = tex, charges = num(charges, 0), index = index, title = title }
	end
	for _, q in ipairs(list) do add(q.index, q.id, q.title, q.complete) end
	-- also quests not shown in the list (folded away or over the limit)
	local n = logCounts()
	for i = 1, n do
		local e = readEntry(i)
		if e and not e.isHeader then add(i, e.questID, e.title, false) end
	end
	return out
end

function Q:UpdateItems()
	RoA:OutOfCombat("quest-items", function()
		guard(function()
			if not itemHolder then
				itemHolder = CreateFrame("Frame", "RoadsOfAzerothQuestItems", UIParent)
				itemHolder:SetSize(ITEM_SIZE, ITEM_SIZE)
			end
			local p = self.panel
			local show = p and p:IsShown() and RoA.char.quests.enabled and RoA.char.quests.questItems ~= false
			local items = show and questItems() or {}
			-- holder sits left of the list's top, fixed on the screen (not anchored to the list)
			local left, top = p and p:GetLeft(), p and p:GetTop()
			if left and top then
				local s = p:GetEffectiveScale() / UIParent:GetEffectiveScale()
				itemHolder:ClearAllPoints()
				itemHolder:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", left * s - 4, top * s)
			end
			for i = 1, math.max(#items, #itemButtons) do
				local it = items[i]
				if it then
					local b = itemButton(i)
					b:SetAttribute("item", it.link)
					b.link, b.questTitle, b.logIndex = it.link, it.title, it.index
					b.icon:SetTexture(it.tex)
					b.count:SetText(it.charges > 1 and it.charges or "")
					b:ClearAllPoints()
					b:SetPoint("TOPRIGHT", itemHolder, "TOPRIGHT", 0, -(i - 1) * (ITEM_SIZE + 3))
					b:Show()
				elseif itemButtons[i] then
					itemButtons[i]:Hide()
					itemButtons[i]:SetAttribute("item", nil)
					itemButtons[i].link = nil
				end
			end
			self:UpdateItemCooldowns()
		end)
	end)
end

function Q:UpdateItemCooldowns()
	if not GetQuestLogSpecialItemCooldown then return end
	for _, b in ipairs(itemButtons) do
		if b:IsShown() and b.logIndex then
			local start, dur, enable = try(GetQuestLogSpecialItemCooldown, b.logIndex)
			start, dur = num(start), num(dur)
			if start and dur and dur > 0 and Safe(enable, 1) ~= 0 then
				b.cd:SetCooldown(start, dur)
			else
				b.cd:Clear()
			end
		end
	end
end

function Q:OnEnable()
	local cfg = RoA.char.quests
	-- quest timers count down in the list
	local timerTick = CreateFrame("Frame")
	local wait = 0
	timerTick:SetScript("OnUpdate", function(_, elapsed)
		wait = wait - elapsed
		if wait > 0 then return end
		wait = 1
		for _, t in ipairs(titles) do
			if t.timed and t:IsShown() then guard(Q.PaintTimer, Q, t) end
		end
	end)
	if not cfg.arrowDefaultOn then
		cfg.arrow, cfg.arrowDefaultOn = true, true
	end
	self:CreatePanel()
	local function update(event, unit)
		if event == "UNIT_QUEST_LOG_CHANGED" and Safe(unit, nil) ~= "player" then return end
		guard(self.Schedule, self)
	end
	for _, ev in ipairs({ "QUEST_LOG_UPDATE", "QUEST_WATCH_LIST_CHANGED", "UNIT_QUEST_LOG_CHANGED",
		"ZONE_CHANGED_NEW_AREA", "QUEST_TURNED_IN", "PLAYER_ENTERING_WORLD" }) do
		guard(RoA.On, RoA, ev, update)
	end
	RoA:On("ADDON_LOADED", function(_, name)
		if name == "Blizzard_ObjectiveTracker" or name == "Questie" then guard(self.ApplyHiding, self) end
	end)
	RoA:Listen("SETTINGS", function(group)
		if group == "quests" then guard(self.Refresh, self) end
	end)
	-- the route changed (ignored while we are asking the plan ourselves: no redraw loops)
	RoA:Listen("QUESTPLAN", function()
		if not self.inPlan then guard(self.Schedule, self) end
	end)
	-- an optional epic provider (add-on) changed its data
	RoA:Listen("EPICS", function() guard(self.Schedule, self) end)
	-- arrived at the arrow's target: point at the plan's next stop when it changed
	RoA:On("BAG_UPDATE_COOLDOWN", function() guard(self.UpdateItemCooldowns, self) end)
	RoA:On("PLAYER_REGEN_ENABLED", function() guard(self.UpdateItems, self) end)
	RoA:Listen("ARROW_ARRIVED", function()
		self.manualArrow = false
		self.selected = nil
		guard(self.Schedule, self)
	end)
	-- the navigation route changed: drop the selection mark when its stop is gone
	RoA:Listen("NAV", function()
		local N = nav()
		if N and self.selected and not (N.HasOverride and N:HasOverride()) then
			self.selected, self.manualArrow = nil, false
			guard(self.Schedule, self)
		end
	end)
	self:Refresh()
end
