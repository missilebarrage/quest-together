local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")
local Network = dofile(HARNESS_DIR .. "/network.lua")

local function Duo(options)
	return Network.Party({ { name = "Tess" }, { name = "Thrall" } }, options)
end

-- Member j's status on a quest as client i sees it.
local function Status(net, i, j, questID, objectives)
	local ns = net:Ns(i)
	local member = ns.Roster.FindByGUID(net.specs[j].guid)
	return ns.PartyState.Status(member, questID, objectives or 1)
end

describe("Sync", function()
	it("shares each member's quests and counts with the others", function()
		local net = Duo()
		Helpers.Accept(net:World(1), Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 2 } }))
		net:Advance(2)
		local status, progress, source = Status(net, 2, 1, 100)
		expect(status).toBe("progress")
		expect(source).toBe("addon")
		expect(progress.counts).toEqual({ 2, 6 })
		expect(Status(net, 1, 2, 100)).toBe("absent")
	end)

	it("sends changes within about a second, batched", function()
		local net = Duo()
		local world = net:World(1)
		Helpers.Accept(world, Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 2 } }))
		net:Advance(2)
		local before = #world.addonSent
		Helpers.Progress(world, 100, 1, 3)
		Helpers.Progress(world, 100, 1, 4)
		net:Advance(1.5)
		expect(#world.addonSent - before).toBe(1)
		local _, progress = Status(net, 2, 1, 100)
		expect(progress.counts).toEqual({ 4, 6 })
	end)

	it("marks finished quests complete", function()
		local net = Duo()
		local world = net:World(1)
		Helpers.Accept(world, Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 5 } }))
		net:Advance(2)
		Helpers.Progress(world, 100, 1, 6)
		net:Advance(1.5)
		local _, progress = Status(net, 2, 1, 100)
		expect(progress.state).toBe("c")
		expect({ net:Ns(2).PartyState.Objective(progress, 1) }).toEqual({ 6, 6, true })
	end)

	it("tells the others when a quest leaves the log", function()
		local net = Duo()
		local world = net:World(1)
		Helpers.Accept(world, Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 2 } }))
		net:Advance(2)
		Helpers.Remove(world, 100)
		net:Advance(1.5)
		expect(Status(net, 2, 1, 100)).toBe("absent")
	end)

	it("resyncs both ways after a reload", function()
		local net = Duo()
		Helpers.Accept(net:World(1), Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 2 } }))
		Helpers.Accept(net:World(2), Helpers.Quest(200, "Gather", { { "Herb", 5, 1 } }))
		net:Advance(2)
		net:Reload(2)
		net:Advance(8)
		expect(Status(net, 2, 1, 100)).toBe("progress")
		expect(Status(net, 1, 2, 200)).toBe("progress")
	end)

	it("resyncs after reloading during a messaging lockdown", function()
		local net = Duo()
		local tess = net:World(1)
		Helpers.Accept(tess, Helpers.Quest(100, "A", { { "Thing", 6, 1 } }))
		Helpers.Accept(tess, Helpers.Quest(101, "B", { { "Thing", 6, 1 } }))
		net:Advance(4)
		local thrall = net:Reload(2)
		thrall.sendResults = { 11 }
		thrall.chatLockdown = true
		net:Advance(3)
		thrall.chatLockdown = false
		thrall:Fire("ADDON_RESTRICTION_STATE_CHANGED", 5, 0)
		net:Advance(5)
		Helpers.Progress(tess, 101, 1, 2)
		net:Advance(3)
		expect(Status(net, 2, 1, 100)).toBe("progress")
		expect(Status(net, 2, 1, 101)).toBe("progress")
	end)

	it("doesn't call quests missing until a member's whole state has arrived", function()
		local world, ns = Harness.Boot()
		Helpers.Party(world)
		world:Advance(15)
		local thrall = ns.Roster.Members()[1]
		local hellos = ns.Sync.Stats().hellos
		-- Only a change arrives: the other quest is unknown, and the addon asks for the rest.
		Helpers.AddonMessage(world, "Thrall Party1", "D1:100,-,1/6")
		expect(ns.PartyState.Status(thrall, 100, 1)).toBe("progress")
		expect(ns.PartyState.Status(thrall, 200, 1)).toBe("unknown")
		expect(ns.Sync.Stats().hellos).toBe(hellos + 1)
		-- The first of two parts doesn't settle it either; the last one does.
		Helpers.AddonMessage(world, "Thrall Party1", "F1:z:1:2:100,-,1/6")
		expect(ns.PartyState.Status(thrall, 200, 1)).toBe("unknown")
		Helpers.AddonMessage(world, "Thrall Party1", "F1:z:2:2:300,-,1/2")
		expect(ns.PartyState.Status(thrall, 200, 1)).toBe("absent")
	end)

	it("asks again for the state of a member who drops out of the roster for a moment", function()
		local net = Network.Party({ { name = "Tess" }, { name = "Thrall" }, { name = "Jaina" } })
		Helpers.Accept(net:World(2), Helpers.Quest(200, "Gather", { { "Herb", 5, 1 } }))
		Helpers.Accept(net:World(2), Helpers.Quest(201, "Hunt", { { "Boar", 5, 1 } }))
		net:Advance(15)
		local tess = net:World(1)
		-- Thrall's name can't be read for a moment on Tess's client.
		local unit = tess.units.party1
		tess.units.party1 = nil
		tess:Fire("GROUP_ROSTER_UPDATE")
		net:Advance(1)
		tess.units.party1 = unit
		tess:Fire("GROUP_ROSTER_UPDATE")
		net:Advance(1)
		Helpers.Progress(net:World(2), 200, 1, 2)
		net:Advance(6)
		expect(Status(net, 1, 2, 201)).toBe("progress")
		expect(Status(net, 1, 2, 999)).toBe("absent")
	end)

	it("drops quests a full state no longer lists", function()
		local net = Duo()
		local world = net:World(1)
		Helpers.Accept(world, Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 2 } }))
		net:Advance(2)
		-- The removal message gets lost; the next full state fixes it.
		net.options.dropMessages = true
		Helpers.Remove(world, 100)
		net:Advance(2)
		net.options.dropMessages = false
		expect(Status(net, 2, 1, 100)).toBe("progress")
		net:Ns(1).Sync.ScheduleFull()
		net:Advance(4)
		expect(Status(net, 2, 1, 100)).toBe("absent")
	end)

	it("answers a burst of hellos with one full state", function()
		local net = Network.Party({ { name = "Tess" }, { name = "Thrall" }, { name = "Jaina" }, { name = "Anduin" } })
		local world, ns = net:World(1), net:Ns(1)
		net:Advance(5)
		local fulls = ns.Sync.Stats().fulls
		for j = 2, 4 do
			Helpers.AddonMessage(world, net.specs[j].name .. " " .. net.specs[j].surname .. "-TestRealm", "H1:0.1.0")
		end
		net:Advance(5)
		expect(ns.Sync.Stats().fulls).toBe(fulls + 1)
	end)

	it("matches senders that come without a surname", function()
		local net = Duo({ shortSenders = true })
		Helpers.Accept(net:World(1), Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 2 } }))
		net:Advance(2)
		expect(Status(net, 2, 1, 100)).toBe("progress")
	end)

	it("ignores its own messages and strangers", function()
		local net = Duo()
		local world, ns = net:World(2), net:Ns(2)
		Helpers.AddonMessage(world, "Stranger Danger-TestRealm", "D1:100,-,1/6")
		local stats = ns.Transport.Stats()
		expect(stats.unknownSender).toBe(1)
		local received = stats.received
		Helpers.AddonMessage(world, "Thrall Family2-TestRealm", "D1:100,-,1/6")
		expect(stats.received).toBe(received)
	end)

	it("forgets everyone's quests when the party breaks up", function()
		local net = Duo()
		Helpers.Accept(net:World(1), Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 2 } }))
		net:Advance(2)
		local guid = net.specs[1].guid
		expect(net:Ns(2).PartyState.Peer(guid)).toBeTruthy()
		Helpers.LeaveParty(net:World(2))
		expect(net:Ns(2).PartyState.Peer(guid)).toBeNil()
	end)

	it("sends nothing while not in a group", function()
		local world = Harness.Boot()
		Helpers.Accept(world, Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 2 } }))
		world:Advance(5)
		expect(world.addonSent).toEqual({})
	end)

	it("says hello and sends its state on joining a party", function()
		local world = Harness.Boot()
		Helpers.Accept(world, Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 2 } }))
		world:Advance(2)
		Helpers.Party(world)
		world:Advance(4)
		local sent = Helpers.Sent(world)
		expect(sent[1]).toMatch("^H1:")
		expect(sent[2]).toMatch("^F1:%w+:1:1:100,%-,2/6$")
	end)

	it("only ever sends quest IDs, states and counts", function()
		local world = Harness.Boot()
		Helpers.Accept(world, Helpers.Quest(100, "Secret Title", { { "Secret Objective", 6, 2 } }))
		Helpers.Party(world)
		world:Advance(4)
		for _, text in ipairs(Helpers.Sent(world)) do
			expect(text:find("Secret", 1, true)).toBeNil()
			expect(text:find("Tester", 1, true)).toBeNil()
		end
	end)

	it("tells the player once when a party member runs a newer version", function()
		local world = Harness.Boot()
		Helpers.Party(world)
		Helpers.AddonMessage(world, "Thrall Party1", "D2:anything")
		Helpers.AddonMessage(world, "Thrall Party1", "D2:anything")
		local _, count = world:Output():gsub("newer Quest Together", "")
		expect(count).toBe(1)
	end)
