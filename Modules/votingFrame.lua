-- Author      : Potdisc
-- Create Date : 12/15/2014 8:54:35 PM
-- DefaultModule
--	votingFrame.lua	Displays everything related to handling loot for all members.
--		Will only show certain aspects depending on addon.isMasterLooter, addon.isCouncil and addon.mldb.observe

local addon = LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil")
local RCVotingFrame = addon:NewModule("RCVotingFrame", "AceComm-3.0", "AceTimer-3.0", "AceEvent-3.0")
local LibDialog = LibStub("RCLootCouncil-LibDialog-1.0")
local L = LibStub("AceLocale-3.0"):GetLocale("RCLootCouncil")
local Deflate = LibStub("LibDeflate")

-- Lua 5.0 compat: no # operator, no table.wipe
local tgetn = table.getn
local wipe = _G.wipe or (_G.table and _G.table.wipe) or function(t) for k in pairs(t) do t[k] = nil end return t end

local ROW_HEIGHT = 20;
local NUM_ROWS = 15;
local db
local session = 1 -- The session we're viewing
local lootTable = {} -- lib-st compatible, extracted from addon's lootTable
local sessionButtons = {}
local moreInfo = false -- Show more info frame?
local active = false -- Are we currently in session?
local candidates = {} -- Candidates for the loot, initial data from the ML
local councilInGroup = {}
local keys = {} -- Lookup table for cols TODO implement this
local menuFrame -- Right click menu frame
local filterMenu -- Filter drop down menu
local enchanters -- Enchanters drop down menu frame
local guildRanks = {} -- returned from addon:GetGuildRanks()
local GuildRankSort, ResponseSort -- Initialize now to avoid errors

function RCVotingFrame:OnInitialize()
	-- "Diff" (ilvl difference vs equipped) removed earlier per user request; "ilvl" itself removed
	-- now too, also per user request - ilvl isn't a tracked/meaningful stat in Vanilla. Every
	-- sortnext chain that pointed at or through it is renumbered below so sorting still cascades
	-- correctly with one fewer column.
	self.scrollCols = {
		{ name = "",															sortnext = 2,		width = 20},	-- 1 Class
		{ name = L["Name"],														sortnext = 4,		width = 80},	-- 2 Candidate Name
		{ name = L["Rank"],		comparesort = GuildRankSort,					sortnext = 4,		width = 95},	-- 3 Guild rank
		{ name = L["Response"],	comparesort = ResponseSort,						sortnext = 7,		width = 240},	-- 4 Response
		{ name = L["g1"],			align = "CENTER",							sortnext = 7,		width = ROW_HEIGHT},	-- 5 Current gear 1
		{ name = L["g2"],			align = "CENTER",							sortnext = 7,		width = ROW_HEIGHT},	-- 6 Current gear 2
		{ name = L["Votes"], 		align = "CENTER",												width = 40},	-- 7 Number of votes
		{ name = L["Vote"],			align = "CENTER",							sortnext = 4,		width = 60},	-- 8 Vote button
		{ name = L["Notes"],		align = "CENTER",												width = 40},	-- 9 Note icon
		{ name = L["Roll"],			align = "CENTER", 							sortnext = 4,		width = 30},	-- 10 Roll
		{ name = L["Award"],		align = "CENTER",												width = 60},	-- 11 Award button (bypasses the right-click menu / Lib_UIDropDownMenu)
	}
	menuFrame = CreateFrame("Frame", "RCLootCouncil_VotingFrame_RightclickMenu", UIParent, "Lib_UIDropDownMenuTemplate")
	filterMenu = CreateFrame("Frame", "RCLootCouncil_VotingFrame_FilterMenu", UIParent, "Lib_UIDropDownMenuTemplate")
	enchanters = CreateFrame("Frame", "RCLootCouncil_VotingFrame_EnchantersMenu", UIParent, "Lib_UIDropDownMenuTemplate")
	-- Right-click menu / Filter / Enchanters are deprioritized for now (Award is now a direct
	-- button in the candidate table instead - see SetCellAward). Lib_UIDropDownMenu_Initialize is
	-- still unresolved on this client, and this call was crashing OnInitialize() for the WHOLE
	-- module (not just these 3 dropdown features) every single time the addon loaded - guard it
	-- so the rest of the Voting Frame works regardless of whether that gets fixed later.
	if _G.Lib_UIDropDownMenu_Initialize then
		Lib_UIDropDownMenu_Initialize(menuFrame, self.RightClickMenu, "MENU")
		Lib_UIDropDownMenu_Initialize(filterMenu, self.FilterMenu)
		Lib_UIDropDownMenu_Initialize(enchanters, self.EnchantersMenu)
	end
end

function RCVotingFrame:OnEnable()
	self:RegisterComm("RCLootCouncil")
	-- Feature request: auto-detect a candidate's first /roll (e.g. after telling 2 people to
	-- roll for an item) instead of requiring it to be entered manually - CHAT_MSG_SYSTEM is
	-- visible to everyone already in the raid/party (native roll announcements), so each client
	-- can pick this up independently without needing any new comm.
	self:RegisterEvent("CHAT_MSG_SYSTEM", "OnChatMsgSystem")
	db = addon:Getdb()
	active = true
	moreInfo = db.modules["RCVotingFrame"].moreInfo
	self.frame = self:GetFrame()
end

-- Parses this client's real roll announcements ("PlayerName rolls 87 (1-100)") - the vanilla
-- RANDOM_ROLL_RESULT format is hardcoded here (rather than derived at runtime) since this port's
-- whole environment is already assumed English-locale (see CLAUDE.md/M0 notes). Only records the
-- FIRST roll seen per candidate per session - a candidate re-rolling later doesn't overwrite it,
-- matching "ver el primer roll de cada jugador" from the feature request.
function RCVotingFrame:OnChatMsgSystem(event, msg)
	if not active or not lootTable or not lootTable[session] then return end
	local s, e, name, value = string.find(msg, "^(.-) rolls (%d+) %(%d+%-%d+%)$")
	if not name then return end
	local candData = lootTable[session].candidates[name]
	if not candData or candData.roll ~= "" then return end -- not a candidate, or already has a roll
	candData.roll = tonumber(value)
	self.frame.st:Refresh()
end

function RCVotingFrame:OnDisable() -- We never really call this
	self:Hide()
	self.frame:SetParent(nil)
	self.frame = nil
	wipe(lootTable)
	active = false
	session = 1
	self:UnregisterAllComm()
end

function RCVotingFrame:Hide()
	addon:Debug("Hide VotingFrame")
	self.frame.moreInfo:Hide()
	self.frame:Hide()
end

function RCVotingFrame:Show()
	if self.frame then
		councilInGroup = addon:GetCouncilInGroup()
		self.frame:Show()
		self:SwitchSession(session)
	else
		addon:Print(L["No session running"])
	end
end

function RCVotingFrame:EndSession(hide)
	active = false -- The session has ended, so deactivate
	self:Update()
	if hide then self:Hide() end -- Hide if need be
end

-- Shared by Setup() and the "candidates" comm's late-arrival backfill (see OnCommReceived below)
-- so both build a freshly-voting candidate entry the exact same way. Declared here (before
-- OnCommReceived, which is defined earlier in the file than Setup()) to avoid the classic Lua
-- upvalue-ordering gotcha - a `local function` declared further down isn't visible yet to code
-- appearing earlier in the same file.
local function NewCandidateEntry(v)
	return {
		class = v.class,
		rank = v.rank,
		role = v.role,
		response = "ANNOUNCED",
		ilvl = "",
		diff = "",
		gear1 = nil,
		gear2 = nil,
		votes = 0,
		note = nil,
		roll = "",
		voters = {},
		haveVoted = false, -- Have we voted for this particular candidate in this session?
	}
end

