-- optionsFrame.lua - Custom tabbed settings window (Council now, more tabs later), styled with
-- a flat dark theme via the shared Modules\uiSkin.lua primitives instead of plain
-- default-Blizzard-look widgets.
--
-- Built as a plain CreateFrame-based window - NOT AceGUI/AceConfigDialog. AceConfigDialog's
-- standalone "Frame" widget never registers on this client (no error, just silently absent - see
-- CLAUDE.md); AddToBlizOptions/InterfaceOptionsFrame_OpenToCategory (Blizzard's native embedded
-- AddOns options panel) doesn't exist at all on 1.12 either (that's a WotLK+ addition), so this
-- addon has no path to a "container someone else built" options UI - it needs its own.

local addon = LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil")
local RCOptionsFrame = addon:NewModule("RCOptionsFrame")
local L = LibStub("AceLocale-3.0"):GetLocale("RCLootCouncil")
local tgetn = table.getn -- Lua 5.0 compat: no # operator

local tabOrder = { "general", "council" }

-- Fixed window size - the previous design dynamically resized the whole window every time the
-- Council tab refreshed (to fit the current member count), which was declared here as a large
-- block of interdependent layout-math constants. That resize-on-every-refresh approach is gone
-- now that Council is rebuilt around a fixed-size rank/member picker (see BuildCouncilPanel) -
-- simpler, and sidesteps whatever was behind the "Council tab goes blank after visiting General"
-- reports (never conclusively root-caused despite several rounds of targeted fixes).
local WINDOW_W = 460
local WINDOW_H = 460
local PANEL_TOP_OFFSET = 40 -- each tab panel's own TOPLEFT offset within f.content

function RCOptionsFrame:OnEnable()
	local Skin = addon.UISkin
	self.frame = self:GetFrame()
	self.frame:Show()
	self:SelectTab(self.pendingTab or "council")
	self.pendingTab = nil
end

function RCOptionsFrame:OnDisable()
	if self.frame then self.frame:Hide() end
end

--- Opens the window to a specific tab (used by e.g. "/rc council" to jump straight to Council).
function RCOptionsFrame:OpenToTab(key)
	if self.frame and self.frame:IsShown() then
		-- Already open - just switch tabs. EnableModule() would be a no-op here (module already
		-- enabled), so pendingTab would never get consumed by OnEnable.
		self:SelectTab(key)
	else
		self.pendingTab = key
		addon:EnableModule("RCOptionsFrame")
	end
end

function RCOptionsFrame:SelectTab(key)
	if not self.panels then return end
	for k, panel in pairs(self.panels) do
		if k == key then panel:Show() else panel:Hide() end
	end
	for k, btn in pairs(self.tabButtons) do
		btn:SetActive(k == key)
	end
	self.activeTab = key
	if key == "council" and self.RefreshCouncilMembers then
		self:RefreshCouncilMembers()
	end
end

