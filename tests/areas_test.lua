local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")

local function Setup(options)
	options = options or {}
	options.configure = function(w)
		Helpers.Have(w, Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 2 } }))
		Helpers.Have(w, Helpers.Quest(101, "Gather", { { "Herb", 5, 1 } }, { isOnMap = false }))
		Helpers.Have(w, Helpers.Quest(102, "Talk", {}))
	end
	local world, ns = Harness.Boot(options)
	local members = Helpers.Party(world)
	return world, ns, members
end

local function Visible(ns)
	return ns.Areas.Visible({})
end

describe("Areas", function()
	it("shows the quests whose area the player is in, from the game's event", function()
		local world, ns = Setup()
		expect(Visible(ns)).toEqual({})
		world.blobs[101] = true
		world:Fire("PLAYER_INSIDE_QUEST_BLOB_STATE_CHANGED", 101, true)
		expect(Visible(ns)).toEqual({ 101 })
	end)

	it("notices areas by polling when no event comes", function()
		local world, ns = Setup()
		world.blobs[100] = true
		world:Advance(2.1)
		expect(Visible(ns)).toEqual({ 100 })
	end)

	it("lists the areas the player is in first", function()
		local world, ns = Setup()
		world:Fire("PLAYER_INSIDE_QUEST_BLOB_STATE_CHANGED", 100, true)
		world:Fire("PLAYER_INSIDE_QUEST_BLOB_STATE_CHANGED", 101, true)
		world:Fire("PLAYER_INSIDE_QUEST_BLOB_STATE_CHANGED", 100, false)
		expect(Visible(ns)).toEqual({ 101, 100 })
	end)

	it("keeps a quest for a few seconds after the player leaves its area", function()
		local world, ns = Setup()
		world.blobs[100] = true
		world:Advance(2.1)
		world.blobs[100] = false
		world:Advance(2.1)
		expect(Visible(ns)).toEqual({ 100 })
		world:Advance(5)
		expect(Visible(ns)).toEqual({})
	end)

	it("keeps a quest finished in its area until the party has finished it too", function()
		local world, ns, members = Setup()
		world.blobs[100] = true
		world:Advance(2.1)
		-- Thrall syncs progress on the quest.
		Helpers.AddonMessage(world, "Thrall Party1", "D1:100,-,3/6")
		world.blobs[100] = false
		Helpers.Progress(world, 100, 1, 6)
		world:Advance(20)
		expect(Visible(ns)).toEqual({ 100 })
		Helpers.AddonMessage(world, "Thrall Party1", "D1:100,c,6/6")
		expect(Visible(ns)).toEqual({})
		expect(members[1].name).toBe("Thrall")
	end)

	it("lets a finished quest go on changing zone or after ten minutes", function()
		local world, ns = Setup()
		Helpers.AddonMessage(world, "Thrall Party1", "D1:100,-,3/6")
		world.blobs[100] = true
		world:Advance(2.1)
		Helpers.Progress(world, 100, 1, 6)
		world.blobs[100] = false
		world:Fire("ZONE_CHANGED_NEW_AREA")
		expect(Visible(ns)).toEqual({})

		local other, otherNs = Setup()
		Helpers.AddonMessage(other, "Thrall Party1", "D1:100,-,3/6")
		other.blobs[100] = true
		other:Advance(2.1)
		Helpers.Progress(other, 100, 1, 6)
		other.blobs[100] = false
		other:Advance(601)
		expect(Visible(otherNs)).toEqual({})
	end)

	it("ignores the game saying the player is in a finished quest's area", function()
		local world, ns = Setup()
		Helpers.Progress(world, 100, 1, 6)
		world:Advance(10)
		world:Fire("PLAYER_INSIDE_QUEST_BLOB_STATE_CHANGED", 100, true)
		expect(Visible(ns)).toEqual({})
	end)

	it("follows the zone in zone mode", function()
		local world, ns = Setup()
		ns.Database.Set("panelMode", "zone")
		expect(Visible(ns)).toEqual({ 100 })
		world:Quest(100).isOnMap = false
		world:Quest(101).isOnMap = true
		world:Fire("ZONE_CHANGED_NEW_AREA")
		world:Advance(0.5)
		expect(Visible(ns)).toEqual({ 101 })
	end)

	it("shows the zone's quests in zone mode", function()
		local _, ns = Setup()
		ns.Database.Set("panelMode", "zone")
		expect(Visible(ns)).toEqual({ 100 })
	end)

	it("falls back to the zone's quests when the client can't tell areas", function()
		local _, ns = Setup({ noBlobApi = true })
		expect(ns.Areas.Mode()).toBe("zone")
		expect(Visible(ns)).toEqual({ 100 })
	end)

	it("shows every quest someone in the party has in 'all' mode", function()
		local world, ns = Harness.Boot({
			configure = function(w)
				Helpers.Have(w, Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 2 } }))
				Helpers.Have(w, Helpers.Quest(101, "Gather", { { "Herb", 5, 1 } }))
			end,
		})
		Helpers.JoinParty(world, { Helpers.Member(1, "Thrall", { quests = { [101] = true } }) })
		ns.Database.Set("panelMode", "all")
		expect(Visible(ns)).toEqual({ 101 })
	end)

	it("only polls while it's needed", function()
		local world, ns = Harness.Boot()
		local polls = ns.Areas.Probe and select(2, ns.Areas.Probe()).polls
		world:Advance(10)
		expect(select(2, ns.Areas.Probe()).polls).toBe(polls)
		Helpers.Party(world)
		world:Advance(10)
		local grouped = select(2, ns.Areas.Probe()).polls
		expect(grouped > polls).toBe(true)
		ns.Database.Set("panelMode", "zone")
		world:Advance(10)
		expect(select(2, ns.Areas.Probe()).polls).toBe(grouped)
	end)
