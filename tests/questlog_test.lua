local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")

local function Read(world, questID)
	local into = { objectives = {} }
	local ok = world.ns.QuestLog.Read(questID, into)
	return ok and into or nil
end

describe("QuestLog", function()
	it("strips the count from objective text in every known shape", function()
		local _, ns = Harness.Load()
		local Label = ns.QuestLog.Label
		expect({ Label("4/6 Boar Tusk") }).toEqual({ "Boar Tusk", true })
		expect({ Label("Boar Tusk: 4/6") }).toEqual({ "Boar Tusk", true })
		expect({ Label("Boar Tusk (4/6)") }).toEqual({ "Boar Tusk", true })
		expect({ Label("Boar Tusk: 6/6 (Complete)") }).toEqual({ "Boar Tusk", true })
		expect({ Label("Speak with Marshal Dughan") }).toEqual({ "Speak with Marshal Dughan", false })
		expect({ Label("10/10 Bear Meat") }).toEqual({ "Bear Meat", true })
	end)

	it("reads a quest with normalized objectives", function()
		local world = Harness.Boot({
			configure = function(w)
				Helpers.Have(w, Helpers.Quest(100, "The Boar Hunt", { { "Boar Tusk", 6, 2 }, { "Bear Meat", 10, 10 } }))
			end,
		})
		local quest = Read(world, 100)
		expect(quest.title).toBe("The Boar Hunt")
		expect(quest.complete).toBe(false)
		expect(quest.objectives[1]).toEqual({
			label = "Boar Tusk",
			fulfilled = 2,
			required = 6,
			done = false,
			hadCount = true,
			hidden = false,
		})
		expect(quest.visible).toBe(2)
		expect(quest.objectives[2].done).toBe(true)
	end)

	it("treats an unfinished objective as unfinished even at a full count (Forever's 1/1 quirk)", function()
		local world = Harness.Boot({
			configure = function(w)
				local quest = Helpers.Have(w, Helpers.Quest(100, "Quirk", { { "Gold Pickup Schedule", 1, 0 } }))
				quest.objectives[1].numFulfilled = 1
				quest.objectives[1].text = "1/1 Gold Pickup Schedule"
			end,
		})
		local objective = Read(world, 100).objectives[1]
		expect(objective.done).toBe(false)
		expect(objective.fulfilled).toBe(0)
		expect(objective.required).toBe(1)
	end)

	it("waits for data that hasn't loaded or is half written", function()
		local world = Harness.Boot({
			configure = function(w)
				Helpers.Have(w, Helpers.Quest(100, "Loading", { { "Boar Tusk", 6 } }))
				Helpers.Have(w, Helpers.Quest(101, "Padded", { { "Boar Tusk", 6 } }))
				Helpers.Have(w, Helpers.Quest(102, "Leading", { { "Boar Tusk", 6 } }))
				w.loadingQuests[100] = true
			end,
		})
		expect(Read(world, 100)).toBeNil()
		world:Quest(101).objectives[1].text = "0/6  "
		expect(Read(world, 101)).toBeNil()
		world:Quest(102).objectives[1].text = " : 0/6"
		expect(Read(world, 102)).toBeNil()
	end)

	it("keeps objectives without text in place, hidden, and counts them toward completion", function()
		local world = Harness.Boot({
			configure = function(w)
				local quest = Helpers.Have(w, Helpers.Quest(100, "Hidden", { { "Secret", 1 }, { "Boar Tusk", 6, 6 } }))
				quest.objectives[1].text = ""
			end,
		})
		local quest = Read(world, 100)
		expect(#quest.objectives).toBe(2)
		expect(quest.visible).toBe(1)
		expect(quest.objectives[1].hidden).toBe(true)
		expect(quest.objectives[2].label).toBe("Boar Tusk")
		expect(quest.complete).toBe(false)
	end)

	it("counts a quest without objectives as complete", function()
		local world = Harness.Boot({
			configure = function(w)
				Helpers.Have(w, Helpers.Quest(100, "Delivery", {}))
			end,
		})
		local quest = Read(world, 100)
		expect(quest.complete).toBe(true)
		expect(#quest.objectives).toBe(0)
	end)

	it("never calls a failed quest complete", function()
		local world = Harness.Boot({
			configure = function(w)
				Helpers.Have(w, Helpers.Quest(100, "Escort", { { "Escort", 1, 1, plain = true } }, { failed = true }))
			end,
		})
		local quest = Read(world, 100)
		expect(quest.failed).toBe(true)
		expect(quest.complete).toBe(false)
	end)

	it("writes announced objectives from the counts, not the possibly stale text", function()
		local world = Harness.Boot({
			configure = function(w)
				local quest =
					Helpers.Have(w, Helpers.Quest(100, "Hunt", { { "Boar slain", 6, 6 }, { "Find the cave", 1, 1 } }))
				quest.objectives[1].text = "5/6 Boar slain"
				quest.objectives[2].plain = true
				quest.objectives[2].text = "Find the cave"
			end,
		})
		local QuestLog = world.ns.QuestLog
		local quest = Read(world, 100)
		expect(QuestLog.ObjectiveText(quest.objectives[1])).toBe("6/6 Boar slain")
		expect(QuestLog.ObjectiveText(quest.objectives[2])).toBe("Find the cave")
	end)

	it("links the quest, or names it in brackets without a link", function()
		local world = Harness.Boot({
			configure = function(w)
				Helpers.Have(w, Helpers.Quest(100, "Hunt", {}))
			end,
		})
		expect(world.ns.QuestLog.Link(100, "Hunt")).toBe("|cffffff00|Hquest:100:10|h[Hunt]|h|r")
		local plain = Harness.Boot({ noQuestLinks = true })
		expect(plain.ns.QuestLog.Link(100, "Hunt")).toBe("[Hunt]")
	end)
end)

describe("Format", function()
	it("cuts text by bytes without splitting a character", function()
		local _, ns = Harness.Load()
		local Truncate = ns.Format.TruncateBytes
		expect(Truncate("abcdef", 4)).toBe("abcd")
		expect(Truncate("abc", 4)).toBe("abc")
		expect(Truncate("aé", 2)).toBe("a")
		expect(Truncate("a€b", 3)).toBe("a")
		expect(Truncate("a€b", 4)).toBe("a€")
		expect(Truncate("abc", 0)).toBe("")
	end)
end)