end)

describe("Transport", function()
	it("backs off when throttled and drops a message after repeated throttling", function()
		local world, ns = Harness.Boot()
		Helpers.Party(world)
		world:Advance(5)
		world.sendResults = { 3, 3 }
		ns.Transport.Send("D1:100,-,1/6")
		expect(ns.Transport.QueueLength()).toBe(1)
		world:Advance(4)
		expect(ns.Transport.QueueLength()).toBe(0)
		expect(Helpers.Sent(world)[#world.addonSent]).toBe("D1:100,-,1/6")

		world.sendResults = { 3, 3, 3, 3 }
		ns.Transport.Send("D1:100,-,2/6")
		world:Advance(10)
		expect(ns.Transport.Stats().dropped).toBe(1)
	end)

	it("drops a whole full state when one part can't be sent, and sends a new one later", function()
		local world, ns = Harness.Boot()
		Helpers.Party(world)
		world:Advance(5)
		for index = 1, 40 do
			Helpers.Have(world, Helpers.Quest(1000 + index, "Q" .. index, { { "Thing", 10, 3 }, { "Other", 10, 3 } }))
		end
		world:Fire("QUEST_LOG_UPDATE")
		-- Let the change messages for the new quests go out first.
		world:Advance(5)
		local fulls = ns.Sync.Stats().fulls
		world.sendResults = { 0, 3, 3, 3, 3 }
		ns.Sync.ScheduleFull()
		world:Advance(10)
		expect(ns.Transport.QueueLength()).toBe(0)
		world:Advance(15)
		expect(ns.Sync.Stats().fulls).toBe(fulls + 2)
	end)

	it("doesn't leave half a full state queued when the queue is full, and tries again", function()
		local world, ns = Harness.Boot()
		Helpers.Party(world)
		for index = 1, 40 do
			Helpers.Have(world, Helpers.Quest(1000 + index, "Q" .. index, { { "Thing", 10, 3 }, { "Other", 10, 3 } }))
		end
		world:Fire("QUEST_LOG_UPDATE")
		world:Advance(8)
		-- The client throttles everything for a while; the queue fills up.
		for index = 1, 40 do
			world.sendResults[index] = 3
		end
		for index = 1, 58 do
			ns.Transport.Send("D1:" .. (2000 + index) .. ",-")
		end
		local fulls, sent = ns.Sync.Stats().fulls, #world.addonSent
		ns.Sync.ScheduleFull()
		world:Advance(3)
		expect(ns.Sync.Stats().fulls).toBe(fulls)
		for index = sent + 1, #world.addonSent do
			expect(world.addonSent[index].text:find("^F1:")).toBeNil()
		end
		world.sendResults = {}
		world:Advance(30)
		expect(ns.Sync.Stats().fulls).toBe(fulls + 1)
	end)

	it("pauses during a messaging lockdown and sends a fresh full state afterwards", function()
		local world, ns = Harness.Boot()
		Helpers.Party(world)
		world:Advance(5)
		world.sendResults = { 11 }
		ns.Transport.Send("D1:100,-,1/6")
		expect(ns.Transport.IsPaused()).toBe(true)
		expect(ns.Transport.Send("D1:100,-,2/6")).toBe(false)
		local fulls = ns.Sync.Stats().fulls
		world:Advance(5)
		world:Fire("ADDON_RESTRICTION_STATE_CHANGED", 5, 0)
		expect(ns.Transport.IsPaused()).toBe(false)
		world:Advance(4)
		expect(ns.Sync.Stats().fulls).toBe(fulls + 1)
	end)

	it("waits longer each time messages are locked again right after resuming", function()
		local world, ns = Harness.Boot()
		Helpers.Party(world)
		world:Advance(5)
		world.sendResults = { 11, 11 }
		ns.Transport.Send("D1:100,-,1/6")
		-- Resumes after 5 seconds; its hello hits the lockdown again, so it waits 10 more.
		world:Advance(5.1)
		expect(ns.Transport.IsPaused()).toBe(true)
		expect(ns.Transport.Stats().lockdowns).toBe(2)
		world:Advance(5)
		expect(ns.Transport.IsPaused()).toBe(true)
		world:Advance(5)
		expect(ns.Transport.IsPaused()).toBe(false)
		expect(ns.Transport.Stats().lockdowns).toBe(2)
	end)

	it("stays paused while chat is still locked down", function()
		local world, ns = Harness.Boot()
		Helpers.Party(world)
		world:Advance(5)
		world.sendResults = { 11 }
		world.chatLockdown = true
		ns.Transport.Send("D1:100,-,1/6")
		world:Fire("ADDON_RESTRICTION_STATE_CHANGED", 5, 1)
		world:Advance(6)
		expect(ns.Transport.IsPaused()).toBe(true)
		world.chatLockdown = false
		world:Advance(6)
		expect(ns.Transport.IsPaused()).toBe(false)
	end)
end)
