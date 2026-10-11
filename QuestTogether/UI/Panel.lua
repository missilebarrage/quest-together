local _, ns = ...

--- The party progress panel: for each quest the player is working on here, one row per
--- objective and one column per party member on the quest, with a green check for what's
--- done. Members without the quest are listed under it. Shown only in a group and only
--- while there's something to show. Shift-drag moves it; right-click opens its menu.
---
---   The Boar Hunt      You  Thrall  Jaina
---   Boar Tusk           ✓    4/6     2/6
---   Bear Meat           ✓     ✓     3/10
---   Not on quest: Anduin
---@class QTPanel
local Panel = ns.Panel
local Scanner = ns.Scanner
local Roster = ns.Roster
local PartyState = ns.PartyState
local Areas = ns.Areas
local Database = ns.Database
local Format = ns.Format
local Events = ns.Events
local Theme = ns.Theme
local Widgets = ns.Widgets
local L = ns.L

local PADDING = 10
local TOP_PADDING = 6
local BOTTOM_PADDING = 6
local BLOCK_GAP = 7
local ROW_HEIGHTS = { title = 18, objective = 16, footer = 15 }
local LABEL_MIN, LABEL_MAX = 90, 170
local CELL_MIN, CELL_MAX = 22, 64
local CELL_GAP = 8
local CHECK_SIZE = 12
local MAX_COLUMNS = 5
local MAX_QUESTS = 4
local PREVIEW_SECONDS = 30

---@class QTPanelCell
---@field kind "check"|"count"|"unknown"|"header"
---@field text string?
---@field color number[]?

---@class QTPanelRow
---@field kind "title"|"objective"|"footer"
---@field text string
---@field cells QTPanelCell[]?

local frame ---@type table?
local rows = {} -- row frames, created as more are needed than ever before
local visible = {} ---@type integer[]
local previewUntil ---@type number?
local expiryTimer
local columnWidths = {}

local PLAYER_COLOR = { 1, 1, 1 }
local UNKNOWN_CELL = { kind = "unknown", text = "?" }
local CHECK_CELL = { kind = "check" }

-- Content ------------------------------------------------------------------------------

local function CountCell(fulfilled, required)
	return { kind = "count", text = fulfilled .. "/" .. required }
end

