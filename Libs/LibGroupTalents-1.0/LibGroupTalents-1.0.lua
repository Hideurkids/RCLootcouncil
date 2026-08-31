--[[
Name: LibGroupTalents-1.0
Revision: $Rev: 55 $
Author: Zek
Documentation: http://wowace.com/wiki/LibGroupTalents-1.0
SVN: svn://svn.wowace.com/wow/libgrouptalents-1-0/mainline/trunk
Description: Talent Library abstraction layer to provide easy interface to the lower level system
Dependancies: LibStub, CallbackHandler-1.0, LibTalentQuery-1.0
License: GPL v3

Purpose:
	LibGroupTalents-1.0 is intended to do the following basic functions usually handled at the mod level.

	- Maintain a raid wide table of talents, automatically updated on roster changes, notifying you on talent receipts.
	- Provide easy access to talent queries (spec weight, spec name, specific talent presence)
	- Monitor talent changes in players, and notify of changes (respec, talent swap, update after out of sight, level up)
	- Monitor player roles, and notify of changes (melee, tank, healer, caster)
	- Communicate directly with itself to other users to update talents via addon channel when possible

Notes:
	The LibTalentQuery-1.0 dependancy must be included before LibGroupTalents-1.0 in any lib.xml or mod side TOC declarations.

Functions:
	UnitHasTalent(unit, talentName)		-- Returns: Points spent in talent or nil
	GUIDHasTalent(guid, talentName)		-- As UnitHasTalent
	GetUnitTalentSpec(unitid)				-- Returns: Dominant Tree, spent1, spent2, spent3
	GetGUIDTalentSpec(guid)					-- As GetUnitTalentSpec
	GetUnitTalents(unit, refresh)			-- Returns: Raw talent information in form of table of 3 strings of points spent. The refresh arg will force a re-query of the unit's talents
	GetGUIDTalents(guid, refresh)			-- As GetUnitTalents
	GetUnitRole(unit)						-- Returns one of: "melee", "caster", "healer", "tank"
	GetGUIDRole(guid)						-- As GetUnitRole
	RefreshTalentsByUnit(unit)				-- Force a refresh of talents for the specific unit
	RefreshTalentsByGUID(guid)				-- Force a refresh of talents for the specific player GUID
	GetTreeNames(class)						-- Returns: The three talent tree names for that class (Note: These return values are only valid after a player of that class has been inspected)
	GetTreeIcons(class)						-- Returns: The three talent tree icons for that class (Note: As above)
	GetTalentCount()						-- Returns: Talent info got, Talent info missing
	GetTalentMissingNames()					-- Returns: Comma delimited list of player names we're missing talents for
	GetClassTalentInfo(class, talentName)	-- Returns: Max Rank, Icon, Tab, Tier, Column, Tree Index
	GetUnitStorageString(unit)				-- Returns: An encoded data string containing talent information for the player which can be stored by mods to set in later sessions using SetStorageString()
	GetGUIDStorageString(guid)				-- As GetUnitStorageString
	SetStorageString(talentString)			-- Returns: true on success (applicable). Any second return value indicates the data was invalid and should not be kept
	GetUnitGlyphs(unit)						-- Returns: Up to 6 spell IDs for the currently assigned Glyphs. NOTE: Glyphs are a WotLK-only (Inscription) feature and don't exist on TurtleWoW/OctoWoW 1.12 -- always returns nothing on this client.
	GetGUIDGlyphs(guid)						-- As GetUnitGlyphs
	UnitHasGlyph(unit, glyph)				-- As above, always nil on this client (no Glyphs)
	GUIDHasGlyph(unit, glyph)				-- As UnitHasGlyph
	PurgeAndRescanTalents()					-- Wipe current roster of all talents and rescan from start

Convenience Functions (Similar to Blizzard API functions, but callable with a unit ID):
	-- NOTE: TurtleWoW/OctoWoW 1.12 has no client-side dual-spec (the WotLK 3.1+
	-- GetActiveTalentGroup()/group-parameter API doesn't exist on this client at all).
	-- Only one talent allocation is ever active, so GetActiveTalentGroup/GetNumTalentGroups
	-- always report 1, and no other function below takes a `group` argument any more.
	GetActiveTalentGroup(unit)				-- Returns: 1 (always -- no dual-spec on this client)
	GetNumTalentGroups(unit)				-- Returns: 1 (always -- no dual-spec on this client)
	GetNumTalentTabs(unit)					-- Returns: Number of talent tabs. Here's a clue; it's going to be 3...
	GetTalentTabInfo(unit, tab)				-- Returns: Tree Name, Tree Icon, Points Spent, Tree Background
	GetNumTalents(unit, tab)				-- Returns: Number of talents for specified tree
	GetTalentInfo(unit, tab, index)			-- Returns: Talent Name, Icon, Tier, Column, Points Spent, Max Rank (Note that preview return values are not given unless called with "player")
	GetUnspentTalentPoints(unit)			-- Returns: Number of un-spent talent points for the unit

Events:
	LibGroupTalents_Update(guid, unit, newSpec, n1, n2, n3 [, oldSpec, o1, o2, o3])	-- Received updated talents. If it's a respec, or old set is know, it passes the old info also (this is not sent if new talent scan is same as previous)
	LibGroupTalents_UpdateComplete(guid1, guid2[, ...])	-- Sent when there are no more pending talent reads due (passes all GUIDs that were updated since last time this event was fired)
	LibGroupTalents_Add(guid, unit, name, realm)	-- Unit added to talent roster (Talents not necessarily available yet, but this is the mod's chance to feed talents using SetStorageString)
	LibGroupTalents_Remove(guid, name, realm)										-- Unit removed from talent roster (This is your last chance to store talents if required using GetUnitStorageString)
	LibGroupTalents_RoleChange(guid, unit, newrole, oldrole)		-- Roles are: "melee", "caster", "healer", "tank"
	LibGroupTalents_GlyphUpdate(guid, unit)			-- Fired when a player's glyphs change (Note: For the moment, we can only see the glyphs of players running LibGroupTalents-1.0)

]]

local TalentQuery = LibStub("LibTalentQuery-1.0")

-- Lua 5.0 has no `string.match`/`:match()` (added in 5.1) -- use `string.find` with a
-- capture instead, per CLAUDE.md's Lua-5.0 recipe.
local MAJOR, MINOR = "LibGroupTalents-1.0", tonumber(select(3, string.find("$Rev: 55 $", "(%d+)")))
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

local ChatThrottleLib = _G.ChatThrottleLib

lib.roster = lib.roster or {}
lib.classTalentData = lib.classTalentData or {}
lib.batch = lib.batch or {}
lib.pendingStorageStrings = lib.pendingStorageStrings or {}

local function UnitFullName(unit)
	local name, realm = UnitName(unit)
	local namerealm = realm and realm ~= "" and name .. "-" .. realm or name
	return namerealm
end

local function RosterInfoFullName(info)
	local name, realm = info.name, info.realm
	local namerealm = realm and realm ~= "" and name .. "-" .. realm or name
	return namerealm
end

-- IsNameConnected: UnitIsConnected(unit) requires an actual unit token on this client - it
-- throws "Unknown unit name: X" for a bare player name instead of returning nil like on retail.
-- Resolve to a raid/party unit token first (same UnitInRaid/UnitInParty lookup ValidateUnit()
-- further down in this file already uses, for the same reason). CONFIRMED LIVE: UnitInRaid/
-- UnitInParty THEMSELVES also throw "Unknown unit name" for a plain name on this client in some
-- contexts - pcall-wrap them too rather than trusting a bare call.
local function IsNameConnected(namerealm)
	if (namerealm == UnitName("player")) then
		return true
	end
	local ok, raidIndex = pcall(UnitInRaid, namerealm)
	if (ok and raidIndex) then
		return UnitIsConnected("raid"..raidIndex)
	end
	local ok2, inParty = pcall(UnitInParty, namerealm)
	if (ok2 and inParty) then
		for i = 1, 4 do
			if (UnitName("party"..i) == namerealm) then
				return UnitIsConnected("party"..i)
			end
		end
	end
	return false
end

local specChangers = {}
if (_G.TALENT_ACTIVATION_SPELLS) then
	-- TALENT_ACTIVATION_SPELLS is a WotLK 3.1+ dual-spec global (spell IDs for the
	-- "Activate Talent Group" trainer button) and does not exist on TurtleWoW/OctoWoW
	-- 1.12 -- guard so this doesn't error on load. specChangers stays empty, so the
	-- UNIT_SPELLCAST_SUCCEEDED handler below (spec-swap detection) simply never matches,
	-- which is correct: there is no in-session spec-swap spell on this client.
	for index,spellid in ipairs(_G.TALENT_ACTIVATION_SPELLS) do
		specChangers[GetSpellInfo(spellid)] = index
	end
end

local frame = lib.frame
if (not frame) then
	frame = CreateFrame("Frame", "LibGroupTalents_Frame")
	lib.frame = frame
end
frame:UnregisterAllEvents()
frame:RegisterEvent("RAID_ROSTER_UPDATE")
frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
frame:RegisterEvent("UNIT_NAME_UPDATE")
frame:RegisterEvent("PLAYER_TALENT_UPDATE")
frame:RegisterEvent("UNIT_LEVEL")
frame:RegisterEvent("UNIT_AURA")					-- Always get a UNIT_AURA when a unit's UnitIsVisible() changes
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("GLYPH_ADDED")
frame:RegisterEvent("GLYPH_REMOVED")
frame:RegisterEvent("GLYPH_UPDATED")

-- This client's OnEvent scripts get zero real function arguments - the engine sets
-- `event`/`arg1`.. as globals instead. A parameter list here would shadow them with nils.
frame:SetScript("OnEvent", function()
	return lib[event](lib, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
end)

if not lib.events then
	lib.events = LibStub("CallbackHandler-1.0"):New(lib)
end

local next, select, pairs, type = next, select, pairs, type
local tgetn = table.getn		-- Lua 5.0: no `#` operator on tables
-- Lua 5.0 / TurtleWoW 1.12 has no guaranteed native `wipe()` global (Blizzard added it in a
-- later client) -- detect-and-fallback per CLAUDE.md.
local wipe = _G.wipe or (_G.table and _G.table.wipe) or function(t)
	for k in pairs(t) do
		t[k] = nil
	end
	return t
end
-- CONFIRMED LIVE (2026-08-26): this client's native/ClassicAPI-provided `strsplit` global
-- returns a single TABLE of pieces instead of multiple string values (see core.lua) - always
-- use our own known-correct implementation instead of `_G.strsplit`.
local strsplit = function(delimiter, str, pieces)
	if not str then return end
	local parts = {}
	local dpat = "[" .. delimiter .. "]"
	local pos = 1
	while true do
		if pieces and tgetn(parts) == pieces - 1 then
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
local new, del, deepDel
do
	local list = setmetatable({},{__mode='k'})
	function new(...)
		local t = next(list)
		if t then
			list[t] = nil
			for i = 1, arg.n do
				t[i] = arg[i]
			end
			return t
		else
			return arg
		end
	end
	function del(t)
		if (t) then
			wipe(t)
			t[''] = true
			t[''] = nil
			list[t] = true
		end
	end
	function deepDel(t)
		if (t) then
			for k,v in pairs(t) do
				if type(v) == "table" then
					deepDel(v)
				end
				t[k] = nil
			end
			t[''] = true
			t[''] = nil
			list[t] = true
		end
	end
end

do
	local delay = 0
	-- This client's OnUpdate scripts get zero real function arguments - the engine sets
	-- `this`/`arg1` (elapsed time) as globals instead. A parameter list here would shadow
	-- them with nil - the body below uses `self` (this handler's original param name) to
	-- refer to the frame, so capture `this` into a local of that same name too.
	frame:SetScript("OnUpdate", function()
		local self, elapsed = this, arg1
		if (lib.raidRosterUpdate) then
			lib.raidRosterUpdate = nil
			lib:OnRaidRosterUpdate()
		end

		if (lib.refreshCheckTimer) then
			lib.refreshCheckTimer = lib.refreshCheckTimer - elapsed
			if (lib.refreshCheckTimer < 0) then
				lib.refreshCheckTimer = nil
				lib:CheckForMissingTalents()
			end
		end

		if (lib.talentTimers) then
			delay = delay + elapsed
			if (delay > 1) then
				delay = 0
				local now = GetTime()
				local triggers
				for guid,when in pairs(lib.talentTimers) do
					if (now > when) then
						-- Pass to second table to process, because RefreshTimers can affect this talentTimers table
						-- So it's important we're not still iterating it at the time
						if (not triggers) then
							triggers = new()
						end
						triggers[guid] = true
						lib.talentTimers[guid] = nil
						if (not next(lib.talentTimers)) then
							lib.talentTimers = del(lib.talentTimers)
							break
						end
					end
				end

				if (triggers) then
					for guid in pairs(triggers) do
						lib:RefreshTalentsByGUID(guid)
					end
					del(triggers)
				end
			end
		end

		if (not lib.talentTimers and not lib.refreshCheckTimer) then
			self:Hide()
		end
	end)
end
frame:Show()
lib.raidRosterUpdate = true

-- GetGUIDTalentsRaw
-- No client-side dual-spec on TurtleWoW/OctoWoW 1.12: only ever one active talent
-- allocation, so this always reads the group r.active points at (which is always 1 --
-- see TalentQuery_Ready/OnReceiveTalents below).
local function GetGUIDTalentsRaw(guid)
	local r = guid and lib.roster[guid]
	return r and r.talents and r.talents[r.active], r
end

-- PLAYER_LOGIN
function lib:PLAYER_LOGIN()
	ChatThrottleLib = _G.ChatThrottleLib
	lib.PLAYER_LOGIN = nil
end

-- RAID_ROSTER_UPDATE
function lib:RAID_ROSTER_UPDATE()
	self.raidRosterUpdate = true
	frame:Show()
end
lib.PARTY_MEMBERS_CHANGED = lib.RAID_ROSTER_UPDATE

-- UNIT_NAME_UPDATE
function lib:UNIT_NAME_UPDATE(unit)
	local guid = unit and UnitGUID(unit)
	local r = guid and self.roster[guid]
	if (r) then
		local needsAdd = r.name == UNKNOWN
		r.name, r.realm = UnitName(unit)
		if (r.realm == "") then
			r.realm = nil
		end
		r.class = select(2, UnitClass(unit))
		r.level = UnitLevel(unit)
		if (not r.talents) then
			if (needsAdd) then
				self.events:Fire("LibGroupTalents_Add", guid, unit, r.name, r.realm)
			end

			self:CheckForMissingTalents()
		end
	end
end

-- AnyPending
local function AnyPending()
	local checkUpdate
	for guid,info in pairs(lib.roster) do
		local namerealm = RosterInfoFullName(info)
		if (IsNameConnected(namerealm)) then
			if (lib.wasOffline) then
				lib.wasOffline[guid] = nil
			end
			if (not info.talents or info.refresh) then
				return true
			end
		else
			if (not lib.wasOffline) then
				lib.wasOffline = new()
			end
			lib.wasOffline[guid] = true
		end
	end
	if (lib.wasOffline and not next(lib.wasOffline)) then
		lib.wasOffline = del(lib.wasOffline)
	end
end

-- CheckForUpdateComplete
local function CheckForUpdateComplete()
	-- When all pending updates are complete, send an event to notify nothing else is due
	if (next(lib.batch)) then
		if (not AnyPending()) then
			lib.events:Fire("LibGroupTalents_UpdateComplete", unpack(lib.batch))
			wipe(lib.batch)
		end
	end
end

-- UNIT_LEVEL
function lib:UNIT_LEVEL(unit)
	if (UnitInParty(unit) or UnitInRaid(unit)) then
		local guid = UnitGUID(unit)
		local r = guid and self.roster[guid]
		if (r) then
			r.level = UnitLevel(unit)
			self:RefreshTalentsByUnit(unit)
		end
	end
end

-- UNIT_AURA
function lib:UNIT_AURA(unit)
	local guid = UnitGUID(unit)
	if (not UnitIsVisible(unit) or (self.wasOffline and self.wasOffline[guid])) then
		if (not self.outOfSight) then
			self.outOfSight = {}
		end
		self.outOfSight[guid] = true
		self:RefreshTalentsByGUID(guid)
	end
end

-- OnRaidRosterUpdate
function lib:OnRaidRosterUpdate()
	local instanceType = select(2, IsInInstance())
	if (instanceType == "pvp" or instanceType == "arena") then
		self.distribution = "BATTLEGROUND"
	else
		if (GetNumRaidMembers() > 0) then
			self.distribution = "RAID"
		elseif (GetNumPartyMembers() > 0) then
			self.distribution = "PARTY"
		else
			self.distribution = nil
		end
	end
	if (self.distribution) then
		if (self.sentHello ~= self.distribution) then
			self.sentHello = self.distribution
			self:SendCommMessage("HELLO "..MINOR, nil, self.distribution)
		end
	else
		self.sentHello = nil
		self.talentThrottle = del(self.talentThrottle)
		self.wasOffline = del(self.wasOffline)
		self.outOfSight = del(self.outOfSight)
		wipe(self.pendingStorageStrings)
	end

	-- Now check for roster changes
	local subtractions = new()
	local additions = new()
	local changes = new()

	if (self.roster) then
		for guid,info in pairs(self.roster) do
			subtractions[guid] = info.level or 0
		end
	end

	for unit in self:IterateRoster() do
		local guid = UnitGUID(unit)
		if (guid) then
			local n = self.roster[guid]
			if (not n) then
				n = new()
				self.roster[guid] = n
			end

			n.name, n.realm = UnitName(unit)
			if (n.realm == "") then
				n.realm = nil				-- Fix this already..
			end
			n.level = UnitLevel(unit)
			n.class = select(2, UnitClass(unit))
			n.unit = unit

			if (subtractions[guid]) then
				if (subtractions[guid] ~= n.level) then
					changes[guid] = unit				-- Level changed, needs a rescan
				end

				subtractions[guid] = nil
			else
				if (n.name ~= UNKNOWN) then
					self.events:Fire("LibGroupTalents_Add", guid, unit, n.name, n.realm)
				end
				additions[guid] = unit
			end
		end
	end

	if (next(additions)) then
		for guid,unit in pairs(additions) do
			self:GetUnitTalents(unit)
		end
	end

	if (next(changes)) then
		for guid,unit in pairs(changes) do
			self:GetUnitTalents(unit)
		end
	end

	if (next(subtractions)) then
		for guid in pairs(subtractions) do
			local r = self.roster[guid]
			if (r) then
				self.events:Fire("LibGroupTalents_Remove", guid, r.name, r.realm)
				self.roster[guid] = deepDel(r)

				local classStorageStrings = self.pendingStorageStrings[r.class]
				if (classStorageStrings) then
				    classStorageStrings[guid] = del(classStorageStrings[guid])
				    if (not next(classStorageStrings)) then
				    	self.pendingStorageStrings[r.class] = del(self.pendingStorageStrings[r.class])
				    end
				end
			end
		end

		CheckForUpdateComplete()
	end

	del(additions)
	del(subtractions)
	del(changes)

	self:CheckForMissingTalents()
end

-- ValidateUnit
-- UnitInRaid/UnitInParty throw "Unknown unit name" on this client for a plain name string in
-- some contexts (confirmed live) - pcall-wrap rather than trusting a bare call.
local function SafeUnitInParty(name)
	local ok, result = pcall(UnitInParty, name)
	return ok and result
end

local function ValidateUnit(r, guid)
	local unit = r.unit
	if (UnitGUID(unit) ~= guid) then
		local name = r.name .. (r.realm and "-" or "") .. (r.realm or "")
		local ok, index = pcall(UnitInRaid, name)
		if (ok and index) then
			r.unit = "raid"..index
			return true
		else
			if (UnitGUID("player") == guid) then
				r.unit = "player"
				return true

			elseif (SafeUnitInParty(name)) then
				for i = 1,4 do
					if (UnitGUID("party"..i) == guid) then
						r.unit = "party"..i
						return true
					end
				end
			end
		end
		return
	end

	return true
end

-- CountTree
local function CountTree(branch)
	local count = 0
	for i = 1,string.len(branch) do
		count = count + string.byte(branch, i) - 48
	end
	return count
end

-- TalentWeight
local function TalentWeight(talents, class)
	if (talents and tgetn(talents) == 3 and class) then
		local c1, c2, c3 = CountTree(talents[1]), CountTree(talents[2]), CountTree(talents[3])

		local weight = 1
		if (c2 > c1 and c2 > c3) then
			weight = 2
		elseif (c3 > c1 and c3 > c2) then
			weight = 3
		end

		local data = lib.classTalentData[class]
		if (data and data[weight]) then
			return data[weight].name, c1, c2, c3
		end

		return weight, c1, c2, c3
	end
	return nil, 0, 0, 0
end

do
-- First segment: Player ID (from GUID), Name, level, class, activePage, TalentString
-- Subsequent: spec number, talentString()

	-- crc
	local function crc32(str)
		-- Lua 5.0/this client: no confirmed `bit` library and no hex literals (0xFFFF) in
		-- source code. bit.band(x, 0xFFFF) == x mod 65536 for any non-negative x (ANDing with
		-- all-16-bits-set is the same as masking to the low 16 bits), and val is always
		-- non-negative here (built from a WoW build number and string byte values), so this
		-- is an exact, dependency-free equivalent.
		local val = tonumber((select(2, GetBuildInfo())))	-- Use WoW build as CRC base
		for i = 1,string.len(str) do
			val = math.mod(val * 2 + string.byte(str, i), 65536)
		end
		return val
	end

	-- GetUnitStorageString
	function lib:GetUnitStorageString(unit)
		return self:GetGUIDStorageString(UnitGUID(unit))
	end

	-- GetGUIDStorageString
	-- Make a storage string for mods to store talents.
	-- Rules: 1) Your own realm only 2) Their talents are complete (nothing unspent)
	function lib:GetGUIDStorageString(guid)
		local r = self.roster[guid]
		if (r) then
			local id
			local playerGUID = UnitGUID("player")
			if (string.sub(playerGUID, 1, 6) == string.sub(guid, 1, 6)) then
				-- Same realm code, so just trim it off. This is likely always true from what I've seen
				id = format("%X", tonumber(string.sub(guid, 7), 16))
			else
				id = string.sub(guid, 4)
			end

			if (r.talents and r.active and not r.realm and (not r.unspent or not r.unspent[r.active])) then
				if (r.level < 1) then
					-- UnitLevel(name) - r.name is a plain stored name, not a live unit token - throws
				-- "Unknown unit name" on this client for a bad/stale name (same bug class as
				-- UnitGUID/UnitInRaid/etc.) - pcall-wrap rather than trust a bare call.
				local ok, lvl = pcall(UnitLevel, r.name)
				r.level = (ok and lvl) or 0
				end
				local str = format("%s,%d,%s,%d,%d", id, r.level, r.class, r.active, r.numActive)
				for i = 1,r.numActive do
					local t = r.talents[i]
					if (t) then
						str = format("%s;%d,%s", str, i, table.concat(t, "-"))
					end
				end
				return format("%s;%d", str, crc32(str))
			end
		end
	end

	-- SetStorageString
	function lib:SetStorageString(str, comms)
		local ret, retInfo
		if (str) then
			local parts = new(strsplit(";", str))
			if (tgetn(parts) >= 2) then
				local strCRC = tonumber(parts[tgetn(parts)])
				local temp = table.concat(parts, ";", 1, tgetn(parts) - 1)
				if (crc32(temp) == strCRC) then
					local part1 = new(strsplit(",", parts[1]))

					while true do
						local guid
						local id = part1[1]
						if (string.len(id) < 12) then
							-- Trimmed GUID, we'll prefix it with our own GUID's realm code
							guid = format("%s%012X", string.sub(UnitGUID("player"), 1, 6), tonumber(id, 16))
						else
							guid = format("0x0%015s", id)
						end

						local r = self.roster[guid]
						if (not r) then
							retInfo = format("Unexpected SetStorageString for ID %s", guid)
							ret = true	-- Still return true, we just didn't want this string yet
							break
						elseif (r.name == UNKNOWN) then
							retInfo = format("Premature SetStorageString for ID %s", guid)
							ret = true	-- Still return true, we just didn't want this string yet
							break
						end
						if (r.talents) then
							-- We've already received talents for this player
							ret = true	-- Still return true, we just didn't want this string because we have their talents
							break
						end

						if (not self.classTalentData[r.class]) then
							-- Received a storage string for a class that we've not yet been able to scan
							-- the talent trees for. We store this until we have that data
							local classStorageStrings = self.pendingStorageStrings[r.class]
							if (not classStorageStrings) then
								classStorageStrings = new()
								self.pendingStorageStrings[r.class] = classStorageStrings
							end
							classStorageStrings[guid] = str
							ret = true
							break
						end

						local level = tonumber(part1[2])
						local class = part1[3]
						local active = tonumber(part1[4])
						local numActive = tonumber(part1[5])

						if (r.level < 1) then
							-- UnitLevel(name) - r.name is a plain stored name, not a live unit token - throws
				-- "Unknown unit name" on this client for a bad/stale name (same bug class as
				-- UnitGUID/UnitInRaid/etc.) - pcall-wrap rather than trust a bare call.
				local ok, lvl = pcall(UnitLevel, r.name)
				r.level = (ok and lvl) or 0
						end
						if (level ~= r.level and r.level > 1) then
							-- Won't accept talents for mismatched levels (but ignore errors reading the UnitLevel early)
							retInfo = "Wrong level"
							break
						end
						if (not r.class and class) then
							-- If we don't have the class, but the storage string does, we'll take it
							r.class = class
						end
						if (class ~= r.class) then
							-- Class doesn't match, probably a char delete/remake or xrealm
							retInfo = format("Wrong class: expected %q, got %q", tostring(r.class), tostring(class))
							break
						end

						-- Now the talent trees
						local talents = new()
						for i = 2,tgetn(parts) - 1 do
							local partN = new(strsplit(",", parts[i]))
							if (tgetn(partN) == 2) then
								local specNumber = tonumber(partN[1])
								local specTalents = new(strsplit("-", partN[2]))

								if (specNumber and tgetn(specTalents) >= 3) then
									talents[specNumber] = specTalents
								else
									del(specTalents)
									talents = del(talents)
									retInfo = "Invalid talent specs in tree "..i
									break
								end
							end
						end

						if (talents) then
							r.talents = talents
							r.active = active
							r.numActive = numActive
							if (comms ~= r.name) then
								-- If comms part sends player name along with packet, then we'll skip the refresh later
								-- which we'd normally do when Storage is set via app startup
								r.refresh = true
							else
								r.refresh = nil
							end

							ValidateUnit(r, guid)
							local newSpec, n1, n2, n3 = TalentWeight(r.talents[r.active], r.class)
							self.events:Fire("LibGroupTalents_Update", guid, r.unit, newSpec, n1, n2, n3)
							self:GetGUIDRole(guid, true)
							ret = true
						end
						break
					end

					del(part1)
				else
					retInfo = "Invalid string"
				end
			end
			del(parts)
		end

		return ret, retInfo
	end
end

-- GetClassTalentData
-- Builds an internal table for talent name -> tree/index lookups.
function GetClassTalentData(unit)
	local _, class = UnitClass(unit)
	if (class) then
		local data = lib.classTalentData[class]
		if (not data) then
			local isnotplayer = not UnitIsUnit("player", unit)
			if (GetNumTalentTabs(isnotplayer) > 0) then
				data = new()

				for tab = 1, GetNumTalentTabs(isnotplayer) do
					local tree = new()
					local _
					tree.name, tree.icon, _, tree.background = GetTalentTabInfo(tab, isnotplayer)
					tinsert(data, tree)

					tree.list = new()
					for i = 1,GetNumTalents(tab, isnotplayer) do
						local name, icon, tier, column, currentRank, maxRank = GetTalentInfo(tab, i, isnotplayer)
						if (name) then
							local entry = new()
							entry.name = name
							entry.icon = icon
							entry.tier = tier
							entry.column = column
							entry.maxRank = maxRank
							entry.index = i
							entry.treeIndex = tab
							tinsert(tree.list, entry)
							if (not data.list) then
								data.list = new()
							end
							data.list[name] = entry
						end
					end
				end

				if (next(data)) then
					lib.classTalentData[class] = data

					--for guid,r in pairs(lib.roster) do
					--	if (r.class == class and r.talents) then
					--		-- We picked up class talent data for a class after receiving talents for them via comms
					--		-- So, we fire an Update event for any members of the class we already have so that
					--		-- talents can now be interpreted correctly.
					--		local spec, n1, n2, n3 = TalentWeight(r.talents[r.active], class)
					--		lib.events:Fire("LibGroupTalents_Update", guid, unit, spec, n1, n2, n3)
					--	end
					--end

					local classStorageStrings = lib.pendingStorageStrings[class]
					if (classStorageStrings) then
						local unitGUID = UnitGUID(unit)
						for guid, str in pairs(classStorageStrings) do
							if (guid ~= unitGUID) then
								lib:SetStorageString(str)
							end
 						end
						lib.pendingStorageStrings[class] = del(lib.pendingStorageStrings[class])
					end
				else
					deepDel(data)
				end
			end
		end
	end
end

-- GetTreeNames
function lib:GetTreeNames(class)
	local info = self.classTalentData[class]
	if (info) then
		return info[1].name, info[2].name, info[3].name
	end
end

-- GetTreeIcons
function lib:GetTreeIcons(class)
	local info = self.classTalentData[class]
	if (info) then
		return info[1].icon, info[2].icon, info[3].icon
	end
end

-- ReadTalentGroup
-- No client-side dual-spec on TurtleWoW/OctoWoW 1.12: GetNumTalents/GetTalentInfo never
-- take a talent-group argument here (that WotLK 3.1+ parameter doesn't exist on this
-- client), so this always reads whatever is currently allocated.
local function ReadTalentGroup(isnotplayer, class)
	local numTabs = GetNumTalentTabs(isnotplayer)
	if (numTabs and numTabs >= 3 and GetNumTalents(1, isnotplayer) > 0) then
		local ctd = lib.classTalentData[class]
--[===[@debug@
assert(ctd and ctd[1] and ctd[2] and ctd[3])
assert(ctd[1].list and ctd[2].list and ctd[3].list)
--@end-debug@]===]

		local n = new()
		for tab = 1, numTabs do
			local branchLength = GetNumTalents(tab, isnotplayer)
			if (branchLength ~= tgetn(ctd[tab].list)) then
				-- Tab tree size is not what we expected for this class
				del(n)
				return
			end

			local t = new()
			local trim
			for i = 1,branchLength do
				local name, icon, tier, column, currentRank, maxRank = GetTalentInfo(tab, i, isnotplayer)
				tinsert(t, currentRank)
				if (currentRank > 0) then
					trim = i			-- We strip off trailing zeros from talent strings to save storage space
				end
			end

			tinsert(n, table.concat(t, nil, 1, trim or 0))
			del(t)
		end

		return n
	end
end

-- TalentQuery_Ready
function lib:TalentQuery_Ready_Outsider(e, name, realm, unit)
	self:TalentQuery_Ready(e, name, realm, unit)
end

-- TalentQuery_Ready
function lib:TalentQuery_Ready(e, name, realm, unit)
	GetClassTalentData(unit)

	local guid = unit and UnitGUID(unit)
	local r = guid and self.roster[guid]
	if (r) then
		local namerealm = realm and realm ~= "" and name .. "-" .. realm or name
		local isnotplayer = not UnitIsUnit(unit, "player")

		if (GetTalentTabInfo(1, isnotplayer)) then
			-- No client-side dual-spec on TurtleWoW/OctoWoW 1.12: GetActiveTalentGroup()/
			-- GetNumTalentGroups() don't exist here at all (WotLK 3.1+ only). Only one
			-- talent allocation is ever active, so hard-code group 1.
			local active, numActive = 1, 1
			local listUnspent, invalid
			local talents = new()

			local n = ReadTalentGroup(isnotplayer, r.class)
			if (n and tgetn(n) >= 3) then
				talents[active] = n
			else
				invalid = true
			end

			-- GetUnspentTalentPoints doesn't exist as a global on this client (confirmed via
			-- a real "attempt to call global 'GetUnspentTalentPoints' (a nil value)" error) -
			-- guard so this degrades to "assume no unspent points" instead of erroring. This
			-- only affects an optimization (re-checking talents sooner if points are unspent),
			-- not core functionality.
			if (not invalid) and _G.GetUnspentTalentPoints then
				local unspent = GetUnspentTalentPoints(isnotplayer)
				if (unspent and unspent > 0) then
					listUnspent = new()
					listUnspent[active] = unspent
				end
			end

			if (isnotplayer and (invalid or (listUnspent and listUnspent[active] or 0) > 0)) then
				-- Unit didn't have all their points spent in active group, so we'll have another look in 10 seconds
				-- Don't need to check when it's "player" because we get PLAYER_TALENT_UPDATE event on changes
				self:TriggerRefreshTalents(guid, 10)
			end

			if (not invalid) then
				self:OnReceiveTalents(guid, unit, talents, active, numActive, listUnspent)
			end
		end
	end
end
TalentQuery.RegisterCallback(lib, "TalentQuery_Ready")
TalentQuery.RegisterCallback(lib, "TalentQuery_Ready_Outsider")

-- GetUnitTalentSpec
function lib:GetUnitTalentSpec(unit)
	return self:GetGUIDTalentSpec(UnitGUID(unit))
end

-- GetGUIDTalentSpec
function lib:GetGUIDTalentSpec(guid)
	local talents, r = GetGUIDTalentsRaw(guid)
	if (talents) then
		return TalentWeight(talents, r.class)
	end
end

-- CompareTalents
local function CompareTalents(tree1, tree2)
	if ((tree1 ~= nil) ~= (tree2 ~= nil)) then
		return
	end
	if (tree1 and tree2 and tgetn(tree1) == tgetn(tree2)) then
		for i = 1,tgetn(tree1) do
			if (tree1[i] ~= tree2[i]) then
				return
			end
		end
		return true
	end
end

-- OnReceiveTalents
function lib:OnReceiveTalents(guid, unit, talents, active, numActive, listUnspent)
	local r = self.roster[guid]
	if (r) then
		if (active ~= r.active or numActive ~= r.numActive or not CompareTalents(talents and talents[active], r.talents and r.talents[r.active])) then
			local oldTalents
			if (r.talents) then
				oldTalents = r.talents[r.active]
			end
			del(r.unspent)

			r.talents = talents
			r.active = active
			r.numActive = numActive
			r.unspent = listUnspent

			local newSpec, n1, n2, n3 = TalentWeight(r.talents[active], r.class)

			local fired
			if (oldTalents) then
				-- For those cases when we didn't have the alternate talents for a player for whatever reason.
				-- Maybe they just picked up dual talent spec, or gated to trainer to respec.
				local oldSpec, o1, o2, o3 = TalentWeight(oldTalents, r.class)

				if (o1 ~= n1 or o2 ~= n2 or o3 ~= n3) then
					self.events:Fire("LibGroupTalents_Update", guid, unit, newSpec, n1, n2, n3, oldSpec, o1, o2, o3)
					fired = true
				end
			end

			if (not fired) then
				self.events:Fire("LibGroupTalents_Update", guid, unit, newSpec, n1, n2, n3)
			end
			self:GetGUIDRole(guid, true)

			tinsert(self.batch, guid)
			CheckForUpdateComplete()

			oldTalents = del(oldTalents)
			return
		end
	end
	del(talents)
end

-- OnReceiveGlyphs
function lib:OnReceiveGlyphs(guid, sender, glyphs)
	local r = self.roster[guid]
	if (r) then
		if (ValidateUnit(r, guid)) then
			local oldGlyphs
			if (r.glyphs) then
				oldGlyphs = r.glyphs[r.active]
				r.glyphs = del(r.glyphs)
			end

			r.glyphs = glyphs

			local newGlyphs = r.glyphs and r.glyphs[r.active]
			if (newGlyphs ~= oldGlyphs) then
				self.events:Fire("LibGroupTalents_GlyphUpdate", guid, r.unit)
			end
			return
		end
	end

	del(glyphs)
end

-- GetUnitGlyphs
function lib:GetUnitGlyphs(unit)
	return self:GetGUIDGlyphs(UnitGUID(unit))
end

-- GetGUIDGlyphs
function lib:GetGUIDGlyphs(guid)
	local r = self.roster[guid]
	if (r) then
		local g = r.glyphs and r.glyphs[r.active]
		if (g) then
			local temp = new(strsplit(",", g))
			for i,str in ipairs(temp) do
				temp[i] = tonumber(str)
			end
			local a, b, c, d, e, f = unpack(temp)
			del(temp)
			return a, b, c, d, e, f
		end
	end
end
                                        
-- UnitHasGlyph
function lib:UnitHasGlyph(unit, glyphID)
	return lib:GUIDHasGlyph(UnitGUID(unit), glyphID)
end

-- GUIDHasGlyph
function lib:GUIDHasGlyph(guid, glyphID)
	local ret
	local r = self.roster[guid]
	if (r) then
		local g = r.glyphs and r.glyphs[r.active]
		if (g) then
			local temp = new(strsplit(",", g))
			for i,str in ipairs(temp) do
				local id = tonumber(str)
				if (type(glyphID) == "number") then
					if (glyphID == id) then
						ret = true
						break
					end
				else
					if (glyphID == GetSpellInfo(id)) then
						ret = true
						break
					end
				end
			end
			del(temp)
		end
	end
	return ret
end

-- GLYPH_ADDED
function lib:GLYPH_ADDED(index, a, b, c)
	self:RefreshPlayerGlyphs()
end

-- GLYPH_REMOVED
function lib:GLYPH_REMOVED(index, a, b, c)
	self:RefreshPlayerGlyphs()
end

-- GLYPH_UPDATED
function lib:GLYPH_UPDATED(index, a, b, c)
	self:RefreshPlayerGlyphs()
end

-- RefreshPlayerGlyphs
-- Glyphs are a WotLK 3.0+ (Inscription) feature -- GetNumGlyphSockets/GetGlyphSocketInfo
-- don't exist on TurtleWoW/OctoWoW 1.12 at all (this is separate from, and in addition to,
-- the dual-spec GetNumTalentGroups() this used to also call). Strip, don't port: bail out
-- gracefully so this never errors when the player's own talents are scanned (which happens
-- on every login), rather than porting a feature this client can't have. r.glyphs simply
-- never gets populated, so GetUnitGlyphs/UnitHasGlyph degrade to "no glyph data" and the
-- GLYPHS comm messages naturally become inert (nothing to send).
function lib:RefreshPlayerGlyphs()
	if (not _G.GetNumGlyphSockets) then
		return
	end

	local guid = UnitGUID("player")
	local r = self.roster[guid]
	if (not r) then
		return
	end

	local glyphs = new()
	local any
	-- No dual-spec on this client: always exactly one glyph set (group 1).
	do
		local talentGroup = 1
		local list = new()
		for i = 1,GetNumGlyphSockets() do
			local enabled, glyphType, glyphSpell, icon = GetGlyphSocketInfo(i, talentGroup)
			if (enabled and glyphType and glyphSpell) then
				tinsert(list, glyphSpell)
				any = true
			end
		end
		glyphs[talentGroup] = table.concat(list, ",")
		del(list)
	end

	local oldGlyphs = r.glyphs
	if (any) then
		r.glyphs = glyphs
	else
		del(glyphs)
	end

	local change = (oldGlyphs and oldGlyphs[r.active]) ~= (r.glyphs and r.glyphs[r.active])
	if (change) then
		self:SendMyGlyphs()
		self.events:Fire("LibGroupTalents_GlyphUpdate", guid, "player")
	end

	del(oldGlyphs)
