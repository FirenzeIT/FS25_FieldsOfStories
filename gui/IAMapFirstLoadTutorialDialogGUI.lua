--
-- One-time tutorial dialog before first-run map places generation.
-- Shown when the savegame isn't persisted yet (`savegameDirectory == nil`).
--
IAMapFirstLoadTutorialDialogGUI = {}
IAMapFirstLoadTutorialDialogGUI.dialog = nil

local IAMapFirstLoadTutorialDialogGUI_mt = Class(IAMapFirstLoadTutorialDialogGUI, DialogElement)

function IAMapFirstLoadTutorialDialogGUI.new(target)
	local self = DialogElement.new(target, IAMapFirstLoadTutorialDialogGUI_mt)
	return self
end

function IAMapFirstLoadTutorialDialogGUI:setDialog(dialog)
	self.dialog = dialog
end

function IAMapFirstLoadTutorialDialogGUI:onOpen()
	IAMapFirstLoadTutorialDialogGUI:superClass().onOpen(self)

	if self.titleElement ~= nil and g_i18n then
		local t = g_i18n:getText("gui_firstload_tutorial_title")
		if t ~= nil and t ~= "" then
			self.titleElement:setText(t)
		end
	end

	if self.messageElement ~= nil and g_i18n then
		local m = g_i18n:getText("gui_firstload_tutorial_message")
		if m ~= nil and m ~= "" then
			self.messageElement:setText(m)
		end
	end

	local m2el = self:getDescendantById("message2Element")
	if m2el ~= nil and g_i18n then
		local m2 = g_i18n:getText("gui_firstload_tutorial_message2")
		if m2 ~= nil and m2 ~= "" then
			m2el:setText(m2)
		end
	end

	local m3el = self:getDescendantById("message3Element")
	if m3el ~= nil and g_i18n then
		local m3 = g_i18n:getText("gui_firstload_tutorial_message3")
		if m3 ~= nil and m3 ~= "" then
			m3el:setText(m3)
		end
	end

	local m4el = self:getDescendantById("message4Element")
	if m4el ~= nil and g_i18n then
		local m4 = g_i18n:getText("gui_firstload_tutorial_message4")
		if m4 ~= nil and m4 ~= "" then
			m4el:setText(m4)
		end
	end

	local m5el = self:getDescendantById("message5Element")
	if m5el ~= nil and g_i18n then
		local m5 = g_i18n:getText("gui_firstload_tutorial_message5")
		if m5 ~= nil and m5 ~= "" then
			m5el:setText(m5)
		end
	end

	local m6el = self:getDescendantById("message6Element")
	if m6el ~= nil and g_i18n then
		local m6 = g_i18n:getText("gui_firstload_tutorial_message6")
		if m6 ~= nil and m6 ~= "" then
			m6el:setText(m6)
		end
	end

	--local m7el = self:getDescendantById("message7Element")
	--if m7el ~= nil and g_i18n then
	--	local m7 = g_i18n:getText("gui_firstload_tutorial_message7")
	--	if m7 ~= nil and m7 ~= "" then
	--		m7el:setText(m7)
	--	end
	--end
end

function IAMapFirstLoadTutorialDialogGUI:onClickOk()
	if IANeighbours ~= nil then
		IANeighbours.firstLoadTutorialDialogShown = true
	end
	if g_gui ~= nil and self.dialog ~= nil then
		g_gui:closeDialog(self.dialog)
	end
end

function IAMapFirstLoadTutorialDialogGUI:onEscPressed()
	self:onClickOk()
end

