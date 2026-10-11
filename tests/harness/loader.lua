-- Loads the addon into a fresh sandbox the way the client does: files in TOC order,
-- each called with (addonName, namespace).

local Wow = dofile(HARNESS_DIR .. "/wow.lua")

local Loader = {}
Loader.Wow = Wow
Loader.SECRET = Wow.SECRET
Loader.ADDON = "QuestTogether"
--- Every world created during the current test (errors in them fail the test).
Loader.created = {}

local ADDON_DIR = ROOT_DIR .. "/QuestTogether"
local TOC = ADDON_DIR .. "/QuestTogether.toc"

-- Globals the addon is allowed to create.
local ALLOWED_GLOBALS = {
	QuestTogetherDB = true,
	SLASH_QUESTTOGETHER1 = true,
	SLASH_QUESTTOGETHER2 = true,
	QuestTogetherPanel = true,
	QuestTogetherFontHeading = true,
	QuestTogetherFontBody = true,
	QuestTogetherFontSmall = true,
	QuestTogetherFontLabel = true,
}
Loader.ALLOWED_GLOBALS = ALLOWED_GLOBALS

--- The addon's files, in load order, as listed in the TOC.
function Loader.TocFiles()
	local files = {}
	for line in io.lines(TOC) do
		line = line:gsub("\r$", "")
		if line ~= "" and not line:match("^#") then
			files[#files + 1] = (line:gsub("\\", "/"))
		end
	end
	return files
end

--- The TOC's "## Key: Value" metadata.
function Loader.TocMetadata()
	local metadata = {}
	for line in io.lines(TOC) do
		local key, value = line:match("^##%s*([%w%-_]+)%s*:%s*(.-)%s*$")
		if key then
			metadata[key] = value
		end
	end
	return metadata
end

--- Creates a world, loads every addon file into it and returns world, ns.
---@param options table? world options (noBlobApi, noUnitOnQuest, ellesmere, saved, configure, ...)
function Loader.Load(options)
	options = options or {}
	local world = Wow.NewWorld(options)
	Loader.created[#Loader.created + 1] = world
	if options.configure then
		options.configure(world)
	end
	local env = Wow.CreateEnvironment(world)
	if options.saved then
		env.QuestTogetherDB = Wow.RoundTrip(options.saved.QuestTogetherDB)
	end
	local ns = {}
	for _, file in ipairs(Loader.TocFiles()) do
		local chunk = assert(loadfile(ADDON_DIR .. "/" .. file))
		setfenv(chunk, env)
		chunk(Loader.ADDON, ns)
	end
	world.ns = ns
	return world, ns
end

--- Loads the addon and plays the login sequence through the first world entry, then lets
--- the first scans and roster reads run.
function Loader.Boot(options)
	options = options or {}
	local world, ns = Loader.Load(options)
	world:Fire("ADDON_LOADED", Loader.ADDON)
	world:Fire("PLAYER_LOGIN")
	local isReload = options.reload == true
	world:Fire("PLAYER_ENTERING_WORLD", not isReload, isReload)
	if options.settle ~= false then
		world:Advance(options.settleSeconds or 6)
	end
	return world, ns
end

--- Logs out (or reloads), writes saved variables through a serialization round trip,
--- then starts a new client session from them.
function Loader.Restart(world, restartOptions)
	restartOptions = restartOptions or {}
	world:Fire("PLAYER_LEAVING_WORLD")
	world:Fire("PLAYER_LOGOUT")
	local options = {}
	for key, value in pairs(world.options) do
		options[key] = value
	end
	options.saved = { QuestTogetherDB = world.env.QuestTogetherDB }
	options.reload = restartOptions.reload == true
	options.settle = restartOptions.settle
	options.now = world.clock.server + (restartOptions.gap or 0)
	options.configure = function(newWorld)
		for _, key in ipairs({ "player", "units", "group", "questLog", "blobs", "partyProgress" }) do
			newWorld[key] = world[key]
		end
		if restartOptions.configure then
			restartOptions.configure(newWorld)
		end
	end
	return Loader.Boot(options)
end

function Loader.LeakedGlobals(world)
	return world:LeakedGlobals(ALLOWED_GLOBALS)
end

return Loader
