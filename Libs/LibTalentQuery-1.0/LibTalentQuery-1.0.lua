--[[
Name: LibTalentQuery-1.0
Revision: $Rev: 84 $
Author: Rich Martel (richmartel@gmail.com)
Documentation: http://wowace.com/wiki/LibTalentQuery-1.0
SVN: svn://svn.wowace.com/wow/libtalentquery-1-0/mainline/trunk
Description: Library to help with querying unit talents
Dependancies: LibStub, CallbackHandler-1.0
License: LGPL v2.1

Example Usage:
	local TalentQuery = LibStub:GetLibrary("LibTalentQuery-1.0")
	TalentQuery.RegisterCallback(self, "TalentQuery_Ready")

	local raidTalents = {}
	...
	TalentQuery:Query(unit)
	...
	function MyAddon:TalentQuery_Ready(e, name, realm, unitid)
		local isnotplayer = not UnitIsUnit(unitid, "player")
		local spec = {}
		for tab = 1, GetNumTalentTabs(isnotplayer) do
			local treename, _, pointsspent = GetTalentTabInfo(tab, isnotplayer)
			tinsert(spec, pointsspent)
		end
		raidTalents[UnitGUID(unitid)] = spec
	end
]]

-- Lua 5.0 has no `string.match`/`:match()` (added in 5.1) -- use `string.find` with a
-- capture instead, per CLAUDE.md's Lua-5.0 recipe.
local MAJOR, MINOR = "LibTalentQuery-1.0", 90000 + tonumber(select(3, string.find("$Rev: 84 $", "(%d+)")))

local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

local INSPECTDELAY = 1
local INSPECTTIMEOUT = 5
if not lib.events then
	lib.events = LibStub("CallbackHandler-1.0"):New(lib)
end

local validateTrees
local enteredWorld = IsLoggedIn()
local frame = lib.frame
if not frame then
	frame = CreateFrame("Frame", MAJOR .. "_Frame")
	lib.frame = frame
