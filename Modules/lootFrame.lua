-- Author      : Potdisc
-- Create Date : 12/16/2014 8:24:04 PM
-- DefaultModule
-- lootFrame.lua	Adds the interface for selecting a response to a session


local addon = LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil")
local LootFrame = addon:NewModule("RCLootFrame", "AceTimer-3.0")
local LibDialog = LibStub("RCLootCouncil-LibDialog-1.0")
local L = LibStub("AceLocale-3.0"):GetLocale("RCLootCouncil")
local LibToken = LibStub("LibArmorToken-1.0")

-- Lua 5.0 compat: no # operator
local tgetn = table.getn

local items = {} -- item.i = {name, link, lvl, texture} (i == session)
local entries = {}
local ENTRY_HEIGHT = 75
local MAX_ENTRIES = 5
local numRolled = 0

function LootFrame:Start(table)
	addon:DebugLog("LootFrame:Start()")
	for k = 1, tgetn(table) do
		if table[k].autopass then
			items[k] = { rolled = true} -- it's autopassed, so pretend we rolled it
			numRolled = numRolled + 1
		else
			items[k] = {
				name = table[k].name,
				link = table[k].link,
				ilvl = table[k].ilvl,
				texture = table[k].texture,
				rolled = false,
				note = nil,
				session = k,
				equipLoc = table[k].equipLoc,
			}
		end
	end
	self:Show()
end

function LootFrame:ReRoll(table)
	addon:DebugLog("LootFrame:ReRoll(#table)", tgetn(table))
	for k,v in ipairs(table) do
		tinsert(items,  {
			name = v.name,
			link = v.link,
			ilvl = v.ilvl,
			texture = v.texture,
			rolled = false,
			note = nil,
			session = v.session,
			equipLoc = v.equipLoc,
		})
	end
	self:Show()
end

function LootFrame:OnEnable()
	self.frame = self:GetFrame()
end

function LootFrame:OnDisable()
	self.frame:Hide() -- We don't disable the frame as we probably gonna need it later
	items = {}
	numRolled = 0
end

function LootFrame:Show()
	self.frame:Show()
	self:Update()
end

--function LootFrame:Hide()
--	self.frame:Hide()
--end

