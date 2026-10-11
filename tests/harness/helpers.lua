-- Shortcuts for driving the fake game in tests.

local Helpers = {}

local function ObjectiveText(objective)
	if objective.plain then
		return objective.label
	end
	return string.format("%d/%d %s", objective.numFulfilled, objective.numRequired, objective.label)
end

--- A quest table for world.questLog. Objectives are { label, required, fulfilled?, plain? }
--- and show the way Forever writes them: "2/6 Boar Tusk".
---@param questID integer
---@param title string
---@param objectives table[]?
---@param extra table? more fields (pushable, isOnMap, complete, failed)
function Helpers.Quest(questID, title, objectives, extra)
	local quest = { questID = questID, title = title, objectives = {} }
	for index, spec in ipairs(objectives or {}) do
		local objective = {
			label = spec[1],
			numRequired = spec[2] or 1,
			numFulfilled = spec[3] or 0,
			plain = spec.plain,
			type = spec.type or "monster",
		}
		objective.finished = objective.numFulfilled >= objective.numRequired
		objective.text = ObjectiveText(objective)
		quest.objectives[index] = objective
	end
	for key, value in pairs(extra or {}) do
		quest[key] = value
	end
	return quest
end

--- Puts a quest in the log as if it had just been accepted.
function Helpers.Accept(world, quest)
	world.questLog[#world.questLog + 1] = quest
	world:Fire("QUEST_ACCEPTED", quest.questID)
	world:Fire("QUEST_LOG_UPDATE")
	return quest
end

--- Puts a quest in the log without any events (for logs that exist before login).
function Helpers.Have(world, quest)
	world.questLog[#world.questLog + 1] = quest
	return quest
end

--- Sets an objective's count the way the game would, then lets the addon scan.
function Helpers.Progress(world, questID, index, fulfilled, options)
	local quest = assert(world:Quest(questID), "no quest " .. questID)
	local objective = quest.objectives[index]
	objective.numFulfilled = fulfilled
	objective.finished = fulfilled >= objective.numRequired
	if options and options.finished ~= nil then
		objective.finished = options.finished
	end
	objective.text = ObjectiveText(objective)
	world:Fire("QUEST_LOG_UPDATE")
	world:Fire("UNIT_QUEST_LOG_CHANGED", "player")
	world:Advance(0.5)
end

--- Takes a quest out of the log (turned in or abandoned).
function Helpers.Remove(world, questID)
	local _, index = world:Quest(questID)
	table.remove(world.questLog, index)
	world:Fire("QUEST_REMOVED", questID, false)
	world:Fire("QUEST_LOG_UPDATE")
	world:Advance(0.5)
end

local CLASSES = { "PALADIN", "MAGE", "PRIEST", "SHAMAN" }

--- Unit data for a party member.
---@param slot integer
---@param name string
---@param extra table? more fields (surname, class, quests, connected, guid)
function Helpers.Member(slot, name, extra)
	local member = {
		name = name,
		surname = "Party" .. slot,
		guid = string.format("Player-1-0000%04X", 0x100 + slot),
		class = CLASSES[slot] or "WARRIOR",
		quests = {},
	}
	for key, value in pairs(extra or {}) do
		member[key] = value
	end
	return member
end

--- Puts the player in a party with these members (unit data from Helpers.Member).
function Helpers.JoinParty(world, members, kind)
	world.group = kind or "party"
	for slot = 1, 4 do
		world.units["party" .. slot] = members[slot]
	end
	world:Fire("GROUP_ROSTER_UPDATE")
	world:Advance(0.5)
end

function Helpers.LeaveParty(world)
	world.group = nil
	for slot = 1, 4 do
		world.units["party" .. slot] = nil
	end
	world:Fire("GROUP_ROSTER_UPDATE")
	world:Advance(0.5)
end

--- The standard three-member party used by many tests: Thrall, Jaina, Anduin.
function Helpers.Party(world)
	local members = {
		Helpers.Member(1, "Thrall"),
		Helpers.Member(2, "Jaina"),
		Helpers.Member(3, "Anduin"),
	}
	Helpers.JoinParty(world, members)
	return members
end

--- Simulates the game's answer to a quest share, as a UI info message (or system chat).
function Helpers.PushResult(world, name, who, viaChat)
	local Wow = Harness.Wow
	local message = Wow.PUSH_STRINGS[name]:format(who)
	if viaChat then
		world:Fire("CHAT_MSG_SYSTEM", message)
	else
		world:Fire("UI_INFO_MESSAGE", Wow.MESSAGE_TYPES[name], message)
	end
end

--- A message from a party member's addon.
function Helpers.AddonMessage(world, sender, text)
	world:Fire("CHAT_MSG_ADDON", "QuestTogether", text, "PARTY", sender, "", 0, 0, "", 0)
end

--- The addon messages the player sent, as strings.
function Helpers.Sent(world)
	local list = {}
	for _, entry in ipairs(world.addonSent) do
		list[#list + 1] = entry.text
	end
	return list
end

--- Opens the panel's right-click menu and returns its entries.
function Helpers.OpenMenu(world)
	local panel = world.env.QuestTogetherPanel
	panel:GetScript("OnClick")(panel, "RightButton")
	return world.menus[#world.menus].entries
end

function Helpers.FindEntry(entries, text)
	for _, entry in ipairs(entries) do
		if entry.text == text then
			return entry
		end
	end
end

return Helpers
