-- Author      : Potdisc
-- Create Date : 8/6/2015
-- DefaultModule
-- lootHistory.lua	Adds the interface for displaying the collected loot history

local addon = LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil")
local LootHistory = addon:NewModule("RCLootHistory")
local L = LibStub("AceLocale-3.0"):GetLocale("RCLootCouncil")
local LibDialog = LibStub("RCLootCouncil-LibDialog-1.0")
local lootDB, scrollCols, data, db, numLootWon;

-- Lua 5.0 compat: strsplit may not be a native global on this client
-- CONFIRMED LIVE (2026-08-26): this client's native/ClassicAPI-provided `strsplit` global
-- returns a single TABLE of pieces instead of multiple string values (see core.lua) - always
-- use our own known-correct implementation instead of `_G.strsplit`.
local strsplit = function(delimiter, str, pieces)
	if not str then return end
	local parts = {}
	local dpat = "[" .. delimiter .. "]"
	local pos = 1
	while true do
		if pieces and table.getn(parts) == pieces - 1 then
			table.insert(parts, string.sub(str, pos))
			break
		end
		local s, e = string.find(str, dpat, pos)
		if not s then
			table.insert(parts, string.sub(str, pos))
			break
		end
		table.insert(parts, string.sub(str, pos, s - 1))
		pos = e + 1
	end
	return unpack(parts)
end
--[[ data structure:
data[date][playerName] = {
	["class"] = CLASS,
	[i] = { -- Num item given to player, lowest first
		-- Remaining content in lootDB[playerName]
	}
}
]]
local selectedDate, selectedName, filterMenu, moreInfo
local ROW_HEIGHT = 20;
local NUM_ROWS = 15;

-- Plain-CSV export, so the ML can audit past awards outside the game (e.g. if a dispute comes up)
local exportDialog = {
	title = L["Export Loot History"] or "Export Loot History",
	text = L["Ctrl+C to copy, then close this window."] or "Ctrl+C to copy, then close this window.",
	width = 520,
	editboxes = {
		{
			width = 480,
			auto_focus = true,
			text = "",
		},
	},
	buttons = {
		{ text = L["Close"] or "Close" },
	},
}
LibDialog:Register("LOOTHISTORY_EXPORT", exportDialog)

function LootHistory:BuildExportString()
	local rows = {"Date,Time,Player,Item,Response,Boss,Instance"}
	for name, v in pairs(lootDB) do
		for i, entry in ipairs(v) do
			local item = string.gsub(entry.lootWon or "", ",", ";")
			local response = string.gsub(tostring(entry.response or ""), ",", ";")
			tinsert(rows, table.concat({
				entry.date or "",
				entry.time or "",
				name,
				item,
				response,
				entry.boss or "",
				entry.instance or "",
			}, ","))
		end
	end
	return table.concat(rows, "\n")
end

function LootHistory:Export()
	exportDialog.editboxes[1].text = self:BuildExportString()
	LibDialog:Spawn("LOOTHISTORY_EXPORT")
end

function LootHistory:OnInitialize()
	scrollCols = {
		{name = "",					width = ROW_HEIGHT, },			-- Class icon, should be same row as player
		{name = L["Name"],		width = 100, 				},		-- Name of the player
		{name = "",					width = ROW_HEIGHT, },			-- Item at index icon
		{name = L["Item"],		width = 250, 				}, 	-- Item string
		{name = L["Reason"],		width = 230, comparesort = self.ResponseSort, sort = "asc", sortnext = 2},	-- Response aka the text supplied to lootDB...response
	}
	filterMenu = CreateFrame("Frame", "RCLootCouncil_LootHistory_FilterMenu", UIParent, "Lib_UIDropDownMenuTemplate")
	-- Filter deprioritized for now while Lib_UIDropDownMenu is unresolved on this client - guard
	-- so this doesn't crash OnInitialize() for the whole module every time the addon loads.
	if _G.Lib_UIDropDownMenu_Initialize then
		Lib_UIDropDownMenu_Initialize(filterMenu, self.FilterMenu, "MENU")
	end
	--MoreInfo
	self.moreInfo = CreateFrame( "GameTooltip", "RCLootHistoryMoreInfo", nil, "GameTooltipTemplate" )