local chunkSpool = {} -- RawSend()'s reassembly buffer - see core.lua:ReceiveRaw(), must be this file's own
function RCVotingFrame:OnCommReceived(prefix, serializedMsg, distri, sender)
	if prefix == "RCLootCouncil" then
		-- CONFIRMED LIVE, ROOT CAUSE of the whole "Nydeh never gets a working Voting Frame" saga:
		-- AceComm's own multi-part splitting (triggered for any payload over ~241 bytes - both
		-- "lootTable" and "candidates" routinely exceed that) appends a control character to the
		-- addon message PREFIX per chunk, which this client apparently mishandles for real
		-- over-the-wire delivery (the ML's own self-loopback never exercises this path at all,
		-- which is why it always looked fine from here). RawSend()/ReceiveRaw() (core.lua) do our
		-- own chunking with the marker in the message BODY instead, bypassing AceComm's native
		-- multi-part path entirely - unwrap that first.
		serializedMsg = addon:ReceiveRaw(serializedMsg, sender, chunkSpool)
		if not serializedMsg then return end -- either mid-reassembly or a malformed message
		-- DIAGNOSTIC: full pipeline visibility - the raw message, its length, and whether
		-- DecodeForPrint even succeeds, since "R" (no compression, confirmed shipped) still fails
		-- to survive the round-trip somehow. Remove once resolved.
		addon:Debug("VotingComm raw len=", tostring(serializedMsg and string.len(serializedMsg)))
		-- data is always a table to be unpacked
		local decoded = Deflate:DecodeForPrint(serializedMsg)
		addon:Debug("VotingComm decoded=", tostring(decoded ~= nil), "len=", tostring(decoded and string.len(decoded)), "marker=", tostring(decoded and string.sub(decoded,1,1)))
		if not decoded then
			return -- probably an old version or somehow a bad message idk just throw this away
		end
		-- 1-byte marker set by RCLootCouncil:SendCommand() - "C" = Deflate-compressed, "R" = raw
		local marker = string.sub(decoded, 1, 1)
		local body = string.sub(decoded, 2)
		-- NOT the and/or ternary idiom - if DecompressDeflate(body) itself fails and returns nil,
		-- "X and Y or Z" would silently fall through to Z (still-compressed garbage) instead of
		-- failing cleanly.
		local decompressed
		if marker == "C" then
			decompressed = Deflate:DecompressDeflate(body)
		else
			decompressed = body
		end
		if not decompressed then
			-- DIAGNOSTIC: addon:Debug (not DebugLog, which never prints to chat) so a real
			-- failure here is finally visible instead of silently dropping the message with no
			-- trace. Remove once the vote/response silent-failure mystery is resolved.
			addon:Debug("VotingComm decompress failed, dropping message from:", sender, "marker=", tostring(marker))
			return
		end
		local test, command, data = addon:Deserialize(decompressed)
		if addon:HandleXRealmComms(self, command, data, sender) then return end

		-- DIAGNOSTIC: same as above - was DebugLog (silent), now Debug (visible).
		addon:Debug("VotingComm received:", tostring(command), "from:", tostring(sender), "distri:", tostring(distri), "test:", tostring(test))

		if test then
			if command == "vote" then
				if addon:IsCouncil(sender) or addon:UnitIsUnit(sender, addon.masterLooter) then
					local s, name, vote = unpack(data)
					addon:Debug("VotingComm vote:", "session=", tostring(s), "name=", tostring(name), "vote=", tostring(vote))
					self:HandleVote(s, name, vote, sender)
				else
					addon:Debug("Non-council member (".. tostring(sender) .. ") sent a vote!")
				end
			
			elseif command == "history_request" and addon.isMasterLooter then 
				local requested_name = unpack(data)
				if addon.successful_history_requests[requested_name] and addon.successful_history_requests[requested_name].ts + 20 > time() then 
					return
				end
				if addon.successful_history_requests[requested_name] and addon.successful_history_requests[requested_name][sender] then 
					return
				end
				addon.successful_history_requests[requested_name] = addon.successful_history_requests[requested_name] or {}
				addon.successful_history_requests[requested_name].ts = time()
				addon.successful_history_requests[requested_name][sender] = true 

				local playerDB = addon:GetHistoryDB()[requested_name] or {}
				local response = {}
				local count = 0

				for i = 1, tgetn(playerDB) do
					local entry = playerDB[i] 
					-- respond with only max rolls and the players last 5 roll wins
					if entry.responseID == 1 then 
						tinsert(response, entry)
					elseif not entry.isAwardReason and count < 5 then 
						tinsert(response, entry)
						count = count + 1
					end
				end

				addon:SendCommand("group", "update_history", requested_name, response) -- tell everyone so we don't have to send this a bunch
			
			elseif command == "update_history" and addon:UnitIsUnit(sender, addon.masterLooter) then
				local entry_name, data = unpack(data) 
				addon.mlhistory[entry_name] = data
			
			elseif command == "change_response" and addon:UnitIsUnit(sender, addon.masterLooter) then
				local ses, name, response = unpack(data)
				self:SetCandidateData(ses, name, "response", response)
				self:Update()

			elseif command == "lootAck" then
				local name = unpack(data)
				for i = 1, tgetn(lootTable) do
					self:SetCandidateData(i, name, "response", "WAIT")
				end
				self:Update()

			elseif command == "awarded" and addon:UnitIsUnit(sender, addon.masterLooter) then
				lootTable[unpack(data)].awarded = true
				if addon.isMasterLooter and session ~= tgetn(lootTable) then -- ML should move to the next item on award
					self:SwitchSession(session + 1)
				else
					self:SwitchSession(session) -- Use switch session to update awardstring
				end

			elseif command == "candidates" and addon:UnitIsUnit(sender, addon.masterLooter) then
				candidates = unpack(data)
				-- CONFIRMED LIVE ("attempt to index field '?'" inside SetCandidateData, for every
				-- response received): Setup() (triggered by "lootTable") can run BEFORE
				-- "candidates" has arrived on this client, since they're sent as 2 separate comms
				-- with no ordering guarantee - Setup() then builds each session's candidate table
				-- from whatever `candidates` holds AT THAT MOMENT (empty, if "candidates" hasn't
				-- landed yet), permanently leaving it empty for the rest of the session since
				-- nothing ever revisits it afterward. Backfill any session that's already been set
				-- up with whichever candidates are still missing, instead of leaving them broken.
				if lootTable then
					for _, t in ipairs(lootTable) do
						t.candidates = t.candidates or {}
						for name, v in pairs(candidates) do
							if not t.candidates[name] then
								t.candidates[name] = NewCandidateEntry(v)
							end
						end
					end
					self:Update()
				end

			elseif command == "offline_timer" and addon:UnitIsUnit(sender, addon.masterLooter) then
				for i = 1, tgetn(lootTable) do
					for name in pairs(lootTable[i].candidates) do
						if self:GetCandidateData(i, name, "response") == "ANNOUNCED" then
							addon:DebugLog("No response from:", name)
							self:SetCandidateData(i, name, "response", "NOTHING")
						end
					end
				end
				self:Update()

			elseif command == "lootTable" and addon:UnitIsUnit(sender, addon.masterLooter) then
				active = true
				self:Setup(unpack(data))
				if not addon.enabled then return end -- We just want things ready
				if db.autoOpen then
					self:Show()
				else
					addon:Print(L['A new session has begun, type "/rc open" to open the voting frame.'])
				end
				guildRanks = addon:GetGuildRanks() -- Just update it on every session

			elseif command == "response" then
				local session, name, t = unpack(data)
				for k,v in pairs(t) do
					self:SetCandidateData(session, name, k, v)
				end
				self:Update()
			end
		end
	end
end

-- Getter/Setter for candidate data
-- Handles errors
function RCVotingFrame:SetCandidateData(session, candidate, data, val)
	local function Set(session, candidate, data, val)
		lootTable[session].candidates[candidate][data] = val
	end
	local ok, arg = pcall(Set, session, candidate, data, val)
	if not ok then addon:Debug("Error in 'SetCandidateData':", arg, session, candidate, data, val) end
end

function RCVotingFrame:GetCandidateData(session, candidate, data)
	local function Get(session, candidate, data)
		return lootTable[session].candidates[candidate][data]
	end
	local ok, arg = pcall(Get, session, candidate, data)
	if not ok then addon:Debug("Error in 'GetCandidateData':", arg, session, candidate, data)
	else return arg end
