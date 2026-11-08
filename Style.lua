-- Roads of Azeroth by DinX: shared flat look
local ADDON, ns = ...
local RoA = ns.RoA

local S = {}
RoA.Style = S

S.flat = "Interface\\Buttons\\WHITE8x8"
-- Roboto (Apache License 2.0, see media\LICENSE-Roboto.txt) reads better than the
-- game font at small sizes; "wow" in the settings brings the game font back.
S.ROBOTO = "Interface\\AddOns\\" .. ADDON .. "\\media\\Roboto-Regular.ttf"

-- A font file added while the game runs is only found after a restart; until
-- then (or if it is missing) fall back to the game font so no text disappears.
local probe
local function usable(path)
	probe = probe or UIParent:CreateFontString(nil, "OVERLAY")
	local ok = pcall(probe.SetFont, probe, path, 12, "")
	return ok and probe:GetFont() ~= nil and (probe:GetFont()):lower():find("roboto", 1, true) ~= nil
end
S.font = usable(S.ROBOTO) and S.ROBOTO or STANDARD_TEXT_FONT
S.flags = "" -- "" = clean text with a soft shadow, "OUTLINE" = thick black outline

function S:LoadFont(db)
	self.font = (db and db.font == "wow" or not usable(self.ROBOTO)) and STANDARD_TEXT_FONT or self.ROBOTO
	self.flags = (db and db.fontOutline) and "OUTLINE" or ""
end

-- Font, flags and a soft shadow in one go (flags: nil = the chosen style).
function S:ApplyFont(fs, size, flags)
	fs:SetFont(self.font, size or 12, flags or self.flags)
	fs:SetShadowColor(0, 0, 0, 1)
	fs:SetShadowOffset(1, -1)
end
S.colors = {
	bg = { 0.04, 0.05, 0.08, 0.85 },
	border = { 0, 0, 0, 1 },
	edge = { 0.16, 0.19, 0.25, 1 },
	accent = { 0.41, 0.80, 0.94 },    -- mage blue
	text = { 0.91, 0.93, 0.95 },
	muted = { 0.60, 0.65, 0.71 },
	warn = { 0.95, 0.30, 0.30 },
	hint = { 1.00, 0.82, 0.25 },
	proc = { 0.85, 0.45, 1.00 },
	xp = { 0.58, 0.36, 0.86 },
	rested = { 0.25, 0.55, 0.95 },
}

-- 1px black border plus dark fill, the classic "ElvUI" panel.
function S:Backdrop(frame, alpha)
	if not frame.SetBackdrop then Mixin(frame, BackdropTemplateMixin) end
	frame:SetBackdrop({ bgFile = self.flat, edgeFile = self.flat, edgeSize = 1 })
	local c = self.colors.bg
	frame:SetBackdropColor(c[1], c[2], c[3], alpha or c[4])
	frame:SetBackdropBorderColor(0, 0, 0, 1)
end

function S:Font(parent, size, layer)
	local fs = parent:CreateFontString(nil, layer or "OVERLAY")
	self:ApplyFont(fs, size)
	fs:SetTextColor(unpack(self.colors.text))
	return fs
end

function S:StatusBar(parent, color)
	local bar = CreateFrame("StatusBar", nil, parent)
	bar:SetStatusBarTexture(self.flat)
	if color then bar:SetStatusBarColor(unpack(color)) end
	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.1, 0.1, 0.12, 0.9)
	bar.bg = bg
	return bar
end

-- Square icon with border, used for reminders and the rotation hint.
function S:Icon(parent, size)
	local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	f:SetSize(size, size)
	self:Backdrop(f, 1)
	local tex = f:CreateTexture(nil, "ARTWORK")
	tex:SetPoint("TOPLEFT", 1, -1)
	tex:SetPoint("BOTTOMRIGHT", -1, 1)
	tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	f.icon = tex
	return f
end

---------------------------------------------------------------------------
-- Movers: any frame can be dragged while the frames are unlocked.
-- Position is saved in RoA.char.points[key]; defaultFn(frame) places it otherwise.
---------------------------------------------------------------------------
S.movers = {}

function S:ApplyPoint(frame, key)
	local m = self.movers[key]
	if InCombatLockdown() and frame:IsProtected() then return end
	frame:ClearAllPoints()
	local pt = RoA.char.points[key]
	if pt then
		frame:SetPoint(pt[1], UIParent, pt[3], pt[4], pt[5])
	elseif m and m.defaultFn then
		m.defaultFn(frame)
	end
end