function RCOptionsFrame:GetFrame()
	if self.frame then return self.frame end
	local Skin = addon.UISkin
	-- NOT L["config"] - that's the /rc config CHAT COMMAND keyword (an AceLocale "= true" entry,
	-- i.e. literally the lowercase string "config"), confirmed live to show up as the window's
	-- title bar text ("config") instead of a proper title like every other window has.
	-- Wider/taller than before per user request - 300 was cramped enough that the tab strip and
	-- the first panel's own content visually crowded each other.
	local f = Skin.CreateWindow("RCLootCouncil_OptionsFrame", L["RCLootCouncil Options"] or "RCLootCouncil Options", WINDOW_W, WINDOW_H)

	local tabLabels = {
		general = L["General"] or "General",
		council = L["Council"] or "Council",
	}

	self.tabButtons = {}
	self.panels = {}

	-- CONFIRMED LIVE, THE actual root cause of "switching tabs breaks/does nothing" surviving a
	-- full Council-panel rewrite: `key` here is the for-loop's OWN control variable, captured
	-- DIRECTLY by the OnClick closure below - the exact same bug class already found and fixed in
	-- lootFrame.lua's response buttons (this client does not appear to give a for-loop's control
	-- variable a genuinely fresh per-iteration binding the way standard Lua does). With only 2
	-- tabs, every tab button's OnClick ended up calling SelectTab("council") (the LAST value `key`
	-- held once the loop finished) regardless of which tab was actually clicked - so "General"
	-- never opened its own panel at all, it just kept re-selecting Council. Route the key through
	-- an explicit function call instead, exactly like the lootFrame.lua fix - a function's own
	-- parameter is unambiguously fresh per call, unlike a for-loop's iteration variable here.
	local function MakeTabClickHandler(tabKey)
		return function() RCOptionsFrame:SelectTab(tabKey) end
	end
	local prevBtn
	for _, key in ipairs(tabOrder) do
		local btn = Skin.CreateTab(f.content, tabLabels[key] or key, 90)
		if prevBtn then
			btn:SetPoint("LEFT", prevBtn, "RIGHT", 4, 0)
		else
			btn:SetPoint("TOPLEFT", 0, 0)
		end
		btn:SetScript("OnClick", MakeTabClickHandler(key))
		self.tabButtons[key] = btn
		prevBtn = btn
	end

	-- CONFIRMED LIVE, likely root cause of "Council tab stays empty after visiting General":
	-- BuildGeneralPanel() ran UNGUARDED - if it threw partway through (a real possibility, it's
	-- brand new code using the also-new Skin.CreateCheckbox), the error would abort GetFrame()
	-- right here, meaning councilPanel/BuildCouncilPanel below would NEVER RUN AT ALL, leaving
	-- self.panels.council permanently nil - SelectTab("council") would then have nothing to
	-- Show(), which looks exactly like "the council tab won't load". pcall-wrap it so a failure
	-- here can never take down the rest of the window, and print the real error instead of
	-- silently swallowing it.
	local generalPanel = CreateFrame("Frame", nil, f.content)
	generalPanel:SetPoint("TOPLEFT", 0, -PANEL_TOP_OFFSET)
	generalPanel:SetPoint("BOTTOMRIGHT", 0, 0)
	self.panels.general = generalPanel
	local ok, err = pcall(function() RCOptionsFrame:BuildGeneralPanel(generalPanel) end)
	if not ok then
		addon:Print("RCLootCouncil Options: the General tab failed to build: "..tostring(err))
	end

	local councilPanel = CreateFrame("Frame", nil, f.content)
	councilPanel:SetPoint("TOPLEFT", 0, -PANEL_TOP_OFFSET)
	councilPanel:SetPoint("BOTTOMRIGHT", 0, 0)
	self.panels.council = councilPanel
	self:BuildCouncilPanel(councilPanel)

	-- Route the window's close button through DisableModule so AceAddon's "is this module
	-- enabled" bookkeeping stays in sync with the frame's actual visibility - otherwise the next
	-- EnableModule() call (from OpenToTab/"/rc config") is a no-op and the window can never be
	-- reopened after being closed once.
	f.onClose = function() addon:DisableModule("RCOptionsFrame") end

	self.frame = f
	return f
end

--- --------------------------------------------------------------------
--- Council tab
--- --------------------------------------------------------------------