end

-- TESTING ONLY: lets a caller (ml_core.lua's solo "Hideurkids" testing bypass) push the ML's own
-- candidate roster directly instead of going through the "candidates" comm broadcast, which
-- Setup() below reads from this file's own `candidates` upvalue. Normally that upvalue is only
-- ever populated by RECEIVING the "candidates" comm (see OnCommReceived's "candidates" branch) -
-- confirmed live that a solo "group"-target comm (which whispers to yourself when not in a
-- raid/party) never actually arrives back on this client, so Setup() would otherwise build every
-- session's candidate list from an empty table. Remove before any real release.
function RCVotingFrame:SetCandidates(t)
	candidates = t
end

function RCVotingFrame:Setup(table)
	--lootTable[session] = {bagged, lootSlot, awarded, name, link, quality, ilvl, type, subType, equipLoc, texture, boe}
	lootTable = table -- Extract all the data we get
	for session, t in ipairs(lootTable) do -- and build the rest (candidates)
		lootTable[session].haveVoted = false -- Have we voted for ANY candidate in this session?
		t.candidates = {}
		for name, v in pairs(candidates) do
			t.candidates[name] = NewCandidateEntry(v)
		end
		-- Init session toggle
		sessionButtons[session] = self:UpdateSessionButton(session, t.texture, t.link, t.awarded)
		sessionButtons[session]:Show()
	end
	-- Hide unused session buttons
	for i = tgetn(lootTable)+1, tgetn(sessionButtons) do
		sessionButtons[i]:Hide()
	end
	session = 1
	-- Check if we have enchanters
	for name, v in pairs(candidates) do

	end
	self:BuildST()
	self:SwitchSession(session)
end

function RCVotingFrame:HandleVote(session, name, vote, voter)
	-- Do the vote
	if not lootTable or not lootTable[session] or not lootTable[session].candidates or not lootTable[session].candidates[name] then
		-- DIAGNOSTIC: this early-return was silent - print exactly which check failed.
		addon:Debug("HandleVote bailed:", "lootTable=", tostring(lootTable), "session=", tostring(session), "candidates=", tostring(lootTable and lootTable[session] and lootTable[session].candidates), "name=", tostring(name))
		return
	end
	
	local candData = lootTable[session].candidates[name]
	local alreadyVoted = tContains(candData.voters, voter)
	-- CONFIRMED LIVE: a single vote click was counting as 2 votes - made this idempotent per
	-- (session, candidate, voter) instead of blindly trusting HandleVote is only ever invoked
	-- once per real vote/unvote (e.g. if this client's "no self-echo" behavior turns out to only
	-- hold for WHISPER and not RAID, the self-loopback fix in SendCommand plus a genuine RAID
	-- echo would double-deliver every vote - this guards against that and any other duplicate
	-- delivery path regardless of root cause).
	if vote == 1 then
		if alreadyVoted then return end
		candData.votes = (candData.votes or 0) + 1
		tinsert(candData.voters, voter)
	else
		if not alreadyVoted then return end
		candData.votes = (candData.votes or 0) - 1
		for i, n in ipairs(candData.voters) do
			if addon:UnitIsUnit(voter, n) then
				tremove(candData.voters, i)
				break
			end
		end
	end
	self.frame.st:Refresh()
	self:UpdatePeopleToVote()
end

function RCVotingFrame:DoRandomRolls(ses)
	for _, v in pairs (lootTable[ses].candidates) do
		v.roll = math.random(100)
	end
	self:Update()
end

------------------------------------------------------------------
--	Visuals														--
------------------------------------------------------------------
function RCVotingFrame:Update()
	self.frame.st:SortData()
	-- update awardString
	if lootTable[session] and lootTable[session].awarded then
		self.frame.awardString:Show()
	else
		self.frame.awardString:Hide()
	end
	-- This only applies to the ML
	if addon.isMasterLooter then
		-- Update close button text
		if active then
			self.frame.abortBtn:SetText(L["Abort"])
		else
			self.frame.abortBtn:SetText(L["Close"])
		end
	else -- Non-MLs:
		self.frame.abortBtn:SetText(L["Close"])
	end
end

function RCVotingFrame:SwitchSession(s)
	addon:Debug("SwitchSession", s)
	-- Start with setting up some statics
	local old = session
	session = s
	local t = lootTable[s] -- Shortcut
	-- CONFIRMED LIVE: a "lootTable" comm can arrive genuinely empty (lootTable[1] nil) if it gets
	-- corrupted in transit, e.g. sent too close together with other comms under heavy AddOn
	-- message traffic - crashing here used to leave the whole window stuck on its placeholder
	-- text with a dead candidate table. Bail out cleanly instead so a follow-up "lootTable" (the
	-- ML's own resend/self-heal paths) can still recover the window.
	if not t then
		return addon:Debug("SwitchSession bailed: no lootTable entry for session", s)
	end
	self.frame.itemIcon:SetNormalTexture(t.texture)
	self.frame.itemText:SetText(t.link)
	self.frame.iState:SetText(self:GetItemStatus(t.link))
	self.frame.itemLvl:SetText(format(L["ilvl: x"], t.ilvl))
	-- Set a proper item type text
	if t.subType and t.subType ~= "Miscellaneous" and t.subType ~= "Junk" and t.equipLoc ~= "" then
		-- getglobal(t.equipLoc) can come back nil on this client (e.g. t.equipLoc not matching a
		-- real INVTYPE_* global) - guard the concat instead of crashing, fall back to the raw
		-- equipLoc token so something still shows rather than nothing.
		self.frame.itemType:SetText((getglobal(t.equipLoc) or t.equipLoc)..", "..t.subType); -- getGlobal to translate from global constant to localized name
	elseif t.subType ~= "Miscellaneous" and t.subType ~= "Junk" then
		self.frame.itemType:SetText(t.subType)
	else
		self.frame.itemType:SetText(getglobal(t.equipLoc));
	end

	-- Update the session buttons
	sessionButtons[s] = self:UpdateSessionButton(s, t.texture, t.link, t.awarded)
	sessionButtons[old] = self:UpdateSessionButton(old, lootTable[old].texture, lootTable[old].link, lootTable[old].awarded)

	-- Since we switched sessions, we want to sort by response
	-- FOUND STALE: this hardcoded index (5) never actually pointed at the Response column - it's
	-- a leftover from an earlier round that removed the "Diff" column and shifted everything
	-- after it, without updating this literal. Response is column 4 (see self.scrollCols above).
	for i in ipairs(self.frame.st.cols) do
		self.frame.st.cols[i].sort = nil
	end
	self.frame.st.cols[4].sort = "asc"
	-- CONFIRMED LIVE: this crashes deep inside Blizzard's own FrameXML (UIPanelTemplates.lua -
	-- "attempt to concatenate a nil value") - lib-st's FauxScrollFrame doesn't set up a real
	-- .scrollChild the way Blizzard's own FauxScrollFrameTemplate usage normally expects (it draws
	-- its own rows/scrolltrough manually instead), so this native helper likely isn't safe to call
	-- directly the way lib-st's OWN internal scroll-drag handler does. pcall-wrapped so a
	-- resulting failure here doesn't crash the whole SwitchSession - falls back to just calling
	-- Refresh() directly, which is really all "reset scrolling to 0" needs (offset already
	-- defaults/resets via SetDisplayRows on data changes; this call's only other job, moving the
	-- value passed to Refresh's callback, isn't otherwise essential here).
	local ok = pcall(FauxScrollFrame_OnVerticalScroll, self.frame.st.scrollframe, 0, self.frame.st.rowHeight, function() self.frame.st:Refresh() end) -- Reset scrolling to 0
	if not ok then
		self.frame.st:Refresh()
	end
	self:Update()
	self:UpdatePeopleToVote()
end

function RCVotingFrame:BuildST()
	local rows = {}
	local i = 1
	for name in pairs(candidates) do
		rows[i] = {
			name = name,
			cols = {
				{ value = "",	DoCellUpdate = self.SetCellClass,		name = "class",},
				{ value = "",	DoCellUpdate = self.SetCellName,			name = "name",},
				{ value = "",	DoCellUpdate = self.SetCellRank,			name = "rank",},
				{ value = "",	DoCellUpdate = self.SetCellResponse,	name = "response",},
				{ value = "",	DoCellUpdate = self.SetCellGear, 		name = "gear1",},
				{ value = "",	DoCellUpdate = self.SetCellGear, 		name = "gear2",},
				{ value = 0,	DoCellUpdate = self.SetCellVotes, 		name = "votes",},
				{ value = 0,	DoCellUpdate = self.SetCellVote,			name = "vote",},
				{ value = 0,	DoCellUpdate = self.SetCellNote, 		name = "note",},
				{ value = "",	DoCellUpdate = self.SetCellRoll,			name = "roll"},
				{ value = "",	DoCellUpdate = self.SetCellAward,		name = "award",},
			},
		}
		i = i + 1
	end
	self.frame.st:SetData(rows)
end

function RCVotingFrame:UpdateMoreInfo(row, data)
	addon:Debug("MoreInfo:", moreInfo)
	local name
	if data then
		name  = data[row].name
	else -- Try to extract the name from the selected row
		name = self.frame.st:GetSelection() and self.frame.st:GetRow(self.frame.st:GetSelection()).name or nil
	end

	if not moreInfo or not name then -- Hide the frame
		return self.frame.moreInfo:Hide()
	end

	local color = addon:GetClassColor(self:GetCandidateData(session, name, "class"))
	tip = self.frame.moreInfo -- shortening
	local count = {} -- Number of loot received
	tip:SetOwner(self.frame, "ANCHOR_RIGHT")

	--Extract loot history for that name
	local lootDB = addon:GetHistoryDB()
	local hasWonMainspec, entry = false, nil
	local nameCheck
	if lootDB[name] then
		nameCheck = true
	end

	tip:AddLine(name, color.r, color.g, color.b)
	color = {} -- Color of the response
	if nameCheck and tgetn(lootDB[name]) > 0 then -- they're in the DB!
		tip:AddLine("")
		local nonMainspecEntries = {}
		for i = tgetn(lootDB[name]), 1, -1 do -- Start from the end
			entry = lootDB[name][i]
			-- check if we have won an item in this slot for a max roll
			-- self.lootTable[session] = {	bagged, lootSlot, awarded, name, link, quality, ilvl, type, subType, equipLoc, texture, boe	}
			local item_slot = lootTable[session].equipLoc
			local itemid = tonumber(select(3, strfind(entry.lootWon, "item:(%d+)"))) or 0
			local historical_item_slot = select(9, addon:GetItemInfo(itemid))

			if not historical_item_slot or historical_item_slot == "" then 
				historical_item_slot = RCTokenTable[itemid]

				if not addon.Slots_INVTYPE[item_slot] then -- when we are comparing a normal item with a token we won previously
					local original = item_slot
					item_slot = addon.INVTYPE_Slots[original] and addon.INVTYPE_Slots[original][1] or addon.INVTYPE_Slots[original] or "INVTYPE_NONE"
					if historic_item_slot ~= item_slot and addon.INVTYPE_Slots[original] and addon.INVTYPE_Slots[original]["or"] then
						item_slot = addon.INVTYPE_Slots[original]["or"]
					end 
				end
			end

			if entry.responseID == addon.db.profile.checkID or 1 and not entry.isAwardReason and item_slot == historical_item_slot and not hasWonMainspec then -- Won MS roll for this slot
				tip:AddDoubleLine(format(L["Item won for 'roll':"], addon:GetResponseText(entry.responseID)), "", 1,1,1, 1,1,1)
				tip:AddLine(entry.lootWon)
				tip:AddDoubleLine(entry.time .. " " ..entry.date, format(L["'n days' ago"], addon:ConvertDateToString(addon:GetNumberOfDaysFromNow(entry.date))), 1,1,1, 1,1,1)
				tip:AddLine(" ") -- Spacer
				hasWonMainspec = true
			else
				if tgetn(nonMainspecEntries) < 5 then -- only save last 5 items won
					tinsert(nonMainspecEntries, entry)
				end
			end

			-- count overall responses
			count[entry.response] = count[entry.response] and count[entry.response] + 1 or 1
			if not color[entry.response] then -- If it's not already added
				color[entry.response] = entry.color and tgetn(entry.color) == 4 and entry.color or addon:GetResponseColorTable(entry.responseID) or {1, 1, 1, 1}
			end

		end -- end counting

		if not hasWonMainspec then -- list non mainspec entries if we havent won a mainspec item
			tip:AddLine(" ")
			tip:AddLine("Last 5 items won:")
			for _, entry in ipairs(nonMainspecEntries) do 
				local r, g, b = unpack(addon:GetResponseColorTable(entry.responseID))
				tip:AddDoubleLine(format(L["Won 'item'"], entry.lootWon), addon:GetResponseText(entry.responseID), 1,1,1, r, g, b)
				tip:AddDoubleLine(entry.time .. " " ..entry.date, format(L["'n days' ago"], addon:ConvertDateToString(addon:GetNumberOfDaysFromNow(entry.date))), 1,1,1, 1,1,1)
			end
			tip:AddLine(" ")
		end

		local totalNum = 0
		for response, num in pairs(count) do
			local r,g,b = unpack(color[response])
			tip:AddDoubleLine(response, num, r,g,b, r,g,b) -- Make sure we don't add the alpha value
			totalNum = totalNum + num
		end
		tip:AddDoubleLine(L["Total items received:"], totalNum, 0,1,1, 0,1,1)
	elseif not nameCheck and not addon.isMasterLooter then
		--request history for this specific guy
		addon:SendCommand(addon.masterLooter, "history_request", name)
		tip:AddLine("Requesting loot history from Master Looter...")
		self:ScheduleTimer("UpdateMoreInfo", 1, row, data)
	else 
		tip:AddLine(L["No entries in the Loot History"])
	end
	tip:SetScale(max(0.5, db.UI.votingframe.scale-0.1)) -- Make it a bit smaller, as it's too wide otherwise
	tip:Show()
	tip:SetAnchorType("ANCHOR_RIGHT", 0, -tip:GetHeight())
end


function RCVotingFrame:GetFrame()
	if self.frame then return self.frame end

	-- Container and title
	local f = addon:CreateFrame("DefaultRCLootCouncilFrame", "votingframe", L["RCLootCouncil Voting Frame"], 250, 420)
	-- Scrolling table
	local st = LibStub("ScrollingTable"):CreateST(self.scrollCols, NUM_ROWS, ROW_HEIGHT, { ["r"] = 1.0, ["g"] = 0.9, ["b"] = 0.0, ["a"] = 0.5 }, f.content)
	st.frame:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 10)
	st:RegisterEvents({
		["OnClick"] = function(rowFrame, cellFrame, data, cols, row, realrow, column, table, button, ...)
			if button == "RightButton" and row then
				if not _G.Lib_ToggleDropDownMenu then
					-- Right-click menu deprioritized for now (Award is a direct button instead)
					-- while Lib_UIDropDownMenu is unresolved on this client.
				elseif active then
					menuFrame.name = data[realrow].name
					Lib_ToggleDropDownMenu(1, nil, menuFrame, cellFrame, 0, 0);
				else
					addon:Print(L["You cannot use the menu when the session has ended."])
				end
			elseif button == "LeftButton" and row then -- Update more info
				self:UpdateMoreInfo(realrow, data)
			end
			-- Return false to have the default OnClick handler take care of left clicks
			return false
		end,
	})
	st:SetFilter(RCVotingFrame.filterFunc)
	st:EnableSelection(true)
	f.st = st
	--[[------------------------------
		Session item icon and strings
	    ------------------------------]]
	local item = CreateFrame("Button", nil, f.content)
	item:EnableMouse()
    item:SetNormalTexture("Interface/ICONS/INV_Misc_QuestionMark")
    item:SetScript("OnEnter", function()
		if not lootTable then return; end
		addon:CreateHypertip(lootTable[session].link)
	end)
	item:SetScript("OnLeave", addon.HideTooltip)
	item:SetScript("OnClick", function()
		if not lootTable then return; end
	    -- IsModifiedClick() doesn't exist on this client - see addon:IsModifiedClick().
	    if ( addon:IsModifiedClick() ) then
		    HandleModifiedItemClick(lootTable[session].link);
        end
    end);
	item:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -20)
	item:SetSize(50,50)
	f.itemIcon = item

	local iTxt = f.content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	iTxt:SetPoint("TOPLEFT", item, "TOPRIGHT", 10, 0)
	iTxt:SetText(L["Something went wrong :'("]) -- Set text for reasons
	f.itemText = iTxt

	local ilvl = f.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	ilvl:SetPoint("TOPLEFT", iTxt, "BOTTOMLEFT", 0, -4)
	ilvl:SetTextColor(1, 1, 1) -- White
	ilvl:SetText("")
	f.itemLvl = ilvl

	local iState = f.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	iState:SetPoint("LEFT", ilvl, "RIGHT", 5, 0)
	iState:SetTextColor(0,1,0,1) -- Green
	iState:SetText("")
	f.iState = iState

	local iType = f.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	iType:SetPoint("TOPLEFT", ilvl, "BOTTOMLEFT", 0, -4)
	iType:SetTextColor(0.5, 1, 1) -- Turqouise
	iType:SetText("")
	f.itemType = iType
	--#end----------------------------

	-- Abort button
	local b1 = addon:CreateButton(L["Close"], f.content)
	b1:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -50)
	if addon.isMasterLooter then
		b1:SetScript("OnClick", function() if active then LibDialog:Spawn("RCLOOTCOUNCIL_CONFIRM_ABORT") else self:Hide() end end)
	else
		b1:SetScript("OnClick", function() self:Hide() end)
	end
	f.abortBtn = b1

	-- More info button
	-- CONFIRMED LIVE: an ANONYMOUS (nil-named) "UIPanelButtonTemplate" button crashes deep inside
	-- Blizzard's own FrameXML (Interface\FrameXML\UIPanelTemplates.lua - "attempt to concatenate
	-- a nil value") - that template's own baked-in scripts do a `self:GetName().."Text"`-style
	-- lookup to find their sibling text region, which fails when GetName() returns nil. This is
	-- Blizzard's OWN template code, not ours - give it a real, unique name instead.
	local b2 = CreateFrame("Button", "RCLootCouncil_VotingFrame_MoreInfoButton", f.content, "UIPanelButtonTemplate")
	b2:SetSize(25,25)
	b2:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -20)
	if moreInfo then
		b2:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up");
		b2:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Down");
	else
		b2:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
		b2:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Down")
	end
	-- SetScript callbacks get ZERO real arguments on this client (the engine sets `this`/argN as
	-- globals instead) - a declared parameter like `button`/`self` here is always nil, so any use
	-- of it in the body crashes. Read `this` instead. This one (b2, "more info" toggle) is a real,
	-- always-active button - the crash would have hit on literally every click.
	b2:SetScript("OnClick", function()
		moreInfo = not moreInfo
		db.modules["RCVotingFrame"].moreInfo = moreInfo
		if moreInfo then -- show the more info frame
			this:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up");
			this:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Down");
		else -- hide it
			this:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
			this:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Down")
		end
		RCVotingFrame:UpdateMoreInfo()
	end)
	b2:SetScript("OnEnter", function() addon:CreateTooltip(L["Click to expand/collapse more info"]) end)
	b2:SetScript("OnLeave", addon.HideTooltip)
	f.moreInfoBtn = b2

	f.moreInfo = CreateFrame( "GameTooltip", "RCVotingFrameMoreInfo", nil, "GameTooltipTemplate" )

	-- Filter and Disenchant(enchanters) buttons removed per user request - both only ever opened
	-- dropdown menus that have been dead/inert since round 23 (Lib_ToggleDropDownMenu unresolved
	-- on this client), so they never did anything when clicked.

	-- Number of votes
	local rf = CreateFrame("Frame", nil, f.content)
	rf:SetWidth(100)
	rf:SetHeight(20)
	if b2 then rf:SetPoint("RIGHT", b2, "LEFT", -10, 0) else rf:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -20) end
	rf:SetScript("OnLeave", function()
		addon:HideTooltip()
	end)
	local rft = rf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	rft:SetPoint("CENTER", rf, "CENTER")
	rft:SetText(" ")
	rft:SetTextColor(0,1,0,1) -- Green
	rf.text = rft
	rf:SetWidth(rft:GetStringWidth())
	f.rollResult = rf

	-- Award string
	local awdstr = f.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	awdstr:SetPoint("CENTER", f.content, "TOP", 0, -60)
	awdstr:SetText(L["Item has been awarded"])
	awdstr:SetTextColor(1, 1, 0, 1) -- Yellow
	awdstr:Hide()
	f.awardString = awdstr

	-- Session toggle
	local stgl = CreateFrame("Frame", nil, f.content)
	stgl:SetWidth(40)
	stgl:SetHeight(f:GetHeight())
	stgl:SetPoint("TOPRIGHT", f, "TOPLEFT", -2, 0)
	f.sessionToggleFrame = stgl

	-- Set a proper width
	f:SetWidth(st.frame:GetWidth() + 20)
	return f;
