local _, ns = ...

--- The addon-message format party members use to share quest progress. Pure functions:
--- building and parsing only, no sending. Messages are ASCII and carry quest IDs, states
--- and counts — never titles, objective text or names.
---
---   H<v>:<addonVersion>                       hello: "I (re)started, please send me your state"
---   F<v>:<syncId>:<part>:<total>:<records>    full state, part of total; the last part ends it
---   D<v>:<records>                            changed quests
---   X<v>:<questID>[,<questID>...]             quests no longer in the log
---   P<v>:<questID>                            "I'm sharing this quest with the party now"
---
---   records := record[;record...]   record := <questID>,<state>[,<fulfilled>/<required>...]
---   state   := "-" in progress | "c" complete | "f" failed
---@class QTProtocol
local Protocol = ns.Protocol

Protocol.VERSION = 1
--- Addon messages are limited to 255 bytes.
Protocol.MAX_MESSAGE_BYTES = 255
Protocol.MAX_OBJECTIVES = 20
Protocol.MAX_QUESTS = 60
Protocol.MAX_PARTS = 20

local MAX_QUEST_ID = 9999999
local MAX_COUNT = 99999
-- Room for a full-state header ("F1:<syncId>:<part>:<total>:") in front of the records.
local RECORD_BYTES = Protocol.MAX_MESSAGE_BYTES - 25

---@class QTPeerQuest
---@field questID integer
---@field state "-"|"c"|"f"
---@field counts integer[] fulfilled, required, fulfilled, required, ...

---@class QTMessage
---@field kind "H"|"F"|"D"|"X"|"P"
---@field version integer protocol version
---@field newer boolean? sent by a newer protocol version this one can't read
---@field addonVersion string? H
---@field syncId string? F
---@field part integer? F
---@field total integer? F
---@field records QTPeerQuest[]? F, D
---@field ids integer[]? X
---@field questID integer? P

local function Header(kind)
	return kind .. Protocol.VERSION .. ":"
end