-- Rebuilt to match the original RCLootCouncil's own Council UI per explicit user request (screenshots
-- of RCLootCouncil2's "Guild Council Members" tab): guild ranks listed on the left, clicking one
-- shows that rank's members on the right with a checkbox each, reflecting/toggling council
-- membership directly - instead of the previous flat add-by-typed-name-only list. Add/remove still
-- goes through the SAME addon:ChatCommand("council add|remove <name>") handler as before (one
-- source of truth), so it still respects the group-or-guild eligibility check and re-broadcasts
-- CouncilChanged() correctly. Also drops the whole "resize the window to fit the row count" system
-- the old flat list needed - this panel has a fixed layout.
function RCOptionsFrame:BuildCouncilPanel(panel)
	local Skin = addon.UISkin

	local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	desc:SetPoint("TOPLEFT", 4, -4)
	desc:SetPoint("TOPRIGHT", -4, -4)
	desc:SetJustifyH("LEFT")
	desc:SetTextColor(0.9, 0.75, 0.3, 1)
	desc:SetText(L["Click a guild rank to see its members, then check who should be on the council."] or "Click a guild rank to see its members, then check who should be on the council.")

	local currentText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	currentText:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -6)
	currentText:SetPoint("TOPRIGHT", desc, "BOTTOMRIGHT", 0, -6)
	currentText:SetJustifyH("LEFT")
	self.currentCouncilText = currentText

	-- Left: guild ranks. Right: members of whichever rank is currently selected.
	local rankFrame = CreateFrame("Frame", nil, panel)
	rankFrame:SetWidth(140)
	rankFrame:SetPoint("TOPLEFT", 0, -46)
	rankFrame:SetPoint("BOTTOMLEFT", 0, 34) -- leave room for Remove All below

	-- Member list needs to scroll - a rank can easily have more members than fit in the visible
	-- area, and confirmed live they were simply overflowing past the bottom of the window into the
	-- game world instead of being contained/scrollable. Plain ScrollFrame + a manually-driven
	-- Slider (UIPanelScrollBarTemplate, the same standard Blizzard scrollbar widget) rather than a
	-- full lib-st table, since this is just a simple checkbox list, not sortable/filterable data.
	local memberFrame = CreateFrame("Frame", nil, panel)
	memberFrame:SetPoint("TOPLEFT", rankFrame, "TOPRIGHT", 10, 0)
	memberFrame:SetPoint("BOTTOMRIGHT", 0, 34)

	local memberScroll = CreateFrame("ScrollFrame", nil, memberFrame)
	memberScroll:SetPoint("TOPLEFT", 0, 0)
	memberScroll:SetPoint("BOTTOMRIGHT", -20, 0) -- leave room for the scrollbar
	memberScroll:EnableMouseWheel(true)

	local memberScrollChild = CreateFrame("Frame", nil, memberScroll)
	memberScrollChild:SetSize(1, 1) -- grown to fit content in RefreshMembers below
	memberScroll:SetScrollChild(memberScrollChild)

	local memberScrollBar = CreateFrame("Slider", nil, memberFrame, "UIPanelScrollBarTemplate")
	memberScrollBar:SetPoint("TOPRIGHT", 0, -16)
	memberScrollBar:SetPoint("BOTTOMRIGHT", 0, 16)
	memberScrollBar:SetWidth(16)
	memberScrollBar:SetMinMaxValues(0, 0)
	memberScrollBar:SetValueStep(24)
	memberScrollBar:SetValue(0)
	memberScrollBar:SetScript("OnValueChanged", function()
		memberScroll:SetVerticalScroll(this:GetValue())
	end)
	memberScroll:SetScript("OnMouseWheel", function()
		local minV, maxV = memberScrollBar:GetMinMaxValues()
		local newV = memberScrollBar:GetValue() - (arg1 * 24)
		if newV < minV then newV = minV end
		if newV > maxV then newV = maxV end
		memberScrollBar:SetValue(newV)
	end)

	self.rankButtons = {}
	self.memberRows = {}
	self.selectedRankIndex = nil

	local function UpdateCurrentText()
		local council = addon.db and addon.db.profile.council or {}
		if tgetn(council) == 0 then
			currentText:SetText(L["Current council: (none)"] or "Current council: (none)")
		else
			currentText:SetText((L["Current council:"] or "Current council:").." "..table.concat(council, ", "))
		end
	end

	local function RefreshMembers()
		for _, row in ipairs(self.memberRows) do row:Hide() end
		UpdateCurrentText()
		if not self.selectedRankIndex then
			memberScrollChild:SetHeight(1)
			memberScrollBar:SetMinMaxValues(0, 0)
			return
		end
		GuildRoster() -- make sure the roster is current before scanning it
		local shown = 0
		for i = 1, GetNumGuildMembers() do
			local name, _, rankIndex = GetGuildRosterInfo(i)
			if rankIndex == self.selectedRankIndex then
				shown = shown + 1
				local row = self.memberRows[shown]
				if not row then
					row = Skin.CreateCheckbox(memberScrollChild, "")
					row:SetPoint("TOPLEFT", 4, -4 - (shown-1)*24)
					-- Checkbox click handlers get registered ONCE here at creation (not on every
					-- refresh) - a lesson learned the hard way with the Voting Frame's Vote/Award
					-- buttons re-registering SetScript on every table refresh, which turned out to
					-- risk firing more than once per real click on this client. Read the member
					-- name from the checkbox's own field (updated every refresh below) instead of
					-- closing over this specific refresh's own `name` local.
					row:SetScript("OnClick", function()
						local memberName = this.memberName
						if this:GetChecked() then
							addon:ChatCommand("council add "..memberName)
						else
							addon:ChatCommand("council remove "..memberName)
						end
						UpdateCurrentText()
					end)
					self.memberRows[shown] = row
				end
				row.memberName = name
				row.text:SetText(name)
				row:SetChecked(tContains(addon.db.profile.council, name))
				row:Show()
			end
		end
		-- Grow the scroll child to fit every row, and let the scrollbar cover whatever
		-- overflows past the visible area (0 range = no scrolling needed, e.g. a short rank).
		local totalHeight = math.max(shown * 24, 1)
		memberScrollChild:SetHeight(totalHeight)
		local visibleHeight = memberScroll:GetHeight()
		local maxScroll = math.max(totalHeight - visibleHeight, 0)
		memberScrollBar:SetMinMaxValues(0, maxScroll)
		if memberScrollBar:GetValue() > maxScroll then memberScrollBar:SetValue(maxScroll) end
	end
	self.RefreshCouncilMembers = RefreshMembers

	-- Build the rank button list once, from a fresh guild roster scan.
	local rankNames = {}
	GuildRoster()
	for i = 1, GetNumGuildMembers() do
		local _, rank, rankIndex = GetGuildRosterInfo(i)
		rankNames[rankIndex] = rank
	end
	local indices = {}
	for idx in pairs(rankNames) do tinsert(indices, idx) end
	table.sort(indices)
	-- Same fix as the tab buttons above: route the loop's own `idx` through a function call so
	-- each button's OnClick gets a genuinely fresh value, instead of every rank button ending up
	-- acting on whichever rank the loop happened to end on.
	local function MakeRankClickHandler(rankIndex)
		return function()
			for _, b in pairs(RCOptionsFrame.rankButtons) do b:SetActive(false) end
			this:SetActive(true)
			RCOptionsFrame.selectedRankIndex = rankIndex
			RefreshMembers()
		end
	end
	local prevBtn
	for _, idx in ipairs(indices) do
		local btn = Skin.CreateTab(rankFrame, rankNames[idx], 130)
		if prevBtn then
			btn:SetPoint("TOPLEFT", prevBtn, "BOTTOMLEFT", 0, -4)
		else
			btn:SetPoint("TOPLEFT", 0, 0)
		end
		btn:SetScript("OnClick", MakeRankClickHandler(idx))
		self.rankButtons[idx] = btn
		prevBtn = btn
	end

	local removeAllBtn = Skin.CreateButton(panel, L["Remove All"] or "Remove All", 90, 20)
	removeAllBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 4)
	removeAllBtn:SetScript("OnClick", function()
		addon.db.profile.council = {}
		if addon:GetActiveModule("masterlooter") then
			addon:GetActiveModule("masterlooter"):CouncilChanged()
		end
		RefreshMembers()
	end)

	UpdateCurrentText()
