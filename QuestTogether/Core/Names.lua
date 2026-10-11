local _, ns = ...

--- Player names. On Forever a character has a first name and a surname: the game shows
--- them joined by a separator, and the second value of UnitName is the surname rather than
--- a realm. Names reach the addon in different shapes ("First", "First Surname", either with a
--- "-Realm" suffix), so they are compared part by part instead of as whole strings.
---@class QTNames
local Names = ns.Names

local FALLBACK_SEPARATOR = " "

---@return string
function Names.SurnameSeparator()
	local constants = Constants and Constants.CharacterNameSeparatorConsts
	local separator = constants and constants.CHARACTERNAME_SURNAME_SEPARATOR
	return type(separator) == "string" and separator ~= "" and separator or FALLBACK_SEPARATOR
end

local function Realm()
	return GetNormalizedRealmName() or ""
end

--- The player's first name and surname (nil when the character has none).
---@return string firstName
---@return string? surname
function Names.PlayerParts()
	local name, second = UnitName("player")
	name, second = ns.Str(name) or "", ns.Str(second)
	-- Outside Forever the second value is a realm, not a surname.
	if second == "" or second == Realm() or (GetRealmName and second == GetRealmName()) then
		second = nil
	end
	return name, second
end

--- How the game displays the player's name: "First Surname" on Forever.
---@return string
function Names.PlayerDisplayName()
	if NameUtil and NameUtil.FormatUnitNameForDisplay then
		local ok, name = pcall(NameUtil.FormatUnitNameForDisplay, "player")
		name = ok and ns.Str(name)
		if name and name ~= "" then
			return name
		end
	end
	local first, surname = Names.PlayerParts()
	return surname and (first .. Names.SurnameSeparator() .. surname) or first
end

--- The player's full name with realm, in the shape chat uses ("First Surname-Realm").
---@return string
function Names.PlayerFullName()
	local first, surname = Names.PlayerParts()
	local base = surname and (first .. Names.SurnameSeparator() .. surname) or first
	return base .. "-" .. Realm()
end

--- Splits "First Surname-Realm" (any part but the first optional) into its parts.
---@param fullName string
---@return string first
---@return string? surname
---@return string? realm
function Names.Parse(fullName)
	local base, realm = fullName:match("^(.-)%-(.+)$")
	base = base or fullName
	local separator = Names.SurnameSeparator()
	local cut = base:find(separator, 1, true)
	if cut then
		return base:sub(1, cut - 1), base:sub(cut + #separator), realm
	end
	return base, nil, realm
end

local function SameOptional(a, b)
	return a == nil or b == nil or a:lower() == b:lower()
end

--- Whether two name strings refer to the same character. Parts missing from either side
--- (surname, realm) are not compared.
---@param a string
---@param b string
---@return boolean
function Names.Same(a, b)
	local firstA, surnameA, realmA = Names.Parse(a)
	local firstB, surnameB, realmB = Names.Parse(b)
	return firstA:lower() == firstB:lower() and SameOptional(surnameA, surnameB) and SameOptional(realmA, realmB)
end

---@param name string
---@return boolean
function Names.IsPlayer(name)
	return Names.Same(name, Names.PlayerFullName())
end

--- The first name of "First Surname-Realm" (or of any shorter shape).
---@param fullName string
---@return string
function Names.First(fullName)
	return (Names.Parse(fullName))
end
