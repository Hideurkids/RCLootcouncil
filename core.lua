--[[	RCLootCouncil by Potdisc
core.lua	Contains core elements of the addon

--------------------------------
TODOs/Notes
	Things marked with "todo"
		- IDEA add an observer/council string to show players their role?
		- If we truly want to be able to edit votingframe scrolltable with modules, it needs to have GetCol by name
		- Pressing shift while hovering an item should do the same as vanilla
		- The 4'th cell in @line81 in versionCheck should not be static
--------------------------------
CHANGELOG
	-- SEE CHANGELOG.TXT
]]

RCLootCouncil = LibStub("AceAddon-3.0"):NewAddon("RCLootCouncil", "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0", "AceSerializer-3.0", "AceHook-3.0", "AceTimer-3.0");
local LibDialog = LibStub("RCLootCouncil-LibDialog-1.0")
local L = LibStub("AceLocale-3.0"):GetLocale("RCLootCouncil")
local lwin = LibStub("LibWindow-1.1")
local Deflate = LibStub("LibDeflate")
local AceComm = LibStub("AceComm-3.0")

-- Lua 5.0 compat: no # operator, no table.wipe/string.match, strsplit/strtrim may not be native
local tgetn = table.getn
local wipe = _G.wipe or (_G.table and _G.table.wipe) or function(t) for k in pairs(t) do t[k] = nil end return t end
-- CONFIRMED LIVE (2026-08-26): this client's native/ClassicAPI-provided `strsplit` global does
-- NOT follow the documented Blizzard API (multiple string return values) - it returns a single
-- TABLE of pieces instead (verified via debug output showing "table: 0x..." where a plain string
-- was expected). Always use our own known-correct implementation instead of `_G.strsplit`.
local strsplit = function(delimiter, str, pieces)
	if not str then return end
	local parts = {}
	local dpat = "[" .. delimiter .. "]"
	local pos = 1
	while true do
		if pieces and tgetn(parts) == pieces - 1 then
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
local strtrim = _G.strtrim or function(s)
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- Lua 5.0/1.12 compat: these Blizzard global strings may not exist (or may be named
-- differently) on this client - guard so a missing global doesn't kill the whole file's
-- load (everything below, including OnInitialize, would never get defined otherwise).
local GUILD_DEMOTE_PATTERN = _G.ERR_GUILD_DEMOTE_SSS and ("^"..string.gsub(_G.ERR_GUILD_DEMOTE_SSS, '%%s', '(.+)').."$") or nil
local GUILD_PROMOTE_PATTERN = _G.ERR_GUILD_PROMOTE_SSS and ("^"..string.gsub(_G.ERR_GUILD_PROMOTE_SSS, '%%s', '(.+)').."$") or nil

RCLootCouncil:SetDefaultModuleState(false)

-- Init shorthands
local db, historyDB, debugLog;-- = self.db.profile, self.lootDB.factionrealm, self.db.global.log
-- init modules
local defaultModules = {
	masterlooter =	"RCLootCouncilML",
	lootframe =		"RCLootFrame",
	history =		"RCLootHistory",
	version =		"RCVersionCheck",
	sessionframe =	"RCSessionFrame",
	votingframe =	"RCVotingFrame",
	options =		"RCOptionsFrame",
}
local userModules = {
	masterlooter = nil,
	lootframe = nil,
	history = nil,
	version = nil,
	sessionframe = nil,
	votingframe = nil,
	options = nil,
}

local frames = {} -- Contains all frames created by RCLootCouncil:CreateFrame()
local unregisterGuildEvent = false
local player_relogged = true -- Determines if we potentially need data from the ML due to /rl