end

--- --------------------------------------------------------------------
--- General tab
--- --------------------------------------------------------------------

-- Each entry: {profile key, label, tooltip}. A deliberately small, commonly-relevant subset of
-- db.profile's ~20 boolean toggles (the rest still live in AceDB defaults and work via SavedVariables
-- even without a checkbox here) - a full 1:1 port of the original AceConfig options table is a
-- separate, larger task (see the plan file's M10 notes), not what was asked for here.
local generalToggles = {
	{ "autoOpen", "Auto-open Voting Frame", "Automatically open the Voting Frame when a new session starts." },
	{ "autoLoot", "Auto-loot equippable items", "Automatically loot items that can be equipped." },
	{ "autoPass", "Auto-pass on ineligible items", "Automatically pass on items your class/spec can't use." },
	{ "selfVote", "Allow voting for yourself", "Council members can vote for their own candidacy." },
	{ "multiVote", "Allow multiple votes", "Council members can vote for more than one candidate per item." },
	{ "allowNotes", "Allow notes", "Candidates can attach a note to their response." },
	{ "observe", "Observer mode", "See the Voting Frame without being on the council or being able to vote." },
	{ "enableHistory", "Record loot history", "Log every awarded item, who got it, and when." },
}

function RCOptionsFrame:BuildGeneralPanel(panel)
	local prev
	for _, entry in ipairs(generalToggles) do
		local dbKey, label, tooltip = entry[1], entry[2], entry[3]
		local cb = addon.UISkin.CreateCheckbox(panel, L[label] or label, L[tooltip] or tooltip)
		if prev then
			cb:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -10)
		else
			cb:SetPoint("TOPLEFT", 6, -6)
		end
		cb:SetChecked(addon.db.profile[dbKey] and true or false)
		cb:SetScript("OnClick", function()
			addon.db.profile[dbKey] = this:GetChecked() and true or false
		end)
		prev = cb
	end
end