end

function LootHistory:OnEnable()
	addon:Debug("OnEnable()")
	moreInfo = true
	db = addon:Getdb()
	lootDB = addon:GetHistoryDB()
	self.frame = self:GetFrame()
	self:BuildData()
	self:Show()
end

function LootHistory:OnDisable()
	self:Hide()
	self.frame:SetParent(nil)
	self.frame = nil
	data = {}
end

function LootHistory:Show()
	self.frame:Show()
end

function LootHistory:Hide()
	self.frame:Hide()
	self.moreInfo:Hide()
	moreInfo = false
end

function LootHistory:BuildData()
	addon:Debug("LootHistory:BuildData()")
	data = {}
	numLootWon = {} -- playerName = #
	local date
	-- We want to rebuild lootDB to the "data" format:
	--local i = 1
	for name, v in pairs(lootDB) do
		numLootWon[name] = 0
		-- Now we actually add the data
		for i,v in ipairs(v) do
			numLootWon[name] = numLootWon[name] + 1
			date = v.date
			if not date then -- Unknown date
				date = L["Unknown date"]
			end
			if not data[date] then -- We haven't added the date to data, do it
				data[date] = {}
			end
			if not data[date][name] then
				data[date][name] = {}
			end
			if not data[date][name][i] then
				data[date][name][i] = {}
			end
			for k, t in pairs(v) do
				if k == "class" then -- we need the class at a different level
					data[date][name].class = t
				elseif k ~= "date" then -- We don't need date
					data[date][name][i][k] = t
				end
			end
			if not data[date][name][i].instance then
				data[date][name][i].instance = L["Unknown"]
			end
		end
	end
	table.sort(data)
	-- Now create a blank data table for lib-st to init with
	self.frame.rows = {}
	local dateData, nameData, insertedNames = {}, {}, {}
	local row = 1;
	for date, v in pairs(data) do
		for name, x in pairs(v) do
			for num, i in pairs(x) do
				if num == "class" then break end
				self.frame.rows[row] = {
					date = date,
					class = x.class,
					name = name,
					num = num,
					response = i.responseID,
					cols = {
						{DoCellUpdate = addon.SetCellClassIcon, args = {x.class}},
						{value = name, color = addon:GetClassColor(x.class)},
						{DoCellUpdate = self.SetCellGear, args={i.lootWon}},
						{value = i.lootWon},
						{DoCellUpdate = self.SetCellResponse, args = {color = i.color, response = i.response, responseID = i.responseID or 0, isAwardReason = i.isAwardReason}}
					}
				}
				row = row + 1
			end
			if not tContains(insertedNames, name) then -- we only want each name added once
				tinsert(nameData,
					{
						{DoCellUpdate = addon.SetCellClassIcon, args = {x.class}},
						{value = name, color = addon:GetClassColor(x.class), name = name}
					}
				)
				tinsert(insertedNames, name)
			elseif x.class then -- it already exists, but we might need to add the class which we now have
				for i in pairs(nameData) do
					if nameData[i][2].name == name then
						nameData[i][1].args = {x.class}
					end
				end
			end
		end
		tinsert(dateData, {date})
	end
	self.frame.st:SetData(self.frame.rows)
	self.frame.date:SetData(dateData, true) -- True for minimal data	format
	self.frame.name:SetData(nameData, true)
end

function LootHistory.FilterFunc(table, row)
	local nameAndDate = true -- default to show everything
	if selectedName and selectedDate then
		nameAndDate = row.name == selectedName and row.date == selectedDate
	elseif selectedName then
		nameAndDate = row.name == selectedName
	elseif selectedDate then
		nameAndDate = row.date == selectedDate
	end

	local responseFilter = true -- default to show
	if not db.modules["RCLootHistory"].filters then return nameAndDate end -- db hasn't been initialized
	local response = row.response
	if response == "AUTOPASS" or response == "PASS" or type(response) == "number" then
		responseFilter = db.modules["RCLootHistory"].filters[response]
	else -- Filter out the status texts
		responseFilter = db.modules["RCLootHistory"].filters["STATUS"]
	end

	return nameAndDate and responseFilter -- Either one can filter the entry
