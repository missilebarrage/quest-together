local _, ns = ...

--- Options > AddOns > Quest Together, built with Blizzard's native settings controls
--- (searchable, with a working Defaults button). Settings live in QuestTogetherDB.settings.
---@class QTOptions
local Options = ns.Options
local Database = ns.Database
local Events = ns.Events
local L = ns.L

local category ---@type table?
-- Setting objects by setting key, so the panel shows changes made elsewhere (the progress
-- panel's menu, slash commands).
local settings = {} ---@type table<string, table[]>
local notifying = false

local function Track(key, setting)
	settings[key] = settings[key] or {}
	table.insert(settings[key], setting)
end

local function Register(key, varType, name)
	local setting = Settings.RegisterAddOnSetting(
		category,
		"QUESTTOGETHER_" .. key,
		key,
		Database.Settings(),
		varType,
		name,
		Database.DEFAULTS[key]
	)
	-- Route changes through Database.Set so the rest of the addon hears about them.
	setting:SetValueChangedCallback(function(_, value)
		if not notifying then
			Database.Set(key, value)
		end
	end)
	Track(key, setting)
	return setting
end

local function Checkbox(key, name, tooltip)
	Settings.CreateCheckbox(category, Register(key, Settings.VarType.Boolean, name), tooltip)
end

local function Dropdown(key, varType, name, tooltip, choices)
	Settings.CreateDropdown(category, Register(key, varType, name), function()
		local container = Settings.CreateControlTextContainer()
		for _, choice in ipairs(choices) do
			container:Add(choice[1], choice[2])
		end
		return container:GetData()
	end, tooltip)
end

-- A slider that shows its value as a percentage; `toPercent` scales the stored value.
local function PercentSlider(key, name, tooltip, minimum, maximum, step, toPercent)
	local options = Settings.CreateSliderOptions(minimum, maximum, step)
	options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
		return string.format("%d%%", value * toPercent + 0.5)
	end)
	Settings.CreateSlider(category, Register(key, Settings.VarType.Number, name), options, tooltip)
end

local function Header(layout, text)
	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
end

local function Build(layout)
	Header(layout, L.OPTIONS_SHARING)
	Checkbox("autoShare", L.OPTION_AUTO_SHARE, L.OPTION_AUTO_SHARE_TOOLTIP)
	Checkbox("autoAccept", L.OPTION_AUTO_ACCEPT, L.OPTION_AUTO_ACCEPT_TOOLTIP)
	layout:AddInitializer(CreateSettingsButtonInitializer(L.OPTION_SHARE_MISSING, L.SHARE, function()
		ns.Share.ShareMissing()
	end, L.OPTION_SHARE_MISSING_TOOLTIP, true))

	Header(layout, L.OPTIONS_CHAT)
	Checkbox("announceObjectives", L.OPTION_ANNOUNCE_OBJECTIVES, L.OPTION_ANNOUNCE_OBJECTIVES_TOOLTIP)
	Checkbox("announceQuests", L.OPTION_ANNOUNCE_QUESTS, L.OPTION_ANNOUNCE_QUESTS_TOOLTIP)

	Header(layout, L.OPTIONS_PANEL)
	Checkbox("panelEnabled", L.OPTION_PANEL, L.OPTION_PANEL_TOOLTIP)
	Dropdown("panelMode", Settings.VarType.String, L.OPTION_PANEL_MODE, L.OPTION_PANEL_MODE_TOOLTIP, {
		{ "areas", L.MODE_AREAS },
		{ "zone", L.MODE_ZONE },
		{ "all", L.MODE_ALL },
	})
	PercentSlider("panelScale", L.OPTION_PANEL_SCALE, L.OPTION_PANEL_SCALE_TOOLTIP, 0.75, 1.5, 0.05, 100)
	PercentSlider("panelOpacity", L.OPTION_PANEL_OPACITY, L.OPTION_PANEL_OPACITY_TOOLTIP, 0, 100, 5, 1)
	layout:AddInitializer(CreateSettingsButtonInitializer(L.OPTION_PREVIEW, L.PREVIEW, function()
		ns.Panel.Preview()
	end, L.OPTION_PREVIEW_TOOLTIP, true))
end

-- A setting changed somewhere else: the panel's controls read their values again. Their
-- change callbacks run too and are told not to store the value a second time.
Events.On("QT_SETTINGS_CHANGED", function(key)
	if notifying then
		return
	end
	notifying = true
	for _, setting in ipairs(settings[key] or {}) do
		setting:NotifyUpdate()
	end
	notifying = false
end)

--- Registers the options page. Called at PLAYER_LOGIN.
function Options.Init()
	local layout
	category, layout = Settings.RegisterVerticalLayoutCategory(L.ADDON_TITLE)
	Build(layout)
	Settings.RegisterAddOnCategory(category)
end

--- Opens Options > AddOns > Quest Together (not possible during combat).
function Options.Open()
	if InCombatLockdown() then
		ns.Print(L.OPTIONS_IN_COMBAT)
		return
	end
	if category then
		Settings.OpenToCategory(category:GetID())
	end
end
