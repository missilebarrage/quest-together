local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")

local function Setup(options)
	options = options or {}
	options.configure = function(w)
		Helpers.Have(w, Helpers.Quest(100, "The Boar Hunt", { { "Boar Tusk", 6, 6 }, { "Bear Meat", 10, 4 } }))
		Helpers.Have(w, Helpers.Quest(101, "Gather", { { "Herb", 5, 1 } }))
	end
	local world, ns = Harness.Boot(options)
	Helpers.JoinParty(world, {
		Helpers.Member(1, "Thrall"),
		Helpers.Member(2, "Jaina", { quests = { [100] = true } }),
		Helpers.Member(3, "Anduin"),
	})
	return world, ns
end

local function Enter(world, questID)
	world.blobs[questID] = true
	world:Fire("PLAYER_INSIDE_QUEST_BLOB_STATE_CHANGED", questID, true)
	world:Advance(0.2)
end

-- What the panel shows, row by row: the left text, then each shown cell ("✓" for a check).
local function Grid(world)
	local panel = world.env.QuestTogetherPanel
	local lines = {}
	for _, row in ipairs(panel.children or {}) do
		if row:IsShown() then
			local parts = { row.left:GetText() }
			for _, cell in ipairs(row.cells) do
				if cell.check:IsShown() then
					parts[#parts + 1] = "✓"
				elseif cell.text:IsShown() then
					parts[#parts + 1] = cell.text:GetText()
				end
			end
			lines[#lines + 1] = table.concat(parts, " | ")
		end
	end
	return lines
end

describe("Panel", function()
	it("shows the party's progress on the quest whose area the player is in", function()
		local world = Setup()
		-- Thrall runs the addon; Jaina doesn't but the game says she's on the quest.
		Helpers.AddonMessage(world, "Thrall Party1-TestRealm", "F1:a:1:1:100,-,4/6,10/10")
		Enter(world, 100)
		expect(world.env.QuestTogetherPanel:IsShown()).toBe(true)
		expect(Grid(world)).toEqual({
			"The Boar Hunt | You | Thrall | Jaina",
			"Boar Tusk | ✓ | 4/6 | ?",
			"Bear Meat | 4/10 | ✓ | ?",
			"Not on quest: Anduin",
		})
	end)

	it("leaves out objectives without text but keeps the others' columns right", function()
		local world = Harness.Boot({
			configure = function(w)
				local quest =
					Helpers.Have(w, Helpers.Quest(100, "The Boar Hunt", { { "Secret", 1 }, { "Boar Tusk", 6, 2 } }))
				quest.objectives[1].text = ""
			end,
		})
		Helpers.JoinParty(world, { Helpers.Member(1, "Thrall") })
		Helpers.AddonMessage(world, "Thrall Party1", "F1:a:1:1:100,-,0/1,5/6")
		Enter(world, 100)
		expect(Grid(world)).toEqual({ "The Boar Hunt | You | Thrall", "Boar Tusk | 2/6 | 5/6" })
	end)

	it("colours member names by class", function()
		local world = Setup()
		Helpers.AddonMessage(world, "Thrall Party1", "F1:a:1:1:100,-,4/6,10/10")
		Enter(world, 100)
		local title = world.env.QuestTogetherPanel.children[1]
		expect(title.cells[2].text.textColor).toEqual({ 0.96, 0.55, 0.73, 1 })
	end)

	it("lists members it knows nothing about separately", function()
		local world = Setup({ noUnitOnQuest = true })
		Enter(world, 100)
		expect(Grid(world)).toEqual({
			"The Boar Hunt | You",
			"Boar Tusk | ✓",
			"Bear Meat | 4/10",
			"No info: Thrall, Jaina, Anduin",
		})
	end)

	it("is hidden while solo, outside quest areas, or switched off", function()
		local world, ns = Harness.Boot({
			configure = function(w)
				Helpers.Have(w, Helpers.Quest(100, "The Boar Hunt", { { "Boar Tusk", 6, 2 } }))
			end,
		})
		Enter(world, 100)
		expect(world.env.QuestTogetherPanel).toBeNil()
		Helpers.Party(world)
		world:Advance(1)
		expect(world.env.QuestTogetherPanel:IsShown()).toBe(true)
		world.blobs[100] = false
		world:Fire("PLAYER_INSIDE_QUEST_BLOB_STATE_CHANGED", 100, false)
		world:Advance(6)
		expect(world.env.QuestTogetherPanel:IsShown()).toBe(false)
		Enter(world, 100)
		expect(world.env.QuestTogetherPanel:IsShown()).toBe(true)
		ns.Database.Set("panelEnabled", false)
		world:Advance(0.2)
		expect(world.env.QuestTogetherPanel:IsShown()).toBe(false)
	end)

	it("follows progress as it happens", function()
		local world = Setup()
		Enter(world, 100)
		Helpers.Progress(world, 100, 2, 7)
		expect(Grid(world)[3]).toBe("Bear Meat | 7/10 | ?")
		Helpers.AddonMessage(world, "Thrall Party1", "D1:100,-,5/6,2/10")
		world:Advance(0.2)
		expect(Grid(world)[3]).toBe("Bear Meat | 7/10 | 2/10 | ?")
	end)

	it("shows several quests, at most four, then how many more", function()
		local world, ns = Harness.Boot({
			configure = function(w)
				for index = 1, 6 do
					Helpers.Have(w, Helpers.Quest(100 + index, "Quest " .. index, { { "Thing", 3, 1 } }))
				end
			end,
		})
		Helpers.Party(world)
		ns.Database.Set("panelMode", "zone")
		world:Advance(0.5)
		local grid = Grid(world)
		expect(grid[1]).toBe("Quest 1 | You")
		expect(grid[#grid]).toBe("+2 more")
	end)

	it("doesn't create frames again when it refreshes", function()
		local world = Setup()
		Helpers.AddonMessage(world, "Thrall Party1", "F1:a:1:1:100,-,4/6,10/10")
		Enter(world, 100)
		world:Advance(1)
		local created = world.createdObjects
		for count = 1, 5 do
			Helpers.Progress(world, 100, 2, 4 + count)
		end
		world:Advance(1)
		expect(world.createdObjects).toBe(created)
	end)

	it("sizes itself to its content and keeps long names in their columns", function()
		local world = Setup()
		world.units.party1.name = "Thrallwithaverylongname"
		world:Fire("UNIT_NAME_UPDATE", "party1")
		Helpers.AddonMessage(world, "Thrallwithaverylongname Party1", "F1:a:1:1:100,-,4/6,10/10")
		Enter(world, 100)
		local panel = world.env.QuestTogetherPanel
		local title = panel.children[1]
		expect(title.cells[2].text.width).toBe(64)
		expect(panel:GetWidth() > 200).toBe(true)
		expect(panel:GetHeight() > 50).toBe(true)
	end)

	it("keeps its top-left corner in place when its size changes", function()
		local world, ns = Setup()
		Enter(world, 100)
		local panel = world.env.QuestTogetherPanel
		local left, top = panel:GetLeft(), panel:GetTop()
		ns.Database.Set("panelScale", 1.5)
		local point, _, relativePoint, x, y = panel:GetPoint(1)
		expect({ point, relativePoint }).toEqual({ "TOPLEFT", "BOTTOMLEFT" })
		expect(x).toBeCloseTo(left / 1.5)
		expect(y).toBeCloseTo(top / 1.5)
		expect(world.env.QuestTogetherDB.windows.panel.point).toBe("TOPLEFT")
	end)

	it("moves only with Shift held, and remembers where it was put", function()
		local world = Setup()
		Enter(world, 100)
		local panel = world.env.QuestTogetherPanel
		panel:GetScript("OnMouseDown")(panel, "LeftButton")
		expect(panel.moving).toBeNil()
		world.shiftDown = true
		panel:GetScript("OnMouseDown")(panel, "LeftButton")
		expect(panel.moving).toBe(true)
		panel:GetScript("OnMouseUp")(panel, "LeftButton")
		local saved = world.env.QuestTogetherDB.windows.panel
		expect(saved.point).toBe("TOPLEFT")
		local reloaded = Harness.Restart(world, { reload = true })
		reloaded:Fire("PLAYER_INSIDE_QUEST_BLOB_STATE_CHANGED", 100, true)
		reloaded:Advance(0.2)
		local point, _, relativePoint, x, y = reloaded.env.QuestTogetherPanel:GetPoint(1)
		expect({ point, relativePoint, x, y }).toEqual({ saved.point, saved.relativePoint, saved.x, saved.y })
	end)

	it("fades only its background with the opacity setting, and scales", function()
		local world, ns = Setup()
		Enter(world, 100)
		local panel = world.env.QuestTogetherPanel
		ns.Database.Set("panelOpacity", 0)
		expect(panel.background.color[4]).toBe(0)
		ns.Database.Set("panelScale", 1.25)
		expect(panel:GetScale()).toBe(1.25)
	end)

	it("offers modes, switches and sharing in its menu", function()
		local world, ns = Setup()
		Enter(world, 100)
		local entries = Helpers.OpenMenu(world)
		local zone = Helpers.FindEntry(entries, "In this zone")
		expect(zone.kind).toBe("radio")
		zone.setSelected(zone.data)
		expect(ns.Database.Get("panelMode")).toBe("zone")
		local autoShare = Helpers.FindEntry(entries, "Share accepted quests")
		autoShare.setSelected(autoShare.data)
		expect(ns.Database.Get("autoShare")).toBe(false)
		local share = Helpers.FindEntry(entries, "Share quests the party is missing (2)")
		expect(share.disabled).toBeFalsy()
		local hide = Helpers.FindEntry(entries, "Hide panel")
		hide.callback()
		expect(ns.Database.Get("panelEnabled")).toBe(false)
		expect(world:Output()).toContain("/qt panel turns it back on")
	end)

	it("greys out sharing when nobody is missing anything", function()
		local world = Setup()
		for slot = 1, 3 do
			world.units["party" .. slot].quests = { [100] = true, [101] = true }
		end
		Enter(world, 100)
		local share = Helpers.FindEntry(Helpers.OpenMenu(world), "Share quests the party is missing (0)")
		expect(share.disabled).toBe(true)
	end)

	it("shows example content to place it while solo, for a while", function()
		local world, ns = Harness.Boot()
		ns.Panel.Preview()
		expect(Grid(world)).toEqual({
			"The Boar Hunt | You | Thrall | Jaina",
			"Boar Tusk | ✓ | 4/6 | 2/6",
			"Bear Meat | ✓ | ✓ | 3/10",
			"Not on quest: Anduin",
		})
		world:Advance(31)
		expect(world.env.QuestTogetherPanel:IsShown()).toBe(false)
	end)

	it("explains itself and each member's source on hover", function()
		local world = Setup({ version = "0.1.0" })
		Helpers.AddonMessage(world, "Thrall Party1", "H1:0.1.0")
		Helpers.AddonMessage(world, "Thrall Party1", "F1:a:1:1:100,-,4/6,10/10")
		Enter(world, 100)
		local panel = world.env.QuestTogetherPanel
		panel:GetScript("OnEnter")(panel)
		local text = {}
		for _, line in ipairs(world.env.GameTooltip.lines) do
			text[#text + 1] = table.concat({ tostring(line[1]), tostring(line[2]) }, " ")
		end
		local joined = table.concat(text, "\n")
		expect(joined).toContain("Quest Together 0.1.0")
		expect(joined).toContain("no Quest Together")
		expect(joined).toContain("Shift-drag to move")
	end)
end)

describe("Options", function()
	it("registers every setting with Blizzard's settings panel", function()
		local world = Harness.Boot()
		local category = world.settingsCategories[1]
		expect(category.name).toBe("Quest Together")
		expect(category.registered).toBe(true)
		for _, key in ipairs({
			"autoShare",
			"autoAccept",
			"announceObjectives",
			"announceQuests",
			"panelEnabled",
			"panelMode",
			"panelScale",
			"panelOpacity",
		}) do
			expect(category.settings[key]).toBeTruthy()
		end
	end)

	it("stays in sync with changes made elsewhere", function()
		local world, ns = Harness.Boot()
		local setting = world.settingsCategories[1].settings.autoShare
		ns.Database.Set("autoShare", false)
		expect(setting.notified).toBe(1)
		setting:SetValue(true)
		expect(ns.Database.Get("autoShare")).toBe(true)
	end)

	it("keeps settings across sessions and repairs invalid ones", function()
		local world, ns = Harness.Boot()
		ns.Database.Set("autoAccept", true)
		world.env.QuestTogetherDB.settings.panelMode = "nonsense"
		local _, again = Harness.Restart(world)
		expect(again.Database.Get("autoAccept")).toBe(true)
		expect(again.Database.Get("panelMode")).toBe("areas")
	end)

	it("leaves settings from a newer version untouched", function()
		local world = Harness.Boot({ saved = { QuestTogetherDB = { schema = 99, settings = { autoShare = false } } } })
		expect(world.ns.Database.Get("autoShare")).toBe(true)
		expect(world.env.QuestTogetherDB.schema).toBe(99)
		expect(world:Output()).toContain("newer version")
	end)

	it("won't open during combat", function()
		local world, ns = Harness.Boot()
		world.combat = true
		ns.Options.Open()
		expect(world.openedSettings).toEqual({})
		world.combat = false
		ns.Options.Open()
		expect(world.openedSettings).toEqual({ 77 })
	end)
end)

describe("Slash commands", function()
	local function Slash(world, text)
		world.env.SlashCmdList.QUESTTOGETHER(text)
	end

	it("prints the status and help", function()
		local world = Harness.Boot()
		Slash(world, "")
		expect(world:Output()).toContain("Share accepted quests: on")
		expect(world:Output()).toContain("/qt options")
	end)

	it("toggles the panel, previews it and opens the options", function()
		local world, ns = Harness.Boot()
		Slash(world, "panel")
		expect(ns.Database.Get("panelEnabled")).toBe(false)
		Slash(world, "PANEL")
		expect(ns.Database.Get("panelEnabled")).toBe(true)
		Slash(world, "preview")
		expect(world.env.QuestTogetherPanel:IsShown()).toBe(true)
		Slash(world, "options")
		expect(world.openedSettings).toEqual({ 77 })
	end)

	it("prints diagnostics without names, titles or objective text", function()
		local world = Setup()
		Helpers.AddonMessage(world, "Thrall Party1", "F1:a:1:1:100,-,4/6,10/10")
		Enter(world, 100)
		world.partyProgress[100] = { { type = 18, leftText = "Jaina" }, { type = 8, leftText = "1/6 Boar Tusk" } }
		world.printed = {}
		for _, topic in ipairs({ "", "quests", "areas", "peers", "tooltip 100", "chat", "share", "comm" }) do
			Slash(world, "debug " .. topic)
		end
		local output = world:Output()
		expect(#world.printed > 15).toBe(true)
		for _, private in ipairs({ "Thrall", "Jaina", "Anduin", "Tester", "Boar", "Bear", "Gather", "Herb" }) do
			expect(output:find(private, 1, true)).toBeNil()
		end
		expect(world.errors).toEqual({})
	end)
end)

describe("Localization", function()
	it("defines every string the addon uses", function()
		local _, ns = Harness.Load()
		local defined = {}
		for key in pairs(ns.L) do
			defined[key] = true
		end
		local missing = {}
		for _, file in ipairs(Harness.TocFiles()) do
			local source = io.open(ROOT_DIR .. "/QuestTogether/" .. file):read("*a")
			for key in source:gmatch("L%.([%u_%d]+)") do
				if not defined[key] then
					missing[#missing + 1] = key
				end
			end
		end
		expect(missing).toEqual({})
	end)
end)
