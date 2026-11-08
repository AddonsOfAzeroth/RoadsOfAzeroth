-- Roads of Azeroth by DinX: navigation arrow
-- The arrow logic (distance, direction, arrival) runs on its own driver frame,
-- so the GPS panel (Nav.lua) can show it while this module's own frame is hidden.
-- The arrow shows the straight-line direction: there is no API for paths or terrain.
local _, ns = ...
local RoA = ns.RoA
local S = RoA.Style
local L = RoA.L

local AR = RoA:NewModule("Arrow")

local IsSecret, Safe = RoA.IsSecret, RoA.Safe
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local cos, floor, max, min = math.cos, math.floor, math.max, math.min

local ARROW_TEX = "Interface\\Minimap\\MinimapArrow"
local GREEN = { 0.35, 0.85, 0.40 }
local RED = { 0.95, 0.35, 0.30 }
local THROTTLE = 0.05 -- seconds between updates (~20 fps)
local ARRIVE_HOLD = 2 -- seconds of "Arrived" before ARROW_ARRIVED fires
local DEFAULT_SPEED = 7 -- yards per second on foot
local DEFAULT_MOUNT = 11.2 -- yards per second on a 60% mount

local frame, arrow, titleText, infoText
local driver -- invisible frame that runs the update while a target is set
local target -- { mapID, x, y, title, cont, wn, ww, arrivedAt, fired }
local acc = 0
local lastDist
local inCombat = false
local embedded = false -- true while the GPS panel shows the arrow

-- Last computed state, read by the GPS panel (do not modify from outside).
-- status: "none", "ok", "other" (other continent), "nopos" (no player position)
local state = { status = "none" }
AR.state = state

-- A plain number, or nil when missing or secret.
local function num(v)
	if v == nil or IsSecret(v) or type(v) ~= "number" then return nil end
	return v
end

---------------------------------------------------------------------------
-- Positions: world coordinates (north, west) plus continent
---------------------------------------------------------------------------
local function worldPosRaw(mapID, x, y)
	local cont, pos = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(x, y))
	if not pos then return end
	local n, w = pos:GetXY()
	cont, n, w = num(cont), num(n), num(w)
	if cont and n and w then return cont, n, w end
end