-- Re-anchor a frame by its top edge (TOPLEFT or TOPRIGHT of the screen,
-- whichever side is nearer), so a change in height grows it downward.
function S:AnchorTop(frame, key)
	local left, right, top = frame:GetLeft(), frame:GetRight(), frame:GetTop()
	if not (left and right and top) then return end
	local fs, us = frame:GetEffectiveScale(), UIParent:GetEffectiveScale()
	left, right, top = left * fs / us, right * fs / us, top * fs / us
	local w, h = UIParent:GetWidth(), UIParent:GetHeight()
	local pt
	if (left + right) / 2 > w / 2 then
		pt = { "TOPRIGHT", "UIParent", "TOPRIGHT", math.floor(right - w + 0.5), math.floor(top - h + 0.5) }
	else
		pt = { "TOPLEFT", "UIParent", "TOPLEFT", math.floor(left + 0.5), math.floor(top - h + 0.5) }
	end
	RoA.char.points[key] = pt
	frame:ClearAllPoints()
	frame:SetPoint(pt[1], UIParent, pt[3], pt[4] * us / fs, pt[5] * us / fs)
end

---------------------------------------------------------------------------
-- Resize: a grip in the bottom-right corner (shown with the movers, or always
-- on windows) scales the frame: its layout stays as it is and grows or
-- shrinks as a whole. The top-left corner stays put. Double-click: normal size.
-- opts: key (saved in RoA.char.sizes) or get/set for a frame's own scale
-- setting; save(frame) stores the new position; parent for the grip.
---------------------------------------------------------------------------
local MIN_SCALE, MAX_SCALE = 0.5, 2

local function sizes()
	RoA.char.sizes = RoA.char.sizes or {}
	return RoA.char.sizes
end

-- the scale a frame gets from its own settings; the grip multiplies it
function S:SetBaseScale(frame, base)
	frame.baseScale = base
	self:ApplyScale(frame)
end

function S:ApplyScale(frame)
	if InCombatLockdown() and frame:IsProtected() then return end
	local g = frame.sizeKey and sizes()[frame.sizeKey] or 1
	frame:SetScale((frame.baseScale or 1) * g)
end

local function pinTopLeft(frame, scale)
	local left, top = frame:GetLeft(), frame:GetTop()
	local fs = frame:GetEffectiveScale()
	frame:SetScale(scale)
	if not (left and top) then return end
	local nfs = frame:GetEffectiveScale()
	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * fs / nfs, top * fs / nfs)
end

local function savePoint(frame, key)
	local left, top = frame:GetLeft(), frame:GetTop()
	if left and top then
		RoA.char.points[key] = { "TOPLEFT", "UIParent", "BOTTOMLEFT", math.floor(left + 0.5), math.floor(top + 0.5) }
	end
end

