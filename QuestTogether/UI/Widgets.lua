local _, ns = ...

--- Small building blocks for the addon's frames.
---@class QTWidgets
local Widgets = ns.Widgets
local Theme = ns.Theme

---@param parent table
---@param role string? font role (see Theme.Font), default "body"
---@param tone string? "primary" | "dim" | "muted" | "faint", default "primary"
---@return table fontString
function Widgets.Text(parent, role, tone)
	local text = parent:CreateFontString(nil, "OVERLAY")
	text:SetFontObject(Theme.Font(role or "body"))
	Theme.Tone(text, tone or "primary")
	text:SetJustifyH("LEFT")
	text:SetWordWrap(false)
	return text
end

--- Opens GameTooltip on the side of the owner that faces the middle of the screen.
---@param owner table
function Widgets.AnchorTooltip(owner)
	local x = owner:GetCenter()
	local onRight = x and x * owner:GetEffectiveScale() > UIParent:GetWidth() * UIParent:GetEffectiveScale() / 2
	GameTooltip:SetOwner(owner, onRight and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
end