local function worldPos(mapID, x, y)
	if not (mapID and x and y and C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
	local ok, cont, n, w = pcall(worldPosRaw, mapID, x, y)
	if ok and cont then return cont, n, w end
end

-- Player's continent and world position; nil in instances or when hidden.
local function playerPosRaw()
	if C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition then
		local mapID = num(C_Map.GetBestMapForUnit("player"))
		local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
		if pos and not IsSecret(pos) then
			local x, y = pos:GetXY()
			x, y = num(x), num(y)
			if x and y and (x > 0 or y > 0) then
				local cont, n, w = worldPos(mapID, x, y)
				if cont then return cont, n, w end
			end
		end
	end
	-- fallback: raw world position (may be restricted)
	if UnitPosition then
		local ok, n, w, _, inst = pcall(UnitPosition, "player")
		if ok then
			n, w, inst = num(n), num(w), num(inst)
			if n and w and inst then return inst, n, w end
		end
	end
end

local function playerPos()
	local ok, cont, n, w = pcall(playerPosRaw)
	if ok and cont then return cont, n, w end
end

-- Shared with Nav.lua and others.
AR.WorldPos = worldPos
AR.PlayerPos = playerPos

---------------------------------------------------------------------------
-- Speed and text helpers
---------------------------------------------------------------------------
local function blend(a, b, t)
	return a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t
end

local function learned(key, lo, hi)
	local q = RoA.char and RoA.char.questLearn
	local v = q and num(q[key])
	if v and v >= lo and v <= hi then return v end
end

local function runSpeed()
	return learned("runSpeed", 3, 60) or DEFAULT_SPEED
end

local function isMounted()
	if not IsMounted then return false end
	local ok, m = pcall(IsMounted)
	return ok and not IsSecret(m) and m and true or false
end

-- Yards per second for ETAs: the current speed while moving, otherwise the
-- mounted speed (when mounted) or the learned run speed.
local function travelSpeed()
	local cur, run
	if GetUnitSpeed then
		local ok, a, b = pcall(GetUnitSpeed, "player")
		if ok then cur, run = num(a), num(b) end
	end
	if cur and cur > 0.5 then return cur end
	if isMounted() then
		if run and run > DEFAULT_SPEED + 0.5 then return run end
		return learned("mountSpeed", 8, 60) or DEFAULT_MOUNT
	end
	return runSpeed()
end

local function formatETA(sec)
	sec = floor(sec + 0.5)
	if sec >= 3600 then
		return "~" .. L["%dh%02d"]:format(floor(sec / 3600), floor(sec % 3600 / 60))
	end
	return ("~%d:%02d"):format(floor(sec / 60), sec % 60)
end

local function distText(d)
	return L["%d yd"]:format(floor(d + 0.5))
end

AR.RunSpeed = runSpeed
AR.TravelSpeed = travelSpeed
AR.IsMounted = isMounted
AR.FormatETA = formatETA
AR.DistText = distText

local function setStatus(status)
	state.status = status
	state.dist, state.rel, state.arrived = nil, nil, false
end

local function showStatus(text)
	lastDist = nil
	if not arrow then return end
	arrow:Hide()
	infoText:SetTextColor(unpack(S.colors.muted))
	infoText:SetText(text)
end

---------------------------------------------------------------------------
-- Update (runs throttled, only while a target is set)
---------------------------------------------------------------------------
local function update()
	local t = target
	if not t then return setStatus("none") end
	if not t.cont then t.cont, t.wn, t.ww = worldPos(t.mapID, t.x, t.y) end
	local cont, pn, pw = playerPos()
	if not cont or not t.cont then
		t.arrivedAt = nil
		setStatus("nopos")
		return showStatus(not cont and L["No position here"] or L["Other zone"])
	end
	if cont ~= t.cont then
		t.arrivedAt = nil
		setStatus("other")
		return showStatus(L["Other continent"])
	end

	local dn, dw = t.wn - pn, t.ww - pw
	local dist = (dn * dn + dw * dw) ^ 0.5
	lastDist = dist

	local arrive = num(RoA.char.arrow.arriveYards) or 15
	local arrived = dist <= arrive
	state.status, state.dist, state.arrived = "ok", dist, arrived

	-- learned paths (Trails.lua): steer along walked paths when that is shorter
	local sn, sw, pathLen
	if not arrived and RoA.Trails and RoA.Trails.Steer then
		sn, sw, pathLen = RoA.Trails:Steer(cont, pn, pw, t.wn, t.ww)
	end
	state.via = sn ~= nil
	local an, aw = dn, dw
	if sn then an, aw = sn - pn, sw - pw end

	-- rotation: 0 = north, counter-clockwise, same as GetPlayerFacing()
	local facing = GetPlayerFacing and num(GetPlayerFacing())
	local r, g, b = unpack(S.colors.accent)
	if facing then
		local rel = atan2(aw, an) - facing
		state.rel = rel
		local dot = cos(rel) -- 1 = straight ahead, -1 = behind
		if arrived then
			r, g, b = unpack(GREEN)
		elseif dot > 0 then
			r, g, b = blend(S.colors.accent, GREEN, dot * dot * 0.55)
		else
			r, g, b = blend(S.colors.accent, RED, dot * dot * 0.55)
		end
	else
		state.rel = nil
	end
	state.r, state.g, state.b = r, g, b

	if arrow then
		if state.rel then
			arrow:SetRotation(state.rel)
			arrow:SetVertexColor(r, g, b, 1)
			arrow:Show()
		else
			arrow:Hide()
		end
	end

	if arrived then
		local now = GetTime()
		t.arrivedAt = t.arrivedAt or now
		if infoText then
			infoText:SetTextColor(unpack(GREEN))
			infoText:SetText(L["Arrived"])
		end
		if not t.fired and now - t.arrivedAt >= ARRIVE_HOLD then
			t.fired = true
			local m, x, y = t.mapID, t.x, t.y
			-- fire outside the protected update so listener errors stay theirs
			C_Timer.After(0, function() RoA:Fire("ARROW_ARRIVED", m, x, y) end)
		end
	else
		t.arrivedAt = nil
		if infoText then
			infoText:SetTextColor(unpack(S.colors.muted))
			local d = pathLen or dist
			infoText:SetText(distText(d) .. "  " .. formatETA(d / travelSpeed()) .. (sn and ("  " .. L["path"]) or ""))
		end
	end
end

local function onUpdate(self, elapsed)
	acc = acc + elapsed
	if acc < THROTTLE then return end
	acc = 0
	local ok, err = pcall(update)
	if not ok then
		-- stop at the first error; never repeat it every frame
		self:SetScript("OnUpdate", nil)
		if RoA.debug then RoA:Print("Arrow:", tostring(err)) end
		geterrorhandler()(err)
	end
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
local function refresh()
	if not RoA.char then return end
	local cfg = RoA.char.arrow
	-- the driver runs while there is a target that someone shows
	if driver then
		if target and (cfg.enabled or embedded) then
			acc = THROTTLE
			driver:SetScript("OnUpdate", onUpdate)
		else
			driver:SetScript("OnUpdate", nil)
			lastDist = nil
			setStatus("none")
		end
	end
	if not frame then return end
	local scale = num(cfg.scale)
	frame:SetScale((scale and scale > 0.3 and scale < 3) and scale or 1)
	if embedded then
		frame:Hide()
	elseif cfg.enabled and target then
		titleText:SetText(target.title or L["Navigation arrow"])
		frame:Show()
	else
		-- show an empty panel while unlocked so it can be dragged
		if not RoA.char.bars.locked and not inCombat and not InCombatLockdown() then
			titleText:SetText(L["Navigation arrow"])
			infoText:SetTextColor(unpack(S.colors.muted))
			infoText:SetText("—")
			arrow:SetRotation(0)
			arrow:SetVertexColor(unpack(S.colors.accent))
			arrow:Show()
			frame:Show()
		else
			frame:Hide()
		end
	end
end

local function build()
	if frame or not RoA.char then return end
	driver = driver or CreateFrame("Frame")

	frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	frame:SetSize(186, 52)
	frame:SetFrameStrata("MEDIUM")
	S:Backdrop(frame, 0.55)
	frame:Hide()

	arrow = frame:CreateTexture(nil, "ARTWORK")
	arrow:SetSize(42, 42)
	arrow:SetPoint("LEFT", 5, 0)
	arrow:SetTexture(ARROW_TEX)
	arrow:SetDesaturated(true)
	arrow:SetVertexColor(unpack(S.colors.accent))

	titleText = S:Font(frame, 12)
	titleText:SetPoint("TOPLEFT", arrow, "TOPRIGHT", 4, -4)
	titleText:SetPoint("RIGHT", frame, "RIGHT", -6, 0)
	titleText:SetJustifyH("LEFT")
	titleText:SetWordWrap(false)
	if titleText.SetMaxLines then titleText:SetMaxLines(1) end

	infoText = S:Font(frame, 11)
	infoText:SetPoint("BOTTOMLEFT", arrow, "BOTTOMRIGHT", 4, 5)
	infoText:SetPoint("RIGHT", frame, "RIGHT", -6, 0)
	infoText:SetJustifyH("LEFT")
	infoText:SetWordWrap(false)
	infoText:SetTextColor(unpack(S.colors.muted))

	frame:EnableMouse(true)
	-- navigation on: right-click skips the stop (clearing would be re-set by the route)
	local function navOwns()
		local N = RoA.Nav
		if not (N and N.OwnsArrow and N.Skip) then return end
		local ok, owns = pcall(N.OwnsArrow, N)
		if ok and owns then return N end
	end
	frame:SetScript("OnMouseUp", function(_, button)
		if button ~= "RightButton" then return end
		local N = navOwns()
		if N then pcall(N.Skip, N) else AR:Clear() end
	end)
	frame:SetScript("OnEnter", function(self)
		if not target then return end
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine(target.title or L["Navigation arrow"], 1, 1, 1)
		GameTooltip:AddLine(lastDist and distText(lastDist) or L["Other zone"], unpack(S.colors.text))
		GameTooltip:AddLine(L["The arrow shows the straight-line direction, not a path around hills or water."], 0.6, 0.65, 0.71, true)
		GameTooltip:AddLine(navOwns() and L["Right-click to skip this stop"] or L["Right-click to clear"], unpack(S.colors.muted))
		GameTooltip:Show()
	end)
	frame:SetScript("OnLeave", function() GameTooltip:Hide() end)

	S:RegisterMover(frame, "arrow", L["Navigation arrow"], function(f)
		f:SetPoint("RIGHT", UIParent, "RIGHT", -260, 120)
	end)
	refresh()
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
-- x, y normalized 0..1 on mapID.
function AR:SetTarget(mapID, x, y, title)
	mapID, x, y = num(mapID), num(x), num(y)
	if not mapID or not x or not y then return end
	-- tolerate 0..100 coordinates
	if x > 1 or y > 1 then x, y = x / 100, y / 100 end
	x, y = max(0, min(1, x)), max(0, min(1, y))
	if type(title) ~= "string" or IsSecret(title) then title = nil end
	target = { mapID = mapID, x = x, y = y, title = title }
	target.cont, target.wn, target.ww = worldPos(mapID, x, y)
	if RoA.debug then
		RoA:Print(("Arrow: %d %.3f %.3f %s"):format(mapID, x, y, title or ""))
	end
	build()
	refresh()
	RoA:Fire("ARROW_TARGET")
end

function AR:Clear()
	target = nil
	lastDist = nil
	setStatus("none")
	if frame and GameTooltip:GetOwner() == frame then GameTooltip:Hide() end
	refresh()
	RoA:Fire("ARROW_TARGET")
end

function AR:GetTarget()
	if not target then return nil end
	return target.mapID, target.x, target.y, target.title
end

-- Last computed state: status, distance (yd), relative angle (radians or nil),
-- arrived, colour. Valid while a target is set and someone shows the arrow.
function AR:GetState()
	return state.status, state.dist, state.rel, state.arrived, state.r, state.g, state.b
end

-- The GPS panel shows the arrow: hide this module's own frame but keep the
-- arrival logic running.
function AR:SetEmbedded(on)
	on = on and true or false
	if on == embedded then return end
	embedded = on
	refresh()
end

function AR:IsEmbedded() return embedded end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
function AR:OnInit()
	build()
end

RoA:Listen("SETTINGS", function(group)
	if group == "arrow" or group == "bars" then refresh() end
end)
RoA:On("PLAYER_REGEN_DISABLED", function() inCombat = true; refresh() end)
RoA:On("PLAYER_REGEN_ENABLED", function() inCombat = false; refresh() end)