end

function RCVotingFrame:UpdatePeopleToVote()
	local voters = {}
	-- Find out who have voted
	for name in pairs(lootTable[session].candidates) do
		for _, voter in pairs(lootTable[session].candidates[name].voters) do
			if not tContains(voters, voter) then
				tinsert(voters, voter)
			end
		end
	end
	if tgetn(councilInGroup) == 0 then
		self.frame.rollResult.text:SetText(L["Couldn't find any councilmembers in the group"])
		self.frame.rollResult.text:SetTextColor(1,0,0,1) -- Red
	elseif tgetn(voters) == tgetn(councilInGroup) then
		self.frame.rollResult.text:SetText(L["Everyone have voted"])
		self.frame.rollResult.text:SetTextColor(0,1,0,1) -- Green
	elseif tgetn(voters) < tgetn(councilInGroup) then
		self.frame.rollResult.text:SetText(format(L["x out of x have voted"], tgetn(voters), tgetn(councilInGroup)))
		self.frame.rollResult.text:SetTextColor(1,1,0,1) -- Yellow
	else
		addon:Debug("#voters > #councilInGroup ?")
	end
	self.frame.rollResult:SetScript("OnEnter", function()
		addon:CreateTooltip(L["The following council members have voted"], unpack(voters))
	end)
	self.frame.rollResult:SetWidth(self.frame.rollResult.text:GetStringWidth())
