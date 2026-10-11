local _, ns = ...

--- The other members of the player's party (party1..party4; in a raid, the player's
--- subgroup). Member tables are reused, one per party slot.
---
--- Fires QT_ROSTER_CHANGED(added, removed, joined) when the membership changes: `added` and
--- `removed` say whether anyone arrived or left, `joined` that the roster was empty before
--- (the player joined a group, logged in or reloaded while grouped). QT_ROSTER_UPDATED
--- follows every re-read (names, classes and connection state may have changed).
---@class QTRoster
local Roster = ns.Roster
local Names = ns.Names
local Events = ns.Events

local MAX_MEMBERS = 4

---@class QTMember
---@field unit string
---@field guid string
---@field name string "First" or "First Surname" as the game shows it
---@field first string
---@field classFile string?
---@field color number[] class colour {r, g, b}
---@field connected boolean

local slots = {} ---@type QTMember[]
local members = {} ---@type QTMember[]
local previous = {} ---@type table<string, boolean> GUIDs of the last build
local current = {} ---@type table<string, boolean>
local stats = { unreadable = 0, builds = 0 }

local function ClassColor(classFile, into)
	local color
	if classFile then
		if C_ClassColor and C_ClassColor.GetClassColor then
			color = C_ClassColor.GetClassColor(classFile)
		end
		color = color or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile])
	end
	into[1] = color and ns.Num(color.r) or 1
	into[2] = color and ns.Num(color.g) or 1
	into[3] = color and ns.Num(color.b) or 1
end

local function Realms()
	return GetNormalizedRealmName and GetNormalizedRealmName(), GetRealmName and GetRealmName()
end

--- Reads one party unit into its slot table; returns nil when its identity can't be read
--- (still loading, or secret in restricted content).
local function Read(slot, unit)
	if not UnitExists(unit) then
		return nil
	end
	local guid = ns.Str(UnitGUID(unit))
	local first, second = UnitName(unit)
	first, second = ns.Str(first), ns.Str(second)
	if not guid or not first or first == "" or first == UNKNOWNOBJECT then
		stats.unreadable = stats.unreadable + 1
		return nil
	end
	-- On Forever the second name is a surname; elsewhere it can be a realm.
	local normalized, realm = Realms()
	if second == "" or second == normalized or second == realm then
		second = nil
	end
	local member = slots[slot]
	if not member then
		member = { color = {} }
		slots[slot] = member
	end
	member.unit = unit
	member.guid = guid
	member.first = first
	member.name = second and (first .. Names.SurnameSeparator() .. second) or first
	member.classFile = ns.Str(select(2, UnitClass(unit)))
	ClassColor(member.classFile, member.color)
	member.connected = ns.Bool(UnitIsConnected(unit)) ~= false
	return member
end

--- Re-reads the party. Fires QT_ROSTER_CHANGED when someone arrived or left.
function Roster.Rebuild()
	stats.builds = stats.builds + 1
	wipe(members)
	wipe(current)
	if Roster.InGroup() then
		for slot = 1, MAX_MEMBERS do
			local member = Read(slot, "party" .. slot)
			if member and not current[member.guid] then
				members[#members + 1] = member
				current[member.guid] = true
			end
		end
	end
	local added, removed = false, false
	for guid in pairs(current) do
		if not previous[guid] then
			added = true
		end
	end
	local wasEmpty = next(previous) == nil
	for guid in pairs(previous) do
		if not current[guid] then
			removed = true
		end
	end
	previous, current = current, previous
	if added or removed then
		Events.Fire("QT_ROSTER_CHANGED", added, removed, added and wasEmpty)
	end
	Events.Fire("QT_ROSTER_UPDATED")
end

local function ScheduleRebuild()
	Events.Debounce("roster", 0.3, Roster.Rebuild)
end

--- The other party members whose identity is known. Don't modify the list.
---@return QTMember[]
function Roster.Members()
	return members
end

--- In a group that announcements and sharing apply to: a party, not a raid. Only groups the
--- player formed count (an instance group's chat is a different channel).
---@return boolean
function Roster.InParty()
	return Roster.InGroup() and not IsInRaid()
end

---@return boolean
function Roster.InGroup()
	return IsInGroup(LE_PARTY_CATEGORY_HOME) == true
end

---@param guid string
---@return QTMember?
function Roster.FindByGUID(guid)
	for _, member in ipairs(members) do
		if member.guid == guid then
			return member
		end
	end
	return nil
end

local function FindByName(name)
	local found
	for _, member in ipairs(members) do
		if Names.Same(member.name, name) then
			if found then
				return nil -- ambiguous: two members match
			end
			found = member
		end
	end
	return found
end

--- The member a name refers to: "First", "First Surname", either with "-Realm". Nil when
--- nobody or more than one member matches.
---@param name string
---@return QTMember?
function Roster.FindByName(name)
	return FindByName(name)
end

--- The member who sent an addon message. Messages can arrive before the roster update
--- that announces their sender, so an unknown sender triggers a re-read first.
---@param sender string
---@return QTMember?
function Roster.FindBySender(sender)
	local member = FindByName(sender)
	if not member then
		Roster.Rebuild()
		member = FindByName(sender)
	end
	return member
end

function Roster.Stats()
	return stats
end

Events.On("GROUP_ROSTER_UPDATE", ScheduleRebuild)
Events.On("UNIT_NAME_UPDATE", ScheduleRebuild)
Events.On("UNIT_CONNECTION", ScheduleRebuild)
Events.On("PLAYER_ENTERING_WORLD", ScheduleRebuild)
