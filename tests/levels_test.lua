local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")

-- Opens a quest's reward window and turns it in. `levelUpTo` levels the player up in between,
-- the way the game reports a turn-in that levels you: level-up first, turn-in after.
local function TurnIn(world, questID, levelUpTo)
	world.questDetail = { questID = questID }
	world:Fire("QUEST_COMPLETE")
	world.questDetail = nil
	world:Fire("QUEST_FINISHED")
	if levelUpTo then
		world.player.level, world.player.xp = levelUpTo, 40
		world:Fire("PLAYER_LEVEL_UP", levelUpTo, 10, 5, 0, 0, 1, 1, 1, 1, 1)
	end
	world:Fire("QUEST_TURNED_IN", questID, 450, 100)
	world:Fire("QUEST_REMOVED", questID, false)
end

local function LevelUp(world, level)
	world.player.level, world.player.xp = level, 15
	world:Fire("PLAYER_LEVEL_UP", level, 10, 5, 0, 0, 1, 1, 1, 1, 1)
end

-- A character that starts its current level with Quest Together running, in a party.
local function Setup(options)
	options = options or {}
	local world, ns = Harness.Boot({ configure = options.configure })
	if options.party ~= false then
		Helpers.Party(world)
	end
	return world, ns
end

describe("Level-up announcements", function()
	it("posts how many quests were turned in at the level just finished", function()
		local world = Setup()
		TurnIn(world, 100)
		TurnIn(world, 101)
		LevelUp(world, 11)
		world:Advance(2)
		expect(world:ChatLines()).toEqual({})
		world:Advance(1.5)
		expect(world:ChatLines()).toEqual({ "[Quest Together]: 2 quests completed at Level 10!" })
		expect(world.chatSent[1].channel).toBe("PARTY")
	end)

	it("counts the turn-in that caused the level-up toward the old level", function()
		local world = Setup()
		TurnIn(world, 100)
		TurnIn(world, 101, 11)
		-- Turned in right after, but its reward window opened at the new level.
		TurnIn(world, 102)
		world:Advance(4)
		expect(world:ChatLines()).toEqual({ "[Quest Together]: 2 quests completed at Level 10!" })
		LevelUp(world, 12)
		world:Advance(4)
		expect(world:ChatLines()[2]).toBe("[Quest Together]: 1 quest completed at Level 11!")
	end)

	it("counts a quest turned in without a reward window right after the level-up toward the old level", function()
		local world = Setup()
		LevelUp(world, 11)
		world:Fire("QUEST_TURNED_IN", 200, 500, 0)
		world:Advance(4)
		expect(world:ChatLines()).toEqual({ "[Quest Together]: 1 quest completed at Level 10!" })
	end)

	it("posts a level without quests too", function()
		local world = Setup()
		LevelUp(world, 11)
		world:Advance(4)
		expect(world:ChatLines()).toEqual({ "[Quest Together]: 0 quests completed at Level 10!" })
	end)

	it("keeps counting across reloads and logouts", function()
		local world = Setup()
		TurnIn(world, 100)
		local again = Harness.Restart(world, { reload = true })
		TurnIn(again, 101)
		local later = Harness.Restart(again, { gap = 3600 })
		TurnIn(later, 102)
		LevelUp(later, 11)
		later:Advance(4)
		expect(later:ChatLines()).toEqual({ "[Quest Together]: 3 quests completed at Level 10!" })
	end)

	it("doesn't post a level it only saw part of, and says why", function()
		local world = Harness.Boot({
			configure = function(w)
				w.player.xp = 600 -- partway into level 10 when the addon first runs
			end,
		})
		Helpers.Party(world)
		TurnIn(world, 100)
		LevelUp(world, 11)
		world:Advance(4)
		expect(world:ChatLines()).toEqual({})
		expect(world:Output()).toContain("Level 10 was only partly tracked")
		-- The next level is tracked from its start.
		TurnIn(world, 101)
		LevelUp(world, 12)
		world:Advance(4)
		expect(world:ChatLines()).toEqual({ "[Quest Together]: 1 quest completed at Level 11!" })
	end)

	it("starts over when the level changed while it wasn't running", function()
		local world = Setup()
		TurnIn(world, 100)
		-- The character leveled to 12 with the addon disabled.
		local again = Harness.Restart(world, {
			configure = function(w)
				w.player.level, w.player.xp = 12, 900
			end,
		})
		TurnIn(again, 101)
		LevelUp(again, 13)
		again:Advance(4)
		expect(again:ChatLines()).toEqual({})
		expect(again:Output()).toContain("Level 12 was only partly tracked")
	end)

	it("doesn't post while solo or in a raid, or when switched off, but keeps counting right", function()
		local solo = Setup({ party = false })
		TurnIn(solo, 100)
		LevelUp(solo, 11)
		solo:Advance(4)
		Helpers.Party(solo)
		TurnIn(solo, 101)
		LevelUp(solo, 12)
		solo:Advance(4)
		expect(solo:ChatLines()).toEqual({ "[Quest Together]: 1 quest completed at Level 11!" })

		local raid = Setup({ party = false })
		Helpers.JoinParty(raid, { Helpers.Member(1, "Thrall") }, "raid")
		LevelUp(raid, 11)
		raid:Advance(4)
		expect(raid:ChatLines()).toEqual({})

		local off, ns = Setup()
		ns.Database.Set("announceLevels", false)
		LevelUp(off, 11)
		off:Advance(4)
		expect(off:ChatLines()).toEqual({})
	end)

	it("posts each of two quick level-ups", function()
		local world = Setup()
		TurnIn(world, 100)
		LevelUp(world, 11)
		world:Advance(1)
		LevelUp(world, 12)
		world:Advance(4)
		expect(world:ChatLines()).toEqual({
			"[Quest Together]: 1 quest completed at Level 10!",
			"[Quest Together]: 0 quests completed at Level 11!",
		})
	end)

	it("ignores a repeated level-up event", function()
		local world = Setup()
		LevelUp(world, 11)
		LevelUp(world, 11)
		world:Advance(4)
		expect(#world:ChatLines()).toBe(1)
	end)

	it("keeps each character's count to itself, also for a new character with an old name", function()
		local world = Setup()
		TurnIn(world, 100)
		TurnIn(world, 101)
		local remade = Harness.Restart(world, {
			configure = function(w)
				w.player.guid = "Player-1-0000BBBB"
				w.player.level, w.player.xp = 1, 0
			end,
		})
		TurnIn(remade, 102)
		LevelUp(remade, 2)
		remade:Advance(4)
		expect(remade:ChatLines()).toEqual({ "[Quest Together]: 1 quest completed at Level 1!" })
	end)

	it("has an option, a menu switch and a /qt debug line", function()
		local world, ns = Setup()
		expect(world.settingsCategories[1].settings.announceLevels).toBeTruthy()
		ns.Panel.Preview()
		local entry = Helpers.FindEntry(Helpers.OpenMenu(world), "Announce level-ups")
		entry.setSelected(entry.data)
		expect(ns.Database.Get("announceLevels")).toBe(false)
		TurnIn(world, 100)
		world.printed = {}
		world.env.SlashCmdList.QUESTTOGETHER("debug chat")
		expect(world:Output()).toContain("Level 10: 1 quests turned in so far, partly tracked no.")
	end)
end)