end

function RCVotingFrame:UpdateSessionButton(i, texture, link, awarded)
	local btn = sessionButtons[i]
	if not btn then -- create the button
		btn = CreateFrame("Button", "RCButton"..i, self.frame.sessionToggleFrame)
		btn:SetSize(40,40)
		--btn:SetText(i)
		if i == 1 then
			btn:SetPoint("TOPRIGHT", self.frame.sessionToggleFrame)
		elseif mod(i,10) == 1 then
			btn:SetPoint("TOPRIGHT", sessionButtons[i-10], "TOPLEFT", -2, 0)
		else
			btn:SetPoint("TOP", sessionButtons[i-1], "BOTTOM", 0, -2)
		end
		-- "Onclick" (was lowercase 'c') isn't a recognized script type on this client - script
		-- type names are case-sensitive, so this silently never fired, meaning clicking a session
		-- button to switch between looted items never worked at all.
		btn:SetScript("OnClick", function() RCVotingFrame:SwitchSession(i); end)
		btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
		-- Confirmed live: GetHighlightTexture()/GetNormalTexture() can come back nil right after
		-- the matching SetXTexture() call on this client (a bare CreateFrame("Button") button, no
		-- template) - guard both instead of crashing on what's purely a cosmetic z-order tweak.
		local highlightTex = btn:GetHighlightTexture()
		if highlightTex then highlightTex:SetBlendMode("ADD") end
		btn:SetNormalTexture(texture or "Interface\\InventoryItems\\WoWUnknownItem01")
		local normalTex = btn:GetNormalTexture()
		if normalTex then normalTex:SetDrawLayer("BACKGROUND") end
	end
	-- then update it
	btn:SetNormalTexture(texture or "Interface\\InventoryItems\\WoWUnknownItem01")
	-- Set the colored border and tooltips
	btn:SetBackdrop({
		bgFile = "",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 18,
		--insets = { left = -4, right = -4, top = -4, bottom = -4 }
	})
	local lines = { format(L["Click to switch to 'item'"], link) }
	-- Confirmed live: GetNormalTexture() can come back nil on this client (same as the
	-- create-button guard above) - guard here too instead of crashing on a cosmetic vertex tint.
	local sessionNormalTex = btn:GetNormalTexture()
	if i == session then
		btn:SetBackdropBorderColor(1,1,0,1) -- yellow
		--btn:SetBackdropColor(1,1,1,1)
		if sessionNormalTex then sessionNormalTex:SetVertexColor(1,1,1) end
	elseif awarded then
		btn:SetBackdropBorderColor(0,1,0,1) -- green
		--btn:SetBackdropColor(1,1,1,0.8)
		if sessionNormalTex then sessionNormalTex:SetVertexColor(0.8,0.8,0.8) end
		tinsert(lines, L["This item has been awarded"])
	else
		btn:SetBackdropBorderColor(1,1,1,1) -- white
		--btn:SetBackdropColor(0.5,0.5,0.5,0.8)
		if sessionNormalTex then sessionNormalTex:SetVertexColor(0.5,0.5,0.5) end
	end
	btn:SetScript("OnEnter", function() addon:CreateTooltip(unpack(lines)) end)
	btn:SetScript("OnLeave", function() addon:HideTooltip() end)
	return btn
