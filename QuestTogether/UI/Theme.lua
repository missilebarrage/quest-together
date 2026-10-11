local _, ns = ...

--- Visual tokens and shared drawing helpers. The look follows EllesmereUI: warm near-black
--- flat panels, 1-pixel hairline borders, white text graded by alpha, and one accent
--- colour used sparingly. When EllesmereUI is loaded, its live accent colour and font are
--- used; otherwise Forever's bronze default and Arial Narrow.
---@class QTTheme
local Theme = ns.Theme
local Events = ns.Events
local Format = ns.Format

Theme.COLORS = {
	panel = { 0.069, 0.058, 0.047, 0.95 },
	border = { 1, 1, 1, 0.08 },
	divider = { 1, 1, 1, 0.06 },
	hover = { 1, 1, 1, 0.06 },
	positive = { 0.45, 0.85, 0.45, 1 },
}

--- Text colours are white at different strengths.
Theme.TEXT = { primary = 1, dim = 0.53, muted = 0.41, faint = 0.3 }

-- EllesmereUI's default accent on the Forever client.
Theme.DEFAULT_ACCENT = { 0.863, 0.655, 0.498 }

local DEFAULT_FONT = "Fonts\\ARIALN.TTF"

-- Fonts --------------------------------------------------------------------------------

-- Text shadows only render when they come from a font object on this client, so every
-- string uses one of these.
local FONT_ROLES = {
	heading = { name = "QuestTogetherFontHeading", size = 12 },
	body = { name = "QuestTogetherFontBody", size = 12 },
	small = { name = "QuestTogetherFontSmall", size = 11 },
	label = { name = "QuestTogetherFontLabel", size = 10 },
}

local fonts = {}
for role, spec in pairs(FONT_ROLES) do
	local font = CreateFont(spec.name)
	font:SetShadowColor(0, 0, 0, 1)
	font:SetShadowOffset(1, -1)
	fonts[role] = font
end

-- Font:SetFont returns nothing and raises for a font file the client can't load.
local function TrySetFont(font, path, size)
	return pcall(font.SetFont, font, path, size, "") and font:GetFont() ~= nil
end

local function ApplyFont(path)
	for role, spec in pairs(FONT_ROLES) do
		if not TrySetFont(fonts[role], path, spec.size) then
			TrySetFont(fonts[role], STANDARD_TEXT_FONT, spec.size)
		end
	end
end
ApplyFont(DEFAULT_FONT)

---@param role "heading"|"body"|"small"|"label"
---@return table fontObject
function Theme.Font(role)
	return fonts[role]
end

-- Accent -------------------------------------------------------------------------------

local accent = { r = Theme.DEFAULT_ACCENT[1], g = Theme.DEFAULT_ACCENT[2], b = Theme.DEFAULT_ACCENT[3] }
local accentHex = nil
-- Regions painted with the accent, repainted when it changes. Weak keys: regions may go away.
local accentRegions = setmetatable({}, { __mode = "k" })

local function Paint(region, paint)
	if paint.kind == "text" then
		region:SetTextColor(accent.r, accent.g, accent.b, paint.alpha)
	elseif paint.kind == "vertex" then
		region:SetVertexColor(accent.r, accent.g, accent.b, paint.alpha)
	else
		region:SetColorTexture(accent.r, accent.g, accent.b, paint.alpha)
	end
end

---@return number r
---@return number g
---@return number b
function Theme.Accent()
	return accent.r, accent.g, accent.b
end

--- The accent as "rrggbb" for |c colour escapes.
---@return string
function Theme.AccentHex()
	if not accentHex then
		accentHex = string.format(
			"%02x%02x%02x",
			math.floor(accent.r * 255 + 0.5),
			math.floor(accent.g * 255 + 0.5),
			math.floor(accent.b * 255 + 0.5)
		)
	end
	return accentHex
end

--- Wraps text in the accent colour.
function Theme.AccentText(text)
	return Format.Color(text, accent.r, accent.g, accent.b)
end

--- Colours a region with the accent and keeps it in sync when the accent changes.
---@param region table texture or font string
---@param alpha number?
---@param kind "texture"|"text"|"vertex"|nil default "texture"
function Theme.PaintAccent(region, alpha, kind)
	local paint = { alpha = alpha or 1, kind = kind or "texture" }
	accentRegions[region] = paint
	Paint(region, paint)
end

--- Stops repainting a region with the accent.
function Theme.ForgetAccent(region)
	accentRegions[region] = nil
end

function Theme.SetAccent(r, g, b)
	if not (ns.Num(r) and ns.Num(g) and ns.Num(b)) then
		return
	end
	accent.r, accent.g, accent.b = r, g, b
	accentHex = nil
	for region, paint in pairs(accentRegions) do
		Paint(region, paint)
	end
	Events.Fire("QT_ACCENT_CHANGED")
end

-- Drawing helpers ------------------------------------------------------------------------

---@param frame table
---@param color number[]? defaults to the panel colour
---@param layer string? draw layer, default BACKGROUND
---@return table texture
function Theme.Fill(frame, color, layer)
	local texture = frame:CreateTexture(nil, layer or "BACKGROUND")
	texture:SetAllPoints()
	texture:SetColorTexture(unpack(color or Theme.COLORS.panel))
	return texture
end

