--[[	RCLootCouncil by Potdisc
ml_core.lua	Contains core elements for the MasterLooter
	-	Although possible, this module shouldn't be replaced unless closely replicated as other default modules depend on it.
	-	Assumes several functions in SessionFrame and VotingFrame

	TODOs/NOTES:
		- SendMessage() on AddItem() to let userModules know it's safe to add to lootTable. Might have to do it other places too.
]]

local addon = LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil")
RCLootCouncilML = addon:NewModule("RCLootCouncilML", "AceEvent-3.0", "AceBucket-3.0", "AceComm-3.0", "AceTimer-3.0", "AceHook-3.0")
local L = LibStub("AceLocale-3.0"):GetLocale("RCLootCouncil")
local LibDialog = LibStub("RCLootCouncil-LibDialog-1.0")
local Deflate = LibStub("LibDeflate")

-- Lua 5.0 compat: no # operator
local tgetn = table.getn

local db;

function RCLootCouncilML:OnInitialize()
	addon:Debug("ML initialized!")
end

function RCLootCouncilML:OnDisable()
	addon:Debug("ML Disabled")
	self:UnregisterAllEvents()
	self:UnregisterAllBuckets()
	self:UnregisterAllComm()
	self:UnregisterAllMessages()
	self:UnhookAll()
end

function RCLootCouncilML:OnEnable()
	addon:Debug("ML Enabled")
	db = addon:Getdb()
	self.candidates = {} 	-- candidateName = { class, role, rank }
	self.lootTable = {} 		-- The MLs operating lootTable
	-- self.lootTable[session] = {	bagged, lootSlot, awarded, name, link, quality, ilvl, type, subType, equipLoc, texture, boe	}
	self.awardedInBags = {} -- Awarded items that are stored in MLs inventory
	self.lootInBags = {} 	-- Items not yet awarded but stored in bags
	self.council = addon:GetCouncilInGroup()		-- the currently active council
	self.lootOpen = false 	-- is the ML lootWindow open or closed?
	self.running = false		-- true if we're handling a session

	self:RegisterComm("RCLootCouncil", "OnCommReceived")
	self:RegisterEvent("LOOT_OPENED","OnEvent")
	self:RegisterEvent("LOOT_CLOSED","OnEvent")
	self:RegisterBucketEvent("RAID_ROSTER_UPDATE", 10, "UpdateGroup") -- Bursts in group creation, and we should have plenty of time to handle it
	self:RegisterEvent("CHAT_MSG_WHISPER","OnEvent")
	self:RegisterBucketMessage("RCConfigTableChanged", 2, "ConfigTableChanged") -- The messages can burst
end