end

-- PLAYER_TALENT_UPDATE
function lib:PLAYER_TALENT_UPDATE()
	self:TriggerRefreshTalents(UnitGUID("player"), 2)
end

-- UNIT_SPELLCAST_SUCCEEDED
function lib:UNIT_SPELLCAST_SUCCEEDED(unit, spell)
	local newActiveGroup = specChangers[spell]
	if (newActiveGroup) then
		local guid = UnitGUID(unit)
		local r = guid and self.roster[guid]
		if (r) then
			if (newActiveGroup == r.active) then
				-- We obviously didn't see them switch from this set
				self:GetGUIDRole(guid, true)
				return
			end

			if (r.talents) then
				local oldSet = r.talents[r.active]
				local newSet = r.talents[newActiveGroup]
				if (oldSet and newSet) then
					-- We have the other talent set, so no need to refresh anything. Just compare and notify
					r.active = newActiveGroup

					local oldSpec, o1, o2, o3 = TalentWeight(oldSet, r.class)
					local newSpec, n1, n2, n3 = TalentWeight(newSet, r.class)

					if (o1 ~= n1 or o2 ~= n2 or o3 ~= n3) then
						self.events:Fire("LibGroupTalents_Update", guid, unit, newSpec, n1, n2, n3, oldSpec, o1, o2, o3)
					else
						self.events:Fire("LibGroupTalents_Update", guid, unit, newSpec, n1, n2, n3)
					end
					self:GetGUIDRole(guid, true)
					return
				end
			end

			-- If we get this far, then someone probably gated to respec
			self:RefreshTalentsByGUID(guid)
		end
	end