--- One quest as a record. Objectives that don't fit (past MAX_OBJECTIVES, or past what one
--- message can carry) are left out.
---@param quest QTQuest
---@return string
function Protocol.EncodeRecord(quest)
	local state = quest.failed and "f" or (quest.complete and "c" or "-")
	local parts = { quest.questID, state }
	local size = #tostring(quest.questID) + 2
	for index, objective in ipairs(quest.objectives) do
		local count = math.min(objective.fulfilled, MAX_COUNT) .. "/" .. math.min(objective.required, MAX_COUNT)
		if index > Protocol.MAX_OBJECTIVES or size + 1 + #count > RECORD_BYTES then
			break
		end
		parts[#parts + 1] = count
		size = size + 1 + #count
	end
	return table.concat(parts, ",")
end

--- Packs items into as few ";"-joined groups as fit in maxBytes each.
---@param items string[]
---@param maxBytes integer
---@param separator string
---@return string[]
local function Pack(items, maxBytes, separator)
	local groups = {}
	local current, size = {}, 0
	for _, item in ipairs(items) do
		local added = #item + (#current > 0 and #separator or 0)
		if #current > 0 and size + added > maxBytes then
			groups[#groups + 1] = table.concat(current, separator)
			current, size = {}, 0
			added = #item
		end
		current[#current + 1] = item
		size = size + added
	end
	if #current > 0 then
		groups[#groups + 1] = table.concat(current, separator)
	end
	return groups
end

---@param addonVersion string
---@return string
function Protocol.Hello(addonVersion)
	local clean = addonVersion:gsub("[^%w%.%-_]", ""):sub(1, 24)
	return Header("H") .. (clean ~= "" and clean or "dev")
end

--- The full state as messages. An empty quest list is one message with no records.
---@param syncId string
---@param records string[] encoded records
---@return string[]
function Protocol.Full(syncId, records)
	local groups = Pack(records, RECORD_BYTES, ";")
	if #groups == 0 then
		groups[1] = ""
	end
	local messages = {}
	local total = math.min(#groups, Protocol.MAX_PARTS)
	for part = 1, total do
		messages[part] = string.format("%s%s:%d:%d:%s", Header("F"), syncId, part, total, groups[part])
	end
	return messages
end

---@param records string[] encoded records
---@return string[]
function Protocol.Delta(records)
	local messages = {}
	for _, group in ipairs(Pack(records, RECORD_BYTES, ";")) do
		messages[#messages + 1] = Header("D") .. group
	end
	return messages
end

---@param questIDs integer[]
---@return string[]
function Protocol.Removed(questIDs)
	local items = {}
	for index, questID in ipairs(questIDs) do
		items[index] = tostring(questID)
	end
	local messages = {}
	for _, group in ipairs(Pack(items, RECORD_BYTES, ",")) do
		messages[#messages + 1] = Header("X") .. group
	end
	return messages
end

---@param questID integer
---@return string
function Protocol.Push(questID)
	return Header("P") .. questID
end

-- Parsing ------------------------------------------------------------------------------

local function QuestID(text)
	local value = tonumber(text)
	if value and value >= 1 and value <= MAX_QUEST_ID and value == math.floor(value) then
		return value
	end
	return nil
end

local function Count(text)
	local value = tonumber(text)
	if value and value >= 0 and value <= MAX_COUNT then
		return value
	end
	return nil
end

---@return QTPeerQuest?
local function ParseRecord(text)
	local id, state, rest = text:match("^(%d+),([%-cf])(.*)$")
	local questID = id and QuestID(id)
	if not questID then
		return nil
	end
	local counts = {}
	local position = 1
	while position <= #rest do
		local fulfilled, required, after = rest:match("^,(%d+)/(%d+)()", position)
		fulfilled, required = Count(fulfilled), Count(required)
		if not (fulfilled and required) or #counts >= Protocol.MAX_OBJECTIVES * 2 then
			return nil
		end
		counts[#counts + 1] = fulfilled
		counts[#counts + 1] = required
		position = after
	end
	return { questID = questID, state = state, counts = counts }
end

---@return QTPeerQuest[]?
local function ParseRecords(text, allowEmpty)
	local records = {}
	if text == "" then
		return allowEmpty and records or nil
	end
	for item in (text .. ";"):gmatch("([^;]*);") do
		local record = ParseRecord(item)
		if not record or #records >= Protocol.MAX_QUESTS then
			return nil
		end
		records[#records + 1] = record
	end
	return records
end

local PARSERS = {
	H = function(message, body)
		local version = body:match("^([%w%.%-_]+)$")
		if not version or #version > 24 then
			return false
		end
		message.addonVersion = version
		return true
	end,
	F = function(message, body)
		local syncId, part, total, records = body:match("^(%w+):(%d+):(%d+):(.*)$")
		part, total = tonumber(part), tonumber(total)
		if not syncId or #syncId > 8 or not part or not total then
			return false
		end
		if total < 1 or total > Protocol.MAX_PARTS or part < 1 or part > total then
			return false
		end
		message.syncId, message.part, message.total = syncId, part, total
		message.records = ParseRecords(records, true)
		return message.records ~= nil
	end,
	D = function(message, body)
		message.records = ParseRecords(body, false)
		return message.records ~= nil
	end,
	X = function(message, body)
		local ids = {}
		for item in (body .. ","):gmatch("([^,]*),") do
			local questID = QuestID(item)
			if not questID or #ids >= Protocol.MAX_QUESTS then
				return false
			end
			ids[#ids + 1] = questID
		end
		message.ids = ids
		return #ids > 0
	end,
	P = function(message, body)
		message.questID = QuestID(body:match("^(%d+)$"))
		return message.questID ~= nil
	end,
}

--- Parses a received message. Returns nil for anything malformed. A message from a newer
--- protocol version comes back as { kind, version, newer = true } without its contents.
---@param text string
---@return QTMessage?
function Protocol.Parse(text)
	if #text > Protocol.MAX_MESSAGE_BYTES then
		return nil
	end
	local kind, version, body = text:match("^(%u)(%d+):(.*)$")
	local parser = kind and PARSERS[kind]
	version = tonumber(version)
	if not parser or not version or version < 1 then
		return nil
	end
	local message = { kind = kind, version = version }
	if version > Protocol.VERSION then
		message.newer = true
		return message
	end
	if not parser(message, body) then
		return nil
	end
	return message
end
