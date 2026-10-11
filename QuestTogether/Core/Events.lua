local _, ns = ...

--- One event frame for the whole addon. Game events and internal signals share a single
--- API; internal signal names start with "QT_" and never touch the frame.
---@class QTEvents
local Events = ns.Events

local INTERNAL_PREFIX = "QT_"

local frame = CreateFrame("Frame")
local handlers = {} ---@type table<string, function[]>
local pendingDebounces = {} ---@type table<string, boolean>

-- securecallfunction isolates handlers: one failing handler reports its error without
-- stopping the others.
local call = securecallfunction or function(handler, ...)
	return handler(...)
end

local function IsInternal(name)
	return name:sub(1, #INTERNAL_PREFIX) == INTERNAL_PREFIX
end

local function Dispatch(name, ...)
	local list = handlers[name]
	if not list then
		return
	end
	for index = 1, #list do
		call(list[index], ...)
	end
end

frame:SetScript("OnEvent", function(_, event, ...)
	Dispatch(event, ...)
end)

--- Subscribes to a game event or internal signal. Handlers receive the event payload
--- (without the event name). Returns false when the client doesn't know the game event.
---@param name string
---@param handler function
---@return boolean registered
function Events.On(name, handler)
	local list = handlers[name]
	if not list then
		if not IsInternal(name) then
			-- Unknown events raise an error; optional events must not break loading.
			local ok, registered = pcall(frame.RegisterEvent, frame, name)
			if not ok or registered == false then
				return false
			end
		end
		list = {}
		handlers[name] = list
	end
	list[#list + 1] = handler
	return true
end

--- Removes a handler. Lists are replaced rather than edited, so an event that is
--- currently dispatching keeps iterating safely.
---@param name string
---@param handler function
function Events.Off(name, handler)
	local list = handlers[name]
	if not list then
		return
	end
	local kept = {}
	for _, existing in ipairs(list) do
		if existing ~= handler then
			kept[#kept + 1] = existing
		end
	end
	if #kept > 0 then
		handlers[name] = kept
		return
	end
	handlers[name] = nil
	if not IsInternal(name) then
		frame:UnregisterEvent(name)
	end
end

--- Fires an internal signal ("QT_*") synchronously.
---@param name string
function Events.Fire(name, ...)
	Dispatch(name, ...)
end

--- Runs fn once, delay seconds after the first call in a burst; later calls during the
--- wait are absorbed.
---@param key string
---@param delay number
---@param fn function
function Events.Debounce(key, delay, fn)
	if pendingDebounces[key] then
		return
	end
	pendingDebounces[key] = true
	C_Timer.After(delay, function()
		pendingDebounces[key] = nil
		call(fn)
	end)
end