end

-- TriggerRefreshTalents
function lib:TriggerRefreshTalents(guid, delay)
	if (not self.talentTimers) then
		self.talentTimers = new()
	end
	if (guid) then
		self.talentTimers[guid] = GetTime() + delay
		frame:Show()
	end
end

-- RefreshTalentsByUnit
function lib:RefreshTalentsByUnit(unit)
	local guid = UnitGUID(unit)
	if (guid) then
		self:RefreshTalentsByGUID(guid)
	end
end

-- RefreshTalentsByGUID
function lib:RefreshTalentsByGUID(guid)
	local r = self.roster[guid]
	if (not r) then
		return
	end
	if (not ValidateUnit(r, guid)) then
		return
	end

	if (self.talentTimers) then
		self.talentTimers[guid] = nil
	end

	if (not self.talentThrottle) then
		self.talentThrottle = {}
	end
	for guidThrottle,when in pairs(self.talentThrottle) do
		if (when < GetTime() - 5) then
			self.talentThrottle[guidThrottle] = nil
		elseif (guid == guidThrottle) then
			return
		end
	end
	self.talentThrottle[guid] = GetTime()

	if (self.commQueried) then
		self.commQueried[guid] = nil
		if (not next(self.commQueried)) then
			self.commQueried = del(self.commQueried)
		end
	end

	r.refresh = true
	self:CheckForMissingTalents()

	if (UnitGUID("player") == guid) then
		self:SendMyTalents()
	end
