-- Author      : Potdisc
-- tokenData.lua
-- Contains equip location and useable classes from tier tokens

-- Stripped for the 1.12/TurtleWoW-OctoWoW port: the original data here was WotLK/Cata raid
-- tier-token item IDs (Naxxramas through Icecrown Citadel), which have no vanilla-era
-- equivalent. Left as empty tables (not deleted) so core.lua/ml_core.lua's existing
-- RCTokenTable/RCTokenLevel/RCTokenClasses lookups keep working - they just never match,
-- which is the correct behavior (no known tokens on this content).
RCTokenTable = {}
RCTokenLevel = {}
RCTokenClasses = {}
