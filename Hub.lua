-- Addons of Azeroth by DinX: one minimap button for every "of Azeroth" add-on.
-- Each add-on carries this same file; whichever loads first builds the button,
-- a newer copy takes over (like LibStub). Click: a list of your add-ons
-- (click one to open it, right-click for its settings). Drag: move the button.
local VERSION = 2

local hub = _G.AddonsOfAzerothHub
if type(hub) == "table" and (hub.version or 0) >= VERSION then return end
hub = type(hub) == "table" and hub or { entries = {} }
hub.version = VERSION
hub.entries = hub.entries or {}
_G.AddonsOfAzerothHub = hub

local FLAT = "Interface\\Buttons\\WHITE8x8"
local ROW = 22

-- Dutch when Casters of Azeroth is set to it, or the game is
local function text(en, nlText)
	local c = _G.CastersOfAzeroth or _G.CasterKit
	local lang = type(c) == "table" and type(c.db) == "table" and c.db.language
	if not lang or lang == "auto" then lang = GetLocale and GetLocale() end
	return lang == "nlNL" and nlText or en
end

local function sorted()
	table.sort(hub.entries, function(a, b) return (a.title or "") < (b.title or "") end)
	return hub.entries
end

-- position and hidden: kept in the add-ons that save it (their db.minimap)
local function saved()
	for _, e in ipairs(sorted()) do
		if e.minimap then return e.minimap() end
	end
end

function hub:Angle()
	local m = saved()
	return m and m.angle or 205
end

-- hidden when any add-on's "minimap button" setting is off
function hub:Hidden()
	for _, e in ipairs(self.entries) do
		local m = e.minimap and e.minimap()
		if m and m.hide then return true end
	end
	return false
end

function hub:Save(angle, hide)
	for _, e in ipairs(self.entries) do
		local m = e.minimap and e.minimap()
		if m then
			if angle ~= nil then m.angle = angle end
			if hide ~= nil then m.hide = hide end
		end
	end
end

function hub:SetHidden(hide)
	self:Save(nil, hide and true or false)
	if self.button then self.button:SetShown(not hide) elseif not hide then self:Build() end
end