--- One objective's cells: the player's, then each member column's.
local function ObjectiveCells(objective, index, columns)
	local cells = { objective.done and CHECK_CELL or CountCell(objective.fulfilled, objective.required) }
	for _, column in ipairs(columns) do
		local cell = UNKNOWN_CELL
		if column.progress then
			local fulfilled, required, done = PartyState.Objective(column.progress, index)
			if done then
				cell = CHECK_CELL
			elseif fulfilled then
				cell = CountCell(fulfilled, required)
			end
		end
		cells[#cells + 1] = cell
	end
	return cells
end

--- The rows for one quest.
---@param questID integer
---@param out QTPanelRow[]
local function QuestRows(questID, out)
	local quest = Scanner.Get(questID)
	local numObjectives = #quest.objectives
	local header = { { kind = "header", text = L.YOU, color = PLAYER_COLOR } }
	local columns = {} -- { progress = record? } per member column
	local notOnQuest, noInfo = {}, {}
	for _, member in ipairs(Roster.Members()) do
		local status, progress = PartyState.Status(member, questID, numObjectives)
		if (status == "progress" or status == "onQuest") and #header < MAX_COLUMNS then
			header[#header + 1] = { kind = "header", text = member.first, color = member.color }
			columns[#columns + 1] = { progress = progress }
		elseif status == "absent" then
			notOnQuest[#notOnQuest + 1] = member.first
		else
			noInfo[#noInfo + 1] = member.first
		end
	end
	out[#out + 1] = { kind = "title", text = quest.title, cells = header }
	for index, objective in ipairs(quest.objectives) do
		if not objective.hidden then
			out[#out + 1] =
				{ kind = "objective", text = objective.label, cells = ObjectiveCells(objective, index, columns) }
		end
	end
	if #notOnQuest > 0 then
		out[#out + 1] = { kind = "footer", text = L.NOT_ON_QUEST:format(Format.List(notOnQuest)) }
	end
	if #noInfo > 0 then
		out[#out + 1] = { kind = "footer", text = L.NO_INFO:format(Format.List(noInfo)) }
	end
end

local function LiveRows()
	local out = {}
	Areas.Visible(visible)
	for position, questID in ipairs(visible) do
		if position > MAX_QUESTS then
			out[#out + 1] = { kind = "footer", text = L.MORE_QUESTS:format(#visible - MAX_QUESTS) }
			break
		end
		QuestRows(questID, out)
	end
	return out
end

local function PreviewRows()
	local thrall, jaina = { 0.96, 0.55, 0.73 }, { 0.25, 0.78, 0.92 }
	return {
		{
			kind = "title",
			text = L.PREVIEW_QUEST,
			cells = {
				{ kind = "header", text = L.YOU, color = PLAYER_COLOR },
				{ kind = "header", text = L.PREVIEW_MEMBER_1, color = thrall },
				{ kind = "header", text = L.PREVIEW_MEMBER_2, color = jaina },
			},
		},
		{ kind = "objective", text = L.PREVIEW_OBJECTIVE_1, cells = { CHECK_CELL, CountCell(4, 6), CountCell(2, 6) } },
		{ kind = "objective", text = L.PREVIEW_OBJECTIVE_2, cells = { CHECK_CELL, CHECK_CELL, CountCell(3, 10) } },
		{ kind = "footer", text = L.NOT_ON_QUEST:format(L.PREVIEW_MEMBER_3) },
	}
end

-- Drawing --------------------------------------------------------------------------------

local function NewRow()
	local row = CreateFrame("Frame", nil, frame)
	row.left = Widgets.Text(row, "small")
	row.divider = Theme.Divider(row)
	row.divider:SetPoint("TOPLEFT", PADDING, BLOCK_GAP / 2 + 1)
	row.divider:SetPoint("TOPRIGHT", -PADDING, BLOCK_GAP / 2 + 1)
	row.cells = {}
	for index = 1, MAX_COLUMNS do
		local text = Widgets.Text(row, "small")
		text:SetJustifyH("CENTER")
		local check = row:CreateTexture(nil, "ARTWORK")
		check:SetSize(CHECK_SIZE, CHECK_SIZE)
		check:SetTexture(Theme.Icon("check"))
		row.cells[index] = { text = text, check = check }
	end
	return row
end

local function ToneCell(cell, data)
	local text = cell.text
	if data.kind == "header" then
		text:SetFontObject(Theme.Font("small"))
		local color = data.color or PLAYER_COLOR
		text:SetTextColor(color[1], color[2], color[3], 1)
	elseif data.kind == "unknown" then
		text:SetFontObject(Theme.Font("small"))
		Theme.Tone(text, "faint")
	else
		text:SetFontObject(Theme.Font("small"))
		Theme.Tone(text, "primary")
	end
end

--- Pass 1: writes every row's content and measures the label and cell columns.
---@return number labelWidth
---@return integer columns
local function Fill(content)
	local labelWidth, columns = LABEL_MIN, 0
	wipe(columnWidths)
	for index, data in ipairs(content) do
		local row = rows[index]
		if not row then
			row = NewRow()
			rows[index] = row
		end
		row.kind = data.kind
		row.left:SetText(data.text)
		if data.kind == "title" then
			row.left:SetFontObject(Theme.Font("heading"))
			Theme.PaintAccent(row.left, 1, "text")
		else
			Theme.ForgetAccent(row.left)
			row.left:SetFontObject(Theme.Font(data.kind == "footer" and "label" or "small"))
			Theme.Tone(row.left, data.kind == "footer" and "faint" or "dim")
		end
		if data.kind ~= "footer" then
			labelWidth = math.max(labelWidth, row.left:GetUnboundedStringWidth())
		end
		local cells = data.cells or {}
		columns = math.max(columns, #cells)
		for column = 1, MAX_COLUMNS do
			local cell, cellData = row.cells[column], cells[column]
			local isCheck = cellData ~= nil and cellData.kind == "check"
			cell.check:SetShown(isCheck)
			cell.text:SetShown(cellData ~= nil and not isCheck)
			local width = isCheck and CHECK_SIZE or 0
			if cellData and not isCheck then
				ToneCell(cell, cellData)
				cell.text:SetText(cellData.text)
				width = math.min(cell.text:GetUnboundedStringWidth(), CELL_MAX)
			end
			if cellData then
				columnWidths[column] = math.max(columnWidths[column] or CELL_MIN, width)
			end
		end
	end
	return math.min(labelWidth, LABEL_MAX), columns
end

--- Pass 2: places the rows and cells and fits the panel around them.
local function Layout(count, labelWidth, columns)
	local width = PADDING + labelWidth + PADDING
	for column = 1, columns do
		width = width + CELL_GAP + columnWidths[column]
	end
	local y = TOP_PADDING
	for index = 1, count do
		local row = rows[index]
		if row.kind == "title" and index > 1 then
			y = y + BLOCK_GAP
		end
		row.divider:SetShown(row.kind == "title" and index > 1)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 0, -y)
		row:SetSize(width, ROW_HEIGHTS[row.kind])
		row.left:ClearAllPoints()
		row.left:SetPoint("LEFT", PADDING, 0)
		row.left:SetWidth(row.kind == "footer" and (width - 2 * PADDING) or labelWidth)
		local x = PADDING + labelWidth
		for column = 1, MAX_COLUMNS do
			local cell = row.cells[column]
			if column <= columns then
				local cellWidth = columnWidths[column]
				local center = x + CELL_GAP + cellWidth / 2
				cell.text:ClearAllPoints()
				cell.text:SetPoint("CENTER", row, "LEFT", center, 0)
				cell.text:SetWidth(cellWidth)
				cell.check:ClearAllPoints()
				cell.check:SetPoint("CENTER", row, "LEFT", center, 0)
				x = x + CELL_GAP + cellWidth
			end
		end
		row:Show()
		y = y + ROW_HEIGHTS[row.kind]
	end
	for index = count + 1, #rows do
		rows[index]:Hide()
	end
	frame:SetSize(width, y + BOTTOM_PADDING)
end

--- Fades the background and border; the text stays fully visible.
local function ApplyOpacity()
	local opacity = math.max(0, math.min(100, Database.Get("panelOpacity"))) / 100
	local panel, border = Theme.COLORS.panel, Theme.COLORS.border
	frame.background:SetColorTexture(panel[1], panel[2], panel[3], panel[4] * opacity)
	for _, edge in ipairs(frame.edges) do
		edge:SetColorTexture(border[1], border[2], border[3], border[4] * opacity)
	end
end

-- Interaction ------------------------------------------------------------------------------

local function MemberSource(member)
	local peer = PartyState.Peer(member.guid)
	if peer and peer.synced then
		return L.SOURCE_ADDON:format(peer.addonVersion or "?")
	end
	return L.SOURCE_NONE
end

local function ShowTooltip(owner)
	Widgets.AnchorTooltip(owner)
	GameTooltip:SetText(L.ADDON_TITLE, 1, 1, 1)
	for _, member in ipairs(Roster.Members()) do
		GameTooltip:AddDoubleLine(
			Format.Color(member.first, member.color[1], member.color[2], member.color[3]),
			MemberSource(member),
			1,
			1,
			1,
			0.75,
			0.75,
			0.75
		)
	end
	GameTooltip:AddLine(L.PANEL_HINT_MOVE, 0.75, 0.75, 0.75)
	GameTooltip:AddLine(L.PANEL_HINT_MENU, 0.75, 0.75, 0.75)
	GameTooltip:Show()
end

local MODES = {
	{ "areas", L.MODE_AREAS },
	{ "zone", L.MODE_ZONE },
	{ "all", L.MODE_ALL },
}

local function IsMode(mode)
	return Database.Get("panelMode") == mode
end

local function SetMode(mode)
	Database.Set("panelMode", mode)
end

local function IsOn(key)
	return Database.Get(key) == true
end

local function Toggle(key)
	Database.Set(key, not Database.Get(key))
end

local function OpenMenu(owner)
	GameTooltip:Hide()
	if not (MenuUtil and MenuUtil.CreateContextMenu) then
		ns.Options.Open()
		return
	end
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle(L.PANEL_SHOWS)
		for _, mode in ipairs(MODES) do
			root:CreateRadio(mode[2], IsMode, SetMode, mode[1])
		end
		root:CreateDivider()
		root:CreateCheckbox(L.OPTION_AUTO_SHARE, IsOn, Toggle, "autoShare")
		root:CreateCheckbox(L.OPTION_AUTO_ACCEPT, IsOn, Toggle, "autoAccept")
		root:CreateCheckbox(L.OPTION_ANNOUNCE_OBJECTIVES, IsOn, Toggle, "announceObjectives")
		root:CreateCheckbox(L.OPTION_ANNOUNCE_QUESTS, IsOn, Toggle, "announceQuests")
		root:CreateDivider()
		local missing = ns.Share.MissingCount()
		local share = root:CreateButton(L.SHARE_MISSING_COUNT:format(missing), function()
			ns.Share.ShareMissing()
		end)
		if missing == 0 and share.SetEnabled then
			share:SetEnabled(false)
		end
		root:CreateButton(L.OPTIONS, function()
			ns.Options.Open()
		end)
		root:CreateButton(L.PANEL_HIDE, function()
			Panel.Disable()
		end)
	end)
end

-- After a move the client may anchor the panel by any point; anchoring it by its top-left
-- corner keeps the top in place when rows come and go.
local function AnchorByTopLeft(self)
	local left, top = self:GetLeft(), self:GetTop()
	if left and top then
		self:ClearAllPoints()
		self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
	end
end

local function StopMoving(self)
	if self.moving then
		self:StopMovingOrSizing()
		self.moving = nil
		AnchorByTopLeft(self)
		Database.SavePosition("panel", self)
	end
end

local function Build()
	frame = CreateFrame("Button", "QuestTogetherPanel", UIParent)
	frame:SetSize(200, 40)
	frame:SetFrameStrata("MEDIUM")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:SetDontSavePosition(true)
	frame:RegisterForClicks("RightButtonUp")
	frame:SetScale(Database.Get("panelScale"))
	frame.background = Theme.Fill(frame, Theme.COLORS.panel)
	frame.edges = Theme.Border(frame)
	frame.hover = Theme.Fill(frame, Theme.COLORS.hover, "BORDER")
	frame.hover:Hide()
	ApplyOpacity()

	frame:SetScript("OnEnter", function(self)
		self.hover:Show()
		if not self.moving then
			ShowTooltip(self)
		end
	end)
	frame:SetScript("OnLeave", function(self)
		self.hover:Hide()
		GameTooltip:Hide()
	end)
	-- Moving needs Shift, so a click never drags the panel by accident.
	frame:SetScript("OnMouseDown", function(self, button)
		if button == "LeftButton" and IsShiftKeyDown() then
			GameTooltip:Hide()
			self.moving = true
			self:StartMoving()
		end
	end)
	frame:SetScript("OnMouseUp", StopMoving)
	frame:SetScript("OnClick", function(self, button)
		if button == "RightButton" then
			OpenMenu(self)
		end
	end)
	frame:SetScript("OnHide", function(self)
		StopMoving(self)
		self.hover:Hide()
	end)

	if not Database.RestorePosition("panel", frame) then
		-- Left of centre by default: the quest tracker usually fills the right side.
		frame:SetPoint("TOPLEFT", UIParent, "LEFT", 40, -40)
	end
	frame:Hide()
end

local function Previewing()
	if previewUntil and GetTime() >= previewUntil then
		previewUntil = nil
	end
	return previewUntil ~= nil
end

local Refresh

local function ScheduleRefresh()
	Events.Debounce("panel", 0.1, Refresh)
end

--- A quest that was just left drops off after a grace period: refresh when it does.
local function ScheduleExpiry()
	local seconds = Areas.NextExpiry()
	if seconds and not expiryTimer then
		expiryTimer = C_Timer.NewTimer(seconds + 0.05, function()
			expiryTimer = nil
			Refresh()
		end)
	end
end

function Refresh()
	local content
	if Previewing() then
		content = PreviewRows()
	elseif Database.Get("panelEnabled") and Roster.InGroup() then
		content = LiveRows()
		ScheduleExpiry()
	end
	if not content or #content == 0 then
		if frame then
			frame:Hide()
		end
		return
	end
	if not frame then
		Build()
	end
	local labelWidth, columns = Fill(content)
	Layout(#content, labelWidth, columns)
	frame:Show()
end

--- Re-reads everything and shows or hides the panel now.
function Panel.Update()
	Refresh()
end

--- Shows example content for a while, so the panel can be placed while not in a group.
function Panel.Preview()
	if Previewing() then
		previewUntil = nil
	else
		previewUntil = GetTime() + PREVIEW_SECONDS
		C_Timer.After(PREVIEW_SECONDS + 0.05, ScheduleRefresh)
	end
	Refresh()
end

--- /qt panel: turns the panel on or off.
function Panel.Toggle()
	if Database.Get("panelEnabled") then
		Panel.Disable()
	else
		Database.Set("panelEnabled", true)
		ns.Print(L.PANEL_SHOWN)
	end
end

function Panel.Disable()
	previewUntil = nil
	Database.Set("panelEnabled", false)
	ns.Print(L.PANEL_HIDDEN)
end

---@return table?
function Panel.Frame()
	return frame
end

for _, signal in ipairs({
	"QT_SCAN_DONE",
	"QT_QUEST_REMOVED",
	"QT_PARTY_CHANGED",
	"QT_AREAS_CHANGED",
	"QT_ROSTER_UPDATED",
	"QT_ROSTER_CHANGED",
}) do
	Events.On(signal, ScheduleRefresh)
end
Events.On("QT_SETTINGS_CHANGED", function(key)
	if key == "panelScale" and frame then
		-- Positions are in the panel's own scale: keep its top-left corner where it is.
		local left, top, old = frame:GetLeft(), frame:GetTop(), frame:GetScale()
		local new = Database.Get("panelScale")
		frame:SetScale(new)
		if left and top then
			frame:ClearAllPoints()
			frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * old / new, top * old / new)
			Database.SavePosition("panel", frame)
		end
		Theme.RefreshPixels()
	elseif key == "panelOpacity" and frame then
		ApplyOpacity()
	elseif key == "panelEnabled" or key == "panelMode" then
		ScheduleRefresh()
	end
end)
