local _, ns = ...

--- What the addon knows about party members' quests. Exact counts come from members who
--- run the addon (synced over addon messages); for the rest, the game's own party progress
--- (GameProgress) or at least whether they're on the quest (C_QuestLog.IsUnitOnQuest).
--- Fires QT_PARTY_CHANGED when synced data changes.
---@class QTPartyState
local PartyState = ns.PartyState
local Roster = ns.Roster
local GameProgress = ns.GameProgress
local Events = ns.Events

---@class QTPeer
---@field addonVersion string?
---@field protocol integer?
---@field synced boolean a complete full state has arrived
---@field lastSeen number
---@field quests table<integer, QTPeerQuest>
---@field fullMarks table<integer, string> sync ID of the full state that last listed each quest

local peers = {} ---@type table<string, QTPeer>
-- Whether IsUnitOnQuest has ever said yes this session: until it has, a "no" may only mean
-- the client doesn't share that information, so members aren't called "not on quest".
local unitOnQuestProven = false
local stats = { unitOnQuestCalls = 0, unitOnQuestYes = 0 }

local function Changed()
	Events.Fire("QT_PARTY_CHANGED")
end

---@param guid string
---@return QTPeer
local function Peer(guid)
	local peer = peers[guid]
	if not peer then
		peer = { synced = false, lastSeen = 0, quests = {}, fullMarks = {} }
		peers[guid] = peer
	end
	peer.lastSeen = GetTime()
	return peer
end

--- A member (re)started and will send their full state. What they sent before stays until
--- it arrives, so the panel doesn't flicker.
---@param member QTMember
---@param addonVersion string?
---@param protocol integer?
function PartyState.Hello(member, addonVersion, protocol)
	local peer = Peer(member.guid)
	peer.addonVersion, peer.protocol = addonVersion, protocol
	Changed()
end

---@param peer QTPeer
---@param records QTPeerQuest[]
---@param syncId string?
local function Store(peer, records, syncId)
	for _, record in ipairs(records) do
		peer.quests[record.questID] = record
		if syncId then
			peer.fullMarks[record.questID] = syncId
		end
	end
end

--- Changed quests from a member. Returns false when their full state hasn't arrived yet:
--- until it has, quests they didn't mention are unknown, not absent.
---@param member QTMember
---@param records QTPeerQuest[]
---@return boolean synced
function PartyState.Apply(member, records)
	local peer = Peer(member.guid)
	Store(peer, records, nil)
	Changed()
	return peer.synced
end

--- One part of a member's full state. The last part removes the quests the full state
--- didn't list.
---@param member QTMember
---@param syncId string
---@param part integer
---@param total integer
---@param records QTPeerQuest[]
function PartyState.ApplyFull(member, syncId, part, total, records)
	local peer = Peer(member.guid)
	Store(peer, records, syncId)
	if part == total then
		peer.synced = true
		for questID in pairs(peer.quests) do
			if peer.fullMarks[questID] ~= syncId then
				peer.quests[questID] = nil
				peer.fullMarks[questID] = nil
			end
		end
	end
	Changed()
end

--- Quests a member no longer has. Returns whether their full state has arrived (see Apply).
---@param member QTMember
---@param questIDs integer[]
---@return boolean synced
function PartyState.Remove(member, questIDs)
	local peer = Peer(member.guid)
	for _, questID in ipairs(questIDs) do
		peer.quests[questID] = nil
		peer.fullMarks[questID] = nil
	end
	Changed()
	return peer.synced
end

--- Whether a member's full state has arrived.
---@param member QTMember
---@return boolean
function PartyState.IsSynced(member)
	local peer = peers[member.guid]
	return peer ~= nil and peer.synced
end

---@param guid string
---@return QTPeer?
function PartyState.Peer(guid)
	return peers[guid]
end

--- Forgets members who left the party.
local function Prune()
	local changed = false
	for guid in pairs(peers) do
		if not Roster.FindByGUID(guid) then
			peers[guid] = nil
			changed = true
		end
	end
	if changed then
		Changed()
	end
end

--- Whether the game says the member is on the quest: true, false, or nil when it can't tell.
---@param member QTMember
---@param questID integer
---@return boolean?
function PartyState.UnitOnQuest(member, questID)
	if not C_QuestLog.IsUnitOnQuest then
		return nil
	end
	stats.unitOnQuestCalls = stats.unitOnQuestCalls + 1
	local ok, onQuest = pcall(C_QuestLog.IsUnitOnQuest, member.unit, questID)
	onQuest = ok and ns.Bool(onQuest)
	if onQuest then
		stats.unitOnQuestYes = stats.unitOnQuestYes + 1
		unitOnQuestProven = true
		return true
	end
	if onQuest == false and unitOnQuestProven then
		return false
	end
	return nil
end

---@alias QTStatus "progress"|"onQuest"|"absent"|"unknown"

--- A member's status on one of the player's quests, and their progress when known
--- (state and counts as in a synced record).
---@param member QTMember
---@param questID integer
---@param numObjectives integer how many objectives the player's copy has
---@return QTStatus status
---@return QTPeerQuest? progress
---@return "addon"|"game"|nil source
function PartyState.Status(member, questID, numObjectives)
	local peer = peers[member.guid]
	local record = peer and peer.quests[questID]
	if record then
		return "progress", record, "addon"
	end
	-- Only a complete full state says what a member doesn't have.
	if peer and peer.synced then
		return "absent", nil, "addon"
	end
	local fromGame = GameProgress.Get(member, questID, numObjectives)
	if fromGame then
		return "progress", fromGame, "game"
	end
	local onQuest = PartyState.UnitOnQuest(member, questID)
	if onQuest then
		return "onQuest"
	elseif onQuest == false then
		return "absent"
	end
	return "unknown"
end

--- Whether a member has the quest, as far as the addon can tell (for sharing).
---@param member QTMember
---@param questID integer
---@return boolean
function PartyState.HasQuest(member, questID)
	local peer = peers[member.guid]
	if peer and peer.quests[questID] then
		return true
	end
	return PartyState.UnitOnQuest(member, questID) == true
end

--- Whether a member is on the quest, cheapest source first: their synced state, the game's
--- yes/no, and only when the game can't say, its party progress.
---@param member QTMember
---@param questID integer
---@param numObjectives integer
---@return boolean
function PartyState.Shares(member, questID, numObjectives)
	local peer = peers[member.guid]
	if peer and peer.quests[questID] then
		return true
	end
	if peer and peer.synced then
		return false
	end
	local onQuest = PartyState.UnitOnQuest(member, questID)
	if onQuest ~= nil then
		return onQuest
	end
	return GameProgress.Get(member, questID, numObjectives) ~= nil
end

--- Objective i of a progress record: fulfilled, required, done.
---@param record QTPeerQuest
---@param index integer
---@return integer? fulfilled
---@return integer? required
---@return boolean done
function PartyState.Objective(record, index)
	local fulfilled, required = record.counts[index * 2 - 1], record.counts[index * 2]
	if not (fulfilled and required) then
		return nil, nil, record.state == "c"
	end
	return fulfilled, required, record.state == "c" or fulfilled >= required
end

function PartyState.Stats()
	return stats, unitOnQuestProven
end

Events.On("QT_ROSTER_CHANGED", function(_, removed)
	if not Roster.InGroup() then
		if next(peers) then
			wipe(peers)
			Changed()
		end
	elseif removed then
		Prune()
	end
end)