function LootFrame:Update()
	local width = 150
	local numEntries = 0
	for k,v in ipairs(items) do
		if numEntries >= MAX_ENTRIES then break end -- Only show a certain amount of items at a time
		if not v.rolled then -- Only show unrolled items
			numEntries = numEntries + 1
			width = 150 -- reset it
			if not entries[numEntries] then entries[numEntries] = self:GetEntry(numEntries) end
			-- Actually update entries
			entries[numEntries].realID = k
			entries[numEntries].link = v.link
			entries[numEntries].icon:SetNormalTexture(v.texture)
			-- Confirmed live (votingFrame.lua hit the same thing): GetNormalTexture() can come
			-- back nil right after SetNormalTexture() on this client - guard instead of crashing
			-- on what's purely a cosmetic texture-coordinate tweak.
			local iconNormalTex = entries[numEntries].icon:GetNormalTexture()
			if iconNormalTex then iconNormalTex:SetTexCoord(0,1,0,1) end
			entries[numEntries].itemText:SetText(v.link)
			entries[numEntries].itemLvl:SetText(format(L["ilvl: x"], v.ilvl))
			local id = addon:GetItemIDFromLink(v.link)
			if id then 
				local slot = select(9, addon:GetItemInfo(id))
				if not slot or slot == "" then 
					slot = RCTokenTable[id]
				end

				local g1, g2 = addon:GetPlayersGear(v.link, slot)
				addon:Debug("GetItemIDFromLink", slot, v.link, g1)
				if g1 then -- incase someone is doing loot council naked? lol
					g1 = addon:GetItemIDFromLink(g1)
				end
				if g2 then
					g2 = addon:GetItemIDFromLink(g2)
				end

				-- Show how this item compares to what's currently equipped, so Need/Greed/Pass
				-- decisions don't require opening a separate tooltip to compare.
				local equippedIlvl = (g1 and select(4, addon:GetItemInfo(g1))) or (g2 and select(4, addon:GetItemInfo(g2)))
				if equippedIlvl and v.ilvl then
					local ilvlDiff = v.ilvl - equippedIlvl
					local diffText
					if ilvlDiff > 0 then
						diffText = "|cff20ff20(+"..ilvlDiff..")|r"
					elseif ilvlDiff < 0 then
						diffText = "|cffff2020("..ilvlDiff..")|r"
					else
						diffText = "|cffffffff(=)|r"
					end
					entries[numEntries].itemLvl:SetText(format(L["ilvl: x"], v.ilvl).." "..diffText)
				end

				local HasTokenItem = false 
				local is_token = LibToken:ItemIsToken(id)
				local _, class = UnitClass("player")

				if is_token and g1 then
					HasTokenItem = id == LibToken:FindTokenForItemByClass(g1, class)
				end

				if not HasTokenItem and (id ~= g1 and id ~= g2) then 
					-- check for raid assist bis list
					local RABisList = _G ["RaidAssistBisList"] 
					if RABisList then 
						local bis_list = RABisList:GetCharacterItemList()
						local in_list = false 
						-- if its a token, check if any of the token items for this class are in the bis list
						if is_token then 
							for _, itemid in LibToken:IterateItemsForTokenAndClass(id, class) do 
								addon:Print("check", id, itemid)
								if tContains(bis_list, itemid) then
									addon:Print("is in list")
									in_list = true 
									break
								end
							end
						else
							-- else just check if the item is in the bislist
							in_list = tContains(bis_list, id) 
						end

						if in_list then 
							entries[numEntries]:SetBackdropColor(0.2, 1, 0.2, 0.3)
							entries[numEntries].bis:SetText("This item is in your bis list") 
						else 
							entries[numEntries]:SetBackdropColor(1, 0.2, 0.2, 0)
							entries[numEntries].bis:SetText("") 
						end
					else 
						entries[numEntries]:SetBackdropColor(1, 0.2, 0.2, 0)
						entries[numEntries].bis:SetText("") 
					end
				else
					entries[numEntries]:SetBackdropColor(1, 0.2, 0.2, 0.4)
					entries[numEntries].bis:SetText("You already have this item") 
				end
			end

			

			-- Update the buttons and get frame width
			-- IDEA There might be a better way of doing this instead of SetText() on every update?
			local but = entries[numEntries].buttons[addon.mldb.numButtons+1]
			-- DIAGNOSTIC: user reports a response always registers as the last button ("Off Spec")
			-- regardless of which one is clicked - a plausible cause is GetTextWidth() reading back
			-- stale/near-zero geometry right after SetText() on this client (same class of bug
			-- already confirmed for GetHeight()-after-SetWidth() in LibDialog's layout), which would
			-- collapse all button widths to ~10px and stack them on top of each other, so whichever
			-- one ends up on top (highest frame level = last created) silently eats every click
			-- regardless of the label the user thinks they're clicking. A floor width guards against
			-- that outright; the debug print gives concrete proof either way on the next test.
			but:SetWidth(math.max(but:GetTextWidth() + 10, 50))
			width = width + but:GetWidth()
			for i = 1, addon.mldb.numButtons do
				but = entries[numEntries].buttons[i]
				but:SetText(addon:GetButtonText(i))
				but:SetWidth(math.max(but:GetTextWidth() + 10, 50))
				width = width + but:GetWidth()
				addon:Debug("LootFrame button", i, addon:GetButtonText(i), "width=", but:GetWidth(), "left=", but:GetLeft())
			end
			entries[numEntries]:SetWidth(width)
			entries[numEntries]:Show()
		end
	end
	self.frame:SetHeight(numEntries * ENTRY_HEIGHT)
	self.frame:SetWidth(width)
	for i = MAX_ENTRIES, numEntries + 1, -1 do -- Hide unused
		if entries[i] then entries[i]:Hide() end
	end
	if numRolled == tgetn(items) then -- We're through them all, so hide the frame
		self:Disable()
	end
end

function LootFrame:OnRoll(entry, button)
	local index = entries[entry].realID
	-- DIAGNOSTIC: 2 identical items in the same session batch both showed as the SAME response
	-- (BiS) on the ML's Voting Frame, even though the candidate clicked different buttons for
	-- each. `entry` (display position) is always the same for sequential rolls at MAX_ENTRIES=1
	-- reuse - what actually matters is whether `index`/`items[index].session` correctly differ
	-- between the two rolls. Print both explicitly instead of guessing from entry/button alone.
	addon:Debug("LootFrame:OnRoll", entry, button, "index=", index, "session=", index and items[index] and items[index].session, "Response:", addon:GetResponseText(button))

	addon:SendCommand("group", "response", addon:CreateResponse(items[index].session, items[index].link, items[index].ilvl, button, items[index].equipLoc, items[index].note))

	numRolled = numRolled + 1
	items[index].rolled = true
	self:Update()
end

function LootFrame:GetFrame()
	if self.frame then return self.frame end
	addon:DebugLog("LootFrame","GetFrame()")
	return addon:CreateFrame("DefaultRCLootFrame", "lootframe", L["RCLootCouncil Loot Frame"], 250, 375)
end

function LootFrame:GetEntry(entry)
	addon:DebugLog("GetEntry("..entry..")")
	if entry == 0 then entry = 1 end
	local f = CreateFrame("Frame", nil, self.frame.content)
	f:SetWidth(self.frame:GetWidth())
	f:SetHeight(ENTRY_HEIGHT)
	self.frame.title:SetFrameLevel(f:GetFrameLevel() + 1)
	if entry == 1 then
		f:SetPoint("TOPLEFT", self.frame, "TOPLEFT")
	else
		f:SetPoint("TOPLEFT", entries[entry-1], "BOTTOMLEFT")
	end

	-- Flat dark theme (Modules\uiSkin.lua) instead of the old gold tooltip-background look.
	local Skin = addon.UISkin
	f:SetBackdrop(Skin.FLAT_BACKDROP)
	f:SetBackdropColor(Skin.PANEL_BG[1], Skin.PANEL_BG[2], Skin.PANEL_BG[3], 0) -- Update() sets a real alpha for bis/have-it highlighting
	f:SetBackdropBorderColor(Skin.PANEL_BORDER[1], Skin.PANEL_BORDER[2], Skin.PANEL_BORDER[3], Skin.PANEL_BORDER[4])

	-- Bare button (not UIPanelButtonTemplate) with a thin flat border instead of Blizzard's gold
	-- pill-button shape showing around the item icon.
	local icon = CreateFrame("Button", nil, f)
	Skin.SkinFrame(icon, Skin.BUTTON_BG, Skin.BUTTON_BORDER)
	icon:SetSize(ENTRY_HEIGHT*2/3, ENTRY_HEIGHT*2/3)
	icon:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -13)
	icon:SetScript("OnEnter", function()
		if not f.link then return; end
		addon:CreateHypertip(f.link)
	end)
	icon:SetScript("OnLeave", function() addon:HideTooltip() end)
	icon:SetScript("OnClick", function()
		if not f.link then return; end
	    -- IsModifiedClick() doesn't exist on this client - see addon:IsModifiedClick().
	    if ( addon:IsModifiedClick() ) then
		    HandleModifiedItemClick(f.link);
        end
    end);
	f.icon = icon

	-------- Buttons -------------
	-- CONFIRMED LIVE (2 different real players both clicking "BiS" both got recorded as "Off
	-- Spec" - button layout/positions were separately verified correct and non-overlapping via
	-- debug trace, ruling that out): every button's OnClick ended up bound to the SAME response
	-- index (the last one, numButtons) regardless of which button was actually clicked. A plain
	-- `for i=1,N do ... function() ... i ... end ... end` closure relies on the for-loop control
	-- variable getting a genuinely fresh binding every iteration - standard in reference Lua, but
	-- this client has already proven to deviate from standard Lua behavior in enough other ways
	-- (see CLAUDE.md) that it can no longer be assumed safe here either. Route the index through
	-- an explicit function CALL instead - a function's own parameters are unambiguously fresh per
	-- call in any Lua implementation, unlike a for-loop's iteration variable, so this can't
	-- possibly share state across buttons even if the loop-variable behavior itself is broken.
	local function MakeOnRollHandler(entryIndex, buttonIndex)
		return function() LootFrame:OnRoll(entryIndex, buttonIndex) end
	end
	f.buttons = {}
	for i = 1, addon.mldb.numButtons do
		f.buttons[i] = addon:CreateButton(addon:GetButtonText(i), f)
		if i == 1 then
			f.buttons[i]:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 5, 0)
		else
			f.buttons[i]:SetPoint("LEFT", f.buttons[i-1], "RIGHT", 5, 0)
		end
		f.buttons[i]:SetScript("OnClick", MakeOnRollHandler(entry, i))
	end
	-- Pass button
	f.buttons[addon.mldb.numButtons + 1] = addon:CreateButton(L["Pass"], f)
	f.buttons[addon.mldb.numButtons + 1]:SetPoint("LEFT", f.buttons[addon.mldb.numButtons], "RIGHT", 5, 0)
	f.buttons[addon.mldb.numButtons + 1]:SetScript("OnClick", function() LootFrame:OnRoll(entry, "PASS") end)

	-------- Note button ---------
	local noteButton = CreateFrame("Button", nil, f)
	noteButton:SetSize(20,20)
   noteButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	noteButton:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up")
   noteButton:SetPoint("BOTTOMRIGHT", -12, 12)
	noteButton:SetScript("OnEnter", function()
		if items[entries[entry].realID].note then -- If they already entered a note:
			addon:CreateTooltip(L["Your note:"], items[entries[entry].realID].note, "\nClick to change your note.")
		else
			addon:CreateTooltip(L["Add Note"], L["Click to add note to send to the council."])
		end
	end)
	noteButton:SetScript("OnLeave", function() addon:HideTooltip() end)
	noteButton:SetScript("OnClick", function() LibDialog:Spawn("LOOTFRAME_NOTE", entry) end)
	f.noteButton = noteButton

	----- item text/lvl ---------------
	local iTxt = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	iTxt:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 5, -5)
	iTxt:SetText("Item name goes here!!!!") -- Set text for reasons
	f.itemText = iTxt

	local ilvl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	ilvl:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -13)
	ilvl:SetTextColor(1, 1, 1) -- White
	ilvl:SetText("ilvl: 670")
	f.itemLvl = ilvl

	local bis = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	bis:SetPoint("RIGHT", ilvl, "LEFT", -2, 0)
	bis:SetTextColor(0.2, 1, 0.2) -- green 
	bis:SetText("")
	f.bis = bis
	return f
end


-- Note button
LibDialog:Register("LOOTFRAME_NOTE", {
	text = L["Enter your note:"],
	editboxes = {
		{
			on_enter_pressed = function(self, entry)
				items[entries[entry].realID].note = self:GetText()
				LibDialog:Dismiss("LOOTFRAME_NOTE")
			end,
			on_escape_pressed = function(self)
				LibDialog:Dismiss("LOOTFRAME_NOTE")
			end,
			auto_focus = true,
		}
	},
})
