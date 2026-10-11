-- Fake widget objects (frames, textures, font strings) for running addon code outside
-- the game. Methods record state where tests need it; calling a method that isn't in
-- the known widget API raises an error, which catches typos in UI code.

local Widgets = {}

local METHODS = {}

local function Define(names, implementation)
	for name in names:gmatch("%S+") do
		METHODS[name] = implementation or function() end
	end
end
Widgets.Define = Define

-- No-op methods that only need to exist.
Define([[
	SetFrameStrata SetFrameLevel SetToplevel SetClampedToScreen SetMovable SetResizable EnableMouse
	EnableMouseWheel EnableKeyboard SetPropagateKeyboardInput RegisterForDrag RegisterForClicks StartMoving
	SetUserPlaced SetHitRectInsets SetClipsChildren Raise Lower SetFixedFrameStrata SetFixedFrameLevel
	SetDontSavePosition SetIgnoreParentScale SetIgnoreParentAlpha SetFlattensRenderLayers SetFrameBuffer
	SetMotionScriptsWhileDisabled SetNormalTexture SetHighlightTexture SetPushedTexture SetDisabledTexture
	SetNormalFontObject SetHighlightFontObject SetDisabledFontObject SetFontString
	SetTexCoord SetDesaturated SetBlendMode SetDrawLayer SetRotation SetSnapToPixelGrid
	SetTexelSnappingBias SetGradient SetHorizTile SetVertTile SetMask AddMaskTexture
	SetJustifyH SetJustifyV SetWordWrap SetNonSpaceWrap SetMaxLines SetSpacing SetShadowOffset
	SetShadowColor SetIndentedWordWrap
	SetAutoFocus SetMultiLine SetMaxLetters SetMaxBytes HighlightText SetFocus ClearFocus SetTextInsets
	SetCursorPosition SetCountInvisibleLetters SetHistoryLines
	SetCreature SetDisplayInfo ClearModel SetCamDistanceScale SetPortraitZoom SetPosition SetFacing
	SetModelScale RefreshCamera SetKeepModelOnHide SetCamera SetAnimation
	SetMinMaxValues SetValueStep SetObeyStepOnDrag SetOrientation SetThumbTexture
	SetHideIfUnscrollable SetPanExtent ScrollToBegin ScrollToEnd ScrollToElementDataIndex FullUpdate
	SetInterpolateScroll SetScrollPercentage ClearLines AddTexture SetMinimumWidth SetPadding
	SetItemByID SetHyperlink SetUnit SetSpellByID
]])

-- Basic state.
Define("SetSize", function(self, width, height)
	self.width, self.height = width, height
end)
Define("SetWidth", function(self, width)
	self.width = width
end)
Define("SetHeight", function(self, height)
	self.height = height
end)
Define("GetWidth", function(self)
	return self.width or 0
end)
Define("GetHeight", function(self)
	return self.height or 0
end)
Define("GetSize", function(self)
	return self.width or 0, self.height or 0
end)
Define("SetScale", function(self, scale)
	self.scale = scale
end)
Define("GetScale", function(self)
	return self.scale or 1
end)
Define("GetEffectiveScale", function(self)
	return self.scale or 1
end)
Define("SetAlpha", function(self, alpha)
	self.alpha = alpha
end)
Define("GetAlpha", function(self)
	return self.alpha or 1
end)
Define("SetID", function(self, id)
	self.id = id
end)
Define("GetID", function(self)
	return self.id or 0
end)
Define("GetName", function(self)
	return self.name
end)
Define("GetObjectType", function(self)
	return self.objectType
end)
Define("IsObjectType", function(self, objectType)
	return self.objectType == objectType
end)
Define("GetParent", function(self)
	return self.parent
end)
Define("SetParent", function(self, parent)
	self.parent = parent
end)
Define("GetLeft", function()
	return 0
end)
Define("GetRight", function(self)
	return self.width or 0
end)
Define("GetTop", function(self)
	return self.height or 0
end)
Define("GetBottom", function()
	return 0
end)
Define("GetCenter", function(self)
	return (self.width or 0) / 2, (self.height or 0) / 2
end)
Define("IsMouseOver", function(self)
	return self.mouseOver == true
end)
Define("GetStringWidth", function(self)
	return #(self.text or "") * 6
end)
Define("GetUnboundedStringWidth", function(self)
	return #(self.text or "") * 6
end)
Define("GetStringHeight", function()
	return 12
end)