end

function LootHistory.SetCellGear(rowFrame, frame, data, cols, row, realrow, column, fShow, table, ...)
	local gear = data[realrow].cols[column].args[1] -- gear1 or gear2
	if gear then
		local texture = select(10, addon:GetItemInfo(gear))
		-- Same fix as votingFrame.lua's SetCellGear ("Usage: GetItemIcon(itemID)") - GetItemIcon
		-- needs a bare numeric ID, but `gear` here is a full decorated item link.
		if not texture and _G.GetItemIcon then texture = GetItemIcon(tonumber(gear) or addon:GetItemIDFromLink(gear)) end
		frame:SetNormalTexture(texture)
		frame:SetScript("OnEnter", function() addon:CreateHypertip(gear) end)
		frame:SetScript("OnLeave", function() addon:HideTooltip() end)
		frame:Show()
	else
		frame:Hide()
	end
end

function LootHistory.SetCellResponse(rowFrame, frame, data, cols, row, realrow, column, fShow, table, ...)
	local args = data[realrow].cols[column].args
	if args.responseID and args.responseID ~= 0 and not args.isAwardReason then
		frame.text:SetText((addon.db.profile.buttons[args.responseID] or addon.responses[args.responseID]).text)
	else
		frame.text:SetText(args.response)
	end
	if args.color then -- Never version saves the color with the entry
		frame.text:SetTextColor(unpack(args.color))
	elseif args.responseID > 0 then -- try to recreate color from ID
		frame.text:SetTextColor(addon:GetResponseColor(args.responseID))
	else -- default to white
		frame.text:SetTextColor(1,1,1,1)
	end
end

function LootHistory.DateSort(table, rowa, rowb, sortbycol)
	local column = table.cols[sortbycol]
	rowa, rowb = table:GetRow(rowa), table:GetRow(rowb);
	local a, b = rowa[1], rowb[1]
	if not (a and b) then return false end
	local d, m, y = strsplit("/", a, 3)
	local aTime = time({year = "20"..y, month = m, day = d})
	d, m, y = strsplit("/", b, 3)
	local bTime = time({year = "20"..y, month = m, day = d})
	local direction = column.sort or column.defaultsort or "asc";
	if string.lower(direction) == "asc" then
		return aTime < bTime;
	else
		return aTime > bTime;
	end
end

function LootHistory.ResponseSort(table, rowa, rowb, sortbycol)
	local column = table.cols[sortbycol]
	rowa, rowb = table:GetRow(rowa), table:GetRow(rowb);
	local a,b
	local aID, bID = data[rowa.date][rowa.name][rowa.num].responseID, data[rowb.date][rowb.name][rowb.num].responseID
	local awardReason = true

	-- NOTE: I'm pretty sure it can only be an awardReason when responseID is nil or 0

	if aID and aID ~= 0 then
		if data[rowa.date][rowa.name][rowa.num].isAwardReason then
			a = db.awardReasons[aID].sort
		else
			a = addon:GetResponseSort(aID)
		end
	else
		-- 500 will be below award reasons and just above status texts
		a = 500
	end

	if bID and bID ~= 0 then
		if data[rowb.date][rowb.name][rowb.num].isAwardReason then
			b = db.awardReasons[bID].sort
		else
			b = addon:GetResponseSort(bID)
		end

	else
		b = 500
	end

	local direction = column.sort or column.defaultsort or "asc";
	if string.lower(direction) == "asc" then
		return a < b;
	else
		return a > b;
	end
end

---------------------------------------------------
-- Visauls
---------------------------------------------------
function LootHistory:Update()
	self.frame.st:SortData()
end