function S:AddSizeGrip(frame, opts)
	local key = opts.key
	if key and not opts.get then frame.sizeKey = key end
	local get = opts.get or function() return sizes()[key] or 1 end
	local set = opts.set or function(v) sizes()[key] = v end
	local base = function() if opts.get then return 1 end return frame.baseScale or 1 end
	local save = opts.save or function(f) savePoint(f, key) end
	local grip = CreateFrame("Button", nil, opts.parent or frame)
	grip:SetSize(14, 14)
	grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
	grip:SetFrameLevel((opts.parent or frame):GetFrameLevel() + 20)
	for i = 0, 2 do
		local t = grip:CreateTexture(nil, "OVERLAY")
		t:SetColorTexture(self.colors.muted[1], self.colors.muted[2], self.colors.muted[3], 0.9)
		t:SetSize(2 + i * 4, 1)
		t:SetPoint("BOTTOMRIGHT", -1, 2 + i * 3)
	end
	grip:SetScript("OnEnter", function(g)
		GameTooltip:SetOwner(g, "ANCHOR_RIGHT")
		GameTooltip:SetText(RoA.L["Drag: bigger or smaller. Double-click: normal size."], 1, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	grip:SetScript("OnLeave", function() GameTooltip:Hide() end)
	grip:SetScript("OnMouseDown", function(g)
		if InCombatLockdown() and frame:IsProtected() then return end
		local startX = GetCursorPosition()
		local start = get()
		local w = math.max(20, frame:GetWidth() * frame:GetEffectiveScale())
		g:SetScript("OnUpdate", function()
			if InCombatLockdown() and frame:IsProtected() then return end
			local s = start * math.max(0.1, (w + GetCursorPosition() - startX) / w)
			s = math.floor(math.max(MIN_SCALE, math.min(MAX_SCALE, s)) * 100 + 0.5) / 100
			if s ~= get() then
				set(s)
				pinTopLeft(frame, base() * s)
			end
		end)
	end)
	grip:SetScript("OnMouseUp", function(g)
		if not g:GetScript("OnUpdate") then return end
		g:SetScript("OnUpdate", nil)
		save(frame)
		if opts.done then opts.done() end
		RoA:Fire("SIZE", key)
	end)
	grip:SetScript("OnDoubleClick", function()
		if InCombatLockdown() and frame:IsProtected() then return end
		set(1)
		pinTopLeft(frame, base())
		save(frame)
		if opts.done then opts.done() end
		RoA:Fire("SIZE", key)
	end)
	return grip
end

function S:RegisterMover(frame, key, label, defaultFn, anchorTop)
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	local o = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	o:SetAllPoints()
	o:SetFrameStrata("DIALOG")
	o:EnableMouse(true)
	o:RegisterForDrag("LeftButton")
	o:SetBackdrop({ bgFile = self.flat, edgeFile = self.flat, edgeSize = 1 })
	o:SetBackdropColor(0.41, 0.80, 0.94, 0.25)
	o:SetBackdropBorderColor(0.41, 0.80, 0.94, 1)
	local t = self:Font(o, 11)
	t:SetPoint("CENTER")
	t:SetText(label)
	o:SetScript("OnDragStart", function()
		if InCombatLockdown() then return end
		frame:StartMoving()
	end)
	o:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		if anchorTop then
			S:AnchorTop(frame, key)
			return
		end
		local p, _, rp, x, y = frame:GetPoint()
		RoA.char.points[key] = { p, "UIParent", rp, math.floor(x + 0.5), math.floor(y + 0.5) }
	end)
	o:Hide()
	self.movers[key] = { frame = frame, overlay = o, defaultFn = defaultFn }
	-- the resize grip shows with the mover
	self:AddSizeGrip(frame, { key = key, parent = o, save = function(f)
		if anchorTop then S:AnchorTop(f, key) else savePoint(f, key) end
	end })
	self:ApplyScale(frame)
	self:ApplyPoint(frame, key)
end

function S:UpdateMovers()
	local show = not RoA:FramesLocked() and not InCombatLockdown()
	for _, m in pairs(self.movers) do m.overlay:SetShown(show) end
end

function S:ResetMovers()
	for key, m in pairs(self.movers) do
		RoA.char.points[key] = nil
		self:ApplyPoint(m.frame, key)
	end
end

RoA:Listen("SETTINGS", function(group) if group == "bars" then S:UpdateMovers() end end)
RoA:On("PLAYER_REGEN_DISABLED", function() for _, m in pairs(S.movers) do m.overlay:Hide() end end)
RoA:On("PLAYER_REGEN_ENABLED", function() S:UpdateMovers() end)

local function kill(region)
	if region then
		region:SetAlpha(0)
		if region.Hide then region:Hide() end
	end
end

-- Flatten a LibActionButton / ActionButtonTemplate button.
function S:SkinButton(btn)
	if btn.__ckSkinned then return end
	btn.__ckSkinned = true

	local icon = btn.icon or btn.Icon
	if btn.IconMask and icon then
		icon:RemoveMaskTexture(btn.IconMask)
		btn.IconMask:Hide()
	end
	kill(btn:GetNormalTexture())
	hooksecurefunc(btn, "SetNormalTexture", function(b)
		local nt = b:GetNormalTexture()
		if nt then nt:SetAlpha(0) end
	end)
	if btn.SetNormalAtlas then
		hooksecurefunc(btn, "SetNormalAtlas", function(b)
			local nt = b:GetNormalTexture()
			if nt then nt:SetAlpha(0) end
		end)
	end
	kill(btn.NormalTexture)
	kill(btn.SlotArt)
	kill(btn.SlotBackground)
	kill(btn.Border)
	kill(btn.FloatingBG)
	if btn.RightDivider then kill(btn.RightDivider) end
	if btn.BottomDivider then kill(btn.BottomDivider) end

	if icon then
		icon:ClearAllPoints()
		icon:SetPoint("TOPLEFT", 1, -1)
		icon:SetPoint("BOTTOMRIGHT", -1, 1)
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end

	local bg = btn:CreateTexture(nil, "BACKGROUND", nil, -8)
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 1)
	local inner = btn:CreateTexture(nil, "BACKGROUND", nil, -7)
	inner:SetPoint("TOPLEFT", 1, -1)
	inner:SetPoint("BOTTOMRIGHT", -1, 1)
	inner:SetColorTexture(0.10, 0.12, 0.17, 1)

	if btn.cooldown then
		btn.cooldown:ClearAllPoints()
		btn.cooldown:SetPoint("TOPLEFT", 1, -1)
		btn.cooldown:SetPoint("BOTTOMRIGHT", -1, 1)
		btn.cooldown:SetSwipeColor(0, 0, 0, 0.75)
	end

	local hl = btn:GetHighlightTexture()
	if hl then
		hl:SetColorTexture(1, 1, 1, 0.15)
		hl:SetPoint("TOPLEFT", 1, -1)
		hl:SetPoint("BOTTOMRIGHT", -1, 1)
	end
	local pushed = btn:GetPushedTexture()
	if pushed then
		pushed:SetColorTexture(0.9, 0.8, 0.1, 0.3)
		pushed:SetPoint("TOPLEFT", 1, -1)
		pushed:SetPoint("BOTTOMRIGHT", -1, 1)
	end
	if btn.GetCheckedTexture and btn:GetCheckedTexture() then
		local ch = btn:GetCheckedTexture()
		ch:SetColorTexture(0.41, 0.80, 0.94, 0.25)
		ch:SetPoint("TOPLEFT", 1, -1)
		ch:SetPoint("BOTTOMRIGHT", -1, 1)
	end
end
