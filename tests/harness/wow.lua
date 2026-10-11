-- Fake WoW client: a table-driven "world" (clock, player, party, quest log, chat...) plus the
-- game API functions the addon calls, installed into a sandbox environment.

local Widgets = dofile(HARNESS_DIR .. "/widgets.lua")

local Wow = {}

-- Tooltip methods.
Widgets.Define("SetOwner", function(self, owner, anchor)
	self.owner, self.anchor = owner, anchor
	self.lines = {}
end)
Widgets.Define("AddLine AddDoubleLine", function(self, ...)
	self.lines = self.lines or {}
	self.lines[#self.lines + 1] = { ... }
end)
Widgets.Define("ClearLines", function(self)
	self.lines = {}
end)
Widgets.Define("NumLines", function(self)
	return #(self.lines or {})
end)

--- A value the game would hide from addons. Any attempt to inspect it raises.
local SECRET = newproxy(true)
do
	local meta = getmetatable(SECRET)
	local function Forbidden()
		error("attempt to inspect a secret value", 2)
	end
	meta.__index = Forbidden
	meta.__newindex = Forbidden
	meta.__call = Forbidden
	meta.__concat = Forbidden
	meta.__add = Forbidden
	meta.__sub = Forbidden
	meta.__mul = Forbidden
	meta.__div = Forbidden
	meta.__unm = Forbidden
	meta.__lt = Forbidden
	meta.__le = Forbidden
	meta.__len = Forbidden
	meta.__tostring = Forbidden
end
Wow.SECRET = SECRET

-- The client's English quest-share answers.
local PUSH_STRINGS = {
	ERR_QUEST_PUSH_SUCCESS_S = "Sharing quest with %s...",
	ERR_QUEST_PUSH_ACCEPTED_S = "%s has accepted your quest.",
	ERR_QUEST_PUSH_DECLINED_S = "%s has declined your quest.",
	ERR_QUEST_PUSH_BUSY_S = "%s is busy.",
	ERR_QUEST_PUSH_ONQUEST_S = "%s is already on that quest.",
	ERR_QUEST_PUSH_ALREADY_DONE_S = "%s has completed that quest.",
	ERR_QUEST_PUSH_INVALID_S = "%s is not eligible for that quest.",
	ERR_QUEST_PUSH_LOG_FULL_S = "%s's quest log is full.",
	ERR_QUEST_PUSH_TOO_FAR_S = "%s is too far away to receive your quest.",
	ERR_QUEST_PUSH_NOT_IN_PARTY_S = "You're not in a party.",
	ERR_QUEST_PUSH_LOW_LEVEL_S = "%s is too low level for that quest.",
}
Wow.PUSH_STRINGS = PUSH_STRINGS

-- Game message types (UI_INFO_MESSAGE's first argument) for the share answers.
local MESSAGE_TYPES = {}
do
	local names = {}
	for name in pairs(PUSH_STRINGS) do
		names[#names + 1] = name
	end
	table.sort(names)
	for index, name in ipairs(names) do
		MESSAGE_TYPES[name] = 600 + index
	end
end
Wow.MESSAGE_TYPES = MESSAGE_TYPES

local GLOBAL_STRINGS = {
	COMPLETE = "Complete",
	UNKNOWNOBJECT = "Unknown",
}
for name, text in pairs(PUSH_STRINGS) do
	GLOBAL_STRINGS[name] = text
end

local CLASS_COLORS = {
	WARRIOR = { r = 0.78, g = 0.61, b = 0.43 },
	MAGE = { r = 0.25, g = 0.78, b = 0.92 },
	PRIEST = { r = 1, g = 1, b = 1 },
	SHAMAN = { r = 0, g = 0.44, b = 0.87 },
	PALADIN = { r = 0.96, g = 0.55, b = 0.73 },
}

local World = {}
World.__index = World

---@return table world
function Wow.NewWorld(options)
	options = options or {}
	local world = setmetatable({
		options = options,
		clock = { server = options.now or 1790000000, uptime = 5000 },
		timers = {},
		nextTimerId = 0,
		eventFrames = {},
		unknownEvents = {},
		createdObjects = 0,
		errors = {},
		printed = {},
		player = {
			guid = "Player-1-0000AAAA",
			name = "Tester",
			surname = "Example",
			realm = "TestRealm",
			class = "WARRIOR",
		},
		units = {},
		group = nil, -- nil | "party" | "raid"
		questLog = {}, -- entries: { header = true, title } or quest tables (see helpers)
		loadingQuests = {}, -- quest IDs whose data hasn't loaded (GetQuestObjectives returns nil)
		requestedQuests = {},
		blobs = {}, -- quest ID -> the player stands in its area
		chatSent = {},
		chatLockdown = false,
		prefixes = {},
		addonSent = {},
		sendResults = {},
		pushes = {},
		accepted = {},
		questDetail = nil,
		partyProgress = {}, -- quest ID -> tooltip lines
		loadedAddons = {},
		missingFiles = {},
		missingFonts = {},
		settingsCategories = {},
		openedSettings = {},
		menus = {},
		combat = false,
		accentCallbacks = {},
	}, World)
	return world
end

--- Fires a game event at every frame that registered it.
function World:Fire(event, ...)
	local frames = self.eventFrames[event]
	if not frames then
		return
	end
	-- Snapshot first: handlers may register or unregister while dispatching.
	local list = {}
	for frame in pairs(frames) do
		list[#list + 1] = frame
	end
	for _, frame in ipairs(list) do
		Widgets.RunScript(frame, "OnEvent", event, ...)
	end
end

--- Advances both clocks and runs every timer that comes due, in order.
function World:Advance(seconds)
	local target = self.clock.uptime + seconds
	while true do
		local nextTimer
		for _, timer in ipairs(self.timers) do
			if not timer.cancelled and timer.due <= target and (not nextTimer or timer.due < nextTimer.due) then
				nextTimer = timer
			end
		end
		if not nextTimer then
			break
		end
		local delta = nextTimer.due - self.clock.uptime
		self.clock.uptime = nextTimer.due
		self.clock.server = self.clock.server + delta
		if nextTimer.interval then
			nextTimer.due = nextTimer.due + nextTimer.interval
			nextTimer.remaining = nextTimer.remaining and nextTimer.remaining - 1
			if nextTimer.remaining == 0 then
				nextTimer.cancelled = true
			end
		else
			nextTimer.cancelled = true
		end
		nextTimer.callback(nextTimer.handle)
	end
	self.clock.server = self.clock.server + (target - self.clock.uptime)
	self.clock.uptime = target
	-- Drop finished timers so long tests stay fast.
	local kept = {}
	for _, timer in ipairs(self.timers) do
		if not timer.cancelled then
			kept[#kept + 1] = timer
		end
	end
	self.timers = kept
end

--- Number of timers still waiting to run.
function World:PendingTimers()
	local count = 0
	for _, timer in ipairs(self.timers) do
		if not timer.cancelled then
			count = count + 1
		end
	end
	return count
end

--- The quest table for an ID, and its log index.
function World:Quest(questID)
	for index, entry in ipairs(self.questLog) do
		if entry.questID == questID then
			return entry, index
		end
	end
end

--- Lines the addon posted in chat, as plain strings.
function World:ChatLines()
	local lines = {}
	for _, entry in ipairs(self.chatSent) do
		lines[#lines + 1] = entry.text
	end
	return lines
end

--- Everything the addon printed, joined.
function World:Output()
	return table.concat(self.printed, "\n")
end

local function Copy(source, into)
	into = into or {}
	for key, value in pairs(source) do
		into[key] = value
	end
	return into
end

local function QuestComplete(quest)
	if quest.complete ~= nil then
		return quest.complete
	end
	if #quest.objectives == 0 then
		return true
	end
	for _, objective in ipairs(quest.objectives) do
		if not objective.finished then
			return false
		end
	end
	return true
end

--- Builds a sandbox environment exposing the fake API backed by the given world.
function Wow.CreateEnvironment(world)
	local options = world.options
	local env = {}
	world.env = env

	-- Lua standard library (no io/os/require/load*: addons can't use them either).
	for _, name in ipairs({
		"assert",
		"error",
		"ipairs",
		"next",
		"pairs",
		"pcall",
		"rawequal",
		"rawget",
		"rawset",
		"select",
		"setmetatable",
		"getmetatable",
		"tonumber",
		"tostring",
		"type",
		"unpack",
		"xpcall",
		"newproxy",
	}) do
		env[name] = _G[name]
	end
	env.string = Copy(string)
	env.table = Copy(table)
	env.math = Copy(math)
	env.math.random = function(low, high)
		world.randomState = ((world.randomState or options.seed or 12345) * 1103515245 + 12345) % 2147483648
		local fraction = world.randomState / 2147483648
		if not low then
			return fraction
		elseif not high then
			low, high = 1, low
		end
		return low + math.floor(fraction * (high - low + 1))
	end
	env._G = env
	env.print = function(...)
		local parts = {}
		for index = 1, select("#", ...) do
			parts[#parts + 1] = tostring((select(index, ...)))
		end
		world.printed[#world.printed + 1] = table.concat(parts, " ")
	end
	env.debugprofilestop = function()
		return os.clock() * 1000
	end
	env.wipe = function(t)
		for key in pairs(t) do
			t[key] = nil
		end
		return t
	end

	for name, value in pairs(GLOBAL_STRINGS) do
		env[name] = value
	end

	-- Secrets and error isolation.
	env.issecretvalue = function(value)
		return rawequal(value, SECRET)
	end
	env.securecallfunction = function(fn, ...)
		local results = { pcall(fn, ...) }
		if not results[1] then
			world.errors[#world.errors + 1] = results[2]
			return
		end
		return unpack(results, 2, table.maxn(results))
	end

	-- Time.
	env.GetTime = function()
		return world.clock.uptime
	end
	env.C_Timer = {}
	local function AddTimer(delay, callback, interval, iterations)
		world.nextTimerId = world.nextTimerId + 1
		local timer = {
			id = world.nextTimerId,
			due = world.clock.uptime + delay,
			callback = callback,
			interval = interval,
			remaining = iterations,
		}
		local handle = {
			Cancel = function()
				timer.cancelled = true
			end,
			IsCancelled = function()
				return timer.cancelled == true
			end,
		}
		timer.handle = handle
		world.timers[#world.timers + 1] = timer
		return handle
	end
	env.C_Timer.After = function(delay, callback)
		AddTimer(delay, callback)
	end
	env.C_Timer.NewTimer = function(delay, callback)
		return AddTimer(delay, callback)
	end
	env.C_Timer.NewTicker = function(interval, callback, iterations)
		return AddTimer(interval, callback, interval, iterations)
	end

	-- Frames.
	env.CreateFrame = function(frameType, name, parent, template)
		local frame = Widgets.Create(world, frameType, name, parent, { template = template })
		if name then
			env[name] = frame
		end
		return frame
	end
	env.UIParent = Widgets.Create(world, "Frame", "UIParent")
	env.UIParent.width, env.UIParent.height = 1920, 1080
	env.GameTooltip = Widgets.Create(world, "GameTooltip", "GameTooltip")
	env.GameTooltip.shown = false
	env.SlashCmdList = {}
	env.CreateFont = function(name)
		local font = { name = name }
		-- Like the client: no return value, and an error for a font file that can't load.
		function font:SetFont(path, size, flags)
			if world.missingFonts[path] then
				error("invalid font asset")
			end
			self.path, self.size, self.flags = path, size, flags
		end
		function font:GetFont()
			return self.path, self.size, self.flags
		end
		function font:SetShadowColor() end
		function font:SetShadowOffset() end
		if name then
			env[name] = font
		end
		return font
	end
	env.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
	env.PixelUtil = {
		GetPixelToUIUnitFactor = function()
			return 1
		end,
	}
	env.GetFileIDFromPath = function(path)
		if world.missingFiles[path] then
			return nil
		end
		return 100000 + #path
	end
	env.InCombatLockdown = function()
		return world.combat
	end
	env.UnitAffectingCombat = function(unit)
		return unit == "player" and world.combat
	end
	env.IsShiftKeyDown = function()
		return world.shiftDown == true
	end
	env.GetBuildInfo = function()
		return "1.60.1", "70338", "Oct 1 2026", 16001
	end

	-- Settings panel.
	env.Settings = {
		VarType = { Boolean = "boolean", Number = "number", String = "string" },
		RegisterVerticalLayoutCategory = function(name)
			local category = { name = name, settings = {}, initializers = {} }
			function category:GetID()
				return 77
			end
			local layout = {}
			function layout:AddInitializer(initializer)
				category.initializers[#category.initializers + 1] = initializer
			end
			world.settingsCategories[#world.settingsCategories + 1] = category
			return category, layout
		end,
		RegisterAddOnCategory = function(category)
			category.registered = true
		end,
		RegisterAddOnSetting = function(category, variable, variableKey, variableTbl, variableType, name, default)
			local setting = {
				variable = variable,
				key = variableKey,
				table = variableTbl,
				type = variableType,
				name = name,
				default = default,
			}
			function setting:SetValueChangedCallback(callback)
				self.callback = callback
			end
			function setting:SetValue(value)
				variableTbl[variableKey] = value
				if self.callback then
					self.callback(self, value)
				end
			end
			function setting:GetValue()
				return variableTbl[variableKey]
			end
			-- Like Blizzard's: tells listeners (the control and the change callback) to read
			-- the value again.
			function setting:NotifyUpdate()
				self.notified = (self.notified or 0) + 1
				if self.callback then
					self.callback(self, variableTbl[variableKey])
				end
			end
			category.settings[variableKey] = setting
			return setting
		end,
		CreateCheckbox = function(_, setting)
			setting.control = "checkbox"
		end,
		CreateSlider = function(_, setting, sliderOptions)
			setting.control = "slider"
			setting.options = sliderOptions
		end,
		CreateDropdown = function(_, setting, getOptions)
			setting.control = "dropdown"
			setting.getOptions = getOptions
		end,
		CreateSliderOptions = function(minimum, maximum, step)
			local sliderOptions = { minimum = minimum, maximum = maximum, step = step }
			function sliderOptions:SetLabelFormatter(_, formatter)
				self.formatter = formatter
			end
			return sliderOptions
		end,
		CreateControlTextContainer = function()
			local container = { data = {} }
			function container:Add(value, label)
				self.data[#self.data + 1] = { value = value, label = label }
			end
			function container:GetData()
				return self.data
			end
			return container
		end,
		OpenToCategory = function(categoryID)
			world.openedSettings[#world.openedSettings + 1] = categoryID
		end,
	}
	env.CreateSettingsListSectionHeaderInitializer = function(name)
		return { kind = "header", name = name }
	end
	env.CreateSettingsButtonInitializer = function(name, buttonText, click)
		return { kind = "button", name = name, buttonText = buttonText, click = click }
	end
	env.MinimalSliderWithSteppersMixin = { Label = { Left = 1, Right = 2 } }

	-- Units and the group.
	local function Unit(unit)
		if unit == "player" then
			return world.player
		end
		return world.units[unit]
	end
	env.UnitExists = function(unit)
		return Unit(unit) ~= nil
	end
	env.UnitGUID = function(unit)
		local data = Unit(unit)
		return data and data.guid
	end
	-- Forever (Camelot): the second value is the surname, not a realm.
	env.UnitName = function(unit)
		local data = Unit(unit)
		if data then
			return data.name, data.surname
		end
	end
	env.UnitClass = function(unit)
		local data = Unit(unit)
		if data and data.class then
			return data.class:sub(1, 1) .. data.class:sub(2):lower(), data.class, 1
		end
	end
	env.UnitIsConnected = function(unit)
		local data = Unit(unit)
		return data ~= nil and data.connected ~= false
	end
	env.C_ClassColor = {
		GetClassColor = function(classFile)
			return CLASS_COLORS[classFile]
		end,
	}
	env.NameUtil = {
		FormatUnitNameForDisplay = function(unit)
			local name, surname = env.UnitName(unit)
			return surname and (name .. " " .. surname) or name
		end,
	}
	env.GetRealmName = function()
		return world.player.realm
	end
	env.GetNormalizedRealmName = function()
		return world.player.realm
	end
	env.IsInGroup = function()
		return world.group ~= nil
	end
	env.IsInRaid = function()
		return world.group == "raid"
	end
	env.Constants = {
		CharacterNameSeparatorConsts = { CHARACTERNAME_SURNAME_SEPARATOR = " " },
	}

	-- Quest log.
	local function Objectives(quest)
		local list = {}
		for index, objective in ipairs(quest.objectives) do
			list[index] = {
				text = objective.text,
				type = objective.type or "monster",
				finished = objective.finished == true,
				numFulfilled = objective.numFulfilled,
				numRequired = objective.numRequired,
			}
		end
		return list
	end
	env.C_QuestLog = {
		GetNumQuestLogEntries = function()
			local quests = 0
			for _, entry in ipairs(world.questLog) do
				if entry.questID then
					quests = quests + 1
				end
			end
			return #world.questLog, quests
		end,
		GetInfo = function(index)
			local entry = world.questLog[index]
			if not entry then
				return nil
			end
			return {
				title = entry.title,
				questID = entry.questID or 0,
				isHeader = entry.header == true,
				isHidden = entry.hidden == true,
				isOnMap = entry.isOnMap ~= false,
				hasLocalPOI = entry.isOnMap ~= false,
			}
		end,
		GetTitleForQuestID = function(questID)
			local quest = world:Quest(questID)
			if quest and not world.loadingQuests[questID] then
				return quest.title
			end
		end,
		GetQuestObjectives = function(questID)
			local quest = world:Quest(questID)
			if not quest or world.loadingQuests[questID] then
				return nil
			end
			return Objectives(quest)
		end,
		IsComplete = function(questID)
			local quest = world:Quest(questID)
			return quest ~= nil and not quest.failed and QuestComplete(quest)
		end,
		ReadyForTurnIn = function(questID)
			local quest = world:Quest(questID)
			return quest ~= nil and not quest.failed and QuestComplete(quest)
		end,
		IsFailed = function(questID)
			local quest = world:Quest(questID)
			return quest ~= nil and quest.failed == true
		end,
		IsOnQuest = function(questID)
			return world:Quest(questID) ~= nil
		end,
		IsPushableQuest = function(questID)
			local quest = world:Quest(questID)
			return quest ~= nil and quest.pushable ~= false
		end,
		GetLogIndexForQuestID = function(questID)
			local _, index = world:Quest(questID)
			return index
		end,
		RequestLoadQuestByID = function(questID)
			world.requestedQuests[#world.requestedQuests + 1] = questID
		end,
		GetSelectedQuest = function()
			return world.selectedQuest or 0
		end,
		SetSelectedQuest = function(questID)
			world.selectedQuest = questID
		end,
	}
	if not options.noUnitOnQuest then
		env.C_QuestLog.IsUnitOnQuest = function(unit, questID)
			local data = Unit(unit)
			if not data or world.unitOnQuestUnknown then
				return false
			end
			if data.onQuest then
				return data.onQuest(questID) == true
			end
			return data.quests ~= nil and data.quests[questID] == true
		end
	end
	env.GetQuestLink = function(questID)
		local quest = world:Quest(questID)
		if quest and not options.noQuestLinks then
			return string.format("|cffffff00|Hquest:%d:10|h[%s]|h|r", questID, quest.title)
		end
	end
	env.QuestLogPushQuest = function(logIndex)
		local entry = world.questLog[logIndex]
		-- A blocked call doesn't run; the client reports it instead.
		if world.blockPush then
			world:Fire("ADDON_ACTION_BLOCKED", "QuestTogether", "QuestLogPushQuest()")
			return
		end
		world.pushes[#world.pushes + 1] = {
			questID = entry and entry.questID,
			selected = world.selectedQuest,
			at = world.clock.uptime,
		}
	end
	env.GetQuestID = function()
		return world.questDetail and world.questDetail.questID or 0
	end
	env.AcceptQuest = function()
		world.accepted[#world.accepted + 1] = world.questDetail and world.questDetail.questID
		if world.onAcceptQuest then
			world.onAcceptQuest(world.questDetail)
		end
	end

	-- Quest areas.
	if not options.noBlobApi then
		env.C_Minimap = {
			IsInsideQuestBlob = function(questID)
				return world.blobs[questID] == true
			end,
		}
	end

	-- The game's own party progress (quest tooltips).
	env.C_TooltipInfo = {
		GetQuestPartyProgress = function(questID)
			local lines = world.partyProgress[questID]
			return lines and { lines = lines } or nil
		end,
	}

	-- Chat and addon messages.
	env.C_ChatInfo = {
		SendChatMessage = function(text, chatType)
			assert(#text <= 255, "chat message too long")
			if world.blockChat then
				world:Fire("ADDON_ACTION_BLOCKED", "QuestTogether", "C_ChatInfo.SendChatMessage()")
				return
			end
			world.chatSent[#world.chatSent + 1] = { text = text, channel = chatType }
		end,
		InChatMessagingLockdown = function()
			return world.chatLockdown
		end,
		RegisterAddonMessagePrefix = function(prefix)
			assert(#prefix <= 16, "prefix too long")
			world.prefixes[prefix] = true
			return 0
		end,
		SendAddonMessage = function(prefix, message, chatType, target)
			assert(#message <= 255, "addon message too long: " .. #message)
			assert(world.prefixes[prefix], "prefix not registered")
			local result = table.remove(world.sendResults, 1) or (world.group and 0 or 5)
			if result == 0 then
				world.addonSent[#world.addonSent + 1] = {
					prefix = prefix,
					text = message,
					channel = chatType,
					target = target,
				}
			end
			return result
		end,
	}
	env.GetGameMessageInfo = function(messageType)
		for name, value in pairs(MESSAGE_TYPES) do
			if value == messageType then
				return name
			end
		end
	end

	-- Context menus (Blizzard_Menu): the generator runs at once and the entries are kept, so
	-- tests can read them and pick checkboxes, radios and buttons.
	env.MenuUtil = {
		CreateContextMenu = function(owner, generator)
			local menu = { owner = owner, entries = {} }
			local root = {}
			local function Add(entry)
				menu.entries[#menu.entries + 1] = entry
				function entry.SetEnabled(self, enabled)
					self.disabled = not enabled
				end
				return entry
			end
			function root.CreateTitle(_, text)
				return Add({ kind = "title", text = text })
			end
			function root.CreateDivider()
				return Add({ kind = "divider" })
			end
			function root.CreateButton(_, text, callback, data)
				return Add({ kind = "button", text = text, callback = callback, data = data })
			end
			function root.CreateCheckbox(_, text, isSelected, setSelected, data)
				return Add({
					kind = "checkbox",
					text = text,
					isSelected = isSelected,
					setSelected = setSelected,
					data = data,
				})
			end
			function root.CreateRadio(_, text, isSelected, setSelected, data)
				return Add({
					kind = "radio",
					text = text,
					isSelected = isSelected,
					setSelected = setSelected,
					data = data,
				})
			end
			generator(owner, root)
			world.menus[#world.menus + 1] = menu
			return menu
		end,
	}

	env.Enum = {
		SendAddonMessageResult = {
			Success = 0,
			AddonMessageThrottle = 3,
			NotInGroup = 5,
			ChannelThrottle = 8,
			AddOnMessageLockdown = 11,
		},
		TooltipDataLineType = { QuestObjective = 8, QuestTitle = 17, QuestPlayer = 18 },
	}

	env.C_AddOns = {
		GetAddOnMetadata = function(_, field)
			if field == "Version" then
				return options.version or "@project-version@"
			end
		end,
		IsAddOnLoaded = function(name)
			return world.loadedAddons[name] == true
		end,
	}

	if options.ellesmere then
		world.loadedAddons.EllesmereUI = true
		env.EllesmereUI = {
			GetAccentColor = function()
				return 0.2, 0.4, 0.6
			end,
			RegAccent = function(entry)
				world.accentCallbacks[#world.accentCallbacks + 1] = entry.fn
			end,
			GetFontPath = function()
				return "Fonts\\Expressway.ttf"
			end,
		}
	end

	world.baselineGlobals = {}
	for key in pairs(env) do
		world.baselineGlobals[key] = true
	end
	return env
end

--- Globals the addon created that it isn't allowed to.
function World:LeakedGlobals(allowed)
	local leaked = {}
	for key in pairs(self.env) do
		if not self.baselineGlobals[key] and not allowed[key] then
			leaked[#leaked + 1] = key
		end
	end
	table.sort(leaked)
	return leaked
end

-- Saved variables round trip -------------------------------------------------------

local function SerializeSaved(value)
	local kind = type(value)
	if kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			error("non-finite number in saved variables")
		end
		return string.format("%.17g", value)
	elseif kind == "string" then
		return string.format("%q", value)
	elseif kind == "boolean" then
		return tostring(value)
	elseif kind == "table" then
		local parts = {}
		for key, inner in pairs(value) do
			if type(key) ~= "string" and type(key) ~= "number" then
				error("unsupported key type in saved variables: " .. type(key))
			end
			parts[#parts + 1] = "[" .. SerializeSaved(key) .. "]=" .. SerializeSaved(inner)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error("cannot save a " .. kind)
end

--- Writes a saved variable out and reads it back, the way the client does at logout.
function Wow.RoundTrip(value)
	if value == nil then
		return nil
	end
	local chunk = assert(loadstring("return " .. SerializeSaved(value)))
	return chunk()
end

Wow.World = World
return Wow
