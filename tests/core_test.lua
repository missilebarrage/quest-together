local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")

describe("Loading", function()
	it("loads every file listed in the TOC without errors", function()
		local world = Harness.Boot()
		expect(world.errors).toEqual({})
		expect(Harness.LeakedGlobals(world)).toEqual({})
	end)

	it("targets Forever and credits Tim", function()
		local metadata = Harness.TocMetadata()
		expect(metadata.Interface).toBe("16001")
		expect(metadata.Author).toBe("Tim")
		expect(metadata.SavedVariables).toBe("QuestTogetherDB")
	end)

	it("boots in a party with quests without errors", function()
		local world = Harness.Boot({
			configure = function(w)
				Helpers.Have(w, Helpers.Quest(100, "The Boar Hunt", { { "Boar Tusk", 6, 2 } }))
			end,
		})
		Helpers.Party(world)
		world:Advance(5)
		expect(world.errors).toEqual({})
	end)
end)
