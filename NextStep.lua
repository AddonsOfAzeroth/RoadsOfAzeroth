-- Roads of Azeroth by DinX: the next step, in one calm line.
-- Not a full guide: one sentence about the one thing to do now. Things that
-- can't wait come first (dead, bags full, gear almost broken, new spells at
-- the trainer), then the first stop of your route (a flight, a quest
-- objective with its progress, a turn-in), else quests to pick up nearby.
-- Display only: it never moves you, clicks, accepts or turns in anything.
local _, ns = ...
local RoA = ns.RoA
local L = RoA.L
local S = RoA.Style
local Safe = RoA.Safe

local N = RoA:NewModule("NextStep")

local WIDTH, HEIGHT = 380, 26
local REPAIR_AT = 0.2 -- warn when an item is below 20% durability

local function cfg() return RoA.char.next end

local ICONS = {
	dead = "Interface\\Icons\\Ability_Rogue_FeignDeath",
	bags = "Interface\\Icons\\INV_Misc_Bag_08",
	repair = "Interface\\Icons\\Trade_BlackSmithing",
	trainer = "Interface\\Icons\\INV_Misc_Book_09",
	flight = "Interface\\Icons\\Ability_Mount_Gryphon_01",
	quest = "Interface\\GossipFrame\\AvailableQuestIcon",
	turnin = "Interface\\GossipFrame\\ActiveQuestIcon",
	custom = "Interface\\Icons\\INV_Misc_Map_01",
	pickup = "Interface\\GossipFrame\\AvailableQuestIcon",
	none = "Interface\\Icons\\INV_Misc_Map_01",
}