end)

describe("PartyState", function()
	it("calls a member without the addon 'on quest' or 'not on quest' from the game", function()
		local world, ns = Harness.Boot()
		Helpers.JoinParty(world, {
			Helpers.Member(1, "Thrall", { quests = { [100] = true } }),
			Helpers.Member(2, "Jaina"),
		})
		local thrall, jaina = unpack(ns.Roster.Members())
		-- Until the game has said yes once, "no" could mean it doesn't know.
		expect(ns.PartyState.Status(jaina, 100, 1)).toBe("unknown")
		expect(ns.PartyState.Status(thrall, 100, 1)).toBe("onQuest")
		expect(ns.PartyState.Status(jaina, 100, 1)).toBe("absent")
	end)

	it("says it doesn't know when the client can't tell", function()
		local world, ns = Harness.Boot({ noUnitOnQuest = true })
		Helpers.JoinParty(world, { Helpers.Member(1, "Thrall", { quests = { [100] = true } }) })
		expect(ns.PartyState.Status(ns.Roster.Members()[1], 100, 1)).toBe("unknown")
	end)

	it("prefers synced progress over the game's word", function()
		local world, ns = Harness.Boot()
		Helpers.JoinParty(world, { Helpers.Member(1, "Thrall", { quests = { [100] = true } }) })
		Helpers.AddonMessage(world, "Thrall Party1", "F1:a:1:1:")
		local status, _, source = ns.PartyState.Status(ns.Roster.Members()[1], 100, 1)
		expect(status).toBe("absent")
		expect(source).toBe("addon")
	end)
end)

describe("GameProgress", function()
	local function Lines(world, questID, lines)
		world.partyProgress[questID] = lines
	end

	it("reads the game's party progress for members without the addon", function()
		local world, ns = Harness.Boot()
		Helpers.JoinParty(world, { Helpers.Member(1, "Thrall"), Helpers.Member(2, "Jaina") })
		Lines(world, 100, {
			{ type = 18, leftText = "|cfff58cbaThrall Party1|r" },
			{ type = 8, leftText = "4/6 Boar Tusk", completed = false },
			{ type = 8, leftText = "10/10 Bear Meat", completed = true },
			{ type = 18, leftText = "Jaina Party2" },
			{ type = 8, leftText = "6/6 Boar Tusk", completed = true },
			{ type = 8, leftText = "Bear Meat: 10/10", completed = true },
		})
		local thrall, jaina = unpack(ns.Roster.Members())
		local status, progress, source = ns.PartyState.Status(thrall, 100, 2)
		expect({ status, source }).toEqual({ "progress", "game" })
		expect(progress.counts).toEqual({ 4, 6, 10, 10 })
		expect(progress.state).toBe("-")
		local _, jainaProgress = ns.PartyState.Status(jaina, 100, 2)
		expect(jainaProgress.state).toBe("c")
	end)

	it("ignores progress that doesn't match the player's copy of the quest", function()
		local world, ns = Harness.Boot()
		Helpers.JoinParty(world, { Helpers.Member(1, "Thrall", { quests = { [100] = true } }) })
		Lines(world, 100, {
			{ type = 18, leftText = "Thrall" },
			{ type = 8, leftText = "4/6 Boar Tusk", completed = false },
		})
		expect(ns.PartyState.Status(ns.Roster.Members()[1], 100, 2)).toBe("onQuest")
	end)

	it("ignores lines it can't read", function()
		local world, ns = Harness.Boot()
		Helpers.JoinParty(world, { Helpers.Member(1, "Thrall") })
		Lines(world, 100, {
			{ type = 18, leftText = "Thrall" },
			{ type = 8, leftText = "Something odd", completed = false },
		})
		expect(ns.GameProgress.Get(ns.Roster.Members()[1], 100, 1)).toBeNil()
		Lines(world, 101, { { type = 18, leftText = Harness.SECRET }, { type = 8, leftText = "1/2 Thing" } })
		expect(ns.GameProgress.Get(ns.Roster.Members()[1], 101, 1)).toBeNil()
	end)

	it("asks the game at most every two seconds per quest, and again when a log changes", function()
		local world, ns = Harness.Boot()
		Helpers.JoinParty(world, { Helpers.Member(1, "Thrall") })
		local thrall = ns.Roster.Members()[1]
		Lines(world, 100, { { type = 18, leftText = "Thrall" }, { type = 8, leftText = "1/6 Boar Tusk" } })
		ns.GameProgress.Get(thrall, 100, 1)
		ns.GameProgress.Get(thrall, 100, 1)
		expect(ns.GameProgress.Stats().queries).toBe(1)
		-- Someone in another raid group: not the player's party.
		world:Fire("UNIT_QUEST_LOG_CHANGED", "raid12")
		world:Advance(1.5)
		ns.GameProgress.Get(thrall, 100, 1)
		expect(ns.GameProgress.Stats().queries).toBe(1)
		-- A party member's log changed: asked again, but not more than once a second.
		world:Fire("UNIT_QUEST_LOG_CHANGED", "party1")
		ns.GameProgress.Get(thrall, 100, 1)
		expect(ns.GameProgress.Stats().queries).toBe(2)
		world:Fire("UNIT_QUEST_LOG_CHANGED", "party1")
		ns.GameProgress.Get(thrall, 100, 1)
		expect(ns.GameProgress.Stats().queries).toBe(2)
		world:Advance(1)
		ns.GameProgress.Get(thrall, 100, 1)
		expect(ns.GameProgress.Stats().queries).toBe(3)
	end)
end)
