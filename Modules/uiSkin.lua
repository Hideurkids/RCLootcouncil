-- uiSkin.lua - Shared dark-theme skinning primitives for RCLootCouncil's own hand-built windows.
--
-- Self-contained (does not depend on any other addon being installed) recreation of a flat,
-- minimal dark look: a single-pixel WHITE8X8 texture as both backdrop and edge, tinted with
-- plain colors, instead of Blizzard's ornate gold DialogBox artwork. This is the "base" all of
-- RCLootCouncil's own custom windows should build on (options/council now, session/loot/voting
-- frames later) so they look consistent with each other.

local addon = LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil")

addon.UISkin = addon.UISkin or {}
local Skin = addon.UISkin

local FLAT_BACKDROP = {
	bgFile = "Interface\\BUTTONS\\WHITE8X8",
	edgeFile = "Interface\\BUTTONS\\WHITE8X8",
	edgeSize = 1,
	insets = { left = 0, right = 0, top = 0, bottom = 0 },
}
-- Exported so other files (e.g. RCLootCouncil:CreateFrame() in core.lua, shared by the Loot/
-- Voting/Session/History/VersionCheck windows) can apply the same flat look without duplicating
-- the backdrop table.
Skin.FLAT_BACKDROP = FLAT_BACKDROP

Skin.PANEL_BG = { 0.05, 0.05, 0.05, 0.95 }
Skin.PANEL_BORDER = { 0.18, 0.18, 0.18, 1 }
Skin.TITLEBAR_BG = { 0.09, 0.09, 0.09, 1 }
Skin.BUTTON_BG = { 0.10, 0.10, 0.10, 1 }
Skin.BUTTON_BG_PRESSED = { 0.05, 0.05, 0.05, 1 }
Skin.BUTTON_BORDER = { 0.30, 0.30, 0.30, 1 }
Skin.BUTTON_BORDER_HOVER = { 0.65, 0.55, 0.20, 1 }
Skin.TAB_ACTIVE_BG = { 0.16, 0.16, 0.16, 1 }
Skin.TAB_INACTIVE_BG = { 0.04, 0.04, 0.04, 1 }
Skin.TEXT_COLOR = { 0.92, 0.92, 0.92, 1 }

--- Applies the flat dark backdrop + border to any frame (Frame, Button, EditBox, ...).
function Skin.SkinFrame(frame, bg, border)
	frame:SetBackdrop(FLAT_BACKDROP)
	local c = bg or Skin.PANEL_BG
	local b = border or Skin.PANEL_BORDER
	frame:SetBackdropColor(c[1], c[2], c[3], c[4])
	frame:SetBackdropBorderColor(b[1], b[2], b[3], b[4])
end

--- Creates a flat-skinned button with its own managed FontString (a bare CreateFrame("Button")
-- has none by default).
function Skin.CreateButton(parent, text, width, height)
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(width or 80)
	b:SetHeight(height or 20)
	Skin.SkinFrame(b, Skin.BUTTON_BG, Skin.BUTTON_BORDER)

	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("CENTER")
	fs:SetTextColor(Skin.TEXT_COLOR[1], Skin.TEXT_COLOR[2], Skin.TEXT_COLOR[3], Skin.TEXT_COLOR[4])
	b:SetFontString(fs)
	if text then b:SetText(text) end

	b:SetScript("OnEnter", function()
		this:SetBackdropBorderColor(Skin.BUTTON_BORDER_HOVER[1], Skin.BUTTON_BORDER_HOVER[2], Skin.BUTTON_BORDER_HOVER[3], Skin.BUTTON_BORDER_HOVER[4])
	end)
	b:SetScript("OnLeave", function()
		if this.active then return end
		this:SetBackdropBorderColor(Skin.BUTTON_BORDER[1], Skin.BUTTON_BORDER[2], Skin.BUTTON_BORDER[3], Skin.BUTTON_BORDER[4])
	end)
	b:SetScript("OnMouseDown", function()
		this:SetBackdropColor(Skin.BUTTON_BG_PRESSED[1], Skin.BUTTON_BG_PRESSED[2], Skin.BUTTON_BG_PRESSED[3], Skin.BUTTON_BG_PRESSED[4])
	end)
	b:SetScript("OnMouseUp", function()
		this:SetBackdropColor(Skin.BUTTON_BG[1], Skin.BUTTON_BG[2], Skin.BUTTON_BG[3], Skin.BUTTON_BG[4])
	end)
	return b
end