-- e: { key, addon (folder name), title, icon, click, right, shift, middle,
--      tip = function(tooltip) adds lines, minimap = function() return db.minimap end }
function hub:Register(e)
	for i, o in ipairs(self.entries) do if o.key == e.key then table.remove(self.entries, i) break end end
	local meta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
	if meta and e.addon then
		e.title = e.title or meta(e.addon, "Title")
		e.icon = e.icon or meta(e.addon, "IconTexture")
	end
	e.title = e.title or e.key
	self.entries[#self.entries + 1] = e
	if not self.button and not self:Hidden() then self:Build() end
	if self.list and self.list:IsShown() then self:Fill() end
end

---------------------------------------------------------------------------
-- The button
---------------------------------------------------------------------------
local function place(b)
	local a = math.rad(hub:Angle())
	local r = Minimap:GetWidth() / 2 + 5
	b:ClearAllPoints()
	b:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

function hub:Build()
	if self.button or not Minimap then return end
	local b = CreateFrame("Button", "AddonsOfAzerothMinimapButton", Minimap)
	self.button = b
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForClicks("AnyUp")
	b:RegisterForDrag("LeftButton")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetSize(20, 20)
	bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	bg:SetPoint("TOPLEFT", 7, -5)
	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetSize(18, 18)
	icon:SetTexture("Interface\\Icons\\INV_Misc_Book_11")
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon:SetPoint("TOPLEFT", 7, -6)
	local border = b:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetPoint("TOPLEFT")
	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local cx, cy = GetCursorPosition()
			local s = Minimap:GetEffectiveScale()
			hub:Save(math.deg(math.atan2(cy / s - my, cx / s - mx)))
			place(self)
		end)
	end)
	b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	b:SetScript("OnClick", function() hub:Toggle() end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Addons of Azeroth")
		GameTooltip:AddLine(text("Click: your add-ons", "Klik: je add-ons"), 1, 1, 1)
		GameTooltip:AddLine(text("Drag: move this button", "Slepen: dit knopje verplaatsen"), 0.6, 0.65, 0.71)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	place(b)
	b:SetShown(not self:Hidden())
end

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------
function hub:Fill()
	local f = self.list
	local entries = sorted()
	for i, e in ipairs(entries) do
		local r = f.rows[i]
		if not r then
			r = CreateFrame("Button", nil, f)
			r:SetHeight(ROW)
			r:SetPoint("TOPLEFT", 4, -24 - (i - 1) * ROW)
			r:SetPoint("TOPRIGHT", -4, -24 - (i - 1) * ROW)
			r:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
			r.hl = r:CreateTexture(nil, "BACKGROUND")
			r.hl:SetAllPoints()
			r.hl:SetColorTexture(0.41, 0.80, 0.94, 0.18)
			r.hl:Hide()
			r.icon = r:CreateTexture(nil, "ARTWORK")
			r.icon:SetSize(16, 16)
			r.icon:SetPoint("LEFT", 4, 0)
			r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
			r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			r.text:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
			r.text:SetJustifyH("LEFT")
			r:SetScript("OnEnter", function(self)
				self.hl:Show()
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:AddLine(self.e.title)
				if self.e.tip then
					pcall(self.e.tip, GameTooltip)
				else
					GameTooltip:AddLine(text("Click: open", "Klik: openen"), 1, 1, 1)
					if self.e.right then GameTooltip:AddLine(text("Right-click: settings", "Rechtsklik: instellingen"), 1, 1, 1) end
				end
				GameTooltip:Show()
			end)
			r:SetScript("OnLeave", function(self) self.hl:Hide() GameTooltip:Hide() end)
			r:SetScript("OnClick", function(self, btn)
				f:Hide()
				local e = self.e
				local fn = e.click
				if btn == "RightButton" then fn = e.right or e.click
				elseif btn == "MiddleButton" then fn = e.middle
				elseif IsShiftKeyDown() and e.shift then fn = e.shift end
				if fn then pcall(fn) end
			end)
			f.rows[i] = r
		end
		r.e = e
		r.icon:SetTexture(e.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
		r.text:SetText(e.title)
		r:Show()
	end
	for i = #entries + 1, #f.rows do f.rows[i]:Hide() end
	f:SetHeight(30 + #entries * ROW)
end

function hub:Toggle()
	local f = self.list
	if not f then
		f = CreateFrame("Frame", "AddonsOfAzerothList", UIParent, "BackdropTemplate")
		if not f.SetBackdrop and BackdropTemplateMixin then Mixin(f, BackdropTemplateMixin) end
		f:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 })
		f:SetBackdropColor(0.04, 0.05, 0.08, 0.95)
		f:SetBackdropBorderColor(0, 0, 0, 1)
		f:SetWidth(210)
		f:SetFrameStrata("DIALOG")
		f:SetClampedToScreen(true)
		f:EnableMouse(true)
		f.rows = {}
		local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		t:SetPoint("TOPLEFT", 8, -7)
		t:SetText("Addons of Azeroth")
		t:SetTextColor(0.41, 0.80, 0.94)
		tinsert(UISpecialFrames, "AddonsOfAzerothList")
		-- gone a moment after the mouse leaves it
		f:SetScript("OnUpdate", function(self, el)
			if self:IsMouseOver() or (hub.button and hub.button:IsMouseOver()) then self.away = 0 return end
			self.away = (self.away or 0) + el
			if self.away > 1.5 then self:Hide() end
		end)
		f:Hide()
		self.list = f
	end
	if f:IsShown() then return f:Hide() end
	self:Fill()
	f:ClearAllPoints()
	f:SetPoint("TOPRIGHT", self.button or Minimap, "BOTTOMLEFT", 0, 0)
	f.away = 0
	f:Show()
end