end

-- CheckForMissingTalents
function lib:CheckForMissingTalents()
	local any
	for guid,info in pairs(self.roster) do
		-- UnitIsVisible/UnitExists throw "Unknown unit name" on this client when given a bare
		-- player name instead of a real unit token (same class of bug as UnitGUID/UnitIsConnected
		-- elsewhere in this file) - use the already-resolved raid/party/player token instead.
		local unit = info.unit
		if (not info.talents or (unit and not UnitIsVisible(unit) and UnitExists(unit)) or info.refresh) then
			any = true
			info.refresh = nil
			self:GetUnitTalents(info.unit, true)
		end
	end

	if (any) then
		lib.refreshCheckTimer = 15
		frame:Show()
	end
end

do
	local survivalOfTheFittest = GetSpellInfo(33853)		-- Survival of the Fittest
	local protectorOfThePack = GetSpellInfo(57873)			-- Protector of the Pack
	local dkBladeBarrier = GetSpellInfo(49182)				-- Blade Barrier
	local dkToughness = GetSpellInfo(49042)					-- Toughness
	local dkAnticipation = GetSpellInfo(55129)				-- Anticipation

	-- GetUnitRole
	function lib:GetUnitRole(unit, reset)
		local guid = UnitGUID(unit)
		if (guid) then
			return self:GetGUIDRole(guid, reset)
		end
	end

	-- GetGUIDRole
	function lib:GetGUIDRole(guid, reset)
		local r = guid and self.roster[guid]
		if (not r) then
			return
		end
		if (r.role and not reset) then
			return r.role
		end
		if (not ValidateUnit(r, guid)) then
			return
		end

		local class = r.class
		local role

		local unit = r.unit
		if (class == "ROGUE" or class == "HUNTER") then
			role = "melee"
		elseif (class == "MAGE" or class == "WARLOCK") then
			role = "caster"
		elseif (r.talents and r.talents[r.active]) then
			if (class == "DEATHKNIGHT") then
				local score = self:GUIDHasTalent(guid, dkBladeBarrier) and 1 or 0
				score = score + (self:GUIDHasTalent(guid, dkToughness) and 1 or 0)
				score = score + (self:GUIDHasTalent(guid, dkAnticipation) and 1 or 0)
				role = score >= 2 and "tank" or "melee"		-- Has 2 of the 3 tanking talents at least

			else
				local specName, t1, t2, t3 = TalentWeight(r.talents[r.active], class)

				if (class == "PRIEST") then
					role = ((t1 + t2) > t3) and "healer" or "caster"
				elseif (class == "WARRIOR") then
					role = ((t1 + t2) > t3) and "melee" or "tank" 
				else
					local heavy = (t1 > t2 and t1 > t3 and 1) or (t2 > t1 and t2 > t3 and 2) or (t3 > t1 and t3 > t2 and 3) or 0
					if (class == "PALADIN") then
						role = heavy == 1 and "healer" or heavy == 2 and "tank" or heavy == 3 and "melee"

					elseif (class == "DRUID") then
						if (heavy == 2) then
							if (self:GUIDHasTalent(guid, survivalOfTheFittest) and self:GUIDHasTalent(guid, protectorOfThePack)) then
								role = "tank"
							else
								role = "melee"
							end
						else
							role = heavy == 1 and "caster" or "healer"
						end

					elseif (class == "SHAMAN") then
						role = heavy == 1 and "caster" or heavy == 2 and "melee" or heavy == 3 and "healer"
					end
				end
			end
		end

		local oldrole = r.role
		r.role = role

		if (role and role ~= oldrole) then
			self.events:Fire("LibGroupTalents_RoleChange", guid, unit, role, oldrole)
		end
		return role
	end