--- Sets text colour to white at one of the Theme.TEXT strengths.
---@param fontString table
---@param strength "primary"|"dim"|"muted"|"faint"
function Theme.Tone(fontString, strength)
	fontString:SetTextColor(1, 1, 1, Theme.TEXT[strength])
end

local borders = setmetatable({}, { __mode = "k" })

local function LayoutBorder(frame, edges)
	-- One physical pixel, whatever the UI scale.
	local pixel = PixelUtil.GetPixelToUIUnitFactor() / frame:GetEffectiveScale()
	local top, bottom, left, right = edges[1], edges[2], edges[3], edges[4]
	top:SetHeight(pixel)
	bottom:SetHeight(pixel)
	left:SetWidth(pixel)
	right:SetWidth(pixel)
end

--- Draws a hairline border inside the frame's edges.
---@param frame table
---@param color number[]? defaults to Theme.COLORS.border
---@return table[] edges top, bottom, left, right textures
function Theme.Border(frame, color)
	color = color or Theme.COLORS.border
	local edges = {}
	for index = 1, 4 do
		local edge = frame:CreateTexture(nil, "BORDER")
		edge:SetColorTexture(unpack(color))
		edge:SetSnapToPixelGrid(false)
		edge:SetTexelSnappingBias(0)
		edges[index] = edge
	end
	edges[1]:SetPoint("TOPLEFT")
	edges[1]:SetPoint("TOPRIGHT")
	edges[2]:SetPoint("BOTTOMLEFT")
	edges[2]:SetPoint("BOTTOMRIGHT")
	edges[3]:SetPoint("TOPLEFT")
	edges[3]:SetPoint("BOTTOMLEFT")
	edges[4]:SetPoint("TOPRIGHT")
	edges[4]:SetPoint("BOTTOMRIGHT")
	borders[frame] = edges
	LayoutBorder(frame, edges)
	return edges
end

local dividers = setmetatable({}, { __mode = "k" })

local function LayoutDivider(line, parent)
	line:SetHeight(PixelUtil.GetPixelToUIUnitFactor() / parent:GetEffectiveScale())
end

--- A 1-pixel horizontal rule.
---@return table texture
function Theme.Divider(parent, color)
	local line = parent:CreateTexture(nil, "ARTWORK")
	line:SetColorTexture(unpack(color or Theme.COLORS.divider))
	line:SetSnapToPixelGrid(false)
	line:SetTexelSnappingBias(0)
	dividers[line] = parent
	LayoutDivider(line, parent)
	return line
end

--- Re-fits every border and divider to one physical pixel (after UI or window scale changes).
function Theme.RefreshPixels()
	for frame, edges in pairs(borders) do
		LayoutBorder(frame, edges)
	end
	for line, parent in pairs(dividers) do
		LayoutDivider(line, parent)
	end
end

-- Icons --------------------------------------------------------------------------------

local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Candidates in order of preference; the first file the client has wins.
local ICON_CANDIDATES = {
	check = { "Interface\\RaidFrame\\ReadyCheck-Ready", "Interface\\Buttons\\UI-CheckBox-Check" },
}

local resolvedIcons = {}
local missingIcons = {}
local canProbeFiles ---@type boolean?

-- GetFileIDFromPath tells whether the client has an icon. If it can't even find the
-- question mark, probing doesn't work on this client: trust the first candidate instead.
local function FileExists(path)
	if canProbeFiles == nil then
		canProbeFiles = GetFileIDFromPath ~= nil and GetFileIDFromPath(QUESTION_MARK) ~= nil
	end
	return not canProbeFiles or GetFileIDFromPath(path) ~= nil
end

--- Path of a themed icon, falling back to a question mark when the client lacks the art.
---@param key string
---@return string
function Theme.Icon(key)
	local resolved = resolvedIcons[key]
	if resolved then
		return resolved
	end
	for _, path in ipairs(ICON_CANDIDATES[key] or {}) do
		if FileExists(path) then
			resolved = path
			break
		end
	end
	if not resolved then
		missingIcons[key] = true
		resolved = QUESTION_MARK
	end
	resolvedIcons[key] = resolved
	return resolved
end

--- Icon keys whose art was missing, for /qt debug.
---@return string[]
function Theme.MissingIcons()
	local keys = {}
	for key in pairs(missingIcons) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

--- Adopts EllesmereUI's accent colour and font when it's loaded. Called at PLAYER_LOGIN.
function Theme.Init()
	local ellesmere = EllesmereUI
	if type(ellesmere) == "table" then
		if type(ellesmere.GetAccentColor) == "function" then
			local ok, r, g, b = pcall(ellesmere.GetAccentColor)
			if ok then
				Theme.SetAccent(r, g, b)
			end
		end
		if type(ellesmere.RegAccent) == "function" then
			pcall(ellesmere.RegAccent, {
				type = "callback",
				fn = function(r, g, b)
					Theme.SetAccent(r, g, b)
				end,
			})
		end
		if type(ellesmere.GetFontPath) == "function" then
			local ok, path = pcall(ellesmere.GetFontPath)
			if ok and type(path) == "string" and path ~= "" then
				ApplyFont(path)
			end
		end
	end
	Events.On("UI_SCALE_CHANGED", Theme.RefreshPixels)
	Events.On("DISPLAY_SIZE_CHANGED", Theme.RefreshPixels)
end
