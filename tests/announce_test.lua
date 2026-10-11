local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")

local LINK = "|cffffff00|Hquest:100:10|h[The Boar Hunt]|h|r"

local function Setup(options)
	options = options or {}
	local world, ns = Harness.Boot({
		configure = function(w)
			Helpers.Have(
				w,
				Helpers.Quest(
					100,
					"The Boar Hunt",
					options.objectives or { { "Boar slain", 6, 5 }, { "Bear Meat", 2, 0 } }
				)
			)
		end,
	})
	if options.party ~= false then
		Helpers.Party(world)
	end
	return world, ns
end

describe("Announce", function()
	it("posts a finished objective in party chat, worded like Questie", function()
		local world = Setup()
		Helpers.Progress(world, 100, 1, 6)
		expect(world:ChatLines()).toEqual({ "{rt1} 6/6 Boar slain for " .. LINK .. "!" })
		expect(world.chatSent[1].channel).toBe("PARTY")
	end)

	it("posts nothing for progress that doesn't finish an objective", function()
		local world = Setup()
		Helpers.Progress(world, 100, 2, 1)
		expect(world:ChatLines()).toEqual({})
	end)

	it("posts the last objective, then the completed quest", function()
		local world = Setup({ objectives = { { "Boar slain", 6, 5 }, { "Bear Meat", 2, 2 } } })
		Helpers.Progress(world, 100, 1, 6)
		world:Advance(1)
		expect(world:ChatLines()).toEqual({
			"{rt1} 6/6 Boar slain for " .. LINK .. "!",
			"{rt1} Quest Completed: " .. LINK,
		})
	end)

	it("spaces lines out instead of sending them all at once", function()
		local world = Setup({ objectives = { { "Boar slain", 6, 5 }, { "Bear Meat", 2, 2 } } })
		local objective = world:Quest(100).objectives[1]
		objective.numFulfilled, objective.finished, objective.text = 6, true, "6/6 Boar slain"
		world:Fire("QUEST_LOG_UPDATE")
		world:Advance(0.26)
		expect(#world.chatSent).toBe(1)
		world:Advance(0.3)
		expect(#world.chatSent).toBe(2)
	end)

	it("posts objectives without a count as the game words them", function()
		local world = Setup({ objectives = { { "Find the hidden cave", 1, 0, plain = true }, { "Bear Meat", 2 } } })
		Helpers.Progress(world, 100, 1, 1)
		expect(world:ChatLines()).toEqual({ "{rt1} Find the hidden cave for " .. LINK .. "!" })
	end)

	it("never posts what was already done at login", function()
		local world = Harness.Boot({
			configure = function(w)
				Helpers.Have(w, Helpers.Quest(100, "The Boar Hunt", { { "Boar slain", 6, 6 } }))
			end,
		})
		Helpers.Party(world)
		world:Fire("QUEST_LOG_UPDATE")
		world:Advance(2)
		expect(world:ChatLines()).toEqual({})
	end)

	it("isn't fooled by objective text that is briefly empty", function()
		local world = Setup({ objectives = { { "Boar slain", 6, 2 }, { "Bear Meat", 2, 2 } } })
		local objective = world:Quest(100).objectives[1]
		local text = objective.text
		objective.text = ""
		world:Fire("QUEST_LOG_UPDATE")
		world:Advance(1)
		objective.text = text
		world:Fire("QUEST_LOG_UPDATE")
		world:Advance(1)
		expect(world:ChatLines()).toEqual({})
		Helpers.Progress(world, 100, 1, 6)
		world:Advance(1)
		expect(world:ChatLines()).toEqual({
			"{rt1} 6/6 Boar slain for " .. LINK .. "!",
			"{rt1} Quest Completed: " .. LINK,
		})
	end)

	it("doesn't post a finished objective that read low right after login", function()
		local world = Harness.Boot({
			settle = false,
			configure = function(w)
				Helpers.Have(w, Helpers.Quest(100, "The Boar Hunt", { { "Boar slain", 6, 6 }, { "Bear Meat", 2 } }))
				w.group = "party"
				w.units.party1 = Helpers.Member(1, "Thrall")
				local objective = w.questLog[1].objectives[1]
				objective.numFulfilled, objective.finished, objective.text = 0, false, "0/6 Boar slain"
			end,
		})
		world:Advance(1)
		Helpers.Progress(world, 100, 1, 6)
		world:Advance(10)
		expect(world:ChatLines()).toEqual({})
		-- Once the window has passed, progress is real again.
		Helpers.Progress(world, 100, 2, 2)
		world:Advance(1)
		expect(world:ChatLines()).toEqual({
			"{rt1} 2/2 Bear Meat for " .. LINK .. "!",
			"{rt1} Quest Completed: " .. LINK,
		})
	end)

	it("posts each objective once, even after dropping below its count and getting back", function()
		local world = Setup()
		Helpers.Progress(world, 100, 1, 6)
		Helpers.Progress(world, 100, 1, 5)
		Helpers.Progress(world, 100, 1, 6)
		world:Advance(1)
		expect(#world:ChatLines()).toBe(1)
	end)

	it("posts again for a quest picked up again after turning it in", function()
		local world = Setup({ objectives = { { "Boar slain", 6, 5 } } })
		Helpers.Progress(world, 100, 1, 6)
		world:Advance(1)
		Helpers.Remove(world, 100)
		Helpers.Accept(world, Helpers.Quest(100, "The Boar Hunt", { { "Boar slain", 6, 5 } }))
		world:Advance(1)
		Helpers.Progress(world, 100, 1, 6)
		world:Advance(1)
		expect(#world:ChatLines()).toBe(4)
	end)

	it("doesn't post while solo, nor later for what was finished solo", function()
		local world = Setup({ party = false })
		Helpers.Progress(world, 100, 1, 6)
		Helpers.Party(world)
		world:Fire("QUEST_LOG_UPDATE")
		world:Advance(1)
		expect(world:ChatLines()).toEqual({})
	end)

	it("doesn't post in a raid", function()
		local world = Setup({ party = false })
		Helpers.JoinParty(world, { Helpers.Member(1, "Thrall") }, "raid")
		Helpers.Progress(world, 100, 1, 6)
		expect(world:ChatLines()).toEqual({})
	end)

	it("follows the two announcement settings", function()
		local world, ns = Setup({ objectives = { { "Boar slain", 6, 5 }, { "Bear Meat", 2, 2 } } })
		ns.Database.Set("announceObjectives", false)
		Helpers.Progress(world, 100, 1, 6)
		world:Advance(1)
		expect(world:ChatLines()).toEqual({ "{rt1} Quest Completed: " .. LINK })

		local other, otherNs = Setup({ objectives = { { "Boar slain", 6, 5 }, { "Bear Meat", 2, 2 } } })
		otherNs.Database.Set("announceQuests", false)
		Helpers.Progress(other, 100, 1, 6)
		other:Advance(1)
		expect(other:ChatLines()).toEqual({ "{rt1} 6/6 Boar slain for " .. LINK .. "!" })
	end)

	it("never posts a failed quest as completed", function()
		local world = Setup({ objectives = { { "Escort", 1, 0, plain = true } } })
		world:Quest(100).failed = true
		Helpers.Progress(world, 100, 1, 1)
		world:Advance(1)
		for _, line in ipairs(world:ChatLines()) do
			expect(line:find("Quest Completed", 1, true)).toBeNil()
		end
	end)

	it("waits while chat is locked down and posts when it's over", function()
		local world = Setup()
		world.chatLockdown = true
		Helpers.Progress(world, 100, 1, 6)
		world:Advance(10)
		expect(world:ChatLines()).toEqual({})
		world.chatLockdown = false
		world:Fire("ADDON_RESTRICTION_STATE_CHANGED", 5, 0)
		world:Advance(0.5)
		expect(#world:ChatLines()).toBe(1)
	end)

	it("drops lines that waited too long", function()
		local world, ns = Setup()
		world.chatLockdown = true
		Helpers.Progress(world, 100, 1, 6)
		world:Advance(130)
		world.chatLockdown = false
		world:Advance(10)
		expect(world:ChatLines()).toEqual({})
		expect(ns.Announce.Stats().stale).toBe(1)
	end)

	it("forgets queued lines when the party breaks up", function()
		local world = Setup()
		world.chatLockdown = true
		Helpers.Progress(world, 100, 1, 6)
		Helpers.LeaveParty(world)
		world.chatLockdown = false
		world:Advance(10)
		expect(world:ChatLines()).toEqual({})
	end)

	it("stops posting for the session when the game blocks it", function()
		local world, ns = Setup({ objectives = { { "Boar slain", 6, 5 }, { "Bear Meat", 2, 1 } } })
		world.blockChat = true
		Helpers.Progress(world, 100, 1, 6)
		expect(world:Output()).toContain("stopped Quest Together from posting")
		world.blockChat = false
		Helpers.Progress(world, 100, 2, 2)
		world:Advance(1)
		expect(world:ChatLines()).toEqual({})
		expect(select(3, ns.Announce.Stats())).toBe(true)
	end)

	it("keeps long lines within one chat message by shortening the objective, not the link", function()
		local long = string.rep("Very long objective name ", 12):sub(1, -2)
		local world = Setup({ objectives = { { long, 2, 1 } } })
		Helpers.Progress(world, 100, 1, 2)
		local line = world:ChatLines()[1]
		expect(#line <= 255).toBe(true)
		expect(line).toContain(LINK .. "!")
	end)

	it("mentions once that Questie announces too", function()
		local world = Harness.Boot({
			configure = function(w)
				w.loadedAddons.Questie = true
			end,
		})
		expect(world:Output()).toContain("Questie is loaded too")
		local again = Harness.Restart(world)
		expect(again:Output()).toBe("")
	end)
end)
