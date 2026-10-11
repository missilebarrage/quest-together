-- Several fake clients in one party: addon messages, quest shares and their answers travel
-- between them. Members without the addon are simulated by the network itself.

local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")

local Network = {}
Network.__index = Network

local STEP = 0.05
local REALM = "TestRealm"

local function FullName(spec)
	return spec.name .. " " .. spec.surname
end

--- The unit data member j shows to the others.
function Network:Unit(j)
	local spec = self.specs[j]
	return {
		name = spec.name,
		surname = spec.surname,
		guid = spec.guid,
		class = spec.class,
		onQuest = function(questID)
			return self:HasQuest(j, questID)
		end,
	}
end

--- Whether member j has a quest.
function Network:HasQuest(j, questID)
	local client = self.clients[j]
	if client then
		return client.world:Quest(questID) ~= nil
	end
	return self.specs[j].quests[questID] == true
end

--- Boots a party. specs: { name, surname?, class?, addon? (default true), quests? (members
--- without the addon), respond? ("accept" | "decline" | nil: never answers) }.
---@param specs table[]
---@param options table? { resultsViaChat }
function Network.Party(specs, options)
	local net = setmetatable({ specs = specs, clients = {}, options = options or {}, cursors = {} }, Network)
	for index, spec in ipairs(specs) do
		spec.surname = spec.surname or ("Family" .. index)
		spec.guid = spec.guid or string.format("Player-1-0000%04X", 0x200 + index)
		spec.class = spec.class or "WARRIOR"
		spec.quests = spec.quests or {}
		spec.completed = spec.completed or {}
	end
	for index, spec in ipairs(specs) do
		if spec.addon ~= false then
			local world, ns = Harness.Boot({
				seed = 1000 + index * 77,
				settle = false,
				configure = function(world)
					world.player = {
						guid = spec.guid,
						name = spec.name,
						surname = spec.surname,
						realm = REALM,
						class = spec.class,
					}
					world.group = "party"
					local slot = 0
					for other = 1, #specs do
						if other ~= index then
							slot = slot + 1
							world.units["party" .. slot] = net:Unit(other)
						end
					end
				end,
			})
			world.onAcceptQuest = function(detail)
				net:Accepted(index, detail)
			end
			net.clients[index] = { world = world, ns = ns, spec = spec }
			net.cursors[index] = { addon = 0, pushes = 0 }
		end
	end
	net:Advance(6)
	return net
end

--- Member i reloads their interface: a fresh client with the same character, quests and party.
function Network:Reload(i)
	local client = self.clients[i]
	local world, ns = Harness.Restart(client.world, { reload = true, settle = false })
	world.onAcceptQuest = function(detail)
		self:Accepted(i, detail)
	end
	client.world, client.ns = world, ns
	self.cursors[i] = { addon = 0, pushes = 0 }
	return world, ns
end

function Network:World(index)
	return self.clients[index].world
end

function Network:Ns(index)
	return self.clients[index].ns
end

--- The party unit token member j has in member i's client.
function Network:UnitIn(i, j)
	return "party" .. (j < i and j or j - 1)
end

local function Result(net, pusher, name, who)
	local world = net.clients[pusher].world
	Helpers.PushResult(world, name, who, net.options.resultsViaChat)
end

--- Member i shared a quest: everyone else gets it offered or answers.
function Network:Pushed(i, questID)
	local pusherWorld = self.clients[i].world
	local quest = pusherWorld:Quest(questID)
	for j, spec in ipairs(self.specs) do
		if j ~= i then
			local who = FullName(spec)
			Result(self, i, "ERR_QUEST_PUSH_SUCCESS_S", who)
			local client = self.clients[j]
			if self:HasQuest(j, questID) then
				Result(self, i, "ERR_QUEST_PUSH_ONQUEST_S", who)
			elseif spec.completed[questID] then
				Result(self, i, "ERR_QUEST_PUSH_ALREADY_DONE_S", who)
			elseif client then
				local world = client.world
				if world.questDetail then
					Result(self, i, "ERR_QUEST_PUSH_BUSY_S", who)
				else
					world.questDetail = { questID = questID, from = i, quest = quest }
					world.units.questnpc = { guid = self.specs[i].guid, name = self.specs[i].name }
					world:Fire("QUEST_DETAIL")
				end
			elseif spec.respond == "accept" then
				spec.quests[questID] = true
				Result(self, i, "ERR_QUEST_PUSH_ACCEPTED_S", who)
			elseif spec.respond == "decline" then
				Result(self, i, "ERR_QUEST_PUSH_DECLINED_S", who)
			end
		end
	end
end

local function CopyQuest(quest)
	local objectives = {}
	for index, objective in ipairs(quest.objectives) do
		objectives[index] = { objective.label, objective.numRequired, 0, plain = objective.plain }
	end
	return Helpers.Quest(quest.questID, quest.title, objectives)
end

--- Member k accepted the quest in their open dialog (AcceptQuest()).
function Network:Accepted(k, detail)
	local world = self.clients[k].world
	world.questDetail = nil
	world.units.questnpc = nil
	if not detail then
		return
	end
	Helpers.Accept(world, CopyQuest(detail.quest))
	Result(self, detail.from, "ERR_QUEST_PUSH_ACCEPTED_S", FullName(self.specs[k]))
	for i, client in pairs(self.clients) do
		if i ~= k then
			client.world:Fire("UNIT_QUEST_LOG_CHANGED", self:UnitIn(i, k))
		end
	end
end

--- Member k clicks Accept in the open quest dialog.
function Network:Accept(k)
	local world = self.clients[k].world
	world.env.AcceptQuest()
end

--- Member k clicks Decline in the open quest dialog.
function Network:Decline(k)
	local world = self.clients[k].world
	local detail = world.questDetail
	world.questDetail = nil
	world.units.questnpc = nil
	if detail then
		Result(self, detail.from, "ERR_QUEST_PUSH_DECLINED_S", FullName(self.specs[k]))
	end
end

--- Delivers what every client sent since the last step.
function Network:Deliver()
	for i, client in pairs(self.clients) do
		local cursor = self.cursors[i]
		local sent = client.world.addonSent
		while cursor.addon < #sent do
			cursor.addon = cursor.addon + 1
			local message = sent[cursor.addon]
			local sender = FullName(self.specs[i]) .. "-" .. REALM
			if self.options.shortSenders then
				sender = self.specs[i].name .. "-" .. REALM
			end
			for _, receiver in pairs(self.clients) do
				if not self.options.dropMessages then
					receiver.world:Fire(
						"CHAT_MSG_ADDON",
						message.prefix,
						message.text,
						"PARTY",
						sender,
						"",
						0,
						0,
						"",
						0
					)
				end
			end
		end
		local pushes = client.world.pushes
		while cursor.pushes < #pushes do
			cursor.pushes = cursor.pushes + 1
			self:Pushed(i, pushes[cursor.pushes].questID)
		end
	end
end

--- Advances every client's clock in small steps, delivering messages in between.
function Network:Advance(seconds)
	local steps = math.floor(seconds / STEP + 0.5)
	for _ = 1, steps do
		for _, client in pairs(self.clients) do
			client.world:Advance(STEP)
		end
		self:Deliver()
	end
end

return Network
