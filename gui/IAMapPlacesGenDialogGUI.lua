--
-- One-time warning before first-run map places generation (placeablePlaces / nodes / splines).
--
IAMapPlacesGenDialogGUI = {}
IAMapPlacesGenDialogGUI.dialog = nil

local IAMapPlacesGenDialogGUI_mt = Class(IAMapPlacesGenDialogGUI, DialogElement)

function IAMapPlacesGenDialogGUI.new(target)
	local self = DialogElement.new(target, IAMapPlacesGenDialogGUI_mt)
	return self
end

function IAMapPlacesGenDialogGUI:setDialog(dialog)
	self.dialog = dialog
end

function IAMapPlacesGenDialogGUI:onOpen()
	IAMapPlacesGenDialogGUI:superClass().onOpen(self)
	if self.titleElement ~= nil and g_i18n then
		local t = g_i18n:getText("gui_mapplaces_gen_title")
		if t ~= nil and t ~= "" then
			self.titleElement:setText(t)
		end
	end
	if self.messageElement ~= nil and g_i18n then
		local m = g_i18n:getText("gui_mapplaces_gen_message")
		if m ~= nil and m ~= "" then
			self.messageElement:setText(m)
		end
	end
	local m2el = self:getDescendantById("message2Element")
	if m2el ~= nil and g_i18n then
		local m2 = g_i18n:getText("gui_mapplaces_gen_message2")
		if m2 ~= nil and m2 ~= "" then
			m2el:setText(m2)
		end
	end
	local beforeEl = self:getDescendantById("beforeLoadElement")
	if beforeEl ~= nil and beforeEl.setText ~= nil and g_i18n then
		local b = g_i18n:getText("gui_mapplaces_gen_before_load")
		if b == nil or b == "" or b == "gui_mapplaces_gen_before_load" then
			b = "Press OK to start loading and generating map places. The game may appear frozen until this finishes. This is normal."
		end
		beforeEl:setText(b)
	end
end

function IAMapPlacesGenDialogGUI:onClickOk()
	if IANeighbours and IANeighbours.onMapPlacesBootstrapConfirmed then
		IANeighbours.onMapPlacesBootstrapConfirmed()
	end
	if g_gui ~= nil and self.dialog ~= nil then
		g_gui:closeDialog(self.dialog)
	end
end

function IAMapPlacesGenDialogGUI:onEscPressed()
	self:onClickOk()
end