-- Points.
Define("SetPoint", function(self, point, relativeTo, relativePoint, x, y)
	self.points = self.points or {}
	self.points[#self.points + 1] = { point, relativeTo, relativePoint, x, y }
end)
Define("ClearAllPoints", function(self)
	self.points = {}
end)
Define("SetAllPoints", function(self, relativeTo)
	self.points = { { "ALL", relativeTo } }
end)
Define("GetNumPoints", function(self)
	return #(self.points or {})
end)
Define("GetPoint", function(self, index)
	local point = (self.points or {})[index or 1]
	if not point then
		return nil
	end
	return point[1], point[2], point[3] or point[1], point[4] or 0, point[5] or 0
end)
Define("StopMovingOrSizing", function(self)
	self.points = { { "CENTER", nil, "CENTER", 10, 20 } }
end)

-- Visibility.
local function RunScript(self, script, ...)
	local handler = self.scripts and self.scripts[script]
	if handler then
		return handler(self, ...)
	end
end
Widgets.RunScript = RunScript

Define("Show", function(self)
	if not self.shown then
		self.shown = true
		RunScript(self, "OnShow")
	end
end)
Define("Hide", function(self)
	if self.shown then
		self.shown = false
		RunScript(self, "OnHide")
	end
end)
Define("SetShown", function(self, shown)
	if shown then
		self:Show()
	else
		self:Hide()
	end
end)
Define("IsShown", function(self)
	return self.shown == true
end)
Define("IsVisible", function(self)
	local current = self
	while current do
		if not current.shown then
			return false
		end
		current = current.parent
	end
	return true
end)

-- Scripts and events.
Define("SetScript", function(self, script, handler)
	self.scripts = self.scripts or {}
	self.scripts[script] = handler
end)
Define("GetScript", function(self, script)
	return self.scripts and self.scripts[script]
end)
Define("HookScript", function(self, script, handler)
	self.scripts = self.scripts or {}
	local previous = self.scripts[script]
	self.scripts[script] = function(...)
		if previous then
			previous(...)
		end
		return handler(...)
	end
end)
Define("RegisterEvent", function(self, event)
	local world = self.world
	if world.unknownEvents[event] then
		error('Attempt to register unknown event "' .. event .. '"')
	end
	world.eventFrames[event] = world.eventFrames[event] or {}
	world.eventFrames[event][self] = true
	return true
end)
Define("UnregisterEvent", function(self, event)
	local frames = self.world.eventFrames[event]
	if frames then
		frames[self] = nil
	end
end)
Define("UnregisterAllEvents", function(self)
	for _, frames in pairs(self.world.eventFrames) do
		frames[self] = nil
	end
end)
Define("IsEventRegistered", function(self, event)
	local frames = self.world.eventFrames[event]
	return frames ~= nil and frames[self] == true
end)

-- Text.
Define("SetText", function(self, text)
	self.text = text
end)
Define("GetText", function(self)
	return self.text
end)
Define("SetFormattedText", function(self, format, ...)
	self.text = string.format(format, ...)
end)
Define("SetTextColor", function(self, r, g, b, a)
	self.textColor = { r, g, b, a }
end)
Define("SetFontObject", function(self, fontObject)
	self.fontObject = fontObject
end)
Define("GetFontObject", function(self)
	return self.fontObject
end)
Define("SetFont", function(self, path, size, flags)
	self.font = { path, size, flags }
	return true
end)
Define("GetFont", function(self)
	local font = self.font or {}
	return font[1], font[2], font[3]
end)
Define("Insert", function(self, text)
	self.text = (self.text or "") .. text
end)
Define("HasFocus", function()
	return false
end)

-- Textures.
Define("SetTexture", function(self, texture)
	self.texture = texture
	return true
end)
Define("GetTexture", function(self)
	return self.texture
end)
Define("SetAtlas", function(self, atlas)
	self.atlas = atlas
end)
Define("GetAtlas", function(self)
	return self.atlas
end)
Define("SetColorTexture", function(self, r, g, b, a)
	self.color = { r, g, b, a }
end)
Define("SetVertexColor", function(self, r, g, b, a)
	self.vertexColor = { r, g, b, a }
end)

-- Buttons.
Define("SetEnabled", function(self, enabled)
	self.disabled = not enabled
end)
Define("Enable", function(self)
	self.disabled = false
end)
Define("Disable", function(self)
	self.disabled = true
end)
Define("IsEnabled", function(self)
	return not self.disabled
end)
Define("Click", function(self, button)
	RunScript(self, "OnClick", button or "LeftButton", true)
end)
Define("GetFontString", function(self)
	return self.fontString
end)
Define("SetChecked", function(self, checked)
	self.checked = checked
end)
Define("GetChecked", function(self)
	return self.checked == true
end)

-- Sliders.
Define("SetValue", function(self, value)
	self.value = value
end)
Define("GetValue", function(self)
	return self.value or 0
end)

-- Children.
local Create

Define("CreateTexture", function(self, name, layer)
	return Create(self.world, "Texture", name, self, { layer = layer })
end)
Define("CreateFontString", function(self, name, layer, template)
	return Create(self.world, "FontString", name, self, { layer = layer, template = template })
end)
Define("CreateMaskTexture", function(self, name)
	return Create(self.world, "MaskTexture", name, self)
end)

-- ScrollBox (Blizzard's WowScrollBoxList template): binding the data provider renders the
-- first rows through the view's initializer, so row code runs in tests.
Define("SetDataProvider", function(self, provider)
	self.dataProvider = provider
	local view = self.view
	if not view or not view.initializer then
		return
	end
	self.rows = self.rows or {}
	local data = provider and provider.collection or {}
	for index = 1, math.min(#data, 12) do
		local row = self.rows[index] or Create(self.world, view.frameType or "Button", nil, self)
		self.rows[index] = row
		view.initializer(row, data[index])
	end
end)
Define("GetDataProvider", function(self)
	return self.dataProvider
end)
Define("ForEachFrame", function(self, callback)
	for _, row in ipairs(self.rows or {}) do
		callback(row, row.elementData)
	end
end)
Define("SetView", function(self, view)
	self.view = view
end)
Define("Init", function(self, view)
	self.view = view
end)
Define("RegisterCallback", function(self, event, callback, owner)
	self.callbacks = self.callbacks or {}
	self.callbacks[#self.callbacks + 1] = { event = event, callback = callback, owner = owner }
end)
Define("HasScrollableExtent", function(self)
	return #(self.dataProvider and self.dataProvider.collection or {}) > 12
end)
Define("GetVisibleExtentPercentage", function(self)
	local count = #(self.dataProvider and self.dataProvider.collection or {})
	return count > 0 and math.min(1, 12 / count) or 1
end)

-- ScrollFrame.
Define("SetScrollChild", function(self, child)
	self.scrollChild = child
end)
Define("GetVerticalScrollRange", function(self)
	local child = self.scrollChild
	return child and math.max(0, (child.height or 0) - (self.height or 0)) or 0
end)
Define("GetVerticalScroll", function(self)
	return self.verticalScroll or 0
end)
Define("SetVerticalScroll", function(self, offset)
	self.verticalScroll = offset
end)

Define("GetRegions", function(self)
	return unpack(self.regions or {})
end)
Define("GetChildren", function(self)
	return unpack(self.children or {})
end)

-- Methods are PascalCase in the WoW API, while addon code keeps its own fields in
-- camelCase. Unknown PascalCase keys are typos (or missing fakes) and raise; unknown
-- camelCase keys are simply unset fields.
local FRAME_METATABLE = {
	__index = function(self, key)
		local method = METHODS[key]
		if method then
			return method
		end
		if type(key) == "string" and key:match("^%u") then
			-- Template-provided children (Track, Thumb, Back, Forward, ...) appear on demand.
			if rawget(self, "allowChildren") then
				local child = Create(rawget(self, "world"), "Frame", nil, self, { allowChildren = true })
				rawset(self, key, child)
				return child
			end
			error("Unknown widget method or child: " .. key, 2)
		end
		return nil
	end,
}

local REGION_TYPES = { Texture = true, FontString = true, MaskTexture = true }

---@return table
function Create(world, objectType, name, parent, extra)
	-- Frames and regions start out shown, as in the game.
	local object = setmetatable({
		world = world,
		objectType = objectType,
		name = name,
		parent = parent,
		shown = true,
	}, FRAME_METATABLE)
	if extra then
		for key, value in pairs(extra) do
			object[key] = value
		end
	end
	if parent then
		local listKey = REGION_TYPES[objectType] and "regions" or "children"
		parent[listKey] = parent[listKey] or {}
		table.insert(parent[listKey], object)
	end
	world.createdObjects = world.createdObjects + 1
	return object
end
Widgets.Create = Create

return Widgets