end

-- GetUnitTalents
function lib:GetUnitTalents(unit, refetch)
	-- UnitGUID errors ("Unknown unit name: ...") on this client for a non-string/invalid unit
	-- token instead of just returning nil - confirmed via a real in-game error where some
	-- caller passed the number 0 instead of a unit string. Guard the type before calling it
	-- so a bad caller degrades to "no talents" instead of erroring.
	if type(unit) ~= "string" then
		return
	end
	local guid = UnitGUID(unit)
	if (not guid) then
		return
	end
	return self:GetGUIDTalents(guid, refetch)
end

-- CanCommQuery
local function CanCommQuery(guid)
	if (not lib.commQueried or not lib.commQueried[guid]) then
		if (not lib.commQueried) then
			lib.commQueried = new()
		end
		lib.commQueried[guid] = true
		return true
	end
end

-- GetGUIDTalents
function lib:GetGUIDTalents(guid, refetch)
	local r = self.roster[guid]
	if (not r) then
		return
	end
	if (not ValidateUnit(r, guid)) then
		return
	end

	local unit = r.unit
	local name, realm = UnitName(unit)
	local activeTalents = r.talents and r.talents[r.active]

	if (activeTalents) then
		-- If someone is out of sight, we won't catch their talent swap spell cast, so we'll invalidate them here and recheck talents
		if ((not UnitIsVisible(unit) and UnitIsConnected(unit)) or (self.outOfSight and self.outOfSight[guid])) then
			if (not r.version) then
				refetch = true
			end
		end
	end

	if (not activeTalents or refetch) then
		if (UnitIsUnit("player", unit)) then
			self:RefreshPlayerGlyphs()
			self:TalentQuery_Ready(nil, name, nil, unit)

		elseif ((UnitInRaid(unit) or UnitInParty(unit)) and UnitIsConnected(unit)) then
			TalentQuery:Query(unit)

			local namerealm = UnitFullName(unit)
			if (not r.talents and not r.requested) then
				-- Don't need to query on a 'refetch' because they'll send changes anyway via comms
				local skipGlyphs
				if (not UnitIsVisible(unit) or not CanInspect(unit)) then
					if (r.version) then
						if (CanCommQuery(guid)) then
							-- We request talents via comms for anyone that may be out of inspect range
							self:SendCommMessage("REQUESTTALENTS", namerealm)
							r.requested = true
							skipGlyphs = true
						end
					end
				end
			end

			if (not r.glyphs and not skipGlyphs) then
				if (r.version and r.version >= 15) then
					if (CanCommQuery(guid)) then
						-- They're in range to inspect, but we'll still want to ask for their glyphs
						self:SendCommMessage("REQUESTGLYPHS", namerealm)
					end
				end
			end
		end

		if (self.outOfSight) then
			self.outOfSight[guid] = nil
		end
	end

	return activeTalents