---------------------------------------------------------------------------
-- What is going on
---------------------------------------------------------------------------
local function freeSlots()
	local C = C_Container
	local free = (C and C.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
	if not free then return nil end
	local n, total = 0, 0
	for bag = 0, tonumber(NUM_BAG_SLOTS) or 4 do
		local ok, f, family = pcall(free, bag)
		if ok and tonumber(f) and (family == 0 or family == nil) then n = n + f total = total + 1 end
	end
	return total > 0 and n or nil
end

local function lowestDurability()
	if not GetInventoryItemDurability then return nil end
	local low
	for slot = 1, 18 do
		local ok, cur, max = pcall(GetInventoryItemDurability, slot)
		cur, max = ok and Safe(cur, nil), ok and Safe(max, nil)
		if cur and max and max > 0 then
			local r = cur / max
			if not low or r < low then low = r end
		end
	end
	return low
end

local function objectiveText(questID)
	if not (questID and C_QuestLog and C_QuestLog.GetQuestObjectives) then return nil end
	local ok, list = pcall(C_QuestLog.GetQuestObjectives, questID)
	if not (ok and type(list) == "table") then return nil end
	for _, o in ipairs(list) do
		if type(o) == "table" and not o.finished and type(o.text) == "string" and o.text ~= "" then return o.text end
	end
end

local function distanceText(e)
	local yd = e and tonumber(e.cum)
	if not yd then return "" end
	local t = tonumber(e.cumTime)
	local parts = { ("%d yd"):format(math.floor(yd + 0.5)) }
	if t and t >= 60 then parts[#parts + 1] = L["%d min"]:format(math.floor(t / 60 + 0.5)) end
	return "  |cff9aa3ad" .. table.concat(parts, " · ") .. "|r"
end

-- the next step: kind, text, and what a click does
function N:Step()
	if UnitIsDeadOrGhost and Safe(UnitIsDeadOrGhost("player"), false) then
		return "dead", L["Run back to your corpse."]
	end
	local free = freeSlots()
	if free == 0 then
		return "bags", L["Your bags are full: sell your greys or mail things away."]
	end
	local low = lowestDurability()
	if low and low < REPAIR_AT then
		return "repair", L["Your gear is at %d%%: repair at the next vendor."]:format(math.floor(low * 100 + 0.5))
	end
	local c = cfg()
	local level = Safe(UnitLevel("player"), nil)
	if c.trainLevel and level and c.trainLevel <= level then
		return "trainer", L["Level %d: new spells may wait at your class trainer."]:format(c.trainLevel)
	end
	local nav = RoA.Nav
	local route = nav and nav.GetRoute and nav:GetRoute()
	local e = type(route) == "table" and route[1] or nil
	if e then
		local dist = distanceText(e)
		if e.kind == "corpse" then return "dead", L["Run back to your corpse."] .. dist, e end
		if e.kind == "flight" then
			return "flight", L["Fly from %s to %s."]:format(e.fromName or "?", e.toName or "?") .. dist, e
		end
		if e.kind == "turnin" then
			return "turnin", L["Turn in: %s"]:format(e.title or "?") .. dist, e
		end
		if e.kind == "quest" then
			local obj = objectiveText(e.questID)
			local text = obj and L["%s: %s"]:format(e.title or "?", obj) or (e.title or "?")
			return "quest", text .. dist, e
		end
		return "custom", (e.title or L["Waypoint"]) .. dist, e
	end
	local P = RoA.Pickup
	if P and P.Collect then
		local ok, list = pcall(P.Collect, P)
		if ok and type(list) == "table" and #list > 0 then
			return "pickup", L["Pick up quests: %d near you (the list under your quests)."]:format(#list)
		end
	end
	return "none", L["Nothing on your route. Look for quests of your level in a nearby zone."]
end

---------------------------------------------------------------------------
-- The line
---------------------------------------------------------------------------
function N:Build()
	local f = CreateFrame("Button", "RoadsOfAzerothNextStep", UIParent, "BackdropTemplate")
	f:SetSize(WIDTH, HEIGHT)
	f:SetFrameStrata("MEDIUM")
	S:Backdrop(f, 0.8)
	f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	f.icon = f:CreateTexture(nil, "ARTWORK")
	f.icon:SetSize(16, 16)
	f.icon:SetPoint("LEFT", 6, 0)
	f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	f.text = S:Font(f, 13)
	f.text:SetPoint("LEFT", f.icon, "RIGHT", 6, 0)
	f.text:SetPoint("RIGHT", -8, 0)
	f.text:SetJustifyH("LEFT")
	f.text:SetWordWrap(false)
	f:SetScript("OnClick", function(_, btn) N:Click(btn) end)
	f:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:AddLine(L["Next step"])
		GameTooltip:AddLine(self.text:GetText() or "", 1, 1, 1, true)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(L["Click: show it (quest or map)"], 0.8, 0.8, 0.8)
		if self.stop then GameTooltip:AddLine(L["Right-click: skip this stop"], 0.8, 0.8, 0.8) end
		GameTooltip:Show()
	end)
	f:SetScript("OnLeave", function() GameTooltip:Hide() end)
	self.frame = f
	S:RegisterMover(f, "next", L["Next step"], function(fr)
		fr:SetPoint("TOP", UIParent, "TOP", 0, -110)
	end)
end

function N:Click(btn)
	local f = self.frame
	if btn == "RightButton" then
		if f.stop and RoA.Nav and RoA.Nav.Skip then RoA.Nav:Skip() end
	elseif f.kind == "trainer" then
		cfg().trainLevel = nil
	elseif f.stop and f.stop.questID and RoA.Quests and RoA.Quests.ClickQuest then
		RoA.Quests:ClickQuest(f.stop.questID, f.stop.title)
	elseif ToggleWorldMap then
		ToggleWorldMap()
	end
	self:Update()
end

function N:Update()
	local f = self.frame
	if not f then return end
	if not cfg().enabled then return f:Hide() end
	local ok, kind, text, stop = pcall(self.Step, self)
	if not ok then kind, text, stop = "none", "", nil end
	f.kind, f.stop = kind, stop
	f.icon:SetTexture(ICONS[kind] or ICONS.none)
	if f.text:GetText() ~= text then f.text:SetText(text) end
	f:Show()
end

function N:OnEnable()
	self:Build()
	RoA:On("PLAYER_LEVEL_UP", function(_, level)
		cfg().trainLevel = tonumber(Safe(level, nil)) or Safe(UnitLevel("player"), nil)
		N:Update()
	end)
	RoA:On("TRAINER_SHOW", function() cfg().trainLevel = nil N:Update() end)
	for _, e in ipairs({ "QUEST_LOG_UPDATE", "BAG_UPDATE_DELAYED", "UPDATE_INVENTORY_DURABILITY", "PLAYER_DEAD",
		"PLAYER_ALIVE", "PLAYER_UNGHOST", "ZONE_CHANGED_NEW_AREA" }) do
		RoA:On(e, function() N:Update() end)
	end
	RoA:Listen("QUESTPLAN", function() N:Update() end)
	RoA:Listen("SETTINGS", function() N:Update() end)
	-- distances change while you walk
	C_Timer.NewTicker(1, function() N:Update() end)
	self:Update()
end