function LootHistory:GetFrame()
	if self.frame then return self.frame end
	local f = addon:CreateFrame("DefaultRCLootHistoryFrame", "history", L["RCLootCouncil Loot History"], 250, 480)
	local st = LibStub("ScrollingTable"):CreateST(scrollCols, NUM_ROWS, ROW_HEIGHT, { ["r"] = 1.0, ["g"] = 0.9, ["b"] = 0.0, ["a"] = 0.5 }, f.content)
	st.frame:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 10)
	st:SetFilter(self.FilterFunc)
	st:EnableSelection(true)
	st:RegisterEvents({
		["OnClick"] = function(rowFrame, cellFrame, data, cols, row, realrow, column, table, button, ...)
			if row or realrow then
				self:UpdateMoreInfo(rowFrame, cellFrame, data, cols, row, realrow, column, table, button, unpack(arg, 1, arg.n))
			end
			return false
		end
	})
	f.st = st

	--Date selection
	f.date = LibStub("ScrollingTable"):CreateST({{name = L["Date"], width = 70, comparesort = self.DateSort, sort = "desc"}}, 5, ROW_HEIGHT, { ["r"] = 1.0, ["g"] = 0.9, ["b"] = 0.0, ["a"] = 0.5 }, f.content)
	f.date.frame:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -20)
	f.date:EnableSelection(true)
	f.date:RegisterEvents({
		["OnClick"] = function(rowFrame, cellFrame, data, cols, row, realrow, column, table, button, ...)
			if button == "LeftButton" and row then
				selectedDate = data[realrow][column] ~= selectedDate and data[realrow][column] or nil
				self:Update()
			end
			return false
		end
	})

	--Name selection
	f.name = LibStub("ScrollingTable"):CreateST({{name = "", width = ROW_HEIGHT},{name = L["Name"], width = 100, sort = "desc"}}, 5, ROW_HEIGHT, { ["r"] = 1.0, ["g"] = 0.9, ["b"] = 0.0, ["a"] = 0.5 }, f.content)
	f.name.frame:SetPoint("TOPLEFT", f.date.frame, "TOPRIGHT", 20, 0)
	f.name:EnableSelection(true)
	f.name:RegisterEvents({
		["OnClick"] = function(rowFrame, cellFrame, data, cols, row, realrow, column, table, button, ...)
			if button == "LeftButton" and row then
				selectedName = selectedName ~= data[realrow][column].name and data[realrow][column].name or nil
				self:Update()
			end
			return false
		end
	})

	-- Abort button
	local b1 = addon:CreateButton(L["Close"], f.content)
	b1:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -100)
	b1:SetScript("OnClick", function() self:Disable() end)
	f.closeBtn = b1

	-- More-info toggle button removed per user request - clicking a row in the table already
	-- shows/updates the more-info tooltip on its own (see the table's own OnClick handler above,
	-- which calls UpdateMoreInfo directly), so that behavior is unaffected by removing this
	-- separate manual show/hide toggle.

	-- Filter and Export buttons removed per user request - Filter only ever opened a dropdown
	-- menu that's been dead/inert since round 23 (Lib_ToggleDropDownMenu unresolved on this
	-- client); Export isn't needed for now either.

	-- Set a proper width
	f:SetWidth(st.frame:GetWidth() + 20)
	return f;
end

