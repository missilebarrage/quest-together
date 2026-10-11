local _, ns = ...

--- Small text helpers.
---@class QTFormat
local Format = ns.Format

local floor = math.floor

--- Wraps text in a |c colour escape.
---@param text string
---@param r number
---@param g number
---@param b number
---@return string
function Format.Color(text, r, g, b)
	return string.format("|cff%02x%02x%02x%s|r", floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5), text)
end

--- Cuts text to at most maxBytes bytes without splitting a UTF-8 character.
---@param text string
---@param maxBytes integer
---@return string
function Format.TruncateBytes(text, maxBytes)
	if #text <= maxBytes then
		return text
	end
	if maxBytes <= 0 then
		return ""
	end
	local cut = maxBytes
	-- Step back over continuation bytes (10xxxxxx) to the start of the cut character, then
	-- drop that character: it doesn't fit whole.
	local byte = text:byte(cut + 1)
	while byte and byte >= 0x80 and byte < 0xC0 and cut > 0 do
		cut = cut - 1
		byte = text:byte(cut + 1)
	end
	return text:sub(1, cut)
end

--- Joins a list of names with ", ".
---@param names string[]
---@return string
function Format.List(names)
	return table.concat(names, ", ")
end