end

-- SendCommMessage
function lib:SendCommMessage(msg, target, channel)
	if (msg) then
		if (ChatThrottleLib) then
			ChatThrottleLib:SendAddonMessage("NORMAL", MAJOR, msg, channel or "WHISPER", target)
		else
			SendAddonMessage(MAJOR, msg, channel or "WHISPER", target)
		end
	end
end

-- Throttle - Purposely local to here
-- Abuse prevention. Yes, who would abuse addon comms? Noone would make a macro to crash a mod user would they. Right?
-- Well, this one time, at band camp. Someone thought it was super funny to make a macro that DCd PallyPower users
local throttle
local function Throttle(sender, key)
	if (not throttle) then
		throttle = {}
	end
	local s = throttle[sender]
	if (not s) then
		s = {}
		throttle[sender] = s
	end

	if ((s[key] or 0) < GetTime() - 4.5) then
		-- Same message key only allowable once every 4.5 secs from 1 person (Respec cast time is 5 seconds)
		s[key] = GetTime()
		return true
	end
end

-- CHAT_MSG_ADDON
function lib:CHAT_MSG_ADDON(prefix, msg, channel, sender)
	if (prefix == MAJOR) then
		if (sender == UnitName("player")) then
			return
		end

		-- UnitGUID(sender) below needs a real unit token on this client (throws "Unknown unit
		-- name" for a bare player name instead of returning nil) - resolve the raid/party slot
		-- here rather than passing the name straight through. UnitInRaid itself can ALSO throw
		-- for a bare name in some contexts (confirmed live) - pcall-wrap it too.
		local senderUnit
		local okRaid, raidIndex = pcall(UnitInRaid, sender)
		if (okRaid and raidIndex) then
			senderUnit = "raid"..raidIndex
		else
			for i = 1, 4 do
				if (UnitName("party"..i) == sender) then
					senderUnit = "party"..i
					break
				end
			end
		end
		if (not senderUnit) then
			return
		end

		local guid = UnitGUID(senderUnit)
		if (not guid) then
			return
		end
		local r = self.roster[guid]
		if (not r) then
			return
		end

		-- Lua 5.0 has no `string.match`/`:match()` -- use `string.find` with captures instead.
		local cmd, str = select(3, string.find(msg, "^(%a+) *(.*)$"))
		if (not cmd) then
			return
		end

		if (cmd == "TALENTS") then
			-- Talents come in form of:
			local t = r.talents
			r.talents = nil		-- SetStorageString won't overwrite talents usually, but we want it to here, without providing a means to do it easily with an arg from a mod
			if (not self:SetStorageString(str, sender)) then
				r.talents = t
			else
				deepDel(t)
			end

		elseif (cmd == "GLYPHS") then
			local invalid
			local pages = new(strsplit(";", str))
			local glyphs = new()
			for page,info in ipairs(pages) do
				local list = new(strsplit(",", info))
				local tab = tonumber(tremove(list, 1))
				if (tab) then
					glyphs[tab] = table.concat(list, ",")
					del(list)
				else
					invalid = true
					del(glyphs)
					del(list)
					break
				end
			end
			if (not invalid) then
				self:OnReceiveGlyphs(guid, sender, glyphs)
			end
			del(pages)

		elseif (cmd == "REQUESTTALENTS") then
			if (Throttle(sender, "REQUESTTALENTS")) then
				if ((r.version or 0) < 39) then
					if (lib.sentToOld and lib.sentToOld[guid]) then
						return
					end
					if (not lib.sentToOld) then
						lib.sentToOld = new()
					end
					lib.sentToOld[guid] = time()
				end

				self:SendMyTalents(sender)
				self:SendMyGlyphs(sender)
			end

		elseif (cmd == "REQUESTGLYPHS") then
			if (Throttle(sender, "REQUESTGLYPHS")) then
				self:SendMyGlyphs(sender)
			end

		elseif (cmd == "HELLO") then
			r.version = tonumber(str)
			if (channel ~= "WHISPER") then
				if (lib.sentToOld) then
					lib.sentToOld[guid] = nil
				end
				if (IsNameConnected(sender) and Throttle(sender, "HELLO")) then
					self:SendCommMessage("HELLO "..MINOR, sender)
					self:SendMyGlyphs(sender)
				end
			end
		end
	end
end

-- SendMy
local function SendMy(sender, str)
	if (sender) then
		if (IsNameConnected(sender)) then
			lib:SendCommMessage(str, sender)
		end
	else
		for guid,info in pairs(lib.roster) do
			if (info.version) then
				local namerealm = RosterInfoFullName(info)
				if (IsNameConnected(namerealm)) then
					lib:SendCommMessage(str, namerealm)
				end
			end
		end
	end
end

-- SendMyTalents
function lib:SendMyTalents(sender)
	if (sender or self:UserCount() > 0) then
		local str = self:GetGUIDStorageString(UnitGUID("player"))
		if (str) then
			SendMy(sender, "TALENTS "..str)
		end
	end
end

-- SendMyGlyphs
function lib:SendMyGlyphs(sender)
	if (sender or self:UserCount() > 0) then
		local r = self.roster[UnitGUID("player")]
		if (r and r.glyphs) then
			local str = "GLYPHS "
			local i = 1
			for tab,g in pairs(r.glyphs) do
				local temp = format("%d,%s", tab, g)
				str = str .. (i > 1 and ";" or "") .. temp
				i = i + 1
			end
			SendMy(sender, str)
		end
	end
end

-- UserCount
function lib:UserCount()
	-- Native UnitIsUnit(unit1, unit2) throws "Unknown unit name" on this client when given a
	-- plain name string instead of a real unit token (same bug class as UnitGUID/UnitInRaid/etc,
	-- and the reason RCLootCouncil:UnitIsUnit exists as a safe wrapper in core.lua - but this is
	-- a standalone library file, so it can't reach into the host addon for that). Compare names
	-- directly instead, same convention this file's own IsNameConnected() already uses.
	local count = 0
	local playerName = UnitName("player")
	for guid,info in pairs(self.roster) do
		if (info.version and RosterInfoFullName(info) ~= playerName) then
			count = count + 1
		end
	end
	return count
end

-- UnitHasTalent
-- eg: lib:UnitHasTalent("player", GetSpellInfo(talentSpellID))
-- Returns: nil, or number of points spent into talent
-- No client-side dual-spec on TurtleWoW/OctoWoW 1.12 -- always reads the unit's one
-- active allocation of talent points.
function lib:UnitHasTalent(unit, talentName)
	return unit and self:GUIDHasTalent(UnitGUID(unit), talentName)
end

-- GUIDHasTalent
-- Returns: nil, or number of points spent into talent
function lib:GUIDHasTalent(guid, talentName)
	local talents, r = GetGUIDTalentsRaw(guid)
	if (talents and r.class) then
		local data = self.classTalentData[r.class]
		if (data) then
			local info = data.list and data.list[talentName]
			if (info) then
				local str = talents[info.treeIndex]
				if (str) then
					local amount = (string.byte(str, info.index) or 48) - 48
					return (amount or 0) > 0 and amount or nil
				end
			end
		end
	end
end

-- GetClassTalentInfo
function lib:GetClassTalentInfo(class, talentName)
-- Returns: Max Rank, Icon, Tab, Tier, Column, Tree Index
	local data = self.classTalentData[class]
	if (data) then
		local info = data.list and data.list[talentName]
		if (info) then
			return info.maxRank, info.icon, info.treeIndex, info.column, info.tier, info.index
		end
	end
end

-- GetActiveTalentGroup
-- No client-side dual-spec on TurtleWoW/OctoWoW 1.12 -- the native GetActiveTalentGroup()
-- is a WotLK 3.1+ function and doesn't exist here at all. Only one talent allocation is
-- ever active, so this always reports group 1 (nil only if the unit isn't tracked).
function lib:GetActiveTalentGroup(unit)
	if (UnitIsUnit(unit, "player")) then
		return 1
	else
		local guid = unit and UnitGUID(unit)
		local r = guid and self.roster[guid]
		return r and 1 or nil
	end
end

-- GetNumTalentGroups
-- Same reasoning as GetActiveTalentGroup above: always exactly 1 talent group exists on
-- this client (the native GetNumTalentGroups() is WotLK 3.1+ only).
function lib:GetNumTalentGroups(unit)
	if (UnitIsUnit(unit, "player")) then
		return 1
	else
		local guid = unit and UnitGUID(unit)
		local r = guid and self.roster[guid]
		return r and 1 or nil
	end
end

-- GetTalentTabInfo
-- No `group` parameter on this client: GetTalentTabInfo natively takes (index, inspect)
-- only on TurtleWoW/OctoWoW 1.12 -- no dual-spec group argument, no pet-talent argument
-- (pet talent trees are a BC+ feature).
function lib:GetTalentTabInfo(unit, tab)
	if (UnitIsUnit(unit, "player")) then
		return GetTalentTabInfo(tab)
	else
		local guid = unit and UnitGUID(unit)
		local r = guid and self.roster[guid]
		if (r and r.class) then
			local ctd = self.classTalentData[r.class]
			if (ctd and tab >= 1 and tab <= tgetn(ctd)) then
				local spec, c1, c2, c3 = self:GetGUIDTalentSpec(guid)
				return ctd[tab].name, ctd[tab].icon, tab == 1 and c1 or tab == 2 and c2 or c3, ctd[tab].background, 0
			end
		end
	end
end

-- GetNumTalents
function lib:GetNumTalents(unit, tab)
	if (UnitIsUnit(unit, "player")) then
		return GetNumTalents(tab)
	else
		local _, class = UnitClass(unit)
		if (class) then
			local ctd = self.classTalentData[class]
			if (ctd and tab >= 1 and tab <= tgetn(ctd)) then
				return tgetn(ctd[tab].list)
			end
		end
	end
end

-- GetTalentInfo
-- No `group` parameter on this client: GetTalentInfo natively takes (tab, index, inspect)
-- only -- no dual-spec group argument.
function lib:GetTalentInfo(unit, tab, index)
	if (UnitIsUnit(unit, "player")) then
		return GetTalentInfo(tab, index)
	else
		local _, class = UnitClass(unit)
		if (class) then
			local ctd = self.classTalentData[class]
			if (ctd and tab >= 1 and tab <= tgetn(ctd)) then
				local info = ctd[tab].list[index]
				if (info) then
					local spent = self:UnitHasTalent(unit, info.name)
					return info.name, info.icon, info.tier, info.column, spent or 0, info.maxRank
				end
			end
		end
	end
end

-- GetNumTalentTabs
function lib:GetNumTalentTabs()
	return GetNumTalentTabs()
end

-- GetUnspentTalentPoints
-- No `group` parameter on this client: GetUnspentTalentPoints natively takes no
-- talent-group argument (WotLK 3.1+ only).
function lib:GetUnspentTalentPoints(unit)
	if (UnitIsUnit(unit, "player")) then
		return GetUnspentTalentPoints()
	else
		local guid = unit and UnitGUID(unit)
		local r = guid and self.roster[guid]
		if (r) then
			return r.unspent and r.unspent[r.active or 1]
		end
	end
end

-- GetTalentCount
function lib:GetTalentCount()
	local count, missing = 0, 0
	for guid,info in pairs(self.roster) do
		if (info.talents) then
			count = count + 1
		else
			missing = missing + 1
		end
	end
	return count, missing
end

-- GetTalentMissingNames
function lib:GetTalentMissingNames()
	local list = new()
	for unit in self:IterateRoster() do
		local guid = UnitGUID(unit)
		local r = guid and self.roster[guid]
		if (not r or not r.talents) then
			tinsert(list, UnitFullName(unit))
		end
	end
	local ret
	if (next(list)) then
		ret = table.concat(list, ",")
	end
	del(list)
	return ret
end

-- PurgeAndRescanTalents
function lib:PurgeAndRescanTalents()
	if (self.roster) then
		wipe(self.pendingStorageStrings)
		for guid,info in pairs(self.roster) do
			info.talents = del(info.talents)
			info.active = nil
			info.numActive = nil
			info.requested = nil
		end
	end
	self:CheckForMissingTalents()
end

-- Roster iterator
do
	local function iter(t)
		local key = t.id
		local ret
		if (t.mode == "raid") then
			if (key > t.r) then
				del(t)
				return nil
			end
			ret = "raid"..key
		else
			if (key > t.p) then
				del(t)
				return nil
			end
			ret = key == 0 and "player" or "party"..key
		end
		t.id = key + 1
		return ret
	end

	-- IterateRoster
	function lib:IterateRoster()
		local t = new()
		if (GetNumRaidMembers() > 0) then
			t.mode = "raid"
			t.id = 1
			t.r = GetNumRaidMembers()
		else
			t.mode = "party"
			t.id = 0
			t.p = GetNumPartyMembers()
		end
		return iter, t
	end
end