end


----------------------------------------------------------
--	Lib-st data functions (not particular pretty, I know)
----------------------------------------------------------
function RCVotingFrame:GetDiffColor(num)
	if num == "" then num = 0 end -- Can't compare empty string
	local green, red, grey = {0,1,0,1},{1,0,0,1},{0.75,0.75,0.75,1}
	if num > 0 then return green end
	if num < 0 then return red end
	return grey
end

function RCVotingFrame.SetCellClass(rowFrame, frame, data, cols, row, realrow, column, fShow, table, ...)
	local name = data[realrow].name
	addon.SetCellClassIcon(rowFrame, frame, data, cols, row, realrow, column, fShow, table, lootTable[session].candidates[name].class)
end

function RCVotingFrame.SetCellName(rowFrame, frame, data, cols, row, realrow, column, fShow, table, ...)
	local name = data[realrow].name
	frame.text:SetText(name)
	local c = addon:GetClassColor(lootTable[session].candidates[name].class)
	frame.text:SetTextColor(c.r, c.g, c.b, c.a)
	data[realrow].cols[column].value = name
end

function RCVotingFrame.SetCellRank(rowFrame, frame, data, cols, row, realrow, column, fShow, table, ...)
	local name = data[realrow].name
	frame.text:SetText(lootTable[session].candidates[name].rank)
	frame.text:SetTextColor(addon:GetResponseColor(lootTable[session].candidates[name].response))
	data[realrow].cols[column].value = lootTable[session].candidates[name].rank
end

function RCVotingFrame.SetCellResponse(rowFrame, frame, data, cols, row, realrow, column, fShow, table, ...)
	local name = data[realrow].name
	frame.text:SetText(addon:GetResponseText(lootTable[session].candidates[name].response))
	frame.text:SetTextColor(addon:GetResponseColor(lootTable[session].candidates[name].response))
end


function RCVotingFrame.SetCellDiff(rowFrame, frame, data, cols, row, realrow, column, fShow, table, ...)
	local name = data[realrow].name
	frame.text:SetText(lootTable[session].candidates[name].diff)
	frame.text:SetTextColor(unpack(RCVotingFrame:GetDiffColor(lootTable[session].candidates[name].diff)))
	data[realrow].cols[column].value = lootTable[session].candidates[name].diff
end

function RCVotingFrame.SetCellGear(rowFrame, frame, data, cols, row, realrow, column, fShow, table, ...)
	local gear = data[realrow].cols[column].name -- gear1 or gear2
	local name = data[realrow].name
	gear = lootTable[session].candidates[name][gear] -- Get the actual gear
	if gear then
		local texture = select(10, addon:GetItemInfo(gear))
		-- Same client-specific GetItemInfo texture gap fixed in ml_core.lua:AddItem - fall back
		-- to the dedicated GetItemIcon() API when GetItemInfo's own texture comes back nil.
		-- CONFIRMED LIVE ("Usage: GetItemIcon(itemID)"): GetItemIcon needs a bare numeric ID, but
		-- `gear` here is a full decorated item link (from GetInventoryItemLink) - extract the ID
		-- first, same as every other GetItemIcon call site in this addon already does.
		if not texture and _G.GetItemIcon then
			texture = GetItemIcon(tonumber(gear) or addon:GetItemIDFromLink(gear))
		end
		frame:SetNormalTexture(texture)
		frame:SetScript("OnEnter", function() addon:CreateHypertip(gear) end)
		frame:SetScript("OnLeave", function() addon:HideTooltip() end)
		frame:Show()
	else
		frame:Hide()
	end
end

function RCVotingFrame.SetCellVotes(rowFrame, frame, data, cols, row, realrow, column, fShow, table, ...)
	local name = data[realrow].name
	frame:SetScript("OnEnter", function()
		if not addon.mldb.anonymousVoting or (db.showForML and addon.isMasterLooter) then
			if not addon.mldb.hideVotes or (addon.mldb.hideVotes and lootTable[session].haveVoted) then
				addon:CreateTooltip(L["Voters"], unpack(lootTable[session].candidates[name].voters))
			end
		end
	end)
	frame:SetScript("OnLeave", function() addon:HideTooltip() end)
	local val = lootTable[session].candidates[name].votes
	data[realrow].cols[column].value = val -- Set the value for sorting reasons
	frame.text:SetText(val)

	if addon.mldb.hideVotes then
		if not lootTable[session].haveVoted then frame.text:SetText(0) end
	end
end

function RCVotingFrame.SetCellVote(rowFrame, frame, data, cols, row, realrow, column, fShow, table, ...)
	local name = data[realrow].name
	if not active or lootTable[session].awarded then -- Don't show the vote button if awarded or not active
		if frame.voteBtn then
			frame.voteBtn:Hide()
		end
		return
	end
	if addon.isCouncil or addon.isMasterLooter then -- Only let the right people vote
		if not frame.voteBtn then -- create it
			frame.voteBtn = addon:CreateButton(L["Vote"], frame)
			frame.voteBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
			frame.voteBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
			-- CONFIRMED LIVE (this is very likely the actual root cause of the old "double vote"
			-- bug, only ever worked around before via idempotent HandleVote rather than fixed at
			-- the source): SetCellVote is a DoCellUpdate callback that lib-st calls on EVERY table
			-- refresh (any vote/response/candidate change re-triggers it for every visible cell),
			-- and the old code called :SetScript("OnClick", ...) again every single time - on this
			-- client, repeatedly re-registering the same script type on the same button appears to
			-- be able to fire more than once per real click. Register the handler ONCE here at
			-- creation instead, and read which candidate it's currently for from a plain field on
			-- the button (updated on every refresh below) rather than closing over this call's own
			-- `name` local - the cached button gets reused for different candidates as the table
			-- re-sorts/scrolls, so the data it acts on still needs to be dynamic even though the
			-- handler registration itself no longer is.
			frame.voteBtn:SetScript("OnClick", function()
				local btnName = this.candidateName
				addon:Debug("Vote button pressed")
				if lootTable[session].candidates[btnName].haveVoted then -- unvote
					addon:SendCommand("group", "vote", session, btnName, -1)
					lootTable[session].candidates[btnName].haveVoted = false

					-- Check if that was our only vote
					local haveVoted = false
					for _, v in pairs(lootTable[session].candidates) do
						if v.haveVoted then haveVoted = true end
					end
					lootTable[session].haveVoted = haveVoted

				else -- vote
					-- Test if they may vote for themselves. selfVote defaults to true (core.lua) -
					-- this only actually blocks anything if the saved profile has it explicitly
					-- disabled. TESTING ONLY: "Hideurkids" bypasses this too - solo testing has
					-- exactly one candidate (the ML themselves), so blocking self-votes would make
					-- voting untestable entirely. Remove before any real release.
					if not addon.mldb.selfVote and addon:UnitIsUnit("player", btnName) and addon.playerName ~= "Hideurkids" then
						return addon:Print(L["The Master Looter doesn't allow votes for yourself."])
					end
					-- Test if they're allowed to cast multiple votes
					if not addon.mldb.multiVote then
						if lootTable[session].haveVoted then
							return addon:Print(L["The Master Looter doesn't allow multiple votes."])
						end
					end
					-- Do the vote
					addon:SendCommand("group", "vote", session, btnName, 1)
					lootTable[session].candidates[btnName].haveVoted = true
					lootTable[session].haveVoted = true
				end
			end)
		end
		frame.voteBtn.candidateName = name
		frame.voteBtn:Show()
		if lootTable[session].candidates[name].haveVoted then
			frame.voteBtn:SetText(L["Unvote"])
		else
			frame.voteBtn:SetText(L["Vote"])
		end
	end