--- A button meant to sit in a tab strip - same look as CreateButton, plus a SetActive(bool)
-- method that lights it up (instead of Enable/Disable, which doesn't exist reliably here for
-- visual "current tab" state on this client).
function Skin.CreateTab(parent, text, width)
	local b = Skin.CreateButton(parent, text, width or 90, 22)
	b.SetActive = function(self, isActive)
		self.active = isActive
		if isActive then
			self:SetBackdropColor(Skin.TAB_ACTIVE_BG[1], Skin.TAB_ACTIVE_BG[2], Skin.TAB_ACTIVE_BG[3], Skin.TAB_ACTIVE_BG[4])
			self:SetBackdropBorderColor(Skin.BUTTON_BORDER_HOVER[1], Skin.BUTTON_BORDER_HOVER[2], Skin.BUTTON_BORDER_HOVER[3], Skin.BUTTON_BORDER_HOVER[4])
		else
			self:SetBackdropColor(Skin.TAB_INACTIVE_BG[1], Skin.TAB_INACTIVE_BG[2], Skin.TAB_INACTIVE_BG[3], Skin.TAB_INACTIVE_BG[4])
			self:SetBackdropBorderColor(Skin.BUTTON_BORDER[1], Skin.BUTTON_BORDER[2], Skin.BUTTON_BORDER[3], Skin.BUTTON_BORDER[4])
		end
	end
	b:SetActive(false)
	return b
end

--- Labeled checkbox for settings panels. UICheckButtonTemplate is a confirmed-safe genuine
-- vanilla template but has no built-in text region (unlike ChatConfigCheckButtonTemplate, which
-- doesn't exist on this client - see sessionFrame.lua's own note on this) - adds its own
-- FontString label. Returns the CheckButton; read/write its state with :GetChecked()/:SetChecked().
function Skin.CreateCheckbox(parent, label, tooltip)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetSize(22, 22)
	local text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	text:SetText(label or "")
	cb.text = text
	if tooltip then
		cb:SetScript("OnEnter", function() addon:CreateTooltip(tooltip) end)
		cb:SetScript("OnLeave", function() addon:HideTooltip() end)
	end
	return cb
end

--- Flat-skinned EditBox (dark background instead of the stock blue inset).
function Skin.CreateEditBox(parent, width, height)
	local e = CreateFrame("EditBox", nil, parent)
	e:SetWidth(width or 120)
	e:SetHeight(height or 20)
	e:SetAutoFocus(false)
	e:SetFontObject(GameFontHighlightSmall)
	e:SetTextColor(Skin.TEXT_COLOR[1], Skin.TEXT_COLOR[2], Skin.TEXT_COLOR[3], Skin.TEXT_COLOR[4])
	e:SetTextInsets(4, 4, 0, 0)
	Skin.SkinFrame(e, Skin.BUTTON_BG, Skin.BUTTON_BORDER)
	return e
end

--- Full draggable window shell: dark panel + title bar + close button + a `.content` frame for
-- callers to build inside. Deliberately separate from RCLootCouncil:CreateFrame() (core.lua),
-- which uses the old gold DialogBox Blizzard look - this is the new, flat dark-themed base.
function Skin.CreateWindow(name, title, width, height)
	local f = CreateFrame("Frame", name, UIParent)
	f:SetWidth(width or 320)
	f:SetHeight(height or 400)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:Hide()
	Skin.SkinFrame(f, Skin.PANEL_BG, Skin.PANEL_BORDER)

	local titleBar = CreateFrame("Frame", nil, f)
	titleBar:SetHeight(24)
	titleBar:SetPoint("TOPLEFT", 0, 0)
	titleBar:SetPoint("TOPRIGHT", 0, 0)
	titleBar:EnableMouse(true)
	Skin.SkinFrame(titleBar, Skin.TITLEBAR_BG, Skin.PANEL_BORDER)
	titleBar:SetScript("OnMouseDown", function() this:GetParent():StartMoving() end)
	titleBar:SetScript("OnMouseUp", function() this:GetParent():StopMovingOrSizing() end)

	local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	titleText:SetPoint("CENTER")
	titleText:SetText(title or "")

	local closeBtn = Skin.CreateButton(titleBar, "X", 20, 18)
	closeBtn:SetPoint("RIGHT", -3, 0)
	closeBtn:SetScript("OnClick", function()
		-- Route through f.onClose (set by the caller) instead of a raw Hide() so callers whose
		-- window is tied to an AceAddon module's Enable/Disable lifecycle can keep that lifecycle
		-- state in sync - a bare Hide() here would desync "module enabled" from actual visibility,
		-- making the module's own EnableModule() a no-op on the next open attempt.
		if f.onClose then f.onClose() else f:Hide() end
	end)

	f.titleBar = titleBar
	f.titleText = titleText

	f.content = CreateFrame("Frame", nil, f)
	f.content:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 4, -4)
	f.content:SetPoint("BOTTOMRIGHT", -4, 4)
	-- Independent backdrop on the content area itself (same fill as the outer window) - confirmed
	-- live a window resized well after creation (e.g. a taller MIN_WINDOW_H) can end up with its
	-- lower portion visually transparent (game world/other UI bleeding through) even though the
	-- outer frame's own backdrop should in theory stretch automatically. Cheap, redundant coverage
	-- rather than chasing exactly why the outer one didn't keep up.
	Skin.SkinFrame(f.content, Skin.PANEL_BG, Skin.PANEL_BORDER)

	return f
end
