-- luacheck configuration: Lua 5.1 (the game's Lua) plus an explicit list of the game
-- API Quest Together is allowed to use, so typos and accidental globals fail the lint.
std = "lua51"
max_line_length = 120
codes = true
self = false
exclude_files = { ".tools/**", ".release/**" }

files["QuestTogether/**/*.lua"] = {
	globals = {
		-- Saved variables and slash command registration.
		"QuestTogetherDB",
		"SLASH_QUESTTOGETHER1",
		"SLASH_QUESTTOGETHER2",
		"SlashCmdList",
	},
	read_globals = {
		-- Lua extensions and helpers provided by the client.
		"wipe",
		"issecretvalue",
		"securecallfunction",
		"debugprofilestop",
		-- Frames and UI framework.
		"CreateFrame",
		"CreateFont",
		"UIParent",
		"GameTooltip",
		"PixelUtil",
		"Settings",
		"CreateSettingsListSectionHeaderInitializer",
		"CreateSettingsButtonInitializer",
		"MinimalSliderWithSteppersMixin",
		"MenuUtil",
		"InCombatLockdown",
		"STANDARD_TEXT_FONT",
		"GetFileIDFromPath",
		"IsShiftKeyDown",
		"GetBuildInfo",
		-- Game API.
		"AcceptQuest",
		"C_AddOns",
		"C_ChatInfo",
		"C_ClassColor",
		"C_Minimap",
		"C_QuestLog",
		"C_Timer",
		"C_TooltipInfo",
		"Constants",
		"Enum",
		"GetGameMessageInfo",
		"GetNormalizedRealmName",
		"GetQuestID",
		"GetQuestLink",
		"GetRealmName",
		"GetTime",
		"IsInGroup",
		"IsInRaid",
		"LE_PARTY_CATEGORY_HOME",
		"NameUtil",
		"QuestLogPushQuest",
		"UnitAffectingCombat",
		"UnitClass",
		"UnitExists",
		"UnitGUID",
		"UnitIsConnected",
		"UnitName",
		-- Global strings and constants.
		"COMPLETE",
		"RAID_CLASS_COLORS",
		"UNKNOWNOBJECT",
		-- Optional addons.
		"EllesmereUI",
	},
}

files["tests/**/*.lua"] = {
	globals = { "ROOT_DIR", "HARNESS_DIR", "describe", "it", "expect", "Harness" },
	read_globals = { "newproxy" },
	ignore = { "631" }, -- long literal lines in fixtures are fine
}
