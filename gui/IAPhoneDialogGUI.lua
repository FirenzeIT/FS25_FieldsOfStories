--
-- Phone shell UI (IAPhoneDialogGUI.xml). Incoming calls store payload + ring audio until IAStartConversation opens this GUI.
-- Unanswered offers end via `IANeighbours.clearPendingIncomingPhoneOffer` (ring clip finished or `PENDING_INCOMING_PHONE_MAX_SEC`); screen refreshes if this GUI is open.
--
IAPhoneDialogGUI = {}
IAPhoneDialogGUI.dialog = nil

local IAPhoneDialogGUI_mt = Class(IAPhoneDialogGUI, DialogElement)

function IAPhoneDialogGUI.new(target)
	local self = DialogElement.new(target, IAPhoneDialogGUI_mt)
	return self
end

function IAPhoneDialogGUI:setDialog(dialog)
	self.dialog = dialog
end

--- Repaint title / message / Answer from `IANeighbours._incomingPhonePayload` (also after missed-call expiry while dialog stays open).
function IAPhoneDialogGUI:refreshPhoneScreenFromNeighboursState()
	local payload = IANeighbours ~= nil and IANeighbours._incomingPhonePayload or nil
	if payload ~= nil then
		local caller = payload.neighbourName ~= nil and tostring(payload.neighbourName) or "?"
		if self.titleElement ~= nil and g_i18n then
			local t = g_i18n:getText("gui_phone_title")
			if t ~= nil and t ~= "" then
				self.titleElement:setText(string.format(t, caller))
			else
				self.titleElement:setText(g_i18n:getText("gui_phone_title_default"))
			end
		end
		if self.messageElement ~= nil and g_i18n then
			local m = g_i18n:getText("gui_phone_message")
			if m ~= nil and m ~= "" then
				self.messageElement:setText(string.format(m, caller))
			else
				self.messageElement:setText("")
			end
		end
		if self.answerButton ~= nil and self.answerButton.setVisible then
			self.answerButton:setVisible(true)
		end
		if self.declineButton ~= nil and self.declineButton.setText then
			local decline = (g_i18n ~= nil and g_i18n:getText("gui_phone_decline")) or "Decline"
			self.declineButton:setText(decline)
		end
	else
		if self.titleElement ~= nil then
			local defaultTitle = (g_i18n ~= nil and g_i18n:getText("gui_phone_title_default")) or "Phone"
			self.titleElement:setText(defaultTitle)
		end
		if self.messageElement ~= nil then
			local idle = (g_i18n ~= nil and g_i18n:getText("gui_phone_no_incoming")) or "No incoming call."
			self.messageElement:setText(idle)
		end
		if self.answerButton ~= nil and self.answerButton.setVisible then
			self.answerButton:setVisible(false)
		end
		if self.declineButton ~= nil and self.declineButton.setText then
			local close = (g_i18n ~= nil and g_i18n:getText("gui_phone_close")) or "Close"
			self.declineButton:setText(close)
		end
	end
end

--- If the phone GUI is the current dialog, sync widgets after `clearPendingIncomingPhoneOffer`.
function IAPhoneDialogGUI.refreshPhoneScreenFromNeighboursStateIfOpen()
	if g_gui == nil or g_gui.guis == nil then
		return
	end
	if g_gui.currentDialog ~= "IAPhoneDialogGUI" then
		return
	end
	local gui = g_gui.guis["IAPhoneDialogGUI"]
	if gui ~= nil and gui.target ~= nil and gui.target.refreshPhoneScreenFromNeighboursState ~= nil then
		gui.target:refreshPhoneScreenFromNeighboursState()
	end
end

function IAPhoneDialogGUI:onOpen()
	IAPhoneDialogGUI:superClass().onOpen(self)
	if IANeighbours ~= nil then
		IANeighbours.incomingPhoneRingDialogOpen = true
		-- Ring plays while the phone is closed; opening the phone stops it (incoming was audio-only until now).
		IANeighbours.stopIncomingCallRingSound()
	end
	self:refreshPhoneScreenFromNeighboursState()
end

function IAPhoneDialogGUI:onClose()
	if IANeighbours ~= nil then
		if IANeighbours._incomingPhonePayload ~= nil then
			IANeighbours.clearPendingIncomingPhoneOffer(IANeighbours.IncomingCallEndReason.PHONE_DIALOG_CLOSED)
		end
		IANeighbours.incomingPhoneRingDialogOpen = false
		IANeighbours.stopIncomingCallRingSound()
	end
	local superOnClose = IAPhoneDialogGUI:superClass().onClose
	if superOnClose ~= nil then
		superOnClose(self)
	end
end

function IAPhoneDialogGUI:onClickAnswer()
	if IANeighbours == nil then
		return
	end
	local p = IANeighbours._incomingPhonePayload
	IANeighbours.clearPendingIncomingPhoneOffer(IANeighbours.IncomingCallEndReason.ANSWERED)
	if g_gui ~= nil and self.dialog ~= nil then
		g_gui:closeDialog(self.dialog)
	end
	if p ~= nil then
		IANeighbours.answerIncomingPhoneFromPayload(p)
	end
end

function IAPhoneDialogGUI:onClickDecline()
	if IANeighbours ~= nil then
		IANeighbours.clearPendingIncomingPhoneOffer(IANeighbours.IncomingCallEndReason.DECLINED)
	end
	if g_gui ~= nil and self.dialog ~= nil then
		g_gui:closeDialog(self.dialog)
	end
end

function IAPhoneDialogGUI:onEscPressed()
	self:onClickDecline()
end
