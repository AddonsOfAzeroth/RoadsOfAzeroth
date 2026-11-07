-- Roads of Azeroth by DinX: public API for other add-ons (Scrum of Azeroth uses it).
-- Plain functions: RoadsOfAzeroth.API.Fn(...). Callbacks (CallbackHandler):
--   ROA_ROUTE_CHANGED       the smart route was replanned
--   ROA_ROUTE_RECALCULATED  "Recalculate route" (a new start; Scrum starts a new sprint)
local _, ns = ...
local RoA = ns.RoA

local API = { version = 1 }
RoA.API = API

local CBH = LibStub and LibStub("CallbackHandler-1.0", true)
local registry = CBH and CBH:New(API)

local function QP() return RoA.QuestPlan end

-- array of { questID, xp, distance, minutes, rank, zoneMatch } in route order
function API.GetRoutePlan() return QP():Get("smart") end
function API.IsRouteLocked() return QP():IsLocked() end
function API.GetFrozenRoute() return QP():GetFrozenRoute() end
function API.SetFrozenRoute(keys) QP():SetFrozenRoute(keys) end
function API.Recalculate() QP():Recalculate() end
function API.RequestReplan() QP():Request() end
function API.LockRoute()
	RoA.char.quests.lockRoute = true
	RoA:Fire("SETTINGS", "quests")
	QP():Recalculate()
end

function API.GetRouteStrategies() return QP().STRATEGIES end
function API.GetRouteStrategy() return QP():Strategy() end
function API.SetRouteStrategy(key) return QP():SetStrategy(key) end

-- tracker
function API.HasTracker() return RoA.char.quests.enabled ~= false end
function API.SelectQuest(id, title) RoA.Quests:ClickQuest(id, title) return true end
function API.SelectedQuest() return RoA.Quests.selected end
function API.OpenQuest(id, index) RoA.Quests:OpenQuest(id, index) return true end

-- GPS / arrow. stop = { questID, title } or { mapID, x, y, title }
function API.AddStop(stop)
	if type(stop) ~= "table" then return false end
	if stop.questID then return RoA.Nav:AddQuest(stop.questID, stop.title) end
	return RoA.Nav:Add(stop.mapID, stop.x, stop.y, stop.title, "quest")
end
function API.PointTo(m, x, y, title)
	if RoA.Nav:OwnsArrow() and RoA.Nav:SetOverride(m, x, y, title, "quest") then return true end
	return RoA.Arrow:SetTarget(m, x, y, title)
end
function API.ClearRoute() RoA.Nav:Clear() end

-- epic groups, sprint line and priority markers in the tracker (Scrum of Azeroth)
function API.RegisterEpicProvider(p)
	RoA.EpicProvider = p
	RoA:Fire("EPICS")
	return true
end
function API.NotifyEpicsChanged() RoA:Fire("EPICS") return true end

function API.ToggleConfig() RoA:ToggleConfig() end

RoA:Listen("QUESTPLAN", function() if registry then registry:Fire("ROA_ROUTE_CHANGED") end end)
RoA:Listen("QUESTPLAN_RECALC", function() if registry then registry:Fire("ROA_ROUTE_RECALCULATED") end end)