--- Add an item to the lootTable
-- @paramsig item[, bagged, slotIndex, index]
-- @param item Any: ItemID|itemString|itemLink
-- @param bagged True if the item is in the ML's inventory
-- @param slotIndex Index of the lootSlot, or nil if none - either this or 'bagged' needs to be supplied
-- @param index Index in self.lootTable, used to set data in a specific session
function RCLootCouncilML:AddItem(item, bagged, slotIndex, index, attempt)
	addon:DebugLog("ML:AddItem", item, bagged, slotIndex, index, attempt)
	-- Resolve to a bare numeric item ID up front. GetItemInfo is documented to accept either a
	-- numeric ID or a full hyperlink, but confirmed live: real, valid items passed as a full
	-- hyperlink (alt-click loot via GetLootSlotLink, a pasted /rc add link) were never resolving
	-- even after the full 20-attempt/10s retry window, while the same items work fine elsewhere
	-- in the addon once cached - this client's GetItemInfo appears to need the bare numeric ID
	-- specifically, not the full link string. Falls back to the original `item` unchanged if
	-- neither a bare number nor a parseable link (shouldn't happen for valid input).
	local numericItemID = tonumber(item) or addon:GetItemIDFromLink(item)
	-- addon:GetItemInfo() prefers C_Item.GetItemInfo (ClassicAPI) over bare GetItemInfo, which on
	-- this client returns one fewer value than expected and silently shifts subType/equipLoc/
	-- texture - see core.lua:GetItemInfo for the full story.
	local name, link, rarity, ilvl, iMinLevel, type, subType, iStackCount, equipLoc, texture = addon:GetItemInfo(numericItemID or item)
	-- Confirmed live: GetItemInfo's own `texture` return comes back nil on this client when
	-- queried with a bare numeric ID (the same query form the fix above uses for reliable name/
	-- link resolution) - name/link/rarity all resolve fine, just not the icon. GetItemIcon() is a
	-- separate, single-purpose Blizzard API (present since vanilla) that doesn't share whatever
	-- this client-specific quirk is - use it as a fallback so the icon actually shows.
	if not texture and _G.GetItemIcon then
		texture = GetItemIcon(numericItemID or item)
	end

	-- Item isn't properly loaded, so update the data in 0.5 sec (Should only happen with /rc test)
	if not name then
		attempt = (attempt or 0) + 1
		if attempt > 20 then -- ~10 sec of retries; give up instead of retrying forever (custom items/cache misses are more likely to permanently fail here than on retail)
			addon:Print(format("Could not load item info for %s after several attempts - it may not exist on this server. Skipping.", tostring(item)))
			addon:DebugLog("ML:AddItem gave up after", attempt, "attempts for", item)
			return
		end
		-- Reserve our slot on the first attempt only, so later items don't jump ahead of us in loot order
		index = index or (tgetn(self.lootTable) + 1)

		-- ClassicAPI (if installed): opportunistically resolve faster via a real load callback
		-- instead of waiting for the next poll below. Not a replacement for the poll - if this
		-- never fires (or ClassicAPI isn't installed), the poll is still the guaranteed path
		-- that eventually succeeds or hits the retry cap above. Only registered on the first
		-- attempt so retries don't stack up duplicate callbacks.
		if attempt == 1 and _G.Item and _G.Item.CreateFromItemID then
			local numericID = tonumber(item)
			local itemObj
			if numericID then
				itemObj = _G.Item:CreateFromItemID(numericID)
			elseif _G.Item.CreateFromItemLink then
				itemObj = _G.Item:CreateFromItemLink(item)
			end
			if itemObj and itemObj.ContinueOnItemLoad then
				itemObj:ContinueOnItemLoad(function()
					if self.lootTable[index] == nil then -- Still pending; the poll may have already filled it in
						self:AddItem(item, bagged, slotIndex, index, attempt)
					end
				end)
			end
		end

		self:ScheduleTimer("Timer", 0.5, "AddItem", item, bagged, slotIndex, index, attempt)
		-- cache item asap - reuse the numericItemID already resolved above (bare ID takes
		-- priority; the full link is only a fallback for whatever couldn't be parsed to an ID).
		GameTooltip:SetHyperlink(numericItemID and ("item:"..numericItemID) or item)
		addon:Debug("Started timer:", "AddItem", "for", item, "attempt", attempt)
		return
	end

	if RCTokenTable[item] then
		ilvl = RCTokenLevel[item]
		equipLoc = RCTokenTable[item]
	end

	-- Prefer the ORIGINAL item value for display if it's already a proper decorated hyperlink
	-- (has a "|H" escape) - confirmed live that GetItemInfo's own returned link, when called with
	-- a bare numeric ID (as we now do above to fix resolution), can come back as a plain
	-- undecorated string like "item:17063:0:0:0" with no color/name - SetText() shows that
	-- literally since there's no |c/|H/|h for it to interpret.
	-- _G.type (not bare type) - AddItem's own local `type` (from GetItemInfo's destructuring
	-- above, the item's TYPE string e.g. "Weapon") shadows the built-in type() function for the
	-- rest of this function body - confirmed live: "attempt to call local `type' (a string value)".
	local displayLink
	if _G.type(item) == "string" and string.find(item, "|H") then
		displayLink = item
	elseif link and name then
		-- /rc test (and any other bare-numeric-ID caller) has no original decorated hyperlink to
		-- fall back on - GetItemInfo's own undecorated link is all we have, so build a real
		-- hyperlink ourselves (confirmed live: without this, the raw "item:ID:0:0:0" string was
		-- shown as literal text instead of the item's name/color, e.g. via /rc test).
		-- CONFIRMED LIVE: GetItemInfo's own link only has 4 numeric fields ("item:ID:0:0:0") -
		-- a real vanilla item link has 9 (item:ID:enchant:jewel1:jewel2:jewel3:jewel4:suffixID:
		-- uniqueID). Other addons that hook GameTooltip and parse hyperlinks themselves (e.g.
		-- AtlasLoot's tooltip hook - confirmed live: "Unknown link type" errors appearing
		-- whenever hovering an item using this short link) choke on the too-short field count.
		-- Pad it out to the full, standard field count so any addon parsing our tooltip's link
		-- sees something well-formed.
		local linkItemID = tonumber(select(3, string.find(link, "item:(%d+)"))) or numericItemID
		local paddedLink = linkItemID and ("item:"..linkItemID..":0:0:0:0:0:0:0:0") or link
		local color = _G.ITEM_QUALITY_COLORS and _G.ITEM_QUALITY_COLORS[rarity]
		local hex = (color and color.hex) or "|cffffffff"
		displayLink = hex.."|H"..paddedLink.."|h["..name.."]|h|r"
	else
		displayLink = link
	end
	local entry = {
		["bagged"]		= bagged,
		["lootSlot"]	= slotIndex,
		["awarded"]		= false,
		["name"]		= name,
		["link"]		= displayLink,
		["quality"]		= rarity,
		["ilvl"]		= ilvl,
		["subType"]		= subType,
		["equipLoc"]	= equipLoc,
		["texture"]		= texture,
		["boe"]			= addon:IsItemBoE(displayLink),
	}
	if index then
		self.lootTable[index] = entry
	else
		tinsert(self.lootTable, entry)
	end
end

--- Removes a session from the lootTable
-- @param session The session (index) in lootTable to remove
function RCLootCouncilML:RemoveItem(session)
	tremove(self.lootTable, session)
end

function RCLootCouncilML:AddCandidate(name, class, role, rank, enchant, lvl)
	addon:DebugLog("ML:AddCandidate",name, class, role, rank, enchant, lvl)
	self.candidates[name] = {
		["class"]		= class,
		["role"]		= role or "DAMAGER",
		["rank"]		= rank or "", -- Rank cannot be nil for votingFrame
		["enchanter"] 	= enchant,
		["enchant_lvl"]	= lvl,
	}
end

function RCLootCouncilML:RemoveCandidate(name)
	addon:DebugLog("ML:RemoveCandidate", name)
	self.candidates[name] = nil
end

function RCLootCouncilML:UpdateGroup(ask)
	if self == nil then 
		self = RCLootCouncilML -- why?
	end
	addon:DebugLog("UpdateGroup", ask)
	if type(ask) ~= "boolean" then ask = false end
	local group_copy = {}
	local updates = false
	for name in pairs(self.candidates) do	group_copy[name] = true end

	if addon:IsInRaid() then
		for i = 1, addon:GetNumGroupMembers() do
			local name, _, _, _, _, class, _, _, _, _, _ = GetRaidRosterInfo(i)
			
			if name then
				-- GetUnitRole ultimately calls UnitGUID(unit), which throws "Unknown unit name"
				-- on this client for a bare name instead of a real token (confirmed live) - use
				-- the real "raid"..i token, matching the party branch below which already does
				-- this correctly with "party"..i.
				local role = addon:GetUnitRole("raid"..i)
				if group_copy[name] then	-- If they're already registered
					group_copy[name] = nil	-- remove them from the check
				else -- add them
					if not ask then -- ask for playerInfo?
						addon:SendCommand(name, "playerInfoRequest")
						addon:SendCommand(name, "MLdb", addon.mldb) -- and send mlDB
					end
					self:AddCandidate(name, class, role) -- Add them in case they haven't installed the adoon
					updates = true
				end
			end
		end
	elseif addon:IsInGroup() then 
		for i = 0, addon:GetNumGroupMembers() do 
			local name, class, role = nil, nil, nil
			if i == 0 then 
				name, class, role =  UnitName("player"), select(2, UnitClass("player")), addon:GetPlayerRole()
			else
				name, class, role =  UnitName("party"..i), select(2, UnitClass("party"..i)), addon:GetUnitRole("party"..i)
			end
			if name then 
				if group_copy[name] then 
					group_copy[name] = nil 
				else
					if not ask then -- ask for playerInfo?
						addon:SendCommand(name, "playerInfoRequest")
						addon:SendCommand(name, "MLdb", addon.mldb) -- and send mlDB
					end
					self:AddCandidate(name, class, role) -- Add them in case they haven't installed the adoon
					updates = true
				end
			end
		end
	end
	-- If anything's left in group_copy it means they left the raid, so lets remove them
	for name, v in pairs(group_copy) do
		if v then self:RemoveCandidate(name); updates = true end
	end
	if updates then
		addon:SendCommand("group", "candidates", self.candidates) 

		local oldCouncil = self.council 
		self.council = addon:GetCouncilInGroup()
		local council_updated = false
		if tgetn(self.council) ~= tgetn(oldCouncil) then 
			council_updated = true 
		else
			for i in ipairs(self.council) do
				if self.council[i] ~= oldCouncil[i] then 
					council_updated = true 
					break
				end
			end
		end

		if council_updated then 
			addon:SendCommand("group", "council", self.council)
		end
	end
end

function RCLootCouncilML:StartSession()
	addon:Debug("ML:StartSession()")
	-- CONFIRMED LIVE, root cause of "candidates" missing a real raid member (Nydeh) even after
	-- the "candidates" backfill fix (votingFrame.lua) landed: self.candidates is normally kept in
	-- sync by RAID_ROSTER_UPDATE, but that's a 10-SECOND BUCKET (RegisterBucketEvent debounce) -
	-- if someone reconnects (confirmed: "Nydeh has gone offline." in the same test) and a session
	-- starts before that 10-second window elapses, self.candidates still doesn't have them yet,
	-- and no backfill on the RECEIVING end can fix data that was never actually in the SENT
	-- "candidates" payload to begin with. Force an immediate, synchronous re-scan right before
	-- using self.candidates for anything, instead of trusting whatever the last bucket cycle saw.
	self:UpdateGroup()
	self.council = addon:GetCouncilInGroup()
	-- TESTING ONLY: "Hideurkids" can start a session solo (no real group required). UpdateGroup()
	-- only ever registers the player's own candidate entry (and builds the council list) when
	-- actually in a raid/party - when testing alone neither ever happens, so this readiness check
	-- would otherwise block forever. /rc test already has its own solo-testing accommodation
	-- (self-registers via AddCandidate) - mirror that here. Scoped to "not actually in a
	-- raid/party" so this doesn't also fire (redundantly, or racing the real comm-driven flow)
	-- during a genuine group session - confirmed this bypass WAS still triggering even in a real
	-- raid (since it only checked the player name), and a genuine group session already has its
	-- own working candidates/council/comm plumbing that doesn't need this shortcut at all. Remove
	-- this whole bypass before any real release.
	local isSolo = not addon:IsInRaid() and not addon:IsInGroup()
	if addon.playerName == "Hideurkids" and isSolo and not self.candidates[addon.playerName] then
		self:AddCandidate(addon.playerName, addon.playerClass, addon:GetPlayerRole())
	end
	-- ensure we are ready
	if not self.candidates[addon.playerName] or (tgetn(self.council) == 0 and addon.playerName ~= "Hideurkids") then
		addon:Print(L["Please wait a few seconds until all data has been synchronized."])
		return addon:Debug("Data wasn't ready", self.candidates[addon.playerName], tgetn(self.council))
	end

	self.running = true
	-- CONFIRMED LIVE: a real council member (Nydeh) never got his Voting Frame despite being on
	-- the council list - root cause is that StartSession() never (re-)broadcasts "council" at
	-- all, only CouncilChanged() does (triggered by /rc council add|remove). A candidate's own
	-- votingframe module only starts listening for comms once it processes a "council" broadcast
	-- and sets addon.isCouncil - if their local flag is stale (a UI reload/relog resets it to the
	-- default false, or they simply never received an earlier "council" broadcast reliably), the
	-- ML seeing them correctly in its OWN local council list proves nothing about their synced
	-- state. Re-send "council" on every session start (before "lootTable", so it's processed
	-- first) so this self-heals every time, not just right after an explicit /rc council add.
	-- CONFIRMED LIVE, self-inflicted regression: sending "council"+"candidates"+"lootTable" all
	-- back-to-back with no delay corrupted the "lootTable" payload for a real recipient (Nydeh) -
	-- it decoded as valid-but-EMPTY (lootTable[1] was nil), crashing SwitchSession(). This is
	-- exactly the risk this codebase's OWN "reconnect" handler already knew about and guarded
	-- against ("v2.0.1: With huge candidates/lootTable we get AceComm lostdatawarning 'First',
	-- presumeably due to the 4kb ChatThrottleLib limit" - which is why THAT handler staggers its
	-- candidates/lootTable sends at +1s/+4s instead of firing them together). Stagger the same way
	-- here instead of sending all 3 simultaneously.
	addon:SendCommand("group", "council", self.council)
	-- Unconditional, not left to UpdateGroup()'s own "only if something changed" gate above -
	-- guarantees every session start gives every recipient the freshest candidate roster,
	-- independent of whether THIS particular UpdateGroup() call happened to detect a change.
	addon:ScheduleTimer("SendCommand", 1, "group", "candidates", self.candidates)
	addon:ScheduleTimer("SendCommand", 4, "group", "lootTable", self.lootTable)

	-- CONFIRMED LIVE (not just a solo-testing quirk): the ML's own client never receives its own
	-- "lootTable"/"candidates" comm broadcasts back, in ANY distribution channel - reproduced both
	-- solo (a "group"-target send whispers to yourself when not in a raid/party) AND in a real
	-- raid as the actual Master Looter (SendCommand above uses real RAID distribution there) -
	-- unlike stock WoW, where SendAddonMessage is normally received by the sender too. Other real
	-- council members' clients DO receive the broadcast normally via their own OnCommReceived and
	-- open their own Voting Frame as designed - only the ML's OWN client can never rely on
	-- receiving its own message, so it has to populate/show its own Voting Frame directly instead
	-- of waiting on a comm round-trip that will never arrive. This is a genuine client
	-- compatibility fix (every Master Looter needs it, not just a "Hideurkids" testing account) -
	-- NOT gated behind isSolo/playerName the way the earlier attempts at this were.
	-- StartSession() can only ever be reached by the Master Looter (every entry point that leads
	-- here - AddUserItem/SessionFromBags/Test - already gates on addon.isMasterLooter or the
	-- Hideurkids bypass before this point) - and IsCouncil() always treats the ML as council
	-- anyway (core.lua:1475). Confirmed live that re-deriving it via IsCouncil() here returned
	-- false regardless - IsCouncil() depends on addon.isMasterLooter, which can apparently go
	-- stale/false in between (GetML()'s own separate solo-detection path, gated on
	-- self.testMode/self.nnp, is a likely culprit when testing alone without either flag set).
	-- Just set it directly instead of trusting a re-derivation that's proven unreliable here.
	-- Also force isMasterLooter itself for the same reason - confirmed live that
	-- RCVotingFrame.SetCellAward's own `if addon.isMasterLooter then` check (which decides
	-- whether to show the per-candidate "Award" button) stayed false/hidden here even though
	-- StartSession() can, by construction, only ever be reached by the actual Master Looter.
	addon.isCouncil = true
	addon.isMasterLooter = true
	-- CONFIRMED LIVE, SUPERSEDES the comments below: the "ML never receives its own broadcast"
	-- premise this whole block (and the LootFrame one further down) was built on is no longer
	-- true - SendCommand's self-loopback (AceComm.callbacks:Fire, added generally for every
	-- "group" comm consumer) DOES deliver "council"/"lootTable" back to the ML's own
	-- core.lua/votingFrame.lua OnCommReceived handlers now, same as any other candidate. Calling
	-- vf:Setup()/vf:Show()/lootframe:Start() directly HERE as well duplicated that - confirmed via
	-- a real "the Loot Frame popped up twice" report, since Start() ran once from here and once
	-- more from the loopback-triggered core.lua handler a moment later. Only pre-warm the module
	-- (enable it, and hand it the freshest candidate roster in case "candidates" itself hasn't
	-- been comm-synced yet this session) - let the loopback-driven "council"/"lootTable" handlers
	-- (the same ones every other council member/candidate relies on) do the actual Setup/Show.
	if addon.isCouncil or (addon.mldb and addon.mldb.observe) then
		addon:CallModule("votingframe")
		local vf = addon:GetActiveModule("votingframe")
		if vf then
			vf:SetCandidates(self.candidates)
		end
	end
	addon:CallModule("lootframe")

	self:AnnounceItems()
	-- Start a timer to set response as offline/not installed unless we receive an ack
	self:ScheduleTimer("Timer", 10, "LootSend")
end

function RCLootCouncilML:AddUserItem(item)
	if self.running then return addon:Print(L["You're already running a session."]) end
	self:AddItem(item, true)
	addon:CallModule("sessionframe")
	addon:GetActiveModule("sessionframe"):Show(self.lootTable)
end

function RCLootCouncilML:SessionFromBags()
	if self.running then return addon:Print(L["You're already running a session."]) end
	if tgetn(self.lootInBags) == 0 then return addon:Print(L["No items to award later registered"]) end
	for i, link in ipairs(self.lootInBags) do self:AddItem(link, true) end
	if db.autoStart then
		self:StartSession()
	else
		addon:CallModule("sessionframe")
		addon:GetActiveModule("sessionframe"):Show(self.lootTable)
	end
end

-- TODO awardedInBags should be kept in db incase the player logs out
function RCLootCouncilML:PrintAwardedInBags()
	if tgetn(self.awardedInBags) == 0 then return addon:Print(L["No winners registered"]) end
	addon:Print(L["Following winners was registered:"])
	for _, v in ipairs(self.awardedInBags) do
		if self.candidates[v.winner] then
			local c = addon:GetClassColor(self.candidates[v.winner].class)
			local text = "|cff"..addon:RGBToHex(c.r,c.g,c.b).. v.winner .."|r"
			addon:Print(v.link, "-->", text)
		else
			addon:Print(v.link, "-->", v.winner) -- fallback
		end
	end
	-- IDEA Do we delete awardedInBags here or keep it?
end

function RCLootCouncilML:ConfigTableChanged(val)
	-- The db was changed, so check if we should make a new mldb
	-- We can do this by checking if the changed value is a key in mldb
	if not addon.mldb then return self:UpdateMLdb() end -- mldb isn't made, so just make it
	for val in pairs(val) do
		for key in pairs(addon.mldb) do
			if key == val then return self:UpdateMLdb() end
		end
	end
end


function RCLootCouncilML:CouncilChanged()
	-- The council was changed, so send out the council
	self.council = addon:GetCouncilInGroup()
	addon:SendCommand("group", "council", self.council)
	-- Send candidates so new council members can register it
	addon:SendCommand("group", "candidates", self.candidates)
end

function RCLootCouncilML:UpdateMLdb()
	-- The db has changed, so update the mldb and send the changes
	addon:Debug("UpdateMLdb")
	addon.mldb = self:BuildMLdb()
	addon:SendCommand("group", "MLdb", addon.mldb)
end

function RCLootCouncilML:BuildMLdb()
	-- Extract changes to responses
	local changedResponses = {};
	for i = 1, db.numButtons do
		if db.responses[i].text ~= addon.defaults.profile.responses[i].text or unpack(db.responses[i].color) ~= unpack(addon.defaults.profile.responses[i].color) then
			changedResponses[i] = db.responses[i]
		end
	end
	-- Extract changed buttons
	local changedButtons = {};
	for i = 1, db.numButtons do
		if db.buttons[i].text ~= addon.defaults.profile.buttons[i].text then
			changedButtons[i] = db.buttons[i]
		end
	end
	-- Extract changed award reasons
	local changedAwardReasons = {}
	for i = 1, db.numAwardReasons do
		if db.awardReasons[i].text ~= addon.defaults.profile.awardReasons[i].text then
			changedAwardReasons[i] = db.awardReasons[i]
		end
	end
	return {
		selfVote			= db.selfVote,
		multiVote		= db.multiVote,
		anonymousVoting = db.anonymousVoting,
		allowNotes		= db.allowNotes,
		numButtons		= db.numButtons,
		hideVotes		= db.hideVotes,
		observe			= db.observe,
		awardReasons	= changedAwardReasons,
		buttons			= changedButtons,
		responses		= changedResponses,
	}
end

function RCLootCouncilML:NewML(newML)
	addon:DebugLog("ML:NewML", newML)
	if addon:UnitIsUnit(newML, "player") then -- we are the the ML
		addon:SendCommand("group", "playerInfoRequest")
		self:UpdateMLdb() -- Will build and send mldb
		self:UpdateGroup(true)
		self.council = addon:GetCouncilInGroup()
		addon:SendCommand("group", "council", self.council)
		-- Set a timer to send out the incoming playerInfo changes
		self:ScheduleTimer("Timer", 10, "GroupUpdate")
	else
		self:Disable() -- We don't want to use this if we're not the ML
	end
end

function RCLootCouncilML:Timer(type, ...)
	if type == "AddItem" then
		self:AddItem(unpack(arg, 1, arg.n))

	elseif type == "LootSend" then
		addon:SendCommand("group", "offline_timer")

	elseif type == "GroupUpdate" then
		addon:SendCommand("group", "candidates", self.candidates)
	end
end

local chunkSpool = {} -- RawSend()'s reassembly buffer - see core.lua:ReceiveRaw(), must be this file's own
function RCLootCouncilML:OnCommReceived(prefix, serializedMsg, distri, sender)
	if prefix == "RCLootCouncil" then
		serializedMsg = addon:ReceiveRaw(serializedMsg, sender, chunkSpool)
		if not serializedMsg then return end -- either mid-reassembly or a malformed message
		-- data is always a table
		local decoded = Deflate:DecodeForPrint(serializedMsg)
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
			-- DecompressDeflate can genuinely fail (the still-not-fully-root-caused LZ77 bug) -
			-- drop the message instead of crashing Deserialize(nil) ("bad argument #1 to gsub").
			return addon:DebugLog("MLComm decompress failed, dropping message from:", sender)
		end
		local test, command, data = addon:Deserialize(decompressed)
		if addon:HandleXRealmComms(self, command, data, sender) then return end
		addon:DebugLog("MLComm received:", command, "from:", sender, "distri:", distri)

		if not addon.isMasterLooter then 
			addon.isMasterLooter, addon.masterLooter = addon:GetML()
		end

		if test and addon.isMasterLooter then -- only ML receives these commands
			if command == "playerInfo" then
				self:AddCandidate(unpack(data))

			elseif command == "MLdb_request" then
				addon:SendCommand(sender, "MLdb", addon.mldb)

			elseif command == "council_request" then
				self.council = addon:GetCouncilInGroup()
				addon:Debug("Replying to council_request from", sender, "with council:", unpack(self.council))
				addon:SendCommand(sender, "council", self.council)

			elseif command == "reconnect" and not addon:UnitIsUnit(sender, addon.playerName) then -- Don't receive our own reconnect
				-- Someone asks for mldb, council and candidates
				addon:SendCommand(sender, "MLdb", addon.mldb)
				self.council = addon:GetCouncilInGroup()
				addon:SendCommand(sender, "council", self.council)

			--[[NOTE: For some reason this can silently fail, but adding a 1 sec timer on the rest of the calls seems to fix it
				v2.0.1: With huge candidates/lootTable we get AceComm lostdatawarning "First", presumeably due to the 4kb ChatThrottleLib limit.
				Bumping loottable to 4 secs is tested to work with 27 candidates + 10 items.]]

				addon:ScheduleTimer("SendCommand", 1, sender, "candidates", self.candidates)
				if self.running then -- Resend lootTable
					addon:ScheduleTimer("SendCommand", 4, sender, "lootTable", self.lootTable)
				end
				addon:Debug("Responded to reconnect from", sender)
			end
		elseif addon.isMasterLooter then
			addon:Debug("Error in deserializing ML comm: ", command)
		end
	end
end

function RCLootCouncilML:OnEvent(event, ...)
	addon:DebugLog("ML event", event)
	if event == "LOOT_OPENED" then -- IDEA Check if event LOOT_READY is useful here (also check GetLootInfo() for this)
		self.lootOpen = true
		if not InCombatLockdown() then
			self:LootOpened()
		else
			addon:Print(L["You can't start a loot session while in combat."])
		end
	elseif event == "LOOT_CLOSED" then
		self.lootOpen = false

	elseif event == "CHAT_MSG_WHISPER" and addon.isMasterLooter and db.acceptWhispers then
		local msg, sender = arg[1], arg[2]
		if msg == "rchelp" then
			self:SendWhisperHelp(sender)
		elseif self.running then
			self:GetItemsFromMessage(msg, sender)
		end
	end
end

function RCLootCouncilML:LootOpened()
	if addon.isMasterLooter and GetNumLootItems() > 0 then
		addon.target = GetUnitName("target") or L["Unknown/Chest"] -- capture the boss name
		for i = 1, GetNumLootItems() do
			-- We have reopened the loot frame, so check if we should update .lootSlot
			if self.running then
				local item = GetLootSlotLink(i)
				for session = 1, tgetn(self.lootTable) do
					if item == self.lootTable[session].link then
						if i ~= self.lootTable[session].lootSlot then -- It has changed!
							self.lootTable[session].lootSlot = i -- and update it
						end
						-- Lets see if we have more of the same item in the rest of the lootTable
						for ses = session, tgetn(self.lootTable) do
							if item == self.lootTable[ses].link then
								-- We have! Lets give this one the current slot, as the first will be updated once we reach it in the main loops
								self.lootTable[ses].lootSlot = i
								break
							end
						end
						break
					end
				end
			else
				if db.altClickLooting then self:ScheduleTimer("HookLootButton", 0.5, i) end -- Delay lootbutton hooking to ensure other addons have had time to build their frames
				local _, _, quantity, quality = GetLootSlotInfo(i)
				local item = GetLootSlotLink(i)
				if self:ShouldAutoAward(item, quality) and quantity > 0 then
					self:AutoAward(i, item, quality, db.autoAwardTo, db.autoAwardReason, addon.target)

				elseif self:CanWeLootItem(item, quality) and quantity > 0 then -- check if our options allows us to loot it
					self:AddItem(item, false, i)

				elseif quantity == 0 then -- it's coin, just loot it
					LootSlot(i)
				end
			end
		end
		if tgetn(self.lootTable) > 0 and not self.running then
			if db.autoStart then -- Settings say go
				self:StartSession()
			else
				addon:CallModule("sessionframe")
				addon:GetActiveModule("sessionframe"):Show(self.lootTable)
			end
		end
	end
end

function RCLootCouncilML:CanWeLootItem(item, quality)
	-- TESTING ONLY (/rc debug allitems): bypass every filter below so ANY looted item can be
	-- added to a session, e.g. to test the Session Setup popup on plain world loot instead of
	-- only real equippable gear. Remove before any real release.
	if addon.debugAllItems then return true end
	local ret = false
	if db.autoLoot and (IsEquippableItem(item) or db.autolootEverything) and quality >= GetLootThreshold() and not self:IsItemIgnored(item) then -- it's something we're allowed to loot
		-- Let's check if it's BoE
		-- Don't bother checking if we know we want to loot it
		ret = db.autolootBoE or not addon:IsItemBoE(item)
	end
	addon:Debug("CanWeLootItem", item, ret)
	return ret
end

function RCLootCouncilML:HookLootButton(i)
	local lootButton = getglobal("LootButton"..i)
	if XLoot then -- hook XLoot
		lootButton = getglobal("XLootButton"..i)
	end
	if XLootFrame then -- if XLoot 1.0
		lootButton = getglobal("XLootFrameButton"..i)
	end
	if getglobal("ElvLootSlot"..i) then -- if ElvUI
		lootButton = getglobal("ElvLootSlot"..i)
	end
	local hooked = self:IsHooked(lootButton, "OnClick")
	if lootButton and not hooked then
		addon:DebugLog("ML:HookLootButton", i)
		self:HookScript(lootButton, "OnClick", "LootOnClick")
	end
end

function RCLootCouncilML:LootOnClick(button)
	-- Guard against self.lootTable being nil (module never OnEnable()'d - e.g. a stale hook that
	-- survived from before losing Master Looter status) the same way every other AddItem entry
	-- point already is (/rc add, SessionFromBags, Test all check addon.isMasterLooter first).
	if not addon.isMasterLooter then return end
	if not IsAltKeyDown() or not db.altClickLooting or IsShiftKeyDown() or IsControlKeyDown() then return; end
	addon:DebugLog("LootAltClick()", button)

	if getglobal("ElvLootFrame") then
		button.slot = button:GetID() -- ElvUI hack
	end

	-- Check we're not already looting that item
	for ses, v in ipairs(self.lootTable) do
		if button.slot == v.lootSlot then
			addon:Print(L["The loot is already on the list"])
			return
		end
	end

	self:AddItem(GetLootSlotLink(button.slot), false, button.slot)
	addon:CallModule("sessionframe")
	addon:GetActiveModule("sessionframe"):Show(self.lootTable)
end

--@param session	The session to award
--@param winner	Nil/false if items should be stored in inventory and awarded later
--@param response	The candidates response, index in db.responses
--@param reason	Entry in db.awardReasons
--@returns True if awarded successfully
function RCLootCouncilML:Award(session, winner, response, reason)
	addon:DebugLog("ML:Award", session, winner, response, reason)
	if addon.testMode then
		if winner then
			addon:SendCommand("group", "awarded", session)
			addon:Print(format(L["The item would now be awarded to 'player'"], winner))
			self.lootTable[session].awarded = true
			if self:HasAllItemsBeenAwarded() then
				 addon:Print(L["All items have been awarded and  the loot session concluded"])
				 self:EndSession()
			end
		end
		return true
	end
	if not self.lootTable[session].lootSlot and not self.lootTable[session].bagged then
		addon:SessionError("Session "..session.." didn't have lootSlot")
		return false
	end
	-- Determine if we should award the item now or just store it in our bags
	if winner then
		local awarded = false
		--  give out the loot or store the result, i.e. bagged or not
		if self.lootTable[session].bagged then   -- indirect mode (the item is in a bag)
			-- Add to the list of awarded items in MLs bags, and remove it from lootInBags
			tinsert(self.awardedInBags, {link = self.lootTable[session].link, winner = winner})
			tremove(self.lootInBags, session)
			awarded = true

		else -- Direct (we can award from a WoW loot list)
			if not self.lootOpen then -- we can't give out loot without the loot window open
				addon:Print(L["Unable to give out loot without the loot window open."])
				--addon:Print(L["Alternatively, flag the loot as award later."])
				return false
			end
			-- CONFIRMED LIVE per explicit user request: an item still on the corpse (not bagged)
			-- should get sent to the winner automatically via GiveMasterLoot when Award is
			-- confirmed - INCLUDING when the winner is the ML themselves. The old code special-
			-- cased "winner is me" to a plain LootSlot() call, but that silently failed to give
			-- the item (confirmed live) - in Master Loot mode, distributing ANY tracked loot slot
			-- (including to yourself) appears to genuinely need GiveMasterLoot, the same as any
			-- other recipient; a bare LootSlot() doesn't reliably hand it to a specific person the
			-- way master-loot distribution expects. Also removed the old quality-based branching -
			-- it only ever tried GiveMasterLoot for items AT/ABOVE the loot threshold, so anything
			-- below it (common for plain world trade goods, e.g. testing via "/rc debug allitems")
			-- skipped straight to the ML's own bags. Always try GiveMasterLoot first for EVERY
			-- winner now (self included); only fall back to bag-it-for-manual-trade if the winner
			-- genuinely isn't a valid master loot candidate.
			for i = 1, MAX_RAID_MEMBERS do
				if addon:UnitIsUnit(GetMasterLootCandidate(i), winner) then
					addon:Debug("GiveMasterLoot", i)
					GiveMasterLoot(self.lootTable[session].lootSlot, i)
					awarded = true
					break
				end
			end
			if not awarded then -- winner isn't a valid master loot candidate - fall back
				LootSlot(self.lootTable[session].lootSlot)
				if not addon:UnitIsUnit(winner, "player") then
					addon:Print(format(L["Cannot give 'item' to 'player' due to Blizzard limitations. Gave it to you for distribution."], self.lootTable[session].link, winner))
					tinsert(self.awardedInBags, {link = self.lootTable[session].link, winner = winner})
				end
				awarded = true
			end
		end
		if awarded then
			-- flag the item as awarded and update
			addon:SendCommand("group", "awarded", session)
			self.lootTable[session].awarded = true -- No need to let Comms handle this
			-- IDEA Switch session ?

			self:AnnounceAward(winner, self.lootTable[session].link, reason and reason.text or db.responses[response].text)
			if self:HasAllItemsBeenAwarded() then self:EndSession() end

		else -- If we reach here it means we couldn't find a valid MasterLootCandidate, propably due to the winner is unable to receive the loot
			addon:Print(format(L["Unable to give 'item' to 'player' - (player offline, left group or instance?)"], self.lootTable[session].link, winner))
		end
		return awarded

	else -- Store in bags and award later
		if not self.lootOpen then return addon:Print(L["Unable to give out loot without the loot window open."]) end
		if self.lootTable[session].quality < GetLootThreshold() then
			LootSlot(self.lootTable[session].lootSlot)
		else
			for i = 1, MAX_RAID_MEMBERS do
				if addon:UnitIsUnit(GetMasterLootCandidate(i), "player") then
					GiveMasterLoot(self.lootTable[session].lootSlot, i)
					break
				end
			end
		end
		tinsert(self.lootInBags, self.lootTable[session].link) -- and store data
		return false -- Item hasn't been awarded
	end
	return false
end

function RCLootCouncilML:AnnounceItems()
	if not db.announceItems then return end
	addon:DebugLog("ML:AnnounceItems()")
	SendChatMessage(db.announceText, addon:GetAnnounceChannel(db.announceChannel))
	for k,v in ipairs(self.lootTable) do
		SendChatMessage(k .. ": " .. v.link, addon:GetAnnounceChannel(db.announceChannel))
	end
end

function RCLootCouncilML:AnnounceAward(name, link, text)
	if db.announceAward then
		for k,v in pairs(db.awardText) do
			if v.channel ~= "NONE" then
				local message = gsub(v.text, "&p", name)
				message = gsub(message, "&i", link)
				message = gsub(message, "&r", text)
				SendChatMessage(message, addon:GetAnnounceChannel(v.channel))
			end
		end
	end
end

function RCLootCouncilML:ShouldAutoAward(item, quality)
	if db.autoAward and quality >= db.autoAwardLowerThreshold and quality <= db.autoAwardUpperThreshold then
		if db.autoAwardLowerThreshold >= GetLootThreshold() or db.autoAwardLowerThreshold < 2 then
			-- CONFIRMED LIVE elsewhere (GetCouncilInGroup - the whole "Nydeh never gets a Voting
			-- Frame" saga): pcall(UnitInRaid, name)/pcall(UnitInParty, name) can silently swallow
			-- this client's "Unknown unit name" throw and just return ok=false, meaning
			-- auto-award-to-a-specific-person would quietly never trigger for anyone unlucky
			-- enough to hit it - not just error, genuinely never work, with no visible trace. Use
			-- the same direct raid/party iteration + UnitName(realToken) comparison already
			-- proven safe in IsNameInGroup() instead.
			if addon:IsNameInGroup(db.autoAwardTo) then -- TEST perhaps use self.group?
				return true;
			else
				addon:Print(L["Cannot autoaward:"])
				addon:Print(format(L["Could not find 'player' in the group."], db.autoAwardTo))
			end
		else
			addon:Print(format(L["Could not Auto Award i because the Loot Threshold is too high!"], item))
		end
	end
	return false
end

function RCLootCouncilML:AutoAward(lootIndex, item, quality, name, reason, boss)
	addon:DebugLog("ML:AutoAward", lootIndex, item, quality, name, reason, boss)
	local awarded = false
	if db.autoAwardLowerThreshold < 2 and quality < 2 then
		if addon:UnitIsUnit("player",name) then -- give it to the player
			LootSlot(lootIndex)
			awarded = true
		else
			addon:Print(L["Cannot autoaward:"])
			addon:Print(format(L["You can only auto award items with a quality lower than 'quality' to yourself due to Blizaard restrictions"],"|cff1eff00"..getglobal("ITEM_QUALITY2_DESC").."|r"))
			return false
		end
	else
		for i = 1, MAX_RAID_MEMBERS do
			if addon:UnitIsUnit(GetMasterLootCandidate(i), name) then
				GiveMasterLoot(lootIndex,i)
				awarded = true
				break
			end
		end
	end
	if awarded then
		addon:Print(format(L["Auto awarded 'item'"], item))
		self:AnnounceAward(name, item, db.awardReasons[reason].text)
		self:TrackAndLogLoot(name, item, reason, boss, 0, nil, nil, db.awardReasons[reason])
	else
		addon:Print(L["Cannot autoaward:"])
		addon:Print(format(L["Unable to give 'item' to 'player' - (player offline, left group or instance?)"], item, name))
	end
	return awarded
end

local history_table = {}
function RCLootCouncilML:TrackAndLogLoot(name, item, response, boss, votes, itemReplaced1, itemReplaced2, reason)
	if reason and not reason.log then return end -- Reason says don't log
	if not (db.sendHistory or db.enableHistory) then return end -- No reason to do stuff when we won't use it
	if addon.testMode and not addon.nnp then return end -- We shouldn't track testing awards.
	local instanceName, _, _, difficultyName = GetInstanceInfo()
	addon:Debug("ML:TrackAndLogLoot()")
	history_table["lootWon"] 		= item
	history_table["date"] 			= date("%d/%m/%y")
	history_table["time"] 			= date("%H:%M:%S")
	history_table["instance"] 		= instanceName.."-"..difficultyName
	history_table["boss"] 			= boss
	history_table["votes"] 			= votes
	history_table["itemReplaced1"]= itemReplaced1
	history_table["itemReplaced2"]= itemReplaced2
	history_table["response"] 		= reason and reason.text or db.responses[response].text
	history_table["responseID"] 	= response or reason.sort - 400 										-- Changed in v2.0 (reason responseID was 0 pre v2.0)
	history_table["color"]			= reason and reason.color or db.responses[response].color	-- New in v2.0
	history_table["class"]			= self.candidates[name].class											-- New in v2.0
	history_table["isAwardReason"] = reason and true or false											-- New in v2.0

	if db.sendHistory then -- Send it, and let comms handle the logging
		addon:SendCommand("group", "history", name, history_table)
	elseif db.enableHistory then -- Just log it
		addon:SendCommand("player", "history", name, history_table)
	end
end

function RCLootCouncilML:HasAllItemsBeenAwarded()
	local moreItems = true
	for i = 1, tgetn(self.lootTable) do
		if not self.lootTable[i].awarded then
			moreItems = false
		end
	end
	return moreItems
end

function RCLootCouncilML:EndSession()
	addon:DebugLog("ML:EndSession()")
	self.lootTable = {}
	addon:SendCommand("group", "session_end")
	self.running = false
	self:CancelAllTimers()
	if addon.testMode then -- We need to undo our ML status
		addon.testMode = false
		addon:ScheduleTimer("NewMLCheck", 1) -- Delay it a bit
	end
	addon.testMode = false
end

-- Initiates a session with the items handed
function RCLootCouncilML:Test(items)
	-- check if we're added in self.group
	-- (We might not be on solo test)
	if not tContains(self.candidates, addon.playerName) then
		self:AddCandidate(addon.playerName, addon.playerClass, addon:GetPlayerRole(), addon.guildRank)
	end
	-- We must send candidates now, since we can't wait the normal 10 secs
	addon:SendCommand("group", "candidates", self.candidates)
	-- Add the items
	for session, iName in ipairs(items) do
		self:AddItem(iName, false, false)
	end
	if db.autoStart then
		addon:Print(L["Autostart isn't supported when testing"])
	end
	addon:CallModule("sessionframe")
	addon:GetActiveModule("sessionframe"):Show(self.lootTable)
end

-- Returns true if we are ignoring the item
function RCLootCouncilML:IsItemIgnored(link)
	local itemID = addon:GetItemIDFromLink(link) -- extract itemID
	return tContains(db.ignore, itemID)
end

function RCLootCouncilML:GetItemsFromMessage(msg, sender)
	addon:Debug("GetItemsFromMessage()", msg, sender)
	if not addon.isMasterLooter then return end

	local ses, arg1, arg2, arg3 = addon:GetArgs(msg, 4) -- We only require session to be correct, we can do some error checking on the rest
	ses = tonumber(ses)
	-- Let's test the input
	if not ses or type(ses) ~= "number" or ses > tgetn(self.lootTable) then return end -- We need a valid session
	-- Set some locals
	local item1, item2
	local response = 1
	if string.find(arg1, "|Hitem:") then -- they didn't give a response
		item1, item2 = arg1, arg2
	else
		-- No reason to continue if they didn't provide an item
		if not arg2 or not string.find(arg2, "|Hitem:") then return end
		item1, item2 = arg2, arg3

		-- check if the response is valid
		local whisperKeys = {}
		for i = 1, db.numButtons do --go through all the button
			gsub(db.buttons[i]["whisperKey"], '[%w]+', function(x) tinsert(whisperKeys, {key = x, num = i}) end) -- extract the whisperKeys to a table
		end
		for _,v in ipairs(whisperKeys) do
			-- strmatch/string.match doesn't exist on this client (Lua 5.0 predates it) -
			-- string.find is sufficient here since only a match/no-match check is needed.
			if string.find(arg1, v.key) then -- if we found a match
				response = v.num
				break;
			end
		end
	end
	local diff = 0
	if item1 then diff = (self.lootTable[ses].ilvl - select(4, GetItemInfo(item1))) end
	local toSend = {
		gear1 = item1,
		gear2 = item2,
		ilvl = nil,
		diff = diff,
		note = nil,
		response = response
	}
	addon:SendCommand("group", "response", ses, sender, toSend)
	-- Let people know we've done stuff
	addon:Print(format(L["Item received and added from 'player'"], sender))
	SendChatMessage("[RCLootCouncil]: "..format(L["Acknowledged as 'response'"], db.responses[response].text ), "WHISPER", nil, sender)
end

function RCLootCouncilML:SendWhisperHelp(target)
	addon:DebugLog("SendWhisperHelp", target)
	local msg
	SendChatMessage(L["whisper_guide"], "WHISPER", nil, target)
	for i = 1, db.numButtons do
		msg = "[RCLootCouncil]: "..db.buttons[i]["text"]..":  " -- i.e. MainSpec/Need:
		msg = msg..""..db.buttons[i]["whisperKey"].."." -- need, mainspec, etc
		SendChatMessage(msg, "WHISPER", nil, target)
	end
	SendChatMessage(L["whisper_guide2"], "WHISPER", nil, target)
	addon:Print(format(L["Sent whisper help to 'player'"], target))
end

--------ML Popups ------------------
LibDialog:Register("RCLOOTCOUNCIL_CONFIRM_ABORT", {
	text = L["Are you sure you want to abort?"],
	buttons = {
		{	text = L["Yes"],
			on_click = function(self)
				addon:DebugLog("ML aborted session")
				RCLootCouncilML:EndSession()
				CloseLoot() -- close the lootlist
				addon:GetActiveModule("votingframe"):EndSession(true)
			end,
		},
		{	text = L["No"],
		},
	},
	hide_on_escape = true,
	show_while_dead = true,
})
LibDialog:Register("RCLOOTCOUNCIL_CONFIRM_AWARD", {
	-- "something_went_wrong" is just a placeholder - on_show below always overrides it. If it's
	-- ever actually SEEN, on_show crashed (confirmed live: format()/SetText() error on a nil
	-- lootTable[session].link, most likely from a stale/mismatched session index) - guarded below
	-- so a failure here degrades to a generic-but-honest message instead of the raw placeholder.
	text = "something_went_wrong",
	icon = "",
	on_show = function(self, data)
		local session, player = unpack(data)
		local entry = RCLootCouncilML.lootTable[session]
		if entry and entry.link then
			self.text:SetText(format(L["Are you sure you want to give #item to #player?"], entry.link, player))
			self.icon:SetTexture(entry.texture)
		else
			self.text:SetText(format(L["Are you sure you want to give #item to #player?"], "?", player or "?"))
		end
	end,
	buttons = {
		{	text = L["Yes"],
			on_click = function(self, data)
				-- IDEA Perhaps come up with a better way of handling this
				local session, player, response, reason, votes, item1, item2 = unpack(data,1,7)
				local item = RCLootCouncilML.lootTable[session].link -- Store it now as we wipe lootTable after Award()
				local awarded = RCLootCouncilML:Award(session, player, response, reason)
				if awarded then -- log it
					RCLootCouncilML:TrackAndLogLoot(player, item, response, addon.target, votes, item1, item2, reason)
				end
				-- We need to delay the test mode disabling so comms have a chance to be send first!
				if addon.testMode and RCLootCouncilML:HasAllItemsBeenAwarded() then RCLootCouncilML:EndSession() end
			end,
		},
		{	text = L["No"],
		},
	},
	hide_on_escape = true,
	show_while_dead = true,
})
