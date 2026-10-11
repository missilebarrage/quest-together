local addonName, ns = ...

--- Start-up wiring and the /qt command.
local Events = ns.Events
local Database = ns.Database
local L = ns.L

Events.On("ADDON_LOADED", function(name)
	if name == addonName then
		Database.Init()
	end
end)

-- Separate handlers, so a failure in one part can't keep the others from starting.
for _, initialize in ipairs({
	ns.Theme.Init,
	ns.Transport.Init,
	ns.PushResults.Init,
	ns.Options.Init,
	ns.Announce.Init,
	ns.Scanner.Start,
	ns.Areas.Update,
}) do
	Events.On("PLAYER_LOGIN", initialize)
end

local COMMANDS = {
	panel = function()
		ns.Panel.Toggle()
	end,
	preview = function()
		ns.Panel.Preview()
	end,
	share = function(argument)
		if argument == "stop" then
			ns.Share.Stop()
		else
			ns.Share.ShareMissing()
		end
	end,
	options = function()
		ns.Options.Open()
	end,
	debug = function(argument)
		ns.Debug.Run(argument)
	end,
}

local function Status()
	local function OnOff(key)
		return Database.Get(key) and L.ON or L.OFF
	end
	ns.Print(
		L.STATUS:format(
			OnOff("autoShare"),
			OnOff("autoAccept"),
			OnOff("announceObjectives"),
			OnOff("announceQuests"),
			OnOff("panelEnabled")
		)
	)
	ns.Print(L.HELP)
end

SLASH_QUESTTOGETHER1 = "/qt"
SLASH_QUESTTOGETHER2 = "/questtogether"
SlashCmdList.QUESTTOGETHER = function(message)
	local command, argument = (message or ""):match("^%s*(%S*)%s*(.-)%s*$")
	local handler = COMMANDS[command:lower()]
	if handler then
		handler(argument:lower())
	else
		Status()
	end
end