end
frame:UnregisterAllEvents()
frame:RegisterEvent("INSPECT_TALENT_READY")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LEAVING_WORLD")
frame:RegisterEvent("PLAYER_LOGIN")
-- This client's OnEvent/OnUpdate scripts get zero real function arguments - the engine sets
-- `this`/`event`/`arg1`.. as globals instead. A parameter list here would shadow them with nils.
frame:SetScript("OnEvent", function()
	return lib[event](lib, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
end)

do
	local lastUpdateTime = 0
	frame:SetScript("OnUpdate", function()
		local elapsed = arg1
		lastUpdateTime = lastUpdateTime + elapsed
		if lastUpdateTime > INSPECTDELAY then
			lib:CheckInspectQueue()
			lastUpdateTime = 0
		end
	end)
	frame:Hide()
end

local inspectQueue = lib.inspectQueue or {}
lib.inspectQueue = inspectQueue
local garbageQueue = lib.garbageQueue or {}	-- Added a second queue to things. Inspects that initially fail are now
lib.garbageQueue = garbageQueue				-- thrown into second queue will will be processed once main queue is empty
-- CONFIRMED LIVE, high-severity annoyance: garbageQueue retries a failed inspect every
-- INSPECTDELAY (1 second) FOREVER with no cap - CanInspect(unit) doesn't actually check distance,
-- so NotifyInspect(unit) on a raid member simply standing more than ~30 yards away (extremely
-- common in real raid/party play) fires the native "Out of range." system message over and over,
-- indefinitely, for as long as that candidate stays out of inspect range. Cap retries so a
-- genuinely-unreachable candidate is given up on instead of spamming forever.
local retryCount = lib.retryCount or {}
lib.retryCount = retryCount
local MAX_INSPECT_RETRIES = 5

if next(inspectQueue) then
	frame:Show()
end

local UnitIsPlayer = _G.UnitIsPlayer
local UnitName = _G.UnitName
local UnitExists = _G.UnitExists
local UnitGUID = _G.UnitGUID
local GetNumRaidMembers = _G.GetNumRaidMembers
local GetNumPartyMembers = _G.GetNumPartyMembers
local UnitIsVisible = _G.UnitIsVisible
local UnitIsConnected = _G.UnitIsConnected
local UnitCanAttack = _G.UnitCanAttack
local CanInspect = _G.CanInspect

-- Lua 5.0 / TurtleWoW 1.12 has no guaranteed native `strsplit` global (Blizzard added it
-- in a later client) -- detect-and-fallback per CLAUDE.md.
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
			tinsert(parts, string.sub(str, pos))
			break
		end
		local s, e = string.find(str, dpat, pos)
		if not s then
			tinsert(parts, string.sub(str, pos))
			break
		end
		tinsert(parts, string.sub(str, pos, s - 1))
		pos = e + 1
	end
	return unpack(parts)
end

local function UnitFullName(unit)
	local name, realm = UnitName(unit)
	local namerealm = realm and realm ~= "" and name .. "-" .. realm or name
	return namerealm
end

-- GuidToUnitID
local function GuidToUnitID(guid)
	local prefix, min, max = "raid", 1, GetNumRaidMembers()
	if max == 0 then
		prefix, min, max = "party", 0, GetNumPartyMembers()
	end

	-- Prioritise getting direct units first because other players targets
	-- can change between notify and event which can bugger things up
	for i = min, max do
		local unit = i == 0 and "player" or prefix .. i
		if (UnitGUID(unit) == guid) then
			return unit
		end
	end

	-- This properly detects target units
	if (UnitGUID("target") == guid) then
        return "target"
	elseif (UnitGUID("focus") == guid) then
		return "focus"
	elseif (UnitGUID("mouseover") == guid) then
		return "mouseover"
    end

	for i = min, max + 3 do
		local unit
		if i == 0 then
			unit = "player"
		elseif i == max + 1 then
			unit = "target"
		elseif i == max + 2 then
			unit = "focus"
		elseif i == max + 3 then
			unit = "mouseover"
		else
			unit = prefix .. i
		end
		if (UnitGUID(unit .. "target") == guid) then
			return unit .. "target"
		elseif (i <= max and UnitGUID(unit.."pettarget") == guid) then
			return unit .. "pettarget"
		end
	end
	return nil
end

-- Query
function lib:Query(unit)
	if (UnitLevel(unit) < 10 or UnitName(unit) == UNKNOWN) then
		return
	end

	self.lastQueuedInspectReceived = nil
	if UnitIsUnit(unit, "player") then
		self.events:Fire("TalentQuery_Ready", UnitName("player"), nil, "player")
	else
		if type(unit) ~= "string" then
			error(string.format("Bad argument #2 to 'Query'. Expected %q, received %q (%s)", "string", type(unit), tostring(unit)), 2)
		elseif not UnitExists(unit) or not UnitIsPlayer(unit) then
			error(string.format("Bad argument #2 to 'Query'. %q is not a valid player unit", tostring(unit)), 2)
		elseif not UnitExists(unit) or not UnitIsPlayer(unit) then
			error(string.format("Bad argument #2 to 'Query'. %q does not require a server query before reading talents", "player"), 2)
		else
			local name = UnitFullName(unit)
			if (not inspectQueue[name]) then
				inspectQueue[name] = UnitGUID(unit)
				garbageQueue[name] = nil
			end
			frame:Show()
		end
	end
end

-- CheckInspectQueue
-- Originally, it would wait until no pending NotifyInspect() were expected, and then do it's own.
-- It was also only bother looking at ready results if it had triggered the Notify for that occasion.
-- For the changes I've done, no assumption is made about which mod is performing NotifyInspect().
-- We note the name, unit, time of any inspects done whether from this queue or any other source,
-- we remove from our queue any we were expecting, and use a seperate event in case extra talent
-- info is any time wanted (opportunistic refreshes etc) - Zeksie, 20th May 2009
function lib:CheckInspectQueue()
	if (_G.InspectFrame and _G.InspectFrame:IsShown()) then
		return
	end

	if (not self.lastInspectTime or self.lastInspectTime < GetTime() - INSPECTTIMEOUT) then
		self.lastInspectPending = 0
	end

	if (self.lastInspectPending > 0 or not enteredWorld) then
		return
	end

	if (self.lastQueuedInspectReceived and self.lastQueuedInspectReceived < GetTime() - 60) then
		-- No queued results received for a minute, so purge the queue as invalid and move on with our lives
		self.lastQueuedInspectReceived = nil
		inspectQueue = {}
		lib.inspectQueue = inspectQueue
		garbageQueue = {}
		lib.garbageQueue = garbageQueue
		frame:Hide()
		return
	end

	for name,guid in pairs(inspectQueue) do
		local unit = GuidToUnitID(guid)
		if (not unit) then
			inspectQueue[name] = nil
			retryCount[name] = nil
		else
			if (UnitIsVisible(unit) and UnitIsConnected(unit) and not UnitCanAttack("player", unit) and not UnitCanAttack(unit, "player") and CanInspect(unit) and UnitClass(unit)) then
				NotifyInspect(unit)
				retryCount[name] = nil
				break
			else
				retryCount[name] = (retryCount[name] or 0) + 1
				if retryCount[name] < MAX_INSPECT_RETRIES then
					garbageQueue[name] = guid	-- Not available, throw into secondary queue and continue
				else
					-- Given up on this one - stop retrying instead of spamming "Out of range."
					-- (or whatever else CanInspect/NotifyInspect fails on) forever.
					retryCount[name] = nil
				end
				inspectQueue[name] = nil
			end
		end
	end

	if (not next(inspectQueue)) then
		if (next(garbageQueue)) then
			-- Retry initially failed inspects
			lib.inspectQueue = garbageQueue
			inspectQueue = lib.inspectQueue
			lib.garbageQueue = {}
			garbageQueue = lib.garbageQueue
		else
			frame:Hide()
		end
	end
end

-- NotifyInspect
if not lib.NotifyInspect then -- don't hook twice
	hooksecurefunc("NotifyInspect", function(...) return lib:NotifyInspect(unpack(arg, 1, arg.n)) end)
end
function lib:NotifyInspect(unit)
	if (not (UnitExists(unit) and UnitIsVisible(unit) and UnitIsConnected(unit) and CheckInteractDistance(unit, 4))) then
		return
	end
	self.lastInspectUnit = unit
	self.lastInspectGUID = UnitGUID(unit)
	self.lastInspectTime = GetTime()
	self.lastInspectName = UnitFullName(unit)
	self.lastInspectPending = self.lastInspectPending + 1
	local isnotplayer = not UnitIsUnit("player", unit)
	self.lastInspectTree = GetTalentTabInfo(1, isnotplayer)		-- Talent tree names are available immediately
end

-- Reset
function lib:Reset()
	self.lastInspectPending = 0
	self.lastInspectUnit = nil
	self.lastInspectTime = nil
	self.lastInspectName = nil
	self.lastInspectGUID = nil
	self.lastInspectTree = nil
end

-- INSPECT_TALENT_READY
function lib:INSPECT_TALENT_READY()
	self.lastInspectPending = self.lastInspectPending - 1

	-- Results are valid only when we have received as many events as we have posted notifies
	if (self.lastInspectName and self.lastInspectPending == 0) then
		-- Check unit ID is still pointing to same actual unit
		if (UnitGUID(self.lastInspectUnit) == self.lastInspectGUID) then
			local guid = inspectQueue[self.lastInspectName]
			inspectQueue[self.lastInspectName] = nil

			local name, realm = strsplit("-", self.lastInspectName)

			self.lastQueuedInspectReceived = GetTime()

			-- Notify of expected talent results
			-- No client-side dual-spec on TurtleWoW/OctoWoW 1.12: GetActiveTalentGroup()
			-- doesn't exist here at all (WotLK 3.1+ only), and GetTalentTabInfo never takes
			-- a talent-group argument on this client -- always read whatever is currently
			-- allocated (this is the unit's only possible talent allocation).
			-- Use the resolved unit token (already available, same scope) rather than
			-- self.lastInspectName (a plain "Name-Realm" string) - native UnitIsUnit throws
			-- "Unknown unit name" on this client for a bare name (same bug class as
			-- UnitGUID/UnitInRaid/etc elsewhere in this port).
			local isnotplayer = not UnitIsUnit("player", self.lastInspectUnit)
			local tree1, _, spent1 = GetTalentTabInfo(1, isnotplayer)
			if (tree1 ~= self.lastInspectTree) then
				-- Expected talent tree name to be the same as it was when we triggered the NotifyInspect()
				garbageQueue[self.lastInspectName] = self.lastInspectGUID
				self:Reset()
				self:CheckInspectQueue()
				return

			elseif (validateTrees) then
				-- Double checking here. Check the tree name matches what we expect for this class
				local _, class = UnitClass(self.lastInspectUnit)
				if (tree1 ~= validateTrees[class]) then
					garbageQueue[self.lastInspectName] = self.lastInspectGUID
					self:Reset()
					self:CheckInspectQueue()
					return
				end
			end

			local tree2, _, spent2 = GetTalentTabInfo(2, isnotplayer)
			local tree3, _, spent3 = GetTalentTabInfo(3, isnotplayer)
			if ((spent1 or 0) + (spent2 or 0) + (spent3 or 0) > 0) then
				if (guid) then
					-- It was in our queue
					self.events:Fire("TalentQuery_Ready", name, realm, self.lastInspectUnit)
				else
					-- Also notify of non-expected ones, as it's entirely useful to refresh them if they're there
					-- It is up to the receiving applicating to determine whether they want to receive the information
					self.events:Fire("TalentQuery_Ready_Outsider", name, realm, self.lastInspectUnit)
				end
			else
				-- Tree came back with zero points spent, probably an issue while logging in
				garbageQueue[self.lastInspectName] = guid
			end
		end

		self:Reset()
		self:CheckInspectQueue()
	end
end

function lib:PLAYER_ENTERING_WORLD()
	-- We can't inspect other's talents until now
	-- We just get 0/0/0 back even though we get an INSPECT_TALENT_READY event
	enteredWorld = true
end

function lib:PLAYER_LEAVING_WORLD()
	enteredWorld = nil
end

function lib:PLAYER_LOGIN()
	validateTrees = {
		DRUID = "Balance",
		PRIEST = "Discipline",
		ROGUE = "Assassination",
		HUNTER = "Beast Mastery",
		WARLOCK = "Affliction",
		WARRIOR = "Arms",
		DEATHKNIGHT = "Blood",
		PALADIN = "Holy",
		SHAMAN = "Elemental",
		MAGE = "Arcane",
	}

	if (GetLocale() ~= "enUS" and GetLocale() ~= "enGB") then
		-- LibBabble-TalentTree-3.0 only loaded if present and not enUS
		local LBT = LibStub("LibBabble-TalentTree-3.0", true)
		if (not LBT) then
			LoadAddOn("LibBabble-TalentTree-3.0")
			LBT = LibStub("LibBabble-TalentTree-3.0", true)
		end
		LBT = LBT and LBT:GetLookupTable()
		if (LBT) then
			for class,tree1 in pairs(validateTrees) do
				validateTrees[class] = LBT[tree1]
			end
		else
			validateTrees = nil
		end
	end
	
	self.PLAYER_LOGIN = nil
end

lib:Reset()
