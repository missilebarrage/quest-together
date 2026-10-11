local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")

-- Records every scanner signal in order.
local function Listen(world)
	local log = {}
	for _, signal in ipairs({
		"QT_QUEST_ADDED",
		"QT_OBJECTIVE_DONE",
		"QT_QUEST_DONE",
		"QT_QUEST_CHANGED",
		"QT_QUEST_REMOVED",
	}) do
		world.ns.Events.On(signal, function(questID, index)
			log[#log + 1] = signal:sub(4) .. ":" .. questID .. (index and (":" .. index) or "")
		end)
	end
	return log
end

local function BootWith(quests)
	return Harness.Boot({
		configure = function(w)
			for _, quest in ipairs(quests) do
				Helpers.Have(w, quest)
			end
		end,
	})
end

describe("Scanner", function()
	it("takes the log at login as its baseline without reporting finished objectives", function()
		local world, ns = Harness.Boot({
			settle = false,
			configure = function(w)
				Helpers.Have(w, Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 6 }, { "Bear Meat", 10, 3 } }))
				Helpers.Have(w, Helpers.Quest(101, "Delivery", {}))
			end,
		})
		local log = Listen(world)
		world:Advance(1)
		expect(log).toEqual({ "QUEST_ADDED:100", "QUEST_ADDED:101" })
		expect(ns.Scanner.Quests()).toEqual({ 100, 101 })
		expect(ns.Scanner.Get(100).objectives[1].done).toBe(true)
	end)

	it("reports an objective finishing, then the quest completing, then the change", function()
		local world, ns = BootWith({ Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 5 }, { "Bear Meat", 2, 2 } }) })
		local log = Listen(world)
		Helpers.Progress(world, 100, 1, 6)
		expect(log).toEqual({ "OBJECTIVE_DONE:100:1", "QUEST_DONE:100", "QUEST_CHANGED:100" })
		expect(ns.Scanner.Get(100).complete).toBe(true)
	end)

	it("reports plain progress as a change only", function()
		local world = BootWith({ Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 1 } }) })
		local log = Listen(world)
		Helpers.Progress(world, 100, 1, 2)
		expect(log).toEqual({ "QUEST_CHANGED:100" })
	end)

	it("reports nothing when nothing changed", function()
		local world = BootWith({ Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 1 } }) })
		local log = Listen(world)
		world:Fire("QUEST_LOG_UPDATE")
		world:Advance(1)
		expect(log).toEqual({})
	end)

	it("batches a burst of log updates into one scan", function()
		local world, ns = BootWith({ Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 1 } }) })
		local before = ns.Scanner.Stats().scans
		for _ = 1, 20 do
			world:Fire("QUEST_LOG_UPDATE")
		end
		world:Advance(1)
		expect(ns.Scanner.Stats().scans).toBe(before + 1)
	end)

	it("adds a newly accepted quest as a baseline even when it's already done", function()
		local world = BootWith({})
		local log = Listen(world)
		Helpers.Accept(world, Helpers.Quest(200, "Collected", { { "Bear Meat", 4, 4 } }))
		world:Advance(1)
		expect(log).toEqual({ "QUEST_ADDED:200" })
	end)

	it("retries quests whose data is still loading and asks the client to load them", function()
		local world, ns = Harness.Boot({
			settle = false,
			configure = function(w)
				Helpers.Have(w, Helpers.Quest(100, "Slow", { { "Boar Tusk", 6, 2 } }))
				w.loadingQuests[100] = true
			end,
		})
		local log = Listen(world)
		world:Advance(2)
		expect(ns.Scanner.Get(100)).toBeNil()
		expect(world.requestedQuests).toEqual({ 100 })
		world.loadingQuests[100] = nil
		world:Advance(1.5)
		expect(log).toEqual({ "QUEST_ADDED:100" })
		expect(world.requestedQuests).toEqual({ 100 })
	end)

	it("removes quests that are turned in or abandoned", function()
		local world, ns = BootWith({ Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 1 } }) })
		local log = Listen(world)
		Helpers.Remove(world, 100)
		expect(log).toEqual({ "QUEST_REMOVED:100" })
		expect(ns.Scanner.Get(100)).toBeNil()
		expect(ns.Scanner.Quests()).toEqual({})
	end)

	it("notices a quest gone from the log even without QUEST_REMOVED", function()
		local world, ns = BootWith({ Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 1 } }) })
		local log = Listen(world)
		table.remove(world.questLog, 1)
		for _ = 1, 2 do
			world:Fire("QUEST_LOG_UPDATE")
			world:Advance(0.5)
		end
		expect(log).toEqual({ "QUEST_REMOVED:100" })
		expect(ns.Scanner.Get(100)).toBeNil()
	end)

	it("keeps reading quests the log stops listing while the player is still on them", function()
		local world, ns = BootWith({ Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 1 } }) })
		-- Collapsing a header hides its quests from the log walk.
		world.questLog[1].hidden = true
		Helpers.Progress(world, 100, 1, 3)
		expect(ns.Scanner.Get(100).objectives[1].fulfilled).toBe(3)
	end)

	it("holds back lower counts right after a loading screen, then applies real ones", function()
		local world, ns = BootWith({ Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 4 } }) })
		local log = Listen(world)
		world:Fire("PLAYER_ENTERING_WORLD", false, false)
		-- Stale data right after the loading screen.
		Helpers.Progress(world, 100, 1, 0)
		expect(ns.Scanner.Get(100).objectives[1].fulfilled).toBe(4)
		-- The real count comes back: nothing to report.
		Helpers.Progress(world, 100, 1, 4)
		world:Advance(6)
		expect(log).toEqual({})
		-- A drop that is still there after the window is real.
		world:Fire("PLAYER_ENTERING_WORLD", false, false)
		Helpers.Progress(world, 100, 1, 1)
		expect(ns.Scanner.Get(100).objectives[1].fulfilled).toBe(4)
		world:Advance(6)
		expect(ns.Scanner.Get(100).objectives[1].fulfilled).toBe(1)
		expect(log).toEqual({ "QUEST_CHANGED:100" })
	end)

	it("reports an objective that gets finished again after dropping below its count", function()
		local world = BootWith({ Helpers.Quest(100, "Hunt", { { "Boar Tusk", 6, 6 }, { "Bear Meat", 2 } }) })
		local log = Listen(world)
		Helpers.Progress(world, 100, 1, 5)
		Helpers.Progress(world, 100, 1, 6)
		expect(log).toEqual({ "QUEST_CHANGED:100", "OBJECTIVE_DONE:100:1", "QUEST_CHANGED:100" })
	end)

	it("ignores quest events before login", function()
		local world, ns = Harness.Load()
		world:Fire("ADDON_LOADED", "QuestTogether")
		world:Fire("QUEST_LOG_UPDATE")
		world:Advance(1)
		expect(ns.Scanner.Stats().scans).toBe(0)
	end)
end)