function RCLootCouncil:OnInitialize()
	--IDEA Consider if we want everything on self, or just whatever modules could need.
  	self.version = "1.0.2" -- hard code the version so reload ui updates will report correct version
	self.nnp = false
	self.debug = false
	self.tVersion = nil -- String or nil. Indicates test version, which alters stuff like version check. Is appended to 'version', i.e. "version-tVersion"

	self.playerClass = select(2, UnitClass("player"))
	self.guildRank = L["Unguilded"]
	self.target = nil
	self.isMasterLooter = false -- Are we the ML?
	self.masterLooter = ""  -- Name of the ML
	self.isCouncil = false -- Are we in the Council?
	self.enabled = true -- turn addon on/off
	self.inCombat = false -- Are we in combat?

	self.verCheckDisplayed = false -- Have we shown a "out-of-date"?

	self.council = {} -- council from ML
	self.mldb = {} -- db recived from ML
	self.mlhistory = {} -- history received from ML
	self.successful_history_requests = {} -- for the master looter, history requests that were done successfully 

	self.responses = {
		NOTANNOUNCED	= { color = {1,0,1,1},				sort = 501,		text = L["Not announced"],},
		ANNOUNCED		= { color = {1,0,1,1},				sort = 502,		text = L["Loot announced, waiting for answer"], },
		WAIT				= { color = {1,1,0,1},				sort = 503,		text = L["Candidate is selecting response, please wait"], },
		TIMEOUT			= { color = {1,0,0,1},				sort = 504,		text = L["Candidate didn't respond on time"], },
		REMOVED			= { color = {0.8,0.5,0,1},			sort = 505,		text = L["Candidate removed"], },
		NOTHING			= { color = {0.5,0.5,0.5,1},		sort = 505,		text = L["Offline or RCLootCouncil not installed"], },
		PASS				= { color = {0.7, 0.7,0.7,1},		sort = 800,		text = L["Pass"],},
		AUTOPASS			= { color = {0.7,0.7,0.7,1},		sort = 801,		text = L["Autopass"], },
		DISABLED			= { color = {0.3, 0.35, 0.5},		sort = 802,		text = L["Candidate has disabled RCLootCouncil"], },
		--[[1]]			  { color = {1, 0, 0.00392156862745098},		sort = 1,		text = L["Best in Slot"],},
		--[[2]]			  { color = {1, 0.5490196078431373, 0, 1},		sort = 2,		text = L["Big Upgrade but not BiS"],},
		--[[3]]			  { color = {0.9882352941176471, 1, 0},			sort = 3,		text = L["Small Upgrade but not BiS"],},
		--[[4]]			  { color = {0.00392156862745098, 0, 1},		sort = 4,		text = L["Off Spec"],},
	}
	self.roleTable = {
		TANK =		L["Tank"],
		HEALER =		L["Healer"],
		DAMAGER =	L["DPS"],
		NONE =		L["None"],
	}

	self.testMode = false;

	-- Option table defaults
	self.defaults = {
		global = {
			logMaxEntries = 500,
			log = {}, -- debug log
			localizedSubTypes = {},
		},
		profile = {
			usage = { -- State of enabledness
				ml = false,				-- Enable when ML
				ask_ml = true,			-- Ask before enabling when ML
				leader = false,		-- Enable when leader
				ask_leader = true,	-- Ask before enabling when leader
				never = false,			-- Never enable
				state = "ask_ml", 	-- Current state
			},
			checkID = 1,
			autoStart = false, -- start a session with all eligible items
			autoLoot = true, -- Auto loot equippable items
			autolootEverything = true,
			autolootBoE = true,
			autoOpen = true, -- auto open the voting frame
			autoPassBoE = true,
			autoPass = true,
			altClickLooting = true,
			acceptWhispers = true,
			selfVote = true,
			multiVote = true,
			anonymousVoting = false,
			showForML = false,
			hideVotes = false, -- Hide the # votes until one have voted
			allowNotes = true,
			autoAward = false,
			autoAwardLowerThreshold = 2,
			autoAwardUpperThreshold = 3,
			autoAwardTo = L["None"],
			autoAwardReason = 1,
			observe = false, -- observe mode on/off
			silentAutoPass = false, -- Show autopass message
			--neverML = false, -- Never use the addon as ML
			minimizeInCombat = false,

			UI = { -- stores all ui information
				['**'] = { -- Defaults for Lib-Window
					y		= 0,
					x		= 0,
					point	= "CENTER",
					scale	= 0.8,
				},
				lootframe = { -- We want the Loot Frame to get a little lower
					y = -200,
				},
			},

			modules = { -- For storing module specific data
				['*'] = {},
			},

			announceAward = true,
			awardText = { -- Just max it at 2 channels
				{ channel = "group",	text = L["&p was awarded with &i for &r!"],},
				{ channel = "NONE",	text = "",},
			},
			announceItems = false,
			announceText = L["Items under consideration:"],
			announceChannel = "group",

			responses = self.responses,

			-- CONFIRMED LIVE: awarding an item never showed up in "/rc history" for anyone, despite
			-- TrackAndLogLoot() correctly firing on every award - the RECEIVING side's "history"
			-- comm handler (core.lua) only actually stores the entry if ITS OWN enableHistory is
			-- true, and this defaulted to false for every fresh install, so nobody ever actually
			-- recorded anything even though the ML dutifully broadcast every award. Default to
			-- true so history works out of the box - still toggleable off in the General tab.
			enableHistory = true,
			sendHistory = true,

			minRank = 3,
			council = {},

			maxButtons = 10,
			numButtons = 4,
			buttons = {
				{	text = L["BiS"],			whisperKey = L["whisperKey_bis"], },	-- 1
				{	text = L["Big Upgrade"],	whisperKey = L["whisperKey_bigupgrade"],},	-- 2
				{	text = L["Small Upgrade"],	whisperKey = L["whisperKey_smallupgrade"],},	-- 3
				{	text = L["Off Spec"],		whisperKey = L["whisperKey_offspec"],},	-- 4
			},
			maxAwardReasons = 10,
			numAwardReasons = 3,
			awardReasons = {
				{ color = {1, 1, 1, 1}, disenchant = true, log = true,	sort = 401,	text = L["Disenchant"], },
				{ color = {1, 1, 1, 1}, disenchant = false, log = true,	sort = 402,	text = L["Banking"], },
				{ color = {1, 1, 1, 1}, disenchant = false, log = false, sort = 403,	text = L["Free"],},
			},
			disenchant = true, -- Disenchant enabled, i.e. there's a true in awardReasons.disenchant

			-- List of items to ignore:
			ignore = {
				43345, -- Dragon Hide Backpack
				43347, -- Satchel of Spoils 
				43346, -- Large Satchel of Spoils
				43986, -- Black Drake
				43954, -- Twilight Drake
				45038, -- Val'anyr fragment
				45087, -- Runed Orb
			},
		},
	} -- defaults end

	-- create the other buttons/responses
	for i = tgetn(self.defaults.profile.buttons)+1, self.defaults.profile.maxButtons do
		tinsert(self.defaults.profile.buttons, {
			text = L["Button"].." "..i,
			whisperKey = ""..i,
		})
	end
	for i = self.defaults.profile.numButtons+1, self.defaults.profile.maxButtons do
		tinsert(self.defaults.profile.responses, {
			color = {0.7, 0.7,0.7,1},
			sort = i,
			text = L["Button"]..i,
		})
	end
	-- create the other AwardReasons
	for i = tgetn(self.defaults.profile.awardReasons)+1, self.defaults.profile.maxAwardReasons do
		tinsert(self.defaults.profile.awardReasons, {color = {1, 1, 1, 1}, disenchant = false, log = true, sort = 400+i, text = "Reason "..i,})
	end

	-- register chat and comms
	self:RegisterChatCommand("rc", "ChatCommand")
  	self:RegisterChatCommand("rclc", "ChatCommand")
	self:RegisterComm("RCLootCouncil")
	self.db = LibStub("AceDB-3.0"):New("RCLootCouncilDB", self.defaults, true)
	self.lootDB = LibStub("AceDB-3.0"):New("RCLootCouncilLootDB")
	--[[ Format:
	"playerName" = {
		[#] = {"lootWon", "date (d/m/y)", "time (h:m:s)", "instance", "boss", "votes", "itemReplaced1", "itemReplaced2", "response", "responseID", "color", "class", "isAwardReason"}
	},
	]]
	self.db.RegisterCallback(self, "OnProfileChanged", "RefreshConfig")
	self.db.RegisterCallback(self, "OnProfileCopied", "RefreshConfig")
	self.db.RegisterCallback(self, "OnProfileReset", "RefreshConfig")

	-- add shortcuts
	db = self.db.profile
	historyDB = self.lootDB.factionrealm
	debugLog = self.db.global.log

	-- register the optionstable
	self.options = self:OptionsTable()
	self.options.args.settings.args.profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(self.db)
	LibStub("RCLootCouncil-AceConfigRegistry-3.0"):RegisterOptionsTable("RCLootCouncil", self.options)

	-- NOTE: this client has no Blizzard "Interface > AddOns" category panel at all (that's a
	-- WotLK+ addition - InterfaceOptions_AddCategory/InterfaceOptionsFrame_OpenToCategory don't
	-- exist here), so AddToBlizOptions is never called. `/rc config`/`/rc council` open
	-- RCOptionsFrame (Modules\optionsFrame.lua), a hand-built dark-themed window instead - the
	-- options table registered above is still useful as the declarative source for its content.
	-- Add logged in message in the log
	self:DebugLog("Logged In")
end

function RCLootCouncil:OnEnable()
	-- Register the player's name
	self.realmName = GetRealmName()
	self.playerName = UnitName("player")
	self:DebugLog(self.playerName, self.version, self.tVersion)

	-- register events
	self:RegisterEvent("PARTY_LOOT_METHOD_CHANGED", "OnEvent")
	self:RegisterEvent("GUILD_ROSTER_UPDATE","OnEvent")
	self:RegisterEvent("RAID_INSTANCE_WELCOME","OnEvent")
	self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnEvent")
	self:RegisterEvent("PLAYER_REGEN_DISABLED", "EnterCombat")
	self:RegisterEvent("PLAYER_REGEN_ENABLED", "LeaveCombat")
	self:RegisterEvent("CHAT_MSG_SYSTEM", "CheckGuildUpdate")
	--self:RegisterEvent("GROUP_ROSTER_UPDATE", "Debug", "event")

	if IsInGuild() then
		self.guildRank = select(2, GetGuildInfo("player"))
		self:SendCommand("guild", "verTest", self.version, self.tVersion) -- send out a version check
	end

	-- Any upgrade to v2.0.0 or from Alpha.12 needs a db reset and possibly lootDB import
	if (self.db.global.version and self.db.global.version < "2.0.0") or (self.db.global.tVersion and self.db.global.tVersion <= "Alpha.12") then -- Upgraded to v.2.0.0
		self:Debug("First time v2.0.0 upgrade!")
		local lootdb = {}
		if self.db.factionrealm.lootDB then
			self:Debug("Extracting old LootDB")
			for k,v in pairs(self.db.factionrealm.lootDB) do
				lootdb[k] = v
			end
			self:Debug("Done")
		end
		self:Debug("Resetting DB")
		self.db:ResetDB("Default")
		self:Debug("Done\nImporting LootDB")
		for k,v in pairs(lootdb) do
			self.lootDB.factionrealm[k] = v
		end
		self:Debug("Done")
		self:Print("Your settings have been reset due to upgrading to v2.0.0")
	end

	if self.db.global.version and self.db.global.version ~= self.version then 
		self.db.global.localizedSubTypes.created = false -- re-cache incase we updated subtypes
		self.db.global.version = self.version
	end

	self.db.global.logMaxEntries = self.defaults.global.logMaxEntries -- reset it now for zzz

	if self.tVersion then
		self.db.global.logMaxEntries = 1000 -- bump it for test version
	end
	if self.db.global.tVersion and self.debug then -- recently ran a test version, so reset debugLog
		self.db.global.log = {}
	end

	self.db.global.tVersion = self.tVersion;
	GuildRoster()

	local filterFunc = function(_, event, msg, player, ...)
		return strfind(msg, "[[RCLootCouncil]]:")
	end
	-- ChatFrame_AddMessageEventFilter doesn't exist on this client (WotLK+ addition) - guard it
	-- rather than let it throw and silently kill the rest of OnEnable() (including the
	-- LibDialog:Register call a few lines below, which was the real cause of the
	-- "does not match a registered delegate" error, not a LibStub name collision).
	if _G.ChatFrame_AddMessageEventFilter then
		ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", filterFunc)
	end

	self:LocalizeSubTypes()

	----------PopUp setups --------------
	-------------------------------------
	LibDialog:Register("RCLOOTCOUNCIL_CONFIRM_USAGE", {
		text = L["confirm_usage_text"],
		buttons = {
			{	text = L["Yes"],
				on_click = function()
					local lootMethod = GetLootMethod()
					if lootMethod ~= "master" then
						self:Print(L["Changing LootMethod to Master Looting"])
						SetLootMethod("master", self.playerName) -- activate ML
					end
					if db.autoAward and GetLootThreshold() ~= 2 and GetLootThreshold() > db.autoAwardLowerThreshold  then
						self:Print(L["Changing loot threshold to enable Auto Awarding"])
						SetLootThreshold(db.autoAwardLowerThreshold >= 2 and db.autoAwardLowerThreshold or 2)
					end
					self:Print(L["Now handles looting"])
					self.isMasterLooter = true
					self.masterLooter = self.playerName
					if tgetn(db.council) == 0 then -- if there's no council
						self:Print(L["You haven't set a council! You can edit your council by typing '/rc council'"])
					end
					self:CallModule("masterlooter")
					self:GetActiveModule("masterlooter"):NewML(self.masterLooter)
				end,
			},
			{	text = L["No"],
				on_click = function()
					RCLootCouncil:Print(L[" is not active in this raid."])
				end,
			},
		},
		hide_on_escape = true,
		show_while_dead = true,
	})
end

function RCLootCouncil:OnDisable()
	self:Debug("OnDisable()")
	--NOTE (not really needed as we probably never call .Disable() on the addon)
		-- delete all windows
		-- disable modules(?)
	self:UnregisterAllEvents()
end

function RCLootCouncil:RefreshConfig(event, database, profile)
	self:Debug("RefreshConfig",event, database, profile)
	self.db.profile = database.profile
	db = database.profile
end

function RCLootCouncil:ConfigTableChanged(val)
	--[[ NOTE By default only ml_core needs to know about changes to the config table,
		  but we'll use AceEvent incase future modules also wants to know ]]
	self:SendMessage("RCConfigTableChanged", val)
end

function RCLootCouncil:CheckGuildUpdate(_, msg)
	local rank_name
	if GUILD_PROMOTE_PATTERN then
		rank_name = select(4, strfind(msg, GUILD_PROMOTE_PATTERN)) -- update on promotion
	end
	if rank_name == nil and GUILD_DEMOTE_PATTERN then
		rank_name = select(4, strfind(msg, GUILD_DEMOTE_PATTERN))
	end
	if rank_name then
		if not self.checkUpdateTimer then
			self.checkUpdateTimer = self:ScheduleTimer("AddGuildRanksToCouncil", 2)
		end
	end
end

function RCLootCouncil:AddGuildRanksToCouncil(rank)
	self.checkUpdateTimer = nil
	rank = rank or self.db.profile.minRank
	self.db.profile.council = {}
	for i = 1, GetNumGuildMembers() do
		local name, _, rankIndex = GetGuildRosterInfo(i) -- get info from all guild members
		if rankIndex + 1 <= rank then -- if the member is the required rank, or above
			tinsert(self.db.profile.council, name) -- then insert them to the council
		end
	end
	self:CouncilChanged()
end

function RCLootCouncil:CouncilChanged()
	if self.isMasterLooter then 
		self:GetActiveModule("masterlooter"):CouncilChanged()
	end
end

--- Returns a table containing the the council members in the group
function RCLootCouncil:GetCouncilInGroup()
	-- CONFIRMED LIVE, high-severity, root cause of the whole "Nydeh never gets a Voting Frame"
	-- saga: pcall(UnitInRaid, v)/pcall(UnitInParty, v) with a bare NAME can throw on this client
	-- ("Unknown unit name") - the pcall wrap silently swallows that (ok=false), so the member is
	-- just quietly OMITTED from the returned council list, no error, no trace anywhere. Every
	-- earlier fix (re-sending "council" on StartSession, a self-heal council_request) was correct
	-- but powerless against this - self.council itself never actually contained Nydeh's name to
	-- begin with, no matter how many times or how reliably it got broadcast. Use the same direct
	-- raid/party iteration + UnitName(realToken) comparison already proven safe in
	-- IsNameInGroup() instead of ever passing a name into UnitInRaid/UnitInParty.
	local council = {}
	if self:IsInRaid() then
		for k,v in ipairs(db.council) do
			if self:IsNameInGroup(v) then
				tinsert(council, v)
			end
		end
	elseif self:IsInGroup() then -- Party
		for k,v in ipairs(db.council) do
			if self:IsNameInGroup(v) then
				tinsert(council, v)
			end
		end
	elseif self.isCouncil then -- When we're alone
		tinsert(council, self.playerName)
	end
	if tgetn(council) == 0 and self.masterLooter then -- We can't have empty council
		tinsert(council, self.masterLooter)
	end
	self:DebugLog("GetCouncilInGroup", unpack(council))
	return council
end

function RCLootCouncil:ChatCommand(msg)
	local input, arg1, arg2 = self:GetArgs(msg,3)
	input = strlower(input or "")
	if not input or strtrim(input) == "" or input == "help" or input == L["help"] then
		if self.tVersion then print(format(L["chat tVersion string"],self.version, self.tVersion))
		else print(format(L["chat version String"],self.version)) end
		self:Print(L["chat_commands"])
		self:Debug("- debug or d - Toggle debugging")
		self:Debug("- log - display the debug log")
		self:Debug("- clearLog - clear the debug log")

	elseif input == 'config' or input == L["config"] or input == "c" then
		self:CallModule("options")

	elseif input == 'debug' or input == 'd' then
		-- TESTING ONLY: lets the ML add ANY looted item to a session regardless of whether it's
		-- equippable, its quality vs the loot threshold, the ignore list, or BoE - so world-loot
		-- (e.g. a plain trade good) can trigger the Session Setup popup for testing, not just
		-- real equippable gear. Remove before any real release.
		if arg1 == "allitems" then
			self.debugAllItems = not self.debugAllItems
			self:Print("Debug allitems (loot ANY item for testing, ignoring equippable/quality/ignore-list/BoE filters) = "..tostring(self.debugAllItems))
		else
			self.debug = not self.debug
			self:Print("Debug = "..tostring(self.debug))
		end

	elseif input == 'open' or input == L["open"] then
		if self.isCouncil or self.mldb.observe or self.nnp then -- only the right people may see the window during a raid since they otherwise could watch the entire voting
			self:GetActiveModule("votingframe"):Show()
		else
			self:Print(L["You are not allowed to see the Voting Frame right now."])
		end

	elseif input == 'council' or input == L["council"] then
		if arg1 == "add" or arg1 == "remove" then
			-- Per explicit user request: editing the council list should NOT require being the
			-- Master Looter. Only the ML's own copy actually governs a real session (each player
			-- keeps their own local council list), but there's no reason to gate who's ALLOWED to
			-- edit their own list - e.g. an officer preparing the roster before ML duty is handed
			-- to them for the night.
			if not arg2 or strtrim(arg2) == "" then
				self:Print("Usage: /rc council add|remove <name>")
				return
			end
			local name = strupper(strsub(arg2,1,1))..strlower(strsub(arg2,2))
			if arg1 == "add" then
				if tContains(db.council, name) then
					self:Print(name.." is already on the council.")
				-- CONFIRMED LIVE per explicit user request: also accept anyone in the same guild,
				-- not just someone currently in your raid/party - a guild's regular loot council
				-- roster often includes people who aren't grouped with you right now.
				elseif not (self:UnitIsUnit(name, "player") or self:IsNameInGroup(name) or self:IsNameInGuild(name)) then
					self:Print(name.." is not in your group or guild.")
				else
					tinsert(db.council, name)
					self:Print("Added "..name.." to the council.")
					local ml = self:GetActiveModule("masterlooter")
					ml:CouncilChanged()
					-- CONFIRMED LIVE: a council member added mid-session never got a Voting Frame,
					-- even though they showed up correctly in the council list - their votingframe
					-- module only starts listening for comms once it processes the "council"
					-- broadcast CouncilChanged() just sent, but the "lootTable" broadcast that
					-- actually started the current session already went out earlier, before they
					-- were council, so they missed it entirely and nothing ever re-sent it. Target
					-- a resend just at them (not a group broadcast - that would reset everyone
					-- ELSE's response back to "WAIT" too, via the lootAck every "lootTable" receipt
					-- triggers) using the same point-to-point comm path already used for reconnects.
					if ml.running then
						self:SendCommand(name, "lootTable", ml.lootTable)
					end
				end
			else -- remove
				local found = false
				for i, v in ipairs(db.council) do
					if v == name then
						tremove(db.council, i)
						found = true
						break
					end
				end
				if found then
					self:Print("Removed "..name.." from the council.")
					self:GetActiveModule("masterlooter"):CouncilChanged()
				else
					self:Print(name.." is not on the council.")
				end
			end
		else
			local optionsFrame = self:GetActiveModule("options")
			if optionsFrame then
				optionsFrame:OpenToTab("council")
			else
				self:CallModule("options")
			end
		end


	elseif input == 'test' or input == L["test"] then
		--self:Print(db.ui.versionCheckScale)
		self:Test(tonumber(arg1) or 1)

	elseif input == 'version' or input == L["version"] or input == "v" or input == "ver" then
		self:CallModule("version")

	elseif input == "history" or input == L["history"] or input == "h" or input == "his" then
		self:CallModule("history")
--@debug@
	elseif input == "nnp" then
		self.nnp = not self.nnp
		self:Print("nnp = "..tostring(self.nnp))
--@end-debug@
	elseif input == "whisper" or input == L["whisper"] then
		self:Print(L["whisper_help"])

	elseif (input == "add" or input == L["add"]) then
		-- TESTING ONLY: "Hideurkids" (tester's own character) bypasses the Master Looter
		-- requirement for /rc add and /rc test, per explicit request, to ease testing without
		-- needing to actually be ML every time. Remove this bypass before any real release.
		if self.isMasterLooter or self.playerName == "Hideurkids" then
			self:CallModule("masterlooter") -- ensure the module (and its lootTable) is enabled
			self:GetActiveModule("masterlooter"):AddUserItem(arg1)
		else
			self:Print(L["You cannot use this command without being the Master Looter"])
		end

	elseif input == "award" or input == L["award"] then
		if self.isMasterLooter then
			self:GetActiveModule("masterlooter"):SessionFromBags()
		else
			self:Print(L["You cannot use this command without being the Master Looter"])
		end

	elseif input == "winners" or input == L["winners"] then
		if self.isMasterLooter then
			self:GetActiveModule("masterlooter"):PrintAwardedInBags()
		else
			self:Print(L["You cannot use this command without being the Master Looter"])
		end

	elseif input == "reset" or input == L["reset"] then
		for k, v in pairs(db.UI) do -- We can't easily reset due to the wildcard in defaults
			if k == "lootframe" then -- Loot Frame is special
				v.y		= -200
			else
				v.y		= 0
			end
			v.point	= "CENTER"
			v.x 			= 0
			v.scale		= 0.8
		end
		for _, frame in ipairs(frames) do
			frame:RestorePosition()
		end
		self:Print(L["Windows reset"])

	elseif input == "debuglog" or input == "log" then
		for k,v in ipairs(debugLog) do print(k,v); end

	elseif input == "clearlog" then
		wipe(debugLog)
		self:Print("Debug Log cleared.")
--@debug@
	elseif input == 't' then -- Tester cmd
		printtable(historyDB)
--@end-debug@

	else
		self:ChatCommand("help")
	end
end

-- CONFIRMED LIVE, very likely the underlying explanation for a whole string of "works fine via
-- the ML's own self-loopback, consistently fails for a real other player" reports throughout this
-- port (Nydeh never getting a working Voting Frame chief among them): AceComm-3.0's OWN built-in
-- multi-part message splitting (SendCommMessage, ~line 95 of Libs\AceComm-3.0\AceComm-3.0.lua)
-- kicks in for any payload over 254-strlen(prefix) bytes (241 for our "RCLootCouncil" prefix) -
-- and it does so by appending a CONTROL CHARACTER (\001/\002/\003) directly onto the addon
-- message PREFIX for each chunk ("RCLootCouncil\001", etc). "lootTable" (350 raw bytes) and
-- "candidates" (278 raw bytes) both exceed that threshold and use this path; "response" (180),
-- "council" (75), "offline_timer" (40) all stay under it and use the plain single-part path -
-- exactly matching which comms reliably reach a real other client and which don't. The ML's own
-- self-loopback (AceComm.callbacks:Fire, used to simulate receiving our own broadcast) never
-- exercises this AT ALL - it fires the complete, unsplit message directly as one in-memory call -
-- which is exactly why every test looked fine from the ML's own perspective while consistently
-- failing for anyone receiving the REAL over-the-wire message. Rather than track down exactly how
-- this heavily-modified client mishandles a control character in an addon-message prefix, sidestep
-- it entirely: do our OWN chunking with a marker embedded in the message BODY instead (never
-- touching the prefix), so AceComm's own SendCommMessage never sees a payload big enough to
-- trigger its native multi-part path in the first place.
local RAWSEND_CHUNK_SIZE = 200 -- comfortably under 241 even with our own small per-chunk header
local rawSendNextMsgID = 0
function RCLootCouncil:RawSend(toSend, distribution, target, prio)
	local len = string.len(toSend)
	if len <= RAWSEND_CHUNK_SIZE then
		self:SendCommMessage("RCLootCouncil", "S"..toSend, distribution, target, prio)
	else
		rawSendNextMsgID = math.mod(rawSendNextMsgID + 1, 100000)
		local total = math.ceil(len / RAWSEND_CHUNK_SIZE)
		for i = 1, total do
			local chunk = string.sub(toSend, (i-1)*RAWSEND_CHUNK_SIZE + 1, i*RAWSEND_CHUNK_SIZE)
			self:SendCommMessage("RCLootCouncil", "M"..rawSendNextMsgID..":"..i..":"..total..":"..chunk, distribution, target, prio)
		end
	end
end

--- Reassembles a message chunked by RawSend(). `spool` MUST be a table owned by the calling
-- module (never shared across modules) - AceComm dispatches every raw chunk independently to
-- EVERY module that's registered "RCLootCouncil", so a shared spool would double-count chunks
-- and never complete. Returns the reassembled string once all chunks have arrived, or nil if
-- the message is either incomplete (buffered, waiting on more chunks) or malformed (dropped).
function RCLootCouncil:ReceiveRaw(rawMsg, sender, spool)
	if not rawMsg or rawMsg == "" then return nil end
	local marker = string.sub(rawMsg, 1, 1)
	if marker == "S" then
		return string.sub(rawMsg, 2)
	elseif marker == "M" then
		local rest = string.sub(rawMsg, 2)
		local _, _, msgID, i, total = string.find(rest, "^(%d+):(%d+):(%d+):")
		if not msgID then return nil end
		i, total = tonumber(i), tonumber(total)
		local header = msgID..":"..i..":"..total..":"
		local chunk = string.sub(rest, string.len(header) + 1)
		local key = tostring(sender)..":"..msgID
		local entry = spool[key]
		if not entry then
			entry = { total = total, count = 0 }
			spool[key] = entry
		end
		if not entry[i] then
			entry[i] = chunk
			entry.count = entry.count + 1
		end
		if entry.count >= entry.total then
			local parts = {}
			for j = 1, entry.total do parts[j] = entry[j] or "" end
			spool[key] = nil
			return table.concat(parts, "")
		end
		return nil
	end
	return nil -- unknown/malformed marker - drop it
end

local deflate_level = {level = 9}
--- Send a RCLootCouncil Comm Message using AceComm-3.0
-- See RCLootCouncil:OnCommReceived() on how to receive these messages.
-- @param target The receiver of the message. Can be "group", "guild" or "playerName".
-- @param command The command to send.
-- @param vararg Any number of arguments to send along. Will be packaged as a table.
function RCLootCouncil:SendCommand(target, command, ...)
	-- send all data as a table, and let receiver unpack it
	local serialized = self:Serialize(command, arg)
	-- CompressDeflate/DecompressDeflate have a known, never-fully-root-caused Lua-5.0-porting bug
	-- on this client ("table index is nil" inside LZ77 internals) - despite multiple rounds of
	-- targeted fixes (string.byte truncation, etc.), CONFIRMED LIVE that decompression fails
	-- CONSISTENTLY (not rarely) for real gameplay messages (vote/response) once every "group"
	-- message actually got exercised through this path via the self-loopback fix. Given the
	-- bandwidth savings are marginal for this addon's small text payloads (AceComm already
	-- transparently splits anything too big for one packet into multiple), and correctness matters
	-- far more than compression here, stop attempting compression entirely instead of continuing
	-- to chase this bug - always send raw ("R"-marked) payloads. The "C" marker/decompress path is
	-- left in every receiver (core.lua/ml_core.lua/votingFrame.lua/versionCheck.lua) for backward
	-- compatibility with any already-compressed message still in flight, but nothing sends "C"
	-- anymore.
	local payload = "R"..serialized
	local toSend = Deflate:EncodeForPrint(payload)
	local prio = "NORMAL"

	if target == "groupfast" then 
		target = "group"
		prio = "ALERT"
	end

	if target == "group" then
		local realDist
		if self:IsInRaid() then
			realDist = "RAID"
		elseif self:IsInGroup() then
			realDist = "PARTY"
		end
		if realDist then
			self:RawSend(toSend, realDist, nil, prio)
		else
			-- CONFIRMED LIVE: "WHISPER" is rejected outright by SendAddonMessage on this client
			-- ("ERROR: Unknown addon chat type", uncaught - not a Lua error we raised, the native
			-- engine call itself throws) - this used to whisper the group broadcast to yourself
			-- when solo. Skip the real send when alone instead of crashing on a distribution type
			-- this client won't accept - the self-loopback below covers reacting to our own
			-- message either way, and there's nobody else to send it to when genuinely solo.
			self:DebugLog("SendCommand: alone, skipping real 'group' broadcast (WHISPER-to-self isn't a valid addon chat type on this client)")
		end
		-- CONFIRMED LIVE: this client never echoes a sent addon message back to the sender, in
		-- ANY distribution (RAID and PARTY both tested, not just the already-broken WHISPER-to-
		-- self solo case) - unlike stock WoW, where SendAddonMessage normally IS received by the
		-- sender too. This broke every single "group" comm consumer one at a time as each got
		-- exercised for the first time (council, candidates, lootTable, vote, response, MLdb...) -
		-- rather than keep adding a one-off direct-call bypass per consumer, fire the same
		-- CallbackHandler event AceComm's real dispatch fires on actual receipt (see
		-- AceComm-3.0.lua: "AceComm.callbacks:Fire(prefix, message, distribution, sender)"),
		-- simulating a genuinely self-received copy through the EXACT same OnCommReceived path
		-- every module already has - covers every current and future "group" comm consumer at
		-- once instead of needing individual fixes.
		-- "S" marker: loopback always fires the complete message in one shot (never chunked, see
		-- RawSend's comment above), so it must match what a real single-part receive would carry.
		AceComm.callbacks:Fire("RCLootCouncil", "S"..toSend, realDist or "WHISPER", self.playerName)

	elseif target == "guild" then
		self:RawSend(toSend, "GUILD", nil, prio)

	else
		if self:UnitIsUnit(target,"player") then -- If target == "player"
			-- Same "Unknown addon chat type" issue as the "group" branch above - WHISPER-to-
			-- yourself isn't a valid addon chat type on this client. Skip the real send and fire
			-- the same self-loopback instead of crashing.
			AceComm.callbacks:Fire("RCLootCouncil", "S"..toSend, "WHISPER", self.playerName)
		elseif target then
			-- CONFIRMED LIVE ("Unknown addon chat type", hit by a real other player - not just
			-- self-targeted): WHISPER is rejected outright as an addon-message distribution on
			-- this client, for ANY target, same-realm or not. Route point-to-point messages
			-- through the SAME broadcast+target-check mechanism already used for cross-realm
			-- targets (HandleXRealmComms) whenever we share a raid/party with the recipient -
			-- only their own client's HandleXRealmComms actually reacts to it, everyone else's
			-- just sees "xrealm" and ignores it. This also fixes a separate pre-existing bug in
			-- the cross-realm path itself: it never went through Deflate:EncodeForPrint the way
			-- every receiver's OnCommReceived expects (a raw AceSerializer string isn't
			-- print-safe-encoded), so it could never have round-tripped correctly even before.
			if self:IsInRaid() or self:IsInGroup() then
				local xrealmData = {target, command}
				for i = 1, arg.n do
					xrealmData[2 + i] = arg[i]
				end
				local xrealmSend = Deflate:EncodeForPrint("R"..self:Serialize("xrealm", xrealmData))
				self:RawSend(xrealmSend, self:IsInRaid() and "RAID" or "PARTY", nil, prio)
			else
				-- No shared raid/party to broadcast through - no reliable delivery path is known
				-- for this case yet. Try the old WHISPER call as a last resort (better than
				-- silently dropping it) rather than giving up outright, even though it's expected
				-- to fail with the same "Unknown addon chat type" error.
				self:RawSend(toSend, "WHISPER", target, prio)
			end
		end
	end
end

--- Receives RCLootCouncil commands
-- Params are delivered by AceComm-3.0, but we need to extract our data created with the
-- RCLootCouncil:SendCommand function.
-- @usage
-- To extract the original data using AceSerializer-3.0:
-- -- local success, command, data = self:Deserialize(serializedMsg)
-- 'data' is a table containing the varargs delivered to RCLootCouncil:SendCommand().
-- To ensure correct handling of x-realm commands, include this line aswell:
-- -- if RCLootCouncil:HandleXRealmComms(self, command, data, sender) then return end
local chunkSpool = {} -- RawSend()'s reassembly buffer - see ReceiveRaw(), must be this file's own
function RCLootCouncil:OnCommReceived(prefix, serializedMsg, distri, sender)
	if prefix == "RCLootCouncil" then
		serializedMsg = self:ReceiveRaw(serializedMsg, sender, chunkSpool)
		if not serializedMsg then return end -- either mid-reassembly or a malformed message
		-- data is always a table to be unpacked
		local decoded = Deflate:DecodeForPrint(serializedMsg)
		if not decoded then
			return -- probably an old version or somehow a bad message idk just throw this away
		end
		-- 1-byte marker set by SendCommand() - "C" = Deflate-compressed, "R" = sent raw
		-- (CompressDeflate failed on the sender's side - see SendCommand()).
		local marker = string.sub(decoded, 1, 1)
		local body = string.sub(decoded, 2)
		-- NOT the and/or ternary idiom here - if marker=="C" but DecompressDeflate(body) itself
		-- fails and returns nil, "X and Y or Z" would silently fall through to Z (the still-
		-- compressed body), feeding binary garbage into Deserialize() instead of failing cleanly
		-- (confirmed live: "Supplied data is not AceSerializer data" from exactly this).
		local decompressed
		if marker == "C" then
			decompressed = Deflate:DecompressDeflate(body)
		else
			decompressed = body
		end
		if not decompressed then
			-- DecompressDeflate can genuinely fail (the still-not-fully-root-caused LZ77 bug) -
			-- drop the message instead of crashing Deserialize(nil) ("bad argument #1 to gsub").
			return self:DebugLog("Comm decompress failed, dropping message from:", sender)
		end
		local test, command, data = self:Deserialize(decompressed)
		-- NOTE: Since I can't find a better way to do this, all xrealms comms is routed through here
		--			to make sure they get delivered properly. Must be included in every OnCommReceived() function.
		if self:HandleXRealmComms(self, command, data, sender) then return end
		self:DebugLog("Comm received:", command, "from:", sender, "distri:", distri)
		if test then
			if command == "lootTable" then
				self.isMasterLooter, self.masterLooter = self:GetML()
				if self:UnitIsUnit(sender, self.masterLooter) then
					local lootTable = unpack(data)
					-- Send "DISABLED" response when not enabled
					if not self.enabled then
						for i = 1, tgetn(lootTable) do
							self:SendCommand("group", "response", i, self.playerName, {response = "DISABLED"})
						end
						return self:Debug("Sent 'DISABLED' response to", sender)
					end

					-- v2.0.1: It seems people somehow receives mldb with numButtons, so check for it aswell.
					if not self.mldb or (self.mldb and not self.mldb.numButtons) then -- Really shouldn't happen, but I'm tired of people somehow not receiving it...
						self:Debug("Received loot table without having mldb :(", sender)
						self:SendCommand(self.masterLooter, "MLdb_request")
						return self:ScheduleTimer("OnCommReceived", 1, prefix, serializedMsg, distri, sender)
					end

					self:SendCommand("group", "lootAck", self.playerName) -- send ack

					-- Self-heal: a "council" broadcast can be missed even though StartSession() now
					-- re-sends it every time - right after starting a session there's a burst of
					-- comm traffic (council+candidates+lootTable+every candidate's lootAck all in
					-- quick succession), and AddOn messages CAN be silently dropped under load. If
					-- our local isCouncil flag isn't set, proactively ask the ML directly (a
					-- targeted request/reply, not another "group" broadcast that could be lost the
					-- same way) instead of silently missing the Voting Frame for the whole session.
					if not self.isCouncil then
						self:SendCommand(self.masterLooter, "council_request")
					end

					if db.autoPass then -- Do autopassing
						for ses, v in ipairs(lootTable) do
							if (v.boe and db.autoPassBoE) or not v.boe then
								if self:AutoPassCheck(v.subType, v.equipLoc, v.link) then
									self:Debug("Autopassed on: ", v.link)
									if not db.silentAutoPass then self:Print(format(L["Autopassed on 'item'"], v.link)) end
									self:SendCommand("group", "response", self:CreateResponse(ses, v.link, v.ilvl, "AUTOPASS", v.equipLoc))
									lootTable[ses].autopass = true
								end
							else
								self:Debug("Didn't autopass on: "..v.link.." because it's BoE!")
							end
						end
					end

					-- Show  the LootFrame
					self:CallModule("lootframe")
					self:GetActiveModule("lootframe"):Start(lootTable)

					-- The votingFrame handles lootTable itself

				else -- a non-ML send a lootTable?!
					self:Debug(tostring(sender).." is not ML, but sent lootTable!")
				end

			elseif command == "council" and self:UnitIsUnit(sender, self.masterLooter) then -- only ML sends council
				self.council = unpack(data)
				self.isCouncil = self:IsCouncil(self.playerName)

				-- prepare the voting frame for the right people
				if self.isCouncil or self.mldb.observe then
					self:CallModule("votingframe")
				end

			elseif command == "MLdb" and not self.isMasterLooter then -- ML sets his own mldb
				if self:UnitIsUnit(sender, self.masterLooter) then
					self.mldb = unpack(data)
				else
					self:Debug("Non-ML:", sender, "sent Mldb!")
				end

			elseif command == "verTest" and not self:UnitIsUnit(sender, "player") then -- Don't reply to our own verTests
				local otherVersion, tVersion = unpack(data)
				self:SendCommand(sender, "verTestReply", self.playerName, self.playerClass, self.guildRank, self.version, self.tVersion)
				if self.version < otherVersion and not self.verCheckDisplayed and (not (tVersion or self.tVersion)) then
					self:Print(format(L["version_outdated_msg"], self.version, otherVersion))
					self.verCheckDisplayed = true

				elseif tVersion and self.tVersion and not self.verCheckDisplayed and self.tVersion < tVersion then
					self:Print(format(L["tVersion_outdated_msg"], tVersion))
					self.verCheckDisplayed = true
				end

			elseif command == "verTestReply" then
				local _,_,_, otherVersion, tVersion = unpack(data)
				if self.version < otherVersion and not self.verCheckDisplayed and (not (tVersion or self.tVersion)) then
					self:Print(format(L["version_outdated_msg"], self.version, otherVersion))
					self.verCheckDisplayed = true

				elseif tVersion and self.tVersion and not self.verCheckDisplayed and self.tVersion < tVersion then
					self:Print(format(L["tVersion_outdated_msg"], tVersion))
					self.verCheckDisplayed = true
				end

			elseif command == "history" and db.enableHistory then
				local name, history = unpack(data)
				-- CONFIRMED LIVE: every award showed up TWICE in "/rc history" - same class of
				-- duplicate-delivery issue already fixed for votes (idempotent HandleVote) via a
				-- "group" SendCommand somehow being processed more than once for the same logical
				-- event (root cause never fully pinned down there either - see votingFrame.lua's
				-- HandleVote comment). historyDB has no unique ID to de-dupe by, so use date+time+
				-- item+response as a good-enough fingerprint (two genuinely different awards to
				-- the same person landing in the same second with the same item+response is not a
				-- realistic collision).
				local isDup = false
				if historyDB[name] then
					for _, existing in ipairs(historyDB[name]) do
						if existing.date == history.date and existing.time == history.time
							and existing.lootWon == history.lootWon and existing.response == history.response then
							isDup = true
							break
						end
					end
				end
				if not isDup then
					if historyDB[name] then
						tinsert(historyDB[name], history)
					else
						historyDB[name] = {history}
					end
				end

			elseif command == "reroll" and self:UnitIsUnit(sender, self.masterLooter) and self.enabled then
				self:Print(format(L["'player' has asked you to reroll"], sender))
				self:CallModule("lootframe")
				self:GetActiveModule("lootframe"):ReRoll(unpack(data))

			elseif command == "playerInfoRequest" then
				self:SendCommand(sender, "playerInfo", self:GetPlayerInfo())

			elseif command == "message" then
				self:Print(unpack(data))

			elseif command == "session_end" and self.enabled then
				if self:UnitIsUnit(sender, self.masterLooter) then
					self:Print(format(L["'player' has ended the session"], self.masterLooter))
					self:GetActiveModule("lootframe"):Disable()
					if self.isCouncil or self.mldb.observe then -- Don't call the voting frame if it wasn't used
						self:GetActiveModule("votingframe"):EndSession(true)
					end
					self.successful_history_requests = {}
					self.mlhistory = {}
				else
					self:Debug("Non ML:", sender, "sent end session command!")
				end
			end
		else
			-- Most likely pre 2.0 command
			local cmd = strsplit(" ", serializedMsg, 2)
			if cmd and cmd == "verTest" then
				self:SendCommand(sender, "verTestReply", self.playerName, self.playerClass, self.guildRank, self.version, self.tVersion)
				return
			end
			self:Debug("Error in deserializing comm:", command, data);
		end
	end
end

-- Used to make sure "WHISPER" type xrealm comms is handled properly.
-- Include this right after unpacking messages. Assumes you use "OnCommReceived" as comm handler:
-- if RCLootCouncil:HandleXRealmComms(self, command, data, sender) then return end
function RCLootCouncil:HandleXRealmComms(mod, command, data, sender)
	if command == "xrealm" then
		local target = tremove(data, 1)
		if self:UnitIsUnit(target, "player") then
			local command = tremove(data, 1)
			-- CONFIRMED LIVE (an infinite MLdb_request retry loop - "VotingComm decoded=false" on
			-- every re-dispatch, every 1 second, forever): this re-serialized the unwrapped inner
			-- message but never ran it through Deflate:EncodeForPrint + the "R" marker the way
			-- every real SendCommand()-produced message does - so the mod:OnCommReceived() call
			-- below always failed at its own first step (DecodeForPrint on a raw, non-print-safe
			-- AceSerializer string), meaning the inner message was NEVER actually delivered.
			local innerSend = Deflate:EncodeForPrint("R"..self:Serialize(command, data))
			-- "S" marker: this re-dispatches directly into OnCommReceived (bypassing a real
			-- AceComm receive), so it must carry the same RawSend single-part marker every real
			-- receive now expects as its first byte.
			mod:OnCommReceived("RCLootCouncil", "S"..innerSend, "WHISPER", sender)
		end
		return true
	end
	return false
end

function RCLootCouncil:Debug(msg, ...)
	if self.debug then
		if arg.n > 0 then
			self:Print("|cffcb6700debug:|r "..tostring(msg).."|cffff6767", unpack(arg, 1, arg.n))
		else
			self:Print("|cffcb6700debug:|r "..tostring(msg).."|r")
		end
	end
	RCLootCouncil:DebugLog(msg, unpack(arg, 1, arg.n))
end

local date_to_debug_log = true
function RCLootCouncil:DebugLog(msg, ...)
	if date_to_debug_log then tinsert(debugLog, date("%x")); date_to_debug_log = false; end
	local time = date("%X", time())
	msg = time.." - ".. tostring(msg)
	for i = 1, arg.n do msg = msg.." ("..tostring(arg[i])..")" end
	if tgetn(debugLog) > self.db.global.logMaxEntries then
		tremove(debugLog, 1)
	end
	tinsert(debugLog, msg)
end

function RCLootCouncil:Test(num)
	self:Debug("Test", num)
	local testItems = {}
	for i = 1, 18 do 
		local id = GetInventoryItemID("player", i)
		tinsert(testItems, id)
	end
	if tgetn(testItems) == 0 then
		testItems = {40384,19019,46017,40343,40384,43952,40384,40399,46038,45038}
	end
	local items = {};
	-- pick "num" random items
	for i = 1, num do
		local j = math.random(1, tgetn(testItems))
		local name = GetItemInfo(testItems[j]) 
		tinsert(items, testItems[j])
	end

	self.testMode = true;
	self.isMasterLooter, self.masterLooter = self:GetML()

	-- We must be in a group and not the ML
	-- TESTING ONLY: "Hideurkids" bypasses this too - see /rc add's comment above. Remove this
	-- bypass before any real release.
	if not self.isMasterLooter and self.playerName ~= "Hideurkids" then
		self:Print(L["You cannot initiate a test while in a group without being the MasterLooter."])
		self.testMode = false
		return
	end

	-- Call ML module and let it handle the rest
	self:CallModule("masterlooter")
	self:GetActiveModule("masterlooter"):NewML(self.masterLooter)
	self:GetActiveModule("masterlooter"):Test(items)
end

-- InterfaceOptionsFrameCancel/Okay may not exist under these exact names on this client (this
-- is TOP-LEVEL code - if it errored here, every function defined further down in this file
-- would silently never exist, which is exactly what happened before this guard was added).
local interface_options_old_cancel = _G.InterfaceOptionsFrameCancel and InterfaceOptionsFrameCancel:GetScript("OnClick")
function RCLootCouncil:EnterCombat()
	-- Hack to remove CompactRaidGroup taint
	-- Make clicking cancel the same as clicking okay
	if _G.InterfaceOptionsFrameCancel and _G.InterfaceOptionsFrameOkay then
		InterfaceOptionsFrameCancel:SetScript("OnClick", function()
		 InterfaceOptionsFrameOkay:Click()
		end)
	end
	self.inCombat = true
	if not db.minimizeInCombat then return end
	for _,frame in ipairs(frames) do
		if frame:IsVisible() and not frame.combatMinimized then -- only minimize for combat if it isn't already minimized
			self:Debug("Minimizing for combat")
			frame.combatMinimized = true -- flag it as being minimized for combat
			frame:Minimize()
		end
	end
end

function RCLootCouncil:LeaveCombat()
	-- Revert
	if _G.InterfaceOptionsFrameCancel then
		InterfaceOptionsFrameCancel:SetScript("OnClick", interface_options_old_cancel)
	end
	self.inCombat = false
	if not db.minimizeInCombat then return end
	for _,frame in ipairs(frames) do
		if frame.combatMinimized then -- Reshow it
			self:Debug("Reshowing frame")
			frame.combatMinimized = false
			frame:Maximize()
		end
	end
end

--[[
	Used by getCurrentGear to determine slot types
	Inspired by EPGPLootMaster
--]]
RCLootCouncil.INVTYPE_Slots = {
		INVTYPE_HEAD		    = "HeadSlot",
		INVTYPE_NECK		    = "NeckSlot",
		INVTYPE_SHOULDER	    = "ShoulderSlot",
		INVTYPE_CLOAK		    = "BackSlot",
		INVTYPE_CHEST		    = "ChestSlot",
		INVTYPE_WRIST		    = "WristSlot",
		INVTYPE_HAND		    = "HandsSlot",
		INVTYPE_WAIST		    = "WaistSlot",
		INVTYPE_LEGS		    = "LegsSlot",
		INVTYPE_FEET		    = "FeetSlot",
		INVTYPE_SHIELD		    = "SecondaryHandSlot",
		INVTYPE_ROBE		    = "ChestSlot",
		INVTYPE_2HWEAPON	    = {"MainHandSlot","SecondaryHandSlot"},
		INVTYPE_WEAPONMAINHAND	= "MainHandSlot",
		INVTYPE_WEAPONOFFHAND	= {"SecondaryHandSlot",["or"] = "MainHandSlot"},
		INVTYPE_WEAPON		    = {"MainHandSlot","SecondaryHandSlot"},
		INVTYPE_THROWN		    = {"RangedSlot"},
		INVTYPE_RANGED		    = {"RangedSlot"},
		INVTYPE_RANGEDRIGHT		= {"RangedSlot"},
		INVTYPE_FINGER		    = {"Finger0Slot","Finger1Slot"},
		INVTYPE_HOLDABLE	    = {"SecondaryHandSlot", ["or"] = "MainHandSlot"},
		INVTYPE_TRINKET		    = {"TRINKET0SLOT", "TRINKET1SLOT"},
		INVTYPE_RELIC			= {"RangedSlot"}
}

-- NOTE: only ever used as an existence/truthy check (self.Slots_INVTYPE[slotName]), never read
-- for its value - so this is just the set of known slot names, not a real slot->invtype map.
-- The original upstream table built these values from Blizzard INVTYPE_* globals (several of
-- them typo'd, and the winning one for RangedSlot - INVTYPE_RELIC - doesn't exist before TBC),
-- which is fragile on a 1.12 client for zero benefit since the value is never consumed. Use a
-- plain `true` instead so slot-name detection doesn't depend on any of those globals existing.
RCLootCouncil.Slots_INVTYPE = {
	["HeadSlot"]			= true,
	["NeckSlot"]			= true,
	["ShoulderSlot"]		= true,
	["BackSlot"]			= true,
	["ChestSlot"]			= true,
	["WristSlot"]			= true,
	["HandsSlot"]			= true,
	["WaistSlot"]			= true,
	["LegsSlot"]			= true,
	["FeetSlot"]			= true,
	["SecondaryHandSlot"]	= true,
	["MainHandSlot"]		= true,
	["RangedSlot"]			= true,
	["Finger0Slot"]			= true,
	["Finger1Slot"]			= true,
	["TRINKET0SLOT"]		= true,
	["TRINKET1SLOT"]		= true,
}

function RCLootCouncil:GetPlayersGear(link, equipLoc)
	local itemID = self:GetItemIDFromLink(link) -- Convert to itemID
	self:DebugLog("GetPlayersGear", itemID, equipLoc)
	if not itemID then return nil, nil; end
	local item1, item2;
	-- check if the item is a token, and if it is, return the matching current gear
	if RCTokenTable[itemID] then
		if RCTokenTable[itemID] == "Trinket" then -- We need to return both trinkets
			item1 = GetInventoryItemLink("player", GetInventorySlotInfo("TRINKET0SLOT"))
			item2 = GetInventoryItemLink("player", GetInventorySlotInfo("TRINKET1SLOT"))
		else	-- Just return the slot from the tokentable
			item1 = GetInventoryItemLink("player", GetInventorySlotInfo(RCTokenTable[itemID]))
		end
		return item1, item2
	end

	if type(equipLoc) == "table" then -- if you're looking to fix t9 and 10 tokens, look here :)
		return nil, nil
	end

	local slot = self.INVTYPE_Slots[equipLoc]

	if not slot and self.Slots_INVTYPE[equipLoc] then 
		slot = equipLoc
	end

	if not slot then return nil, nil; end;
	-- CONFIRMED LIVE ("attempt to index local 'slot' (a string value)"): `slot` can be a plain
	-- STRING here (line ~1098, single-slot equip types like INVTYPE_CLOAK just use the equipLoc
	-- itself) rather than a table (multi-slot types like rings/trinkets, keyed by 1/2/"or") -
	-- indexing a string with [1]/[2]/['or'] crashes on this client (same underlying restriction
	-- as colon-calls on strings - both go through the string metatable). Branch on type first.
	if type(slot) == "table" then
		item1 = GetInventoryItemLink("player", GetInventorySlotInfo(slot[1] or slot))
		if not item1 and slot['or'] then
			item1 = GetInventoryItemLink("player", GetInventorySlotInfo(slot['or']))
		end;
		if slot[2] then
			item2 = GetInventoryItemLink("player", GetInventorySlotInfo(slot[2]))
		end
	else
		item1 = GetInventoryItemLink("player", GetInventorySlotInfo(slot))
	end
	return item1, item2;
end

function RCLootCouncil:Timer(type, ...)
	self:Debug("Timer "..type.." passed")
	if type == "LocalizeSubTypes" then
		self:LocalizeSubTypes()
	elseif type == "MLdb_check" then
		-- If we have a ML
		if self.masterLooter then
			-- But haven't received the mldb, then request it
			if not self.mldb then
				self:SendCommand(self.masterLooter, "MLdb_request")
			end
			-- and if we haven't received a council, request it
			if not self.council then
				self:SendCommand(self.masterLooter, "council_request")
			end
		end
	end
end

-- Classes that should auto pass a subtype
local autopassTable = {}
if not AscensionUI then -- Ascension don't auto pass anything
	autopassTable = {
		["Cloth"]					= {"WARRIOR", "DEATHKNIGHT", "ROGUE", "HUNTER"},
		["Leather"] 				= {"PRIEST", "MAGE", "WARLOCK"},
		["Mail"] 					= {"DRUID", "ROGUE", "PRIEST", "MAGE", "WARLOCK"},
		["Plate"]					= {"DRUID", "ROGUE", "HUNTER", "SHAMAN", "PRIEST", "MAGE", "WARLOCK"},
		["Shields"] 				= {"DEATHKNIGHT", "DRUID", "ROGUE", "HUNTER", "PRIEST", "MAGE", "WARLOCK"},
		["Bows"] 					= {"DEATHKNIGHT", "PALADIN", "DRUID", "SHAMAN", "PRIEST", "MAGE", "WARLOCK"},
		["Crossbows"] 				= {"DEATHKNIGHT", "PALADIN", "DRUID", "SHAMAN", "PRIEST", "MAGE", "WARLOCK"},
		["Daggers"]					= {"WARRIOR", "DEATHKNIGHT", "PALADIN", "DRUID", "HUNTER"},
		["Guns"]					= {"DEATHKNIGHT", "PALADIN", "DRUID","SHAMAN", "PRIEST", "MAGE", "WARLOCK"},
		["Fist Weapons"] 			= {"DEATHKNIGHT", "PALADIN", "PRIEST", "MAGE", "WARLOCK"},
		["One-Handed Axes"]			= {"DRUID", "PRIEST", "MAGE", "WARLOCK"},
		["One-Handed Maces"]		= {"HUNTER", "MAGE", "WARLOCK"},
		["One-Handed Swords"] 		= {"DRUID", "SHAMAN", "PRIEST"},
		["Polearms"] 				= {"ROGUE", "SHAMAN", "PRIEST", "MAGE", "WARLOCK"},
		["Staves"]					= {"WARRIOR", "DEATHKNIGHT", "PALADIN",  "ROGUE"},
		["Two-Handed Axes"]			= {"DRUID", "ROGUE", "PRIEST", "MAGE", "WARLOCK"},
		["Two-Handed Maces"]		= {"ROGUE", "HUNTER", "PRIEST", "MAGE", "WARLOCK"},
		["Two-Handed Swords"]		= {"DRUID", "ROGUE", "SHAMAN", "PRIEST", "MAGE", "WARLOCK"},
		["Wands"]					= {"WARRIOR", "DEATHKNIGHT", "PALADIN", "DRUID", "ROGUE", "HUNTER", "SHAMAN"},
		["Totems"]					= {"DEATHKNIGHT", "DRUID", "ROGUE", "HUNTER", "PRIEST", "MAGE", "WARLOCK", "PALADIN", "WARRIOR"},
		["Sigils"]					= {"DRUID", "ROGUE", "HUNTER", "PRIEST", "MAGE", "WARLOCK", "PALADIN", "WARRIOR", "SHAMAN"},
		["Idols"]					= {"DEATHKNIGHT", "ROGUE", "HUNTER", "PRIEST", "MAGE", "WARLOCK", "PALADIN", "WARRIOR", "SHAMAN"},
		["Librams"]					= {"DEATHKNIGHT", "DRUID", "ROGUE", "HUNTER", "PRIEST", "MAGE", "WARLOCK", "WARRIOR", "SHAMAN"},
	}
end

-- Used to find localized subType names
local subTypeLookup = {
	["Cloth"]					= 39252, -- Preceptor's Bindings
	["Leather"] 				= 39275, -- Contagion Gloves
	["Mail"] 					= 39274, -- Retcher's Shoulderpads
	["Plate"]					= 39262, -- Gauntlets of Combined Strength
	["Shields"] 				= 40400, -- Wall of Terror
	["Bows"] 					= 40265, -- Arrowsong
	["Crossbows"] 				= 40346, -- Final Voyage
	["Daggers"]					= 39714, -- Webbed Death
	["Guns"]					= 40385, -- Envoy of Mortality
	["Fist Weapons"] 			= 40239, -- The hand of Nerub
	["One-Handed Axes"]			= 40402, -- Last Laugh
	["One-Handed Maces"]		= 40395, -- Torch of Holy Fire
	["One-Handed Swords"] 		= 40407, -- Silent Crusader
	["Polearms"] 				= 40208, -- Cryptfiend's Bite
	["Staves"]					= 40300, -- Spire of Sunset
	["Two-Handed Axes"]			= 40384, -- Betrayer of Humanity
	["Two-Handed Maces"]		= 39758, -- The Jawbone
	["Two-Handed Swords"]		= 40343, -- Armageddon
	["Wands"]					= 40335, -- Touch of Horror
	["Totems"]					= 51507, -- Wrathful Gladiator Totem
	["Sigils"]					= 51417, -- Wrathful Gladiator Sigil
	["Idols"]					= 51429, -- Wrathful Gladiator Idol
	["Librams"]					= 40707, -- Libram of Obstruction
}

-- Never autopass these armor types
local autopassOverride = {
	"INVTYPE_CLOAK",
}

function RCLootCouncil:AutoPassCheck(subType, equipLoc, link)
	if not tContains(autopassOverride, equipLoc) then
		if subType and autopassTable[self.db.global.localizedSubTypes[subType]] then
			return tContains(autopassTable[self.db.global.localizedSubTypes[subType]], self.playerClass)
		end
		-- The item wasn't a type we check for, but it might be a token
		local id = type(link) == "number" and link or self:GetItemIDFromLink(link) -- Convert to id if needed
		if RCTokenClasses[id] then -- It's a token
			return not tContains(RCTokenClasses[id], self.playerClass)
		end
	end
	return false
end

function RCLootCouncil:LocalizeSubTypes()
	if self.db.global.localizedSubTypes.created then return end -- We only need to create it once
	-- All 22 reference item IDs in subTypeLookup are WotLK-era (Naxxramas/Ulduar/arena) items
	-- that don't exist in this server's item database, so GetItemInfo() will NEVER resolve a
	-- subType for them - not a caching delay, a permanent mismatch. Without a retry cap this
	-- retried every 2 seconds forever (confirmed live) and, since it also reset all progress to
	-- {} and bailed on the FIRST unresolved item every single time, left AutoPassCheck's
	-- subtype-based autopass permanently, silently non-functional. Cap retries, then fall back to
	-- the English name directly for anything that never resolves (correct if the server/client is
	-- English, which is the reasonable default assumption here; a non-English client just keeps
	-- today's silently-inert behavior for whichever subtype never resolved).
	self.localizeSubTypesAttempts = (self.localizeSubTypesAttempts or 0) + 1
	-- Get the item info
	for _, item in pairs(subTypeLookup) do
		GameTooltip:Hide()
		GameTooltip:SetHyperlink(self:BuildItemLink(item)) -- force item update
		self:GetItemInfo(item)
	end
	local result = {}
	local anyMissing = false
	for name, item in pairs(subTypeLookup) do
		local sType = select(7, self:GetItemInfo(item))
		if sType then
			result[sType] = name
			self:DebugLog("Found "..name.." localized as: "..sType)
		elseif self.localizeSubTypesAttempts >= 15 then
			result[name] = name
			self:DebugLog("Giving up on finding a localized name for:", name, item, "- using English name as fallback")
		else
			anyMissing = true
		end
	end
	if anyMissing then -- Probably not cached, set a timer
		self:ScheduleTimer("Timer", 2, "LocalizeSubTypes")
		return
	end
	result.created = true
	self.db.global.localizedSubTypes = result
end

function RCLootCouncil:IsItemBoE(item)
	if not item then return false end
	GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
	GameTooltip:SetHyperlink(item)
	if GameTooltip:NumLines() > 1 then -- check that there is something here
		for i = 1, 5 do -- BoE status won't be further away than line 5
			local line = getglobal('GameTooltipTextLeft' .. i)
			if line and line.GetText then
				if line:GetText() == ITEM_BIND_ON_EQUIP then
					GameTooltip:Hide()
					return true
				end
			end
		end
	end
	GameTooltip:Hide()
	return false
end

--- Formats a response for the player to be send to the group
-- @param session		The session to respond to
-- @param link 		The itemLink of the item in the session
-- @param ilvl			The ilvl of the item in the session
-- @param response	The selected response, must be index of db.responses
-- @param equipLoc	The item in the session's equipLoc
-- @param note			The player's note
-- @returns A formatted table that can be passed directly to :SendCommand("group", "response", -return-)
function RCLootCouncil:CreateResponse(session, link, ilvl, response, equipLoc, note)
	self:DebugLog("CreateResponse", session, link, ilvl, response, equipLoc, note)
	local g1, g2 = self:GetPlayersGear(link, equipLoc)
	local diff = nil
	-- select(4, GetItemInfo(gX)) can come back nil (item not yet cached client-side) - guard
	-- instead of crashing on the arithmetic below.
	if g1 then
		local g1ilvl = select(4, GetItemInfo(g1))
		if g1ilvl then diff = ilvl - g1ilvl end
	end
	if g1 and g2 and diff then
		local g2ilvl = select(4, GetItemInfo(g2))
		if g2ilvl then
			local g2diff = ilvl - g2ilvl
			local test1, test2 = abs(diff), abs(g2diff)
			if test2 > test1 then
				diff = g2diff
			end
		end
	elseif g2 and not diff then  -- this shouldn't be possible but idk i dont wanna come back and fix it later if it somehow is
		local g2ilvl = select(4, GetItemInfo(g2))
		if g2ilvl then diff = ilvl - g2ilvl end
	end

	local ilvl = GearScore_GetScore and GearScore_GetScore(UnitName("player"), "player") or 0
	if ilvl == 0 then 
		if GS_Data then 
			ilvl = GS_Data[GetRealmName()].Players[UnitName("player")].GearScore or 0
		end
	end
	return
		session,
		self.playerName,
		{	gear1 = g1,
			gear2 = g2,
			ilvl = ilvl,
			diff = diff,
			note = note,
			response = response
		}
end

function RCLootCouncil:GetPlayersGuildRank()
	self:DebugLog("GetPlayersGuildRank()")
	GuildRoster() -- let the event trigger this func
	if IsInGuild() then
		local rank = select(2, GetGuildInfo("player"))
		if rank then
			self:Debug("Found Guild Rank: "..rank)
			unregisterGuildEvent = true;
			return rank;
		else
			return L["Not Found"];
		end
	else
		return L["Unguilded"];
	end
end

function RCLootCouncil:GetPlayerInfo()
	-- Check if the player has enchanting
	local enchant, lvl = IsSpellKnown(13262), 0 -- disenchant spell 
	if enchant then lvl = 450 end -- assume max enchanting idc
	return self.playerName, self.playerClass, self:GetPlayerRole(), self.guildRank, enchant, lvl
end

function RCLootCouncil:GetUnitRole(unit)
	-- Role (tank/healer/dps) was only ever STORED per-candidate (votingFrame.lua's Setup()) but
	-- never actually read back anywhere in the addon's UI or logic (TranslateRole() below is
	-- defined but never called) - the only thing computing it did was drive
	-- LibGroupTalents:GetUnitRole(unit), which triggers real NotifyInspect() talent-inspection
	-- traffic on every raid member - the source of the recurring "Out of range." spam whenever
	-- someone is out of inspection range, for a value nothing consumes. Per explicit request,
	-- stop inspecting for spec entirely - only class is actually needed, and that's already known
	-- natively (GetRaidRosterInfo/UnitClass) without any inspection at all.
	return "DAMAGER"
end

function RCLootCouncil:GetPlayerRole()
	return self:GetUnitRole("player")	
end

function RCLootCouncil.TranslateRole(role) -- reasons
	return (role and role ~= "") and RCLootCouncil.roleTable[role] or ""
end

--- GetGuildRanks
-- Returns a lookup table containing GuildRankNames and their index
-- @return table "GuildRankName" = rankIndex
function RCLootCouncil:GetGuildRanks()
	if not IsInGuild() then return {} end
	self:DebugLog("GetGuildRankNum()")
	GuildRoster()
	local t = {}
	for i = 1, GuildControlGetNumRanks() do
		local name = GuildControlGetRankName(i)
		t[name] = i
	end
	return t;
end

function RCLootCouncil:GetNumberOfDaysFromNow(oldDate)
	local d, m, y = strsplit("/", oldDate, 3)
	local sinceEpoch = time({year = "20"..y, month = m, day = d}) -- convert from string to seconds since epoch
	local diff = date("*t", time() - sinceEpoch) -- get the difference as a table
	-- Convert to number of d/m/y
	return diff.day - 1, diff.month - 1, diff.year - 1970
end

function RCLootCouncil:ConvertDateToString(day, month, year)
	local text = format(L["x days"], day)
	if year > 0 then
		text = format(L["days, x months, y years"], text, month, year)
	elseif month > 0 then
		text = format(L["days and x months"], text, month)
	end
	return text;
end

function RCLootCouncil:OnEvent(event, ...)
	if event == "PARTY_LOOT_METHOD_CHANGED" then
		self:Debug("Event:", event, unpack(arg, 1, arg.n))
		self:NewMLCheck()

	elseif event == "RAID_ROSTER_UPDATE" then
		self:Debug("Event:", event, unpack(arg, 1, arg.n))
		self:NewMLCheck()

	elseif event == "RAID_INSTANCE_WELCOME" then
		self:Debug("Event:", event, unpack(arg, 1, arg.n))
		-- high server-side latency causes the UnitIsGroupLeader("player") condition to fail if queried quickly (upon entering instance) regardless of state.
		-- NOTE v2.0: Not sure if this is still an issue, but just add a 2 sec timer to the MLCheck call
		self:ScheduleTimer("OnRaidEnter", 2)

	elseif event == "PLAYER_ENTERING_WORLD" then
		self:Debug("Event:", event, unpack(arg, 1, arg.n))
		local is_retry = arg[1]
		self:NewMLCheck()
		if not self.masterLooter and not is_retry then -- retry once just incase it didn't send
			self:ScheduleTimer("OnEvent", 1, "PLAYER_ENTERING_WORLD", true)
			self:Debug("Retry PLAYER_ENTERING_WORLD")
			return
		end
		-- Ask for data when we have done a /rl and have a ML
		if not self.isMasterLooter and self.masterLooter and self.masterLooter ~= "" and player_relogged then
			self:ScheduleTimer("SendCommand", 2, self.masterLooter, "reconnect")
			self:SendCommand(self.masterLooter, "playerInfo", self:GetPlayerInfo()) -- Also send out info, just in case
		end
		player_relogged = false

	elseif event == "GUILD_ROSTER_UPDATE" then
		self.guildRank = self:GetPlayersGuildRank();
		if unregisterGuildEvent then
			self:UnregisterEvent("GUILD_ROSTER_UPDATE"); -- we don't need it any more
			self:GetGuildOptions() -- get the guild data to the options table now that it's ready
		end
	end
end

function RCLootCouncil:NewMLCheck()
	local old_ml = self.masterLooter
	self.isMasterLooter, self.masterLooter = self:GetML()
	self:Debug("isMasterLooter", self.isMasterLooter, "masterLooter", self.masterLooter)
	if self:UnitIsUnit(old_ml, "player") and not self.isMasterLooter then
		-- We were ML, but no longer, so disable masterlooter module
		self:GetActiveModule("masterlooter"):Disable()
	end
	if self:UnitIsUnit(old_ml, self.masterLooter) or db.usage.never then return end -- no change
	if not self.isMasterLooter and self.masterLooter then return end -- Someone else is ML

	-- We are ML and shouldn't ask the player for usage
	if self.isMasterLooter and db.usage.ml then -- addon should auto start
		self:Print(L["Now handles looting"])
		if db.autoAward and GetLootThreshold() ~= 2 and GetLootThreshold() > db.autoAwardLowerThreshold  then
			self:Print(L["Changing loot threshold to enable Auto Awarding"])
			SetLootThreshold(db.autoAwardLowerThreshold >= 2 and db.autoAwardLowerThreshold or 2)
		end
		self:CallModule("masterlooter")
		self:GetActiveModule("masterlooter"):NewML(self.masterLooter)

	-- We're ML and must ask the player for usage
	elseif self.isMasterLooter and db.usage.ask_ml then
		return LibDialog:Spawn("RCLOOTCOUNCIL_CONFIRM_USAGE")
	end
end

function RCLootCouncil:OnRaidEnter(arg)
	-- NOTE: We shouldn't need to call GetML() as it's most likely called on "LOOT_METHOD_CHANGED"
	-- There's no ML, and lootmethod ~= ML, but we are the group leader
	if not self.masterLooter and (IsRaidLeader() or IsPartyLeader()) then
		-- We don't need to ask the player for usage, so change loot method to master, and make the player ML
		if db.usage.leader then
			SetLootMethod("master", self.playerName)
			self:Print(L[" you are now the Master Looter and RCLootCouncil is now handling looting."])
			if db.autoAward and GetLootThreshold() ~= 2 and GetLootThreshold() > db.autoAwardLowerThreshold  then
				self:Print(L["Changing loot threshold to enable Auto Awarding"])
				SetLootThreshold(db.autoAwardLowerThreshold >= 2 and db.autoAwardLowerThreshold or 2)
			end
			self.isMasterLooter, self.masterLooter = true, self.playerName
			self:CallModule("masterlooter")
			self:GetActiveModule("masterlooter"):NewML(self.masterLooter)

		-- We must ask the player for usage
		elseif db.usage.ask_leader then
			return LibDialog:Spawn("RCLOOTCOUNCIL_CONFIRM_USAGE")
		end
	end
end

-- Returns boolean, mlName. (true if the player is ML), (nil if there's no ML)
function RCLootCouncil:GetML()
	self:DebugLog("GetML()")
	if self:GetNumGroupMembers() == 0 and (self.testMode or self.nnp) then -- always the player when testing alone
		return true, self.playerName
	end
	local lootMethod, mlPartyID, mlRaidID = GetLootMethod()
	self:Debug("LootMethod = ", lootMethod)
	if lootMethod == "master" then
		local name;
		if mlRaidID then 				-- Someone in raid
			name = UnitName("raid"..mlRaidID)
		elseif mlPartyID == 0 then -- Player in party
			name = self.playerName
		elseif mlPartyID then		-- Someone in party
			name = UnitName("party"..mlPartyID)
		end
		self:Debug("MasterLooter = ", name)
		-- Check to see if we have recieved mldb within 10 secs, otherwise request it
		self:ScheduleTimer("Timer", 10, "MLdb_check")
		return self:UnitIsUnit(name, "player"), name
	end
	return false, nil;
end

function RCLootCouncil:IsCouncil(name)
	local ret = tContains(self.council, name)
	if self:UnitIsUnit(name, self.playerName) and self.isMasterLooter or self.nnp then ret = true end -- ML and nnp is always council
	self:DebugLog(tostring(ret).." =", "IsCouncil", name)
	return ret
end


function RCLootCouncil:SessionError(...)
	self:Print(L["session_error"])
	self:Debug(unpack(arg, 1, arg.n))
end

function RCLootCouncil:Getdb()
	return db
end

function RCLootCouncil:GetHistoryDB()
	if self.isMasterLooter or (not self:IsInGroup() and not self:IsInRaid()) then 
		return self.lootDB.factionrealm
	else 
		return self.mlhistory 
	end
end

function RCLootCouncil:GetAnnounceChannel(channel)
	return channel == "group" and (self:IsInRaid() and "RAID" or "PARTY") or channel
end

function RCLootCouncil:GetItemIDFromLink(link)
	-- Lua 5.0 has no string.match/:match() (added in 5.1) - strmatch doesn't exist on this
	-- client (confirmed live: "attempt to call global 'strmatch' (a nil value)"). This function
	-- was never actually exercised before ml_core.lua:AddItem started calling it this round -
	-- other callers (AutoPassCheck, lootFrame.lua) never happened to reach it either. Use
	-- string.find with a capture instead, the established pattern elsewhere in this port.
	local _, _, id = string.find(link, "item:(%d+):")
	return tonumber(id)
end

--- Builds a full, standard-field-count item link from a bare numeric ID.
-- A short "item:ID" link (no trailing fields) is valid input to Blizzard's own SetHyperlink, but
-- other addons that hook GameTooltip and parse the link themselves (confirmed live: at least two
-- other installed addons' own tooltip hooks both threw "Unknown link type") expect the full
-- vanilla field count (item:ID:enchant:jewel1:jewel2:jewel3:jewel4:suffixID:uniqueID, 9 fields) and choke on
-- anything shorter. Every SetHyperlink call this addon makes from a bare ID should go through
-- this instead of hand-rolling "item:"..id, so we never trip other addons' hooks again.
function RCLootCouncil:BuildItemLink(itemID)
	return "item:"..itemID..":0:0:0:0:0:0:0:0"
end

--- Custom, better UnitIsUnit() function
-- Blizz UnitIsUnit() doesn't know how to compare unit-realm with unit
-- Seems to be because unit-realm isn't a valid unitid
-- This addon mixes real unit tokens (only ever the literal "player", in practice) with plain,
-- addon-tracked player NAMES (sender/winner/masterLooter/etc.) when calling this. The native
-- UnitIsUnit throws "Unknown unit name" on this client for a non-token string (unlike retail,
-- which accepts a visible player's name as an effective token) - so resolve "player" to a real
-- name and compare names directly instead of ever passing a name straight into the native call.
-- strsplit("-", name) on this client returns a TABLE of pieces (confirmed live via debug -
-- resolved1/resolved2 printed as "table: 0x...") rather than multiple string values like the
-- documented Blizzard API - handle both shapes defensively rather than assuming either one.
local function StripRealm(name)
	local result = strsplit("-", name)
	if type(result) == "table" then
		return result[1] or name
	end
	return result
end

-- UnitInRaid/UnitInParty throw "Unknown unit name" on this client for a plain name string
-- (confirmed live, e.g. with the player's own name while raid-grouped) - pcall-wrap them rather
-- than trusting they always return nil/false gracefully like on retail.
-- CONFIRMED LIVE per explicit user request: "council add" should also accept anyone in the same
-- guild, not just someone currently in your raid/party - a guild's regular loot council roster
-- often includes people who aren't grouped with you at the exact moment you're editing the list.
function RCLootCouncil:IsNameInGuild(name)
	if not IsInGuild() then return false end
	GuildRoster() -- make sure the roster is current before scanning it
	for i = 1, GetNumGuildMembers() do
		if GetGuildRosterInfo(i) == name then return true end
	end
	return false
end

function RCLootCouncil:IsNameInGroup(name)
	-- Direct raid/party iteration + UnitName(realToken) comparison instead of UnitInRaid(name)/
	-- UnitInParty(name) - those take a bare name and, beyond the already-confirmed "throws on a
	-- bad name" issue, may simply fail to match a name that IS genuinely in the group on this
	-- custom client (reported live: "Nydeh is not in your group" for a name that was in the
	-- party). This sidesteps that whole class of uncertainty - UnitName always gets a real token.
	if self:IsInRaid() then
		for i = 1, 40 do
			if UnitName("raid"..i) == name then return true end
		end
	elseif self:IsInGroup() then
		for i = 1, 4 do
			if UnitName("party"..i) == name then return true end
		end
	end
	return false
end

function RCLootCouncil:UnitIsUnit(unit1, unit2)
	if not unit1 or not unit2 then return false end
	if unit1 == "player" then unit1 = UnitName("player") end
	if unit2 == "player" then unit2 = UnitName("player") end
	-- Remove realm names, if any
	unit1 = StripRealm(unit1)
	unit2 = StripRealm(unit2)
	return unit1 == unit2
end

---------------------------------------------------------------------------
-- Custom module support funcs
---------------------------------------------------------------------------

--- Enables a userModule if set, defaultModule otherwise
-- @paramsig module
-- @param module String, must correspond to a index in self.defaultModules
function RCLootCouncil:CallModule(module)
	if not self.enabled then return end -- Don't call modules unless enabled
	self:EnableModule(userModules[module] or defaultModules[module])
end

--- Returns the active module
--	Always use this when calling functions in another module
-- @paramsig module
-- @param module String, must correspond to a index in self.defaultModules
-- @return The module object of the active module or nil if not found. Prioritises userModules if set
function RCLootCouncil:GetActiveModule(module)
	return self:GetModule(userModules[module] or defaultModules[module], false)
end

--- Registers a module that should override a default module
-- The custom module must have all functions that a default module can be called with
-- @param type Index (string) in userModules
-- @param The name passed to AceAddon:NewModule()
function RCLootCouncil:RegisterUserModule(type, name)
	assert(defaultModules[type], format("Module \"%s\" is not a default module.", tostring(type)))
	userModules[type] = name
end

--#end Module support -----------------------------------------------------


---------------------------------------------------------------------------
-- UI Functions used throughout the addon
---------------------------------------------------------------------------

--- Used as a "DoCellUpdate" function for lib-st
function RCLootCouncil.SetCellClassIcon(rowFrame, frame, data, cols, row, realrow, column, fShow, table, class)
	local celldata = data[realrow].cols and data[realrow].cols[column] or data[realrow][column]
	local class = celldata.args and celldata.args[1] or class
	if class then
		frame:SetNormalTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES"); -- this is the image containing all class icons
		local coords = CLASS_ICON_TCOORDS[class]; -- get the coordinates of the class icon we want
		-- Confirmed live elsewhere (votingFrame.lua/lootFrame.lua hit the same thing):
		-- GetNormalTexture() can come back nil right after SetNormalTexture() on this client -
		-- guard instead of crashing on the class-icon texture-coordinate cutout.
		local normalTex = frame:GetNormalTexture()
		if normalTex then normalTex:SetTexCoord(unpack(coords)) end -- cut out the region with our class icon according to coords
	else -- if there's no class
		-- No file extension on a Blizzard texture path - the engine resolves the underlying .blp
		-- itself; a literal ".png" suffix can fail to load on this client (confirmed live
		-- elsewhere in this addon, e.g. sessionFrame.lua).
		frame:SetNormalTexture("Interface\\ICONS\\INV_Sigil_Thorim")
	end
end

--- Returns a color table for use with lib-st
function RCLootCouncil:GetClassColor(class)
	local color = RAID_CLASS_COLORS[class]
	if not color then
		-- if class not found, return epic color.
		return {r=1,g=1,b=1,a=1}--{["r"] = 0.63921568627451, ["g"] = 0.2078431372549, ["b"] = 0.93333333333333, ["a"] = 1.0 };
	else
		color.a = 1.0
		return color
	end
end

function RCLootCouncil:RGBToHex(r,g,b)
	return string.format("%02x%02x%02x",255*r, 255*g, 255*b)
end

--- Creates a standard frame for RCLootCouncil with title, minimizuing, positioning and zoom support.
--		Adds Minimize(), Maximize() and IsMinimized() functions on the frame, and registers it for hide on combat.
--		SetWidth/SetHeight called on frame will also be called on frame.content
--		Minimizing is done by double clicking the title. The returned frame and frame.title is NOT minimized.
-- 	Only frame.content is minimized, so put children there for minimize support.
-- @paramsig name, cName, title[, width, height]
-- @param name Global name of the frame
-- @param cName Name of the module (used for lib-window-1.1 config in db.UI[cName])
-- @param title The title text
-- @param width The width of the titleframe, defaults to 250
-- @param height Height of the frame, defaults to 325
-- @return The frame object
function RCLootCouncil:CreateFrame(name, cName, title, width, height)
	local f = CreateFrame("Frame", name, nil) -- LibWindow seems to work better with nil parent
	f:Hide()
	f:SetFrameStrata("HIGH")
	f:SetWidth(width or 450)
	f:SetHeight(height or 325)
	lwin:Embed(f)
	f:RegisterConfig(db.UI[cName])
	f:RestorePosition() -- might need to move this to after whereever GetFrame() is called
	f:MakeDraggable()
	f:EnableMouseWheel(true)
	-- This client's OnMouseWheel scripts get zero real function arguments - the engine sets
	-- `arg1` (wheel delta) as a global instead; a `delta` parameter here would shadow it with
	-- nil, and a same-named `f` parameter would shadow the frame itself with nil too.
	f:SetScript("OnMouseWheel", function() if IsControlKeyDown() then lwin.OnMouseWheel(f, arg1) end end)

	local Skin = self.UISkin
	local tf = CreateFrame("Frame", nil, f)
	-- Flat dark theme (Modules\uiSkin.lua) instead of the old gold ChatFrameBackground look -
	-- shared by every RCLootCouncil:CreateFrame() caller (Loot/Voting/Session/History/
	-- VersionCheck frames).
	tf:SetBackdrop(Skin.FLAT_BACKDROP)
	tf:SetBackdropColor(Skin.TITLEBAR_BG[1], Skin.TITLEBAR_BG[2], Skin.TITLEBAR_BG[3], Skin.TITLEBAR_BG[4])
	tf:SetBackdropBorderColor(Skin.PANEL_BORDER[1], Skin.PANEL_BORDER[2], Skin.PANEL_BORDER[3], Skin.PANEL_BORDER[4])
	tf:SetHeight(22)
	tf:EnableMouse()
	tf:SetMovable(true)
	tf:SetWidth(width or 250)
	tf:SetPoint("CENTER",f,"TOP",0,-1)
	-- CONFIRMED LIVE ("attempt to index local 'self' (a nil value)"): SetScript callbacks get
	-- ZERO real arguments on this client - a declared `self` parameter here is always nil. Read
	-- `this` instead. This affects every window built via RCLootCouncil:CreateFrame (Loot/Voting/
	-- Session/History/VersionCheck) - hit here by a real other player (not just the ML/testing
	-- account), confirming it's not solo-testing-specific.
	tf:SetScript("OnMouseDown", function() this:GetParent():StartMoving() end)
	tf:SetScript("OnMouseUp", function() -- Get double click by trapping time betweem mouse up
		local frame = this:GetParent()
		frame:StopMovingOrSizing()
		frame:SavePosition()
		if this.lastClick and GetTime() - this.lastClick <= 0.5 then
			this.lastClick = nil
			if frame.minimized then frame:Maximize() else frame:Minimize() end
		else
			this.lastClick = GetTime()
		end
	end)

	local text = tf:CreateFontString(nil,"OVERLAY","GameFontNormal")
	text:SetPoint("CENTER",tf,"CENTER")
	text:SetTextColor(1,1,1,1)
	text:SetText(title)
	tf.text = text
	f.title = tf

	local c = CreateFrame("Frame", nil, f) -- frame that contains the actual content
	c:SetBackdrop(Skin.FLAT_BACKDROP)
	c:EnableMouse(true)
	c:SetWidth(450)
	c:SetHeight(height or 325)
	c:SetBackdropColor(Skin.PANEL_BG[1], Skin.PANEL_BG[2], Skin.PANEL_BG[3], Skin.PANEL_BG[4])
	c:SetBackdropBorderColor(Skin.PANEL_BORDER[1], Skin.PANEL_BORDER[2], Skin.PANEL_BORDER[3], Skin.PANEL_BORDER[4])
	c:SetPoint("TOPLEFT")
	-- Same SetScript-zero-args issue as the titlebar (tf) above.
	c:SetScript("OnMouseDown", function() this:GetParent():StartMoving() end)
	c:SetScript("OnMouseUp", function() this:GetParent():StopMovingOrSizing(); this:GetParent():SavePosition() end)
	f.content = c
	f.minimized = false
	f.IsMinimized = function(frame) return frame.minimized end
	f.Minimize = function(frame)
		self:Debug("Minimize()")
		if not frame.minimized then
		  	frame.content:Hide()
			frame.minimized = true
		end
	end
	f.Maximize = function(frame)
		self:Debug("Maximize()")
		if frame.minimized then
		  	frame.content:Show()
			frame.minimized = false
		end
	end
	-- Support for auto hide in combat:
	tinsert(frames, f)
	local old_setwidth = f.SetWidth
	f.SetWidth = function(self, width) -- Hack so we only have to set width once
		old_setwidth(self, width)
		self.content:SetWidth(width)
	end
	local old_setheight = f.SetHeight
	f.SetHeight = function(self, height)
		old_setheight(self, width)
		self.content:SetHeight(height)
	end
	return f
end

--- Creates a standard button for RCLootCouncil
-- @param text The button's text
-- @param parent The frame that should hold the button
-- @return The button object
function RCLootCouncil:CreateButton(text, parent)
	-- Delegates to the shared dark-theme skin (Modules\uiSkin.lua) instead of
	-- UIPanelButtonTemplate's gold Blizzard look, for every window built with this button
	-- (Loot/Voting/Session/History/VersionCheck frames).
	-- Same 100x25 default size as before so existing SetPoint layouts don't shift.
	return self.UISkin.CreateButton(parent, text, 100, 25)
end

--- Displays a tooltip anchored to the mouse
-- @paramsig ...
-- @param ... Lines to be added.
function RCLootCouncil:CreateTooltip(...)
	GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR")
	for i = 1, arg.n do
		GameTooltip:AddLine(arg[i],1,1,1)
	end
	GameTooltip:Show()
end

--- Displays a hyperlink tooltip
-- @paramsig link
-- @param link The link to display
function RCLootCouncil:CreateHypertip(link)
	if not link or link == "" then return end
	-- Normalize to the bare "item:ID" numeric form before calling SetHyperlink - this exact form
	-- is already confirmed to work on this client (used by ml_core.lua:AddItem's cache-warming
	-- call), whereas callers here pass a mix of fully-decorated hyperlinks, raw itemstrings, and
	-- occasionally already-bare numeric IDs, and this client's GameTooltip:SetHyperlink has
	-- proven unreliable with types beyond what's already been proven to work elsewhere.
	local itemID = tonumber(link) or self:GetItemIDFromLink(link)
	if not itemID then return end
	GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR")
	GameTooltip:SetHyperlink(self:BuildItemLink(itemID))
end

--- Hide the tooltip created with :CreateTooltip()
function RCLootCouncil:HideTooltip()
	GameTooltip:Hide()
end

-- CONFIRMED LIVE: IsModifiedClick() doesn't exist as a global on this client ("attempt to call
-- global 'IsModifiedClick' (a nil value)") - it's normally a thin Blizzard wrapper around the
-- shift/ctrl/alt key-state functions (used for "shift-click to link" style behavior), all 3 of
-- which DO exist here. Provide the same behavior directly instead.
function RCLootCouncil:IsModifiedClick()
	return IsShiftKeyDown() or IsControlKeyDown() or IsAltKeyDown()
end

-- CONFIRMED LIVE, high-severity: bare GetItemInfo() on this client returns ONE FEWER value than
-- the standard 10-field signature (the "type" class-name string, e.g. "Armor", appears to be
-- omitted entirely) - every field after it silently shifts left by one. Observed live: subType
-- held iStackCount's value ("1"), and a full TEXTURE PATH ended up in equipLoc. This isn't just a
-- missing icon - it corrupts equipLoc/subType with completely wrong values, silently (no error).
-- C_Item.GetItemInfo (ClassicAPI) returns the correct, full 10-field shape - prefer it everywhere
-- addon code calls GetItemInfo, falling back to the bare (field-shifted) global only when
-- ClassicAPI isn't installed.
function RCLootCouncil:GetItemInfo(item)
	local getItemInfo = (_G.C_Item and _G.C_Item.GetItemInfo) or GetItemInfo
	return getItemInfo(item)
end


--- Returns the text of a button, returning settings from mldb, or default buttons
-- @paramsig index
-- @param index The button's index
function RCLootCouncil:GetButtonText(i)
	return (self.mldb.buttons and self.mldb.buttons[i]) and self.mldb.buttons[i].text or db.buttons[i] and db.buttons[i].text or "Unknown"
end

--- The following functions returns the text, sort or color of a response, returning a result from mldb if possible, otherwise the default responses.
-- @paramsig response
-- @param response Index in db.responses
function RCLootCouncil:GetResponseText(response)
	return (self.mldb.responses and self.mldb.responses[response]) and self.mldb.responses[response].text or db.responses[response] and db.responses[response].text or "Unknown Response"
end

function RCLootCouncil:GetResponseColor(response)
	local color = (self.mldb.responses and self.mldb.responses[response]) and self.mldb.responses[response].color or db.responses[response] and db.responses[response].color or {1, 1, 1, 1}
	return unpack(color)
end

function RCLootCouncil:GetResponseColorTable(response)
	local color = (self.mldb.responses and self.mldb.responses[response]) and self.mldb.responses[response].color or db.responses[response] and db.responses[response].color or {1, 1, 1, 1}
	return color
end

function RCLootCouncil:GetResponseSort(response)
	return (self.mldb.responses and self.mldb.responses[response]) and self.mldb.responses[response].sort or db.responses[response].sort
end

--#end UI Functions -----------------------------------------------------
--@debug@
-- debug func
function printtable( data, level )
	level = level or 0
	local ident=strrep('     ', level)
	if level>6 then return end
	if type(data)~='table' then print(tostring(data)) end;
	for index,value in pairs(data) do repeat
		if type(value)~='table' then
			print( ident .. '['..index..'] = ' .. tostring(value) .. ' (' .. type(value) .. ')' );
			break;
		end
		print( ident .. '['..index..'] = {')
        printtable(value, level+1)
        print( ident .. '}' );
	until true end
end
--@end-debug@
