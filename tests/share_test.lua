local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")
local Network = dofile(HARNESS_DIR .. "/network.lua")

local function Hunt(fulfilled)
	return Helpers.Quest(100, "The Boar Hunt", { { "Boar Tusk", 6, fulfilled or 0 } })
end

local function Pushed(world)
	local ids = {}
	for _, push in ipairs(world.pushes) do
		ids[#ids + 1] = push.questID
	end
	return ids
end

describe("Auto-share", function()
	it("shares an accepted quest with the party a moment later", function()
		local net = Network.Party({ { name = "Tess" }, { name = "Thrall" } })
		local world = net:World(1)
		Helpers.Accept(world, Hunt())
		net:Advance(1)
		expect(Pushed(world)).toEqual({})
		net:Advance(3)
		expect(Pushed(world)).toEqual({ 100 })
		expect(net:World(2).questDetail.questID).toBe(100)
	end)

	it("selects the quest for the share and puts the player's selection back", function()
		local world = Harness.Boot()
		Helpers.Party(world)
		world.selectedQuest = 555
		Helpers.Accept(world, Hunt())
		world:Advance(5)
		expect(world.pushes[1].selected).toBe(100)
		expect(world.selectedQuest).toBe(555)
	end)

	it("lets the other player accept, and doesn't share the quest back", function()
		local net = Network.Party({ { name = "Tess" }, { name = "Thrall" } })
		Helpers.Accept(net:World(1), Hunt())
		net:Advance(4)
		net:Accept(2)
		net:Advance(6)
		expect(net:World(2):Quest(100)).toBeTruthy()
		expect(Pushed(net:World(2))).toEqual({})
		expect(net:Ns(2).Share.State().sharedBack).toBe(1)
		-- The sharer saw the answer and is free again.
		local _, _, inFlight = net:Ns(1).Share.State()
		expect(inFlight).toBeNil()
	end)

	it("skips the share when everyone already has the quest", function()
		local net = Network.Party({ { name = "Tess" }, { name = "Thrall" } })
		Helpers.Accept(net:World(2), Hunt())
		net:Advance(1)
		-- Thrall's own share is pending; Tess already has it before it arrives.
		Helpers.Accept(net:World(1), Hunt())
		net:Advance(6)
		expect(#net:World(1).pushes + #net:World(2).pushes <= 1).toBe(true)
	end)

	it("lets only one of two players who take the same quest share it", function()
		local net = Network.Party({ { name = "Tess" }, { name = "Thrall" }, { name = "Jaina", addon = false } })
		Helpers.Accept(net:World(1), Hunt())
		Helpers.Accept(net:World(2), Hunt())
		net:Advance(8)
		expect(#net:World(1).pushes + #net:World(2).pushes).toBe(1)
	end)

	it("skips members known to have the quest without the addon", function()
		local world = Harness.Boot()
		Helpers.JoinParty(world, { Helpers.Member(1, "Thrall", { quests = { [100] = true } }) })
		Helpers.Accept(world, Hunt())
		world:Advance(5)
		expect(Pushed(world)).toEqual({})
		expect(world.ns.Share.State().skipped).toBe(1)
	end)

	it("does nothing when switched off, solo, in a raid or for quests that can't be shared", function()
		local off = Harness.Boot()
		Helpers.Party(off)
		off.ns.Database.Set("autoShare", false)
		Helpers.Accept(off, Hunt())
		off:Advance(5)
		expect(Pushed(off)).toEqual({})

		local solo = Harness.Boot()
		Helpers.Accept(solo, Hunt())
		solo:Advance(5)
		expect(Pushed(solo)).toEqual({})

		local raid = Harness.Boot()
		Helpers.JoinParty(raid, { Helpers.Member(1, "Thrall") }, "raid")
		Helpers.Accept(raid, Hunt())
		raid:Advance(5)
		expect(Pushed(raid)).toEqual({})

		local unshareable = Harness.Boot()
		Helpers.Party(unshareable)
		Helpers.Accept(unshareable, Helpers.Quest(100, "Class quest", { { "Thing", 1 } }, { pushable = false }))
		unshareable:Advance(5)
		expect(Pushed(unshareable)).toEqual({})
	end)

	it("waits until combat is over", function()
		local world = Harness.Boot()
		Helpers.Party(world)
		world.combat = true
		Helpers.Accept(world, Hunt())
		world:Advance(10)
		expect(Pushed(world)).toEqual({})
		world.combat = false
		world:Advance(1)
		expect(Pushed(world)).toEqual({ 100 })
	end)

	it("shares one quest at a time, waiting for everyone's answer", function()
		local net = Network.Party({ { name = "Tess" }, { name = "Thrall" } })
		local world = net:World(1)
		Helpers.Accept(world, Hunt())
		Helpers.Accept(world, Helpers.Quest(101, "Bear Necessities", { { "Bear Meat", 10 } }))
		net:Advance(10)
		expect(Pushed(world)).toEqual({ 100 })
		net:Decline(2)
		net:Advance(3)
		expect(Pushed(world)).toEqual({ 100, 101 })
	end)

	it("moves on after a while when someone never answers", function()
		local net = Network.Party({ { name = "Tess" }, { name = "Thrall" } })
		local world = net:World(1)
		Helpers.Accept(world, Hunt())
		Helpers.Accept(world, Helpers.Quest(101, "Bear Necessities", { { "Bear Meat", 10 } }))
		net:Advance(15)
		expect(#world.pushes).toBe(1)
		net:Advance(15)
		expect(#world.pushes).toBe(2)
		expect(net:Ns(1).Share.State().timeouts).toBe(1)
	end)

	it("counts shares the game never answered, for /qt debug", function()
		local world, ns = Harness.Boot()
		Helpers.Party(world)
		Helpers.Accept(world, Hunt())
		world:Advance(30)
		expect(#world.pushes).toBe(1)
		expect(ns.Share.State().silent).toBe(1)

		local net = Network.Party({ { name = "Tess" }, { name = "Thrall" } })
		Helpers.Accept(net:World(1), Hunt())
		net:Advance(30)
		expect(net:Ns(1).Share.State().silent).toBe(0)
	end)

	it("tries once more for a member who was busy", function()
		local net = Network.Party({ { name = "Tess" }, { name = "Thrall" } })
		local thrall = net:World(2)
		-- Thrall is reading another quest when the share arrives.
		thrall.questDetail = { questID = 999 }
		Helpers.Accept(net:World(1), Hunt())
		net:Advance(5)
		expect(#net:World(1).pushes).toBe(1)
		thrall.questDetail = nil
		net:Advance(15)
		expect(#net:World(1).pushes).toBe(2)
		expect(thrall.questDetail.questID).toBe(100)
	end)

	it("doesn't credit a late answer to an earlier share to the current one", function()
		local net = Network.Party({ { name = "Tess" }, { name = "Thrall" }, { name = "Jaina" } })
		local tess, ns = net:World(1), net:Ns(1)
		Helpers.Accept(tess, Helpers.Quest(100, "A", { { "Thing", 6 } }))
		net:Advance(4)
		net:Accept(3) -- Jaina takes A; Thrall leaves its dialog open
		Helpers.Accept(tess, Helpers.Quest(101, "B", { { "Thing", 6 } }))
		net:Advance(25) -- A times out; B is shared: Thrall is busy, Jaina gets it
		expect(#tess.pushes).toBe(2)
		net:Accept(2) -- Thrall finally takes A: "Thrall has accepted your quest."
		net:Advance(1)
		net:Accept(3)
		net:Advance(30)
		-- B is offered to Thrall again (he was busy), not skipped as if he'd accepted it.
		expect(#tess.pushes).toBe(3)
		expect(net:World(2).questDetail.questID).toBe(101)
		expect(ns.Share.State().lateAnswers > 0).toBe(true)
	end)

	it("offers a quest again on request once a member who accepted it has abandoned it", function()
		local net = Network.Party({ { name = "Tess" }, { name = "Thrall" } })
		local tess, ns = net:World(1), net:Ns(1)
		Helpers.Accept(tess, Hunt())
		net:Advance(4)
		net:Accept(2)
		net:Advance(4)
		Helpers.Remove(net:World(2), 100)
		net:Advance(4)
		expect(ns.Share.MissingCount()).toBe(1)
	end)

	it("forgets after a while that a member couldn't take a quest", function()
		local world, ns = Harness.Boot({
			configure = function(w)
				Helpers.Have(w, Hunt())
			end,
		})
		Helpers.JoinParty(world, { Helpers.Member(1, "Thrall") })
		ns.Share.ShareMissing()
		world:Advance(0.5)
		Helpers.PushResult(world, "ERR_QUEST_PUSH_LOW_LEVEL_S", "Thrall Party1")
		world:Advance(3)
		expect(ns.Share.MissingCount()).toBe(0)
		world:Advance(900)
		expect(ns.Share.MissingCount()).toBe(1)
	end)

	it("understands answers that arrive as system chat", function()
		local net = Network.Party({ { name = "Tess" }, { name = "Thrall" } }, { resultsViaChat = true })
		local world = net:World(1)
		Helpers.Accept(world, Hunt())
		Helpers.Accept(world, Helpers.Quest(101, "Bear Necessities", { { "Bear Meat", 10 } }))
		net:Advance(5)
		net:Decline(2)
		net:Advance(3)
		expect(Pushed(world)).toEqual({ 100, 101 })
	end)

	it("counts the same answer arriving two ways once", function()
		local world, ns = Harness.Boot()
		Helpers.Party(world)
		local results = {}
		ns.Events.On("QT_PUSH_RESULT", function(kind, member)
			results[#results + 1] = kind .. ":" .. (member and member.first or "?")
		end)
		Helpers.PushResult(world, "ERR_QUEST_PUSH_DECLINED_S", "Thrall Party1")
		Helpers.PushResult(world, "ERR_QUEST_PUSH_DECLINED_S", "Thrall Party1", true)
		Helpers.PushResult(world, "ERR_QUEST_PUSH_LOW_LEVEL_S", "Jaina Party2")
		Helpers.PushResult(world, "ERR_QUEST_PUSH_NOT_IN_PARTY_S")
		expect(results).toEqual({ "declined:Thrall", "ineligible:Jaina", "notInParty:?" })
	end)

	it("turns itself off for the session when the game blocks sharing", function()
		local world, ns = Harness.Boot()
		Helpers.Party(world)
		world.blockPush = true
		Helpers.Accept(world, Hunt())
		world:Advance(5)
		expect(world:Output()).toContain("doesn't let Quest Together share quests")
		expect(select(3, ns.Share.State())).toBeNil()
		world.blockPush = false
		Helpers.Accept(world, Helpers.Quest(101, "Bear Necessities", { { "Bear Meat", 10 } }))
		world:Advance(5)
		expect(world.pushes).toEqual({})
		expect(select(4, ns.Share.State())).toBe(true)
	end)
end)

describe("Share missing quests", function()
	it("shares every quest someone is missing, one after another, and reports the result", function()
		local net = Network.Party({
			{ name = "Tess" },
			{ name = "Thrall", addon = false, respond = "accept", quests = { [102] = true } },
		})
		local world, ns = net:World(1), net:Ns(1)
		for _, quest in ipairs({
			Helpers.Quest(100, "A", { { "Thing", 1 } }),
			Helpers.Quest(101, "B", { { "Thing", 1 } }),
			Helpers.Quest(102, "C", { { "Thing", 1 } }),
		}) do
			Helpers.Have(world, quest)
		end
		world:Fire("QUEST_LOG_UPDATE")
		net:Advance(1)
		expect(ns.Share.MissingCount()).toBe(2)
		ns.Share.ShareMissing()
		net:Advance(10)
		expect(Pushed(world)).toEqual({ 100, 101 })
		expect(world:Output()).toContain("Done sharing: 2 shared, 2 accepted, 0 declined.")
		expect(ns.Share.MissingCount()).toBe(0)
	end)

	it("says so when nobody is missing anything", function()
		local world, ns = Harness.Boot({
			configure = function(w)
				Helpers.Have(w, Hunt())
			end,
		})
		Helpers.JoinParty(world, { Helpers.Member(1, "Thrall", { quests = { [100] = true } }) })
		ns.Share.ShareMissing()
		expect(world:Output()).toContain("already has your shareable quests")
	end)

	it("doesn't try a stopped share again for a member who was busy", function()
		local net = Network.Party({ { name = "Tess" }, { name = "Thrall" } })
		local tess, ns = net:World(1), net:Ns(1)
		Helpers.Have(tess, Hunt())
		tess:Fire("QUEST_LOG_UPDATE")
		net:Advance(2)
		net:World(2).questDetail = { questID = 999 }
		ns.Share.ShareMissing()
		net:Advance(0.2)
		ns.Share.Stop()
		net:World(2).questDetail = nil
		net:Advance(20)
		expect(#tess.pushes).toBe(1)
	end)

	it("can be stopped", function()
		local world, ns = Harness.Boot({
			configure = function(w)
				Helpers.Have(w, Helpers.Quest(100, "A", { { "Thing", 1 } }))
				Helpers.Have(w, Helpers.Quest(101, "B", { { "Thing", 1 } }))
			end,
		})
		Helpers.Party(world)
		ns.Share.ShareMissing()
		world:Advance(0.1)
		expect(#world.pushes).toBe(1)
		ns.Share.Stop()
		world:Advance(60)
		expect(#world.pushes).toBe(1)
		expect(world:Output()).toContain("Stopped sharing quests.")
	end)

	it("asks to be in a party first", function()
		local world, ns = Harness.Boot()
		ns.Share.ShareMissing()
		expect(world:Output()).toContain("need to be in a party")
	end)

	it("offers a quest again to someone who declined it when it was accepted", function()
		local net = Network.Party({ { name = "Tess" }, { name = "Thrall", addon = false, respond = "decline" } })
		local world, ns = net:World(1), net:Ns(1)
		Helpers.Accept(world, Hunt())
		net:Advance(5)
		expect(#world.pushes).toBe(1)
		ns.Share.ShareMissing()
		net:Advance(5)
		expect(#world.pushes).toBe(2)
	end)

	it("doesn't offer a quest again to someone who has already completed it", function()
		local net =
			Network.Party({ { name = "Tess" }, { name = "Thrall", addon = false, completed = { [100] = true } } })
		local world, ns = net:World(1), net:Ns(1)
		Helpers.Accept(world, Hunt())
		net:Advance(5)
		expect(#world.pushes).toBe(1)
		expect(ns.Share.MissingCount()).toBe(0)
	end)
end)

describe("Auto-accept", function()
	it("accepts quests a party member shares when switched on", function()
		local net = Network.Party({ { name = "Tess" }, { name = "Thrall" } })
		net:Ns(2).Database.Set("autoAccept", true)
		Helpers.Accept(net:World(1), Hunt())
		net:Advance(6)
		expect(net:World(2):Quest(100)).toBeTruthy()
		expect(net:World(2).pushes).toEqual({})
	end)

	it("is off by default", function()
		local net = Network.Party({ { name = "Tess" }, { name = "Thrall" } })
		Helpers.Accept(net:World(1), Hunt())
		net:Advance(6)
		expect(net:World(2).accepted).toEqual({})
	end)

	it("never accepts quests from NPCs, the player's own items or strangers", function()
		local world, ns = Harness.Boot()
		Helpers.Party(world)
		ns.Database.Set("autoAccept", true)
		for _, giver in ipairs({
			{ guid = "Creature-0-1-2-3-4-5" },
			{ guid = world.player.guid },
			{ guid = "Player-1-0000FFFF" },
			{ guid = Harness.SECRET },
		}) do
			world.questDetail = { questID = 300 }
			world.units.questnpc = giver
			world:Fire("QUEST_DETAIL")
		end
		expect(world.accepted).toEqual({})
		expect(ns.AutoAccept.WasShared(300)).toBe(false)
	end)

	it("doesn't accept a quest the player already has", function()
		local world, ns = Harness.Boot({
			configure = function(w)
				Helpers.Have(w, Hunt())
			end,
		})
		local members = Helpers.Party(world)
		ns.Database.Set("autoAccept", true)
		world.questDetail = { questID = 100 }
		world.units.questnpc = { guid = members[1].guid }
		world:Fire("QUEST_DETAIL")
		expect(world.accepted).toEqual({})
	end)
end)
