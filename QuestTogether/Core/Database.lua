local _, ns = ...

--- SavedVariables: QuestTogetherDB holds the account-wide settings and the panel position.
--- Data written by a newer version is never modified: the addon runs on defaults and warns.
---@class QTDatabase
local Database = ns.Database
local Events = ns.Events
local L = ns.L

--- Default values for every setting. Keys here are the only settings the addon knows about.
Database.DEFAULTS = {
	autoShare = true,
	autoAccept = false,
	announceObjectives = true,
	announceQuests = true,
	panelEnabled = true,
	panelMode = "areas", -- "areas" | "zone" | "all"
	panelScale = 1,
	panelOpacity = 90, -- background and border, in percent
}

-- Settings that only take one of a few values.
local CHOICES = {
	panelMode = { areas = true, zone = true, all = true },
}

-- Numbered migrations: MIGRATIONS[n] upgrades data from schema n - 1 to n.
local MIGRATIONS = {}

local VALID_POINTS = {
	TOPLEFT = true,
	TOP = true,
	TOPRIGHT = true,
	LEFT = true,
	CENTER = true,
	RIGHT = true,
	BOTTOMLEFT = true,
	BOTTOM = true,
	BOTTOMRIGHT = true,
}

local account ---@type table
local readOnly = false

local function FillDefaults(settings)
	for key, default in pairs(Database.DEFAULTS) do
		local value = settings[key]
		if type(value) ~= type(default) or (CHOICES[key] and not CHOICES[key][value]) then
			settings[key] = default
		end
	end
end

--- Upgrades data in place. Returns false when the data is unusable or newer than this
--- version understands.
local function Upgrade(data)
	if type(data) ~= "table" then
		return false
	end
	local schema = data.schema
	if type(schema) ~= "number" or schema > ns.SCHEMA then
		return false
	end
	for version = schema + 1, ns.SCHEMA do
		if MIGRATIONS[version] then
			MIGRATIONS[version](data)
		end
		data.schema = version
	end
	return true
end

--- Loads the saved variables. Called once, at ADDON_LOADED.
function Database.Init()
	if QuestTogetherDB == nil then
		QuestTogetherDB = { schema = ns.SCHEMA }
	end
	if Upgrade(QuestTogetherDB) then
		account = QuestTogetherDB
	else
		readOnly = true
		account = { schema = ns.SCHEMA }
		ns.Print(L.DATA_FROM_NEWER_VERSION)
	end
	if type(account.settings) ~= "table" then
		account.settings = {}
	end
	if type(account.windows) ~= "table" then
		account.windows = {}
	end
	if type(account.notices) ~= "table" then
		account.notices = {}
	end
	FillDefaults(account.settings)
end

--- True the first time it's asked about a one-time notice, false ever after.
---@param key string
---@return boolean
function Database.FirstTime(key)
	if account.notices[key] then
		return false
	end
	account.notices[key] = true
	return true
end

---@return boolean
function Database.IsReadOnly()
	return readOnly
end

--- The live settings table (also handed to the Blizzard Settings panel).
---@return table
function Database.Settings()
	return account.settings
end

function Database.Get(key)
	return account.settings[key]
end

--- Stores a setting and notifies listeners with QT_SETTINGS_CHANGED(key, value).
function Database.Set(key, value)
	account.settings[key] = value
	Events.Fire("QT_SETTINGS_CHANGED", key, value)
end

--- Remembers where a window was dragged to.
---@param key string
---@param frame table
function Database.SavePosition(key, frame)
	local point, _, relativePoint, x, y = frame:GetPoint(1)
	if not point then
		return
	end
	account.windows[key] = { point = point, relativePoint = relativePoint, x = x, y = y }
end

--- Moves a window back to its saved position. Returns false (leaving the frame
--- untouched) when nothing valid was saved.
---@param key string
---@param frame table
---@return boolean
function Database.RestorePosition(key, frame)
	local saved = account.windows[key]
	if type(saved) ~= "table" then
		return false
	end
	local x, y = ns.Num(saved.x), ns.Num(saved.y)
	if not (VALID_POINTS[saved.point] and VALID_POINTS[saved.relativePoint] and x and y) then
		return false
	end
	frame:ClearAllPoints()
	frame:SetPoint(saved.point, UIParent, saved.relativePoint, x, y)
	return true
end