end

--- Direct "Award" button per candidate row, so awarding doesn't require the right-click menu
-- (which depends on Lib_UIDropDownMenu, currently broken on this client). Delegates to the SAME
-- confirm-award dialog + RCLootCouncilML:Award() flow the right-click menu's "Award" option
-- already used - Award() itself already handles both cases correctly (give the item directly if
-- it's still in the loot window, or just announce+track it if it's already in the ML's bags), so
-- no new award logic needed here, just a non-dropdown way to trigger it.
function RCVotingFrame.SetCellAward(rowFrame, frame, data, cols, row, realrow, column, fShow, table, ...)
	local name = data[realrow].name
	if not active or lootTable[session].awarded then
		if frame.awardBtn then
			frame.awardBtn:Hide()
		end
		return
	end
	if addon.isMasterLooter then -- Only the ML can award
		if not frame.awardBtn then
			frame.awardBtn = addon:CreateButton(L["Award"], frame)
			frame.awardBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
			frame.awardBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
			-- CONFIRMED LIVE (an award was getting logged to history twice) - same root cause as
			-- SetCellVote's fix above: SetCellAward is a DoCellUpdate callback re-run on every
			-- table refresh, and re-registering OnClick every time on this client risks firing
			-- more than once per real click. Register once here, read the candidate name from a
			-- field on the button (updated every refresh below) instead of closing over this
			-- call's own `name` local.
			frame.awardBtn:SetScript("OnClick", function()
				local btnName = this.candidateName
				local candData = lootTable[session].candidates[btnName]
				LibDialog:Spawn("RCLOOTCOUNCIL_CONFIRM_AWARD", {
					session,
					btnName,
					candData.response,
					nil,
					candData.votes,
					candData.gear1,
					candData.gear2,
				})
			end)
		end
		frame.awardBtn.candidateName = name
		frame.awardBtn:Show()
	elseif frame.awardBtn then
		frame.awardBtn:Hide()
	end
end

function RCVotingFrame.SetCellNote(rowFrame, frame, data, cols, row, realrow, column, fShow, table, ...)
	local name = data[realrow].name
	local note = lootTable[session].candidates[name].note
	local f = frame.noteBtn or CreateFrame("Button", nil, frame)
	f:SetSize(ROW_HEIGHT, ROW_HEIGHT)
	f:SetPoint("CENTER", frame, "CENTER")
	-- No file extension on a Blizzard texture path (see sessionFrame.lua/core.lua's same fix) -
	-- a literal ".png" suffix can fail to load on this client.
	if note then
		f:SetNormalTexture("Interface\\BUTTONS\\UI-GuildButton-PublicNote-Up")
		f:SetScript("OnEnter", function() addon:CreateTooltip(L["Note"], note)	end)
		f:SetScript("OnLeave", function() addon:HideTooltip() end)
		data[realrow].cols[column].value = 1 -- Set value for sorting compability
	else
		f:SetScript("OnEnter", nil)
		f:SetNormalTexture("Interface\\BUTTONS\\UI-GuildButton-PublicNote-Disabled")
		data[realrow].cols[column].value = 0
	end
	frame.noteBtn = f
end

function RCVotingFrame.SetCellRoll(rowFrame, frame, data, cols, row, realrow, column, fShow, table, ...)
	local name = data[realrow].name
	frame.text:SetText(lootTable[session].candidates[name].roll)
	data[realrow].cols[column].value = lootTable[session].candidates[name].roll
end

function RCVotingFrame.filterFunc(table, row)
	if not db.modules["RCVotingFrame"].filters then return true end -- db hasn't been initialized, so just show it
	local response = lootTable[session].candidates[row.name].response
	if response == "AUTOPASS" or response == "PASS" or type(response) == "number" then
		return db.modules["RCVotingFrame"].filters[response]
	else -- Filter out the status texts
		return db.modules["RCVotingFrame"].filters["STATUS"]
	end
end

function ResponseSort(table, rowa, rowb, sortbycol)
	if type(rowa) == "table" then printtable(rowa) end
	local column = table.cols[sortbycol]
	local a, b = table:GetRow(rowa), table:GetRow(rowb);
	a, b = addon:GetResponseSort(lootTable[session].candidates[a.name].response), addon:GetResponseSort(lootTable[session].candidates[b.name].response)
	if a == b then
		if column.sortnext then
			local nextcol = table.cols[column.sortnext];
			if not(nextcol.sort) then
				if nextcol.comparesort then
					return nextcol.comparesort(table, rowa, rowb, column.sortnext);
				else
					return table:CompareSort(rowa, rowb, column.sortnext);
				end
			end
		end
		return false
	else
		local direction = column.sort or column.defaultsort or "asc";
		if string.lower(direction) == "asc" then
			return a < b;
		else
			return a > b;
		end
	end
end

function GuildRankSort(table, rowa, rowb, sortbycol)
	local column = table.cols[sortbycol]
	local a, b = table:GetRow(rowa), table:GetRow(rowb);
	-- Extract the rank index from the name, fallback to 100 if not found
	a = guildRanks[lootTable[session].candidates[a.name].rank] or 100
	b = guildRanks[lootTable[session].candidates[b.name].rank] or 100
	if a == b then
		if column.sortnext then
			local nextcol = table.cols[column.sortnext];
			if not(nextcol.sort) then
				if nextcol.comparesort then
					return nextcol.comparesort(table, rowa, rowb, column.sortnext);
				else
					return table:CompareSort(rowa, rowb, column.sortnext);
				end
			end
		end
		return false
	else
		local direction = column.sort or column.defaultsort or "asc";
		if string.lower(direction) == "asc" then
			return a > b;
		else
			return a < b;
		end
	end
end

----------------------------------------------------
--	Dropdowns
----------------------------------------------------
do
	-- CONFIRMED LIVE, high-severity: this call is at the enclosing `do` block's own top level -
	-- i.e. it runs unconditionally the moment this FILE loads, unlike the ~10 other
	-- Lib_UIDropDownMenu_CreateInfo() calls inside RightClickMenu/FilterMenu/EnchantersMenu below
	-- (those only run if the dropdown system ever actually invokes those callbacks, which round
	-- 23 confirmed it doesn't). Lib_UIDropDownMenu_CreateInfo being nil (the still-unresolved
	-- dropdown mystery) crashed HERE, at file-load time, every single session - and per this
	-- port's established "unguarded top-level crash kills every function defined after it in the
	-- file" bug class, that silently undefined EVERYTHING from here to the end of the file,
	-- including RCVotingFrame:GetItemStatus() (used by Update() - the function that actually
	-- populates the Voting Frame with item/candidate data). This is very likely the true, complete
	-- explanation for the Voting Frame never working all session, regardless of any comm/isCouncil
	-- fix upstream - OnEnable/Show could still run fine, but the moment Update() tried to call the
	-- (nonexistent) GetItemStatus, it crashed before finishing.
	local info = _G.Lib_UIDropDownMenu_CreateInfo and Lib_UIDropDownMenu_CreateInfo() or {} -- Efficiency :)
	-- NOTE Take care of info[] values when inserting new buttons
	function RCVotingFrame.RightClickMenu(menu, level)
		if not addon.isMasterLooter then return end

		local candidateName = menu.name
		local data = lootTable[session].candidates[candidateName] -- Shorthand

		if level == 1 then
			info.text = candidateName
			info.isTitle = true
			info.notCheckable = true
			info.disabled = true
			Lib_UIDropDownMenu_AddButton(info, level)

			info.text = ""
			info.isTitle = false
			Lib_UIDropDownMenu_AddButton(info, level)

			info.text = L["Award"]
			info.func = function()
				LibDialog:Spawn("RCLOOTCOUNCIL_CONFIRM_AWARD", {
					session,
				  	candidateName,
					data.response,
					nil,
					data.votes,
					data.gear1,
					data.gear2,
			}) end
			info.disabled = false
			Lib_UIDropDownMenu_AddButton(info, level)
			info = Lib_UIDropDownMenu_CreateInfo()

			info.text = L["Award for ..."]
			info.value = "AWARD_FOR"
			info.notCheckable = true
			info.hasArrow = true
			Lib_UIDropDownMenu_AddButton(info, level)
			info = Lib_UIDropDownMenu_CreateInfo()

			info.text = ""
			info.notCheckable = true
			info.disabled = true
			Lib_UIDropDownMenu_AddButton(info, level)

			info.text = L["Change Response"]
			info.value = "CHANGE_RESPONSE"
			info.hasArrow = true
			info.disabled = false
			Lib_UIDropDownMenu_AddButton(info, level)

			info.text = L["Reannounce ..."]
			info.value = "REANNOUNCE"
			Lib_UIDropDownMenu_AddButton(info, level)
			info = Lib_UIDropDownMenu_CreateInfo()

			info.text = L["Remove from consideration"]
			info.notCheckable = true
			info.func = function()
				addon:SendCommand("group", "change_response", session, candidateName, "REMOVED")
			end
			Lib_UIDropDownMenu_AddButton(info, level)

			info.text = L["Add rolls"]
			info.notCheckable = true
			info.func = function() RCVotingFrame:DoRandomRolls(session) end
			Lib_UIDropDownMenu_AddButton(info, level)

		elseif level == 2 then
			local value = LIB_UIDROPDOWNMENU_MENU_VALUE
			info = Lib_UIDropDownMenu_CreateInfo()
			if value == "AWARD_FOR" then
				for k,v in ipairs(db.awardReasons) do
					if k > db.numAwardReasons then break end
					info.text = v.text
					info.notCheckable = true
					info.func = function()
						LibDialog:Spawn("RCLOOTCOUNCIL_CONFIRM_AWARD", {
							session,
						  	candidateName,
							nil,
							v,
							data.votes,
							data.gear1,
							data.gear2,
				}) end
					Lib_UIDropDownMenu_AddButton(info, level)
				end

			elseif value == "CHANGE_RESPONSE" then
				for i = 1, db.numButtons do
					local v = db.responses[i]
					info.text = v.text
					info.colorCode = "|cff"..addon:RGBToHex(unpack(v.color))
					info.notCheckable = true
					info.func = function()
							addon:SendCommand("group", "change_response", session, candidateName, i)
					end
					Lib_UIDropDownMenu_AddButton(info, level)
				end

			elseif value == "REANNOUNCE" then
				info.text = candidateName
				info.isTitle = true
				info.notCheckable = true
				info.disabled = true
				Lib_UIDropDownMenu_AddButton(info, level)
				info = Lib_UIDropDownMenu_CreateInfo()

				info.text = L["This item"]
				info.notCheckable = true
				info.func = function()
					local t = {
						{	name = lootTable[session].name,
							link = lootTable[session].link,
							ilvl = lootTable[session].ilvl,
							texture = lootTable[session].texture,
							session = session,
							equipLoc = lootTable[session].equipLoc,
						}
					}
					addon:SendCommand(candidateName, "reroll", t)
				end
				Lib_UIDropDownMenu_AddButton(info, level);
				info = Lib_UIDropDownMenu_CreateInfo()

				info.text = L["All items"]
				info.notCheckable = true
				info.func = function()
					local t = {}
					for k,v in ipairs(lootTable) do
						if not v.awarded then
							tinsert(t, {
								name = v.name,
								link = v.link,
								ilvl = v.ilvl,
								texture = v.texture,
								session = k,
								equipLoc = v.equipLoc,
							})
						end
					end
					addon:SendCommand(candidateName, "reroll", t)
				end
				Lib_UIDropDownMenu_AddButton(info, level);
			end
		end
	end

	function RCVotingFrame.FilterMenu(menu, level)
		if level == 1 then -- Redundant
			-- Build the data table:
			local data = {["STATUS"] = true, ["PASS"] = true, ["AUTOPASS"] = true}
			for i = 1, addon.mldb.numButtons or db.numButtons do
				data[i] = i
			end
			if not db.modules["RCVotingFrame"].filters then -- Create the db entry
				addon:DebugLog("Created VotingFrame filters")
				db.modules["RCVotingFrame"].filters = {}
			end
			for k in pairs(data) do -- Update the db entry to make sure we have all buttons in it
				if type(db.modules["RCVotingFrame"].filters[k]) ~= "boolean" then
					addon:Debug("Didn't contain "..k)
					db.modules["RCVotingFrame"].filters[k] = true -- Default as true
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
					db.modules["RCVotingFrame"].filters[k] = not db.modules["RCVotingFrame"].filters[k]
					RCVotingFrame:Update()
				end
				info.checked = db.modules["RCVotingFrame"].filters[k]
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
						db.modules["RCVotingFrame"].filters[k] = not db.modules["RCVotingFrame"].filters[k]
						RCVotingFrame:Update()
					end
					info.checked = db.modules["RCVotingFrame"].filters[k]
					Lib_UIDropDownMenu_AddButton(info, level)
				end
			end
		end
	end

	function RCVotingFrame.EnchantersMenu(menu, level)
		if level == 1 then
			local added = false
			info = Lib_UIDropDownMenu_CreateInfo()
			if not db.disenchant then
				return addon:Print("You haven't selected an award reason to use for disenchanting!")
			end
			for name, v in pairs(candidates) do
				if v.enchanter then
					local c = addon:GetClassColor(v.class)
					info.text = "|cff"..addon:RGBToHex(c.r, c.g, c.b)..name.."|r "..tostring(v.enchant_lvl)
					info.notCheckable = true
					info.func = function()
						for k,v in ipairs(db.awardReasons) do
							if v.disenchant then
								LibDialog:Spawn("RCLOOTCOUNCIL_CONFIRM_AWARD", {
									session,
								  	name,
									nil,
									v,
								})
								return
							end
						end
					end
					added = true
					Lib_UIDropDownMenu_AddButton(info, level)
				end
			end
			if not added then -- No enchanters available
				info.text = L["No (dis)enchanters found"]
				info.notCheckable = true
				info.isTitle = true
				Lib_UIDropDownMenu_AddButton(info, level)
			end
		end
	end
end

function RCVotingFrame:GetItemStatus(item)
	--addon:DebugLog("GetitemStatus", item)
	if not item then return "" end
	GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
	GameTooltip:SetHyperlink(item)
	local text = ""
	if GameTooltip:NumLines() > 1 then -- check that there is something here
		local line = getglobal('GameTooltipTextLeft2') -- Should always be line 2
		-- line:GetText() can be nil (an empty tooltip line) - guard before strfind, which errors
		-- on a nil first argument instead of just failing the match.
		local lineText = line and line:GetText()
		-- The following color string should be there if we have a green status text
		if lineText and strfind(lineText, "cFF 0FF 0") then
			text = lineText
		end
	end
	GameTooltip:Hide()
	return text
end