function LootHistory:UpdateMoreInfo(rowFrame, cellFrame, dat, cols, row, realrow, column, table, button, ...)
	if not dat then return end
	local tip = self.moreInfo -- shortening
	tip:SetOwner(self.frame, "ANCHOR_RIGHT")
	local row = dat[realrow]
	local color = addon:GetClassColor(row.class)
	local data = data[row.date][row.name][row.num]
	tip:AddLine(row.name, color.r, color.g, color.b)
	tip:AddLine("")
	tip:AddDoubleLine(L["Time:"], (data.time or L["Unknown"]) .." ".. row.date or L["Unknown"], 1,1,1, 1,1,1)
	tip:AddDoubleLine(L["Loot won:"], data.lootWon or L["Unknown"], 1,1,1, 1,1,1)
	if data.itemReplaced1 then
		tip:AddDoubleLine(L["Item(s) replaced:"], data.itemReplaced1, 1,1,1)
		if data.itemReplaced2 then
			tip:AddDoubleLine(" ", data.itemReplaced2)
		end
	end
	tip:AddDoubleLine(L["Dropped by:"], data.boss or L["Unknown"], 1,1,1, 0.862745, 0.0784314, 0.235294)
	tip:AddDoubleLine(L["From:"], data.instance or L["Unknown"], 1,1,1, 0.823529, 0.411765, 0.117647)
	tip:AddDoubleLine(L["Votes"]..":", data.votes or L["Unknown"], 1,1,1, 1,1,1)
	tip:AddDoubleLine(L["Total items won:"], numLootWon[row.name], 1,1,1, 0,1,0)

	-- Debug stuff
	if addon.debug then
		tip:AddLine("\nDebug:")
		tip:AddDoubleLine("ResponseID", tostring(data.responseID), 1,1,1, 1,1,1)
		tip:AddDoubleLine("Response:", data.response, 1,1,1, 1,1,1)
		tip:AddDoubleLine("isAwardReason:", tostring(data.isAwardReason), 1,1,1, 1,1,1)
		tip:AddDoubleLine("color:", data.color and data.color[1]..", "..data.color[2]..", "..data.color[3] or "none", 1,1,1, 1,1,1)
	end
	tip:SetScale(db.UI.history.scale)
	tip:Show()
	tip:SetAnchorType("ANCHOR_RIGHT", 0, -tip:GetHeight())
end



---------------------------------------------------
-- Dropdowns
---------------------------------------------------
function LootHistory.FilterMenu(menu, level)
	local info = Lib_UIDropDownMenu_CreateInfo()
		if level == 1 then -- Redundant
			-- Build the data table:
			local data = {["STATUS"] = true, ["PASS"] = true, ["AUTOPASS"] = true}
			for i = 1, addon.mldb.numButtons or db.numButtons do
				data[i] = i
			end
			if not db.modules["RCLootHistory"].filters then -- Create the db entry
				addon:DebugLog("Created LootHistory filters")
				db.modules["RCLootHistory"].filters = {}
			end
			for k in pairs(data) do -- Update the db entry to make sure we have all buttons in it
				if type(db.modules["RCLootHistory"].filters[k]) ~= "boolean" then
					addon:Debug("Didn't contain "..k)
					db.modules["RCLootHistory"].filters[k] = true -- Default as true
				end
			end
			info.text = L["Filter"]
			info.isTitle = true
			info.notCheckable = true
			info.disabled = true
			Lib_UIDropDownMenu_AddButton(info, level)
			info = Lib_UIDropDownMenu_CreateInfo()

			for k in ipairs(data) do -- Make sure normal responses are on top
				info.text = addon:GetResponseText(k)
				info.colorCode = "|cff"..addon:RGBToHex(addon:GetResponseColor(k))
				info.func = function()
					addon:Debug("Update Filter")
					db.modules["RCLootHistory"].filters[k] = not db.modules["RCLootHistory"].filters[k]
					LootHistory:Update()
				end
				info.checked = db.modules["RCLootHistory"].filters[k]
				Lib_UIDropDownMenu_AddButton(info, level)
			end
			for k in pairs(data) do -- A bit redundency, but it makes sure these "specials" comes last
				if type(k) == "string" then
					if k == "STATUS" then
						info.text = L["Status texts"]
						info.colorCode = "|cffde34e2" -- purpleish
					else
						info.text = addon:GetResponseText(k)
						info.colorCode = "|cff"..addon:RGBToHex(addon:GetResponseColor(k))
					end
					info.func = function()
						addon:Debug("Update Filter")
						db.modules["RCLootHistory"].filters[k] = not db.modules["RCLootHistory"].filters[k]
						LootHistory:Update()
					end
					info.checked = db.modules["RCLootHistory"].filters[k]
					Lib_UIDropDownMenu_AddButton(info, level)
				end
			end
		end
	end
