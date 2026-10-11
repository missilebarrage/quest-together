local _, ns = ...

--- Stateless reading of the player's quest log through C_QuestLog. Objective counts are
--- normalized here, so everything else can trust them:
---   * an objective's `finished` flag is the truth; counts are display only. Forever
---     sometimes reports 1/1 for an objective that isn't finished yet, so an unfinished
---     objective never shows a full count;
---   * the label is the objective text without its count ("4/6 Boar Tusk" -> "Boar Tusk").
---@class QTQuestLog
local QuestLog = ns.QuestLog

---@class QTObjective
---@field label string the objective text without its count
---@field fulfilled integer
---@field required integer
---@field done boolean
---@field hadCount boolean the client's text carried a count
---@field hidden boolean the objective has no text: it counts but isn't shown or announced

---@class QTQuestRead
---@field questID integer
---@field title string
---@field complete boolean every objective done (ready to turn in)
---@field failed boolean
---@field objectives QTObjective[] every objective, in the game's order (indexes match other clients')
---@field visible integer objectives with text

-- Where the count sits in objective text, tried in order; each captures the label.
local COUNT_PATTERNS = {
	"^%d+%s*/%s*%d+%s+(.-)$", -- "4/6 Boar Tusk" (Forever)
	"^(.-)%s*:%s*%d+%s*/%s*%d+$", -- "Boar Tusk: 4/6" (classic clients)
	"^(.-)%s*%(%d+%s*/%s*%d+%)$", -- "Boar Tusk (4/6)"
}

--- Splits objective text into its label and whether it carried a count.
---@param text string
---@return string label
---@return boolean hadCount
function QuestLog.Label(text)
	local complete = " (" .. (ns.Str(COMPLETE) or "Complete") .. ")"
	if #text > #complete and text:sub(-#complete) == complete then
		text = text:sub(1, -#complete - 1)
	end
	for _, pattern in ipairs(COUNT_PATTERNS) do
		local label = text:match(pattern)
		if label and label ~= "" then
			return label, true
		end
	end
	return text, false
end

---@param objective QTObjective
---@param text string
---@param entry table a QuestObjectiveInfo from C_QuestLog.GetQuestObjectives
local function Normalize(objective, text, entry)
	local done = ns.Bool(entry.finished) == true
	local required = math.max(math.floor(ns.Num(entry.numRequired) or 0), 1)
	local fulfilled = math.max(math.floor(ns.Num(entry.numFulfilled) or 0), 0)
	if done then
		fulfilled = required
	else
		fulfilled = math.min(fulfilled, required - 1)
	end
	objective.label, objective.hadCount = QuestLog.Label(text)
	objective.fulfilled = fulfilled
	objective.required = required
	objective.done = done
end

--- Calls visit(questID, info) for every quest the log lists, in log order (headers and
--- hidden entries skipped).
---@param visit fun(questID: integer, info: table)
function QuestLog.Walk(visit)
	local count = ns.Num((C_QuestLog.GetNumQuestLogEntries())) or 0
	for index = 1, count do
		local info = C_QuestLog.GetInfo(index)
		if type(info) == "table" and not info.isHeader and not info.isHidden then
			local questID = ns.Num(info.questID)
			if questID and questID > 0 then
				visit(questID, info)
			end
		end
	end
end

---@param questID integer
---@return boolean
function QuestLog.IsOnQuest(questID)
	return ns.Bool(C_QuestLog.IsOnQuest(questID)) == true
end

--- Reads one quest into `into` (tables inside are reused). Returns false while the client
--- hasn't loaded the quest completely; `into` is then left half-written and must not be used.
---@param questID integer
---@param into QTQuestRead
---@return boolean complete
function QuestLog.Read(questID, into)
	local title = ns.Str(C_QuestLog.GetTitleForQuestID(questID))
	if not title or title == "" then
		return false
	end
	local raw = C_QuestLog.GetQuestObjectives(questID)
	if type(raw) ~= "table" then
		return false
	end
	into.questID = questID
	into.title = title
	local objectives = into.objectives
	local count, visible = 0, 0
	local allDone = true
	for _, entry in ipairs(raw) do
		local text = ns.Str(entry.text)
		if text == nil or not ns.Str(entry.type) then
			return false
		end
		-- Text padded with spaces (" : 0/1", "0/1  ") hasn't finished loading.
		if text ~= "" and (text:find("^%s") or text:find("%s$")) then
			return false
		end
		count = count + 1
		local objective = objectives[count]
		if not objective then
			objective = {}
			objectives[count] = objective
		end
		Normalize(objective, text, entry)
		-- Some quests carry objectives without text; they still count toward completion
		-- and keep their place, so indexes stay the same on every client.
		objective.hidden = text == ""
		if not objective.hidden then
			visible = visible + 1
		end
		allDone = allDone and objective.done
	end
	for index = #objectives, count + 1, -1 do
		objectives[index] = nil
	end
	into.visible = visible
	into.failed = ns.Bool(C_QuestLog.IsFailed(questID)) == true
	into.complete = not into.failed
		and (
			ns.Bool(C_QuestLog.IsComplete(questID)) == true
			or ns.Bool(C_QuestLog.ReadyForTurnIn(questID)) == true
			or (count > 0 and allDone)
		)
	return true
end

--- Asks the client to load a quest's data (QUEST_DATA_LOAD_RESULT follows).
---@param questID integer
function QuestLog.RequestLoad(questID)
	if C_QuestLog.RequestLoadQuestByID then
		pcall(C_QuestLog.RequestLoadQuestByID, questID)
	end
end

---@param questID integer
---@return boolean
function QuestLog.IsPushable(questID)
	local ok, pushable = pcall(C_QuestLog.IsPushableQuest, questID)
	return ok and ns.Bool(pushable) == true
end

---@param questID integer
---@return integer?
function QuestLog.LogIndex(questID)
	local index = ns.Num(C_QuestLog.GetLogIndexForQuestID(questID))
	return index and index > 0 and index or nil
end

--- Shares a quest with the party. Blizzard's Share button passes the log index; some
--- clients share the selected quest instead, so the quest is selected for the call and the
--- previous selection restored afterwards.
---@param questID integer
---@param index integer the quest's log index
---@return boolean called
function QuestLog.Push(questID, index)
	local previous = C_QuestLog.GetSelectedQuest and ns.Num(C_QuestLog.GetSelectedQuest())
	if C_QuestLog.SetSelectedQuest then
		pcall(C_QuestLog.SetSelectedQuest, questID)
	end
	local ok = pcall(QuestLogPushQuest, index)
	if previous and previous ~= questID and C_QuestLog.SetSelectedQuest then
		pcall(C_QuestLog.SetSelectedQuest, previous)
	end
	return ok
end

--- A clickable quest link for chat, or the title in brackets when the client has none.
---@param questID integer
---@param title string
---@return string
function QuestLog.Link(questID, title)
	local link = GetQuestLink and ns.Str(GetQuestLink(questID))
	if link and link ~= "" then
		return link
	end
	return "[" .. title .. "]"
end

--- An objective as announced: "6/6 Boar slain", or just the text when it has no count.
---@param objective QTObjective
---@return string
function QuestLog.ObjectiveText(objective)
	if objective.hadCount or objective.required > 1 then
		return objective.fulfilled .. "/" .. objective.required .. " " .. objective.label
	end
	return objective.label
end
