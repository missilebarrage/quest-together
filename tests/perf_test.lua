local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")

describe("Performance", function()
	it("scans a full quest log and redraws the panel quickly", function()
		local world, ns = Harness.Boot({
			configure = function(w)
				for index = 1, 35 do
					local objectives = {}
					for objective = 1, 10 do
						objectives[objective] = { "Objective " .. objective, 10, objective % 10 }
					end
					Helpers.Have(w, Helpers.Quest(1000 + index, "Quest " .. index, objectives))
				end
			end,
		})
		Helpers.Party(world)
		ns.Database.Set("panelMode", "all")
		for slot = 1, 3 do
			local quests = {}
			for index = 1, 35 do
				quests[1000 + index] = true
			end
			world.units["party" .. slot].quests = quests
		end
		world:Advance(1)
		local started = os.clock()
		for round = 1, 200 do
			Helpers.Have(world, Helpers.Quest(5000 + round, "Extra", { { "Thing", 2 } }))
			world:Fire("QUEST_LOG_UPDATE")
			world:Advance(0.3)
		end
		local perScan = (os.clock() - started) / 200 * 1000
		-- Generous: the fake client is slower than the game, and CI machines vary.
		expect(perScan).toBeLessThan(25)
		expect(ns.Scanner.Stats().scans > 200).toBe(true)
	end)
end)
