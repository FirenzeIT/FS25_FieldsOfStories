--
-- ConversationDialog: controller for the conversation subtitle + options dialog.
-- Used by IAConversation; handles onClickOption so option clicks trigger selectConversationOption.
--
IAConversationDialog = {}
IAConversationDialog._mt = Class(IAConversationDialog, DialogElement)

function IAConversationDialog.new(target)
	local self = DialogElement.new(target, IAConversationDialog._mt)
	return self
end

function IAConversationDialog:setSituation(situation)
	self.situation = situation
end

function IAConversationDialog:setNpcName(npcName)
	self.npcName = npcName
	if self.npcNameElement and self.npcNameElement.setText then
		self.npcNameElement:setText(npcName and tostring(npcName) or "")
		self:updateTextBoxHeight()
	end
end

function IAConversationDialog:setDialog(dialog)
	self.dialog = dialog
end

function IAConversationDialog:onClose()
	if IAConversation ~= nil and IAConversation.DEBUG_DIALOG_ON_CLOSE then
		print("--- IAConversationDialog:onClose() entered")
	end
	local superOnClose = IAConversationDialog:superClass().onClose
	if superOnClose ~= nil then
		if IAConversation ~= nil and IAConversation.DEBUG_DIALOG_ON_CLOSE then
			print("--- IAConversationDialog:onClose() calling superClass().onClose")
		end
		superOnClose(self)
	elseif IAConversation ~= nil and IAConversation.DEBUG_DIALOG_ON_CLOSE then
		print("--- IAConversationDialog:onClose() superClass().onClose is nil")
	end
	if self.situation == nil then
		if IAConversation ~= nil and IAConversation.DEBUG_DIALOG_ON_CLOSE then
			print("--- IAConversationDialog:onClose() self.situation is nil — not calling onExternalDialogClose")
		end
		return
	end
	if self.situation.conversation == nil then
		if IAConversation ~= nil and IAConversation.DEBUG_DIALOG_ON_CLOSE then
			print("--- IAConversationDialog:onClose() situation.conversation is nil — not calling onExternalDialogClose")
		end
		return
	end
	if self.situation.conversation.onExternalDialogClose == nil then
		if IAConversation ~= nil and IAConversation.DEBUG_DIALOG_ON_CLOSE then
			print("--- IAConversationDialog:onClose() conversation.onExternalDialogClose is nil")
		end
		return
	end
	if IAConversation ~= nil and IAConversation.DEBUG_DIALOG_ON_CLOSE then
		print("--- IAConversationDialog:onClose() calling conversation:onExternalDialogClose()")
	end
	self.situation.conversation:onExternalDialogClose()
end

--- Design reference: 1920x1080. All pixel-like sizes are converted to normalized (0-1) so layout scales with resolution and aspect ratio.
local REFERENCE_SCREEN_WIDTH  = 1920
local REFERENCE_SCREEN_HEIGHT = 1080

--- Convert design pixels (at 1080p reference) to normalized height (fraction of screen height).
local function normH(pixelY)
	local ref = (g_referenceScreenHeight and g_referenceScreenHeight > 0) and g_referenceScreenHeight or REFERENCE_SCREEN_HEIGHT
	return pixelY / ref
end

--- Convert design pixels (at 1920 reference) to normalized width.
local function normW(pixelX)
	local ref = (g_referenceScreenWidth and g_referenceScreenWidth > 0) and g_referenceScreenWidth or REFERENCE_SCREEN_WIDTH
	return pixelX / ref
end

--- Update the conversation text box height to fit the NPC name + dialog text.
--- Uses normalized sizes (0-1) derived from reference resolution so layout is correct at every aspect ratio and screen resolution.
function IAConversationDialog:updateTextBoxHeight(choiceOptionsVisible)
	local textBox = self.textBox
	local textElement = self.textElement
	local npcNameElement = self.npcNameElement
	if textBox == nil then
		return
	end
	-- Recalculate text layout after content change (IADialogGUI pattern)
	if npcNameElement and npcNameElement.updateSize then
		npcNameElement:updateSize()
	end
	if textElement and textElement.updateSize then
		textElement:updateSize()
	end
	-- getTextHeight() returns normalized height; use normalized padding
	local nameH = (npcNameElement and npcNameElement.getTextHeight and npcNameElement:getTextHeight()) or 0
	local textH = (textElement and textElement.getTextHeight and textElement:getTextHeight()) or 0
	local padding = normH(24)   -- spacing between name, text and Skip row
	local skipBtnHeightNorm = normH(36)  -- Skip button height in normalized (36px at reference)
	local boxHeight = nameH + textH + padding + skipBtnHeightNorm

	-- Keep the width that was set in XML / layout; only update height.
	local w = (textBox.size and textBox.size[1]) or (self.box and self.box.size and self.box.size[1])
	if w then
		textBox:setSize(w, boxHeight)
	end

	-- Options box: below the text box (name + text + Skip), small gap then options area.
	local opt = self.optionBoxBackground
	if opt and opt.setSize then
		local optionsHeightNorm = normH(150)
		if choiceOptionsVisible then
			if textBox.setPosition then
				textBox:setPosition(0, boxHeight + normH(-70) + optionsHeightNorm)
			elseif textBox.position then
				textBox.position[1] = 0
				textBox.position[2] = boxHeight + normH(-70) + optionsHeightNorm
			end
		else
			if textBox.setPosition then
				textBox:setPosition(0, normH(-70)+boxHeight)
			elseif textBox.position then
				textBox.position[1] = 0
				textBox.position[2] = normH(-70)+boxHeight
			end
		end
		if w then
			opt:setSize(w, optionsHeightNorm)
		end
	end

	-- Force layout refresh so wrapper/layout stay at top of box
	if self.textLayoutWrapper and self.textLayoutWrapper.invalidateLayout then
		self.textLayoutWrapper:invalidateLayout()
	end
	if self.textLayout and self.textLayout.invalidateLayout then
		self.textLayout:invalidateLayout()
	end
end

--- Called when user clicks the text area (transparent overlay). Advances to next line when not at choice point. Option buttons are outside this overlay so they receive clicks.
function IAConversationDialog:onClickAdvance()
	if self.situation == nil or self.situation.conversation == nil then
		return
	end
	self.situation.conversation:requestAdvanceToNextLine()
end

--- Called when an option button is clicked (onClick in XML; clones use onClickCallback in IAConversation).
function IAConversationDialog:onClickOption(triggerElement)
	local entryId = (triggerElement and triggerElement.optionEntryId) or (self.optionsScrollingLayout and self.optionsScrollingLayout.focusElement and self.optionsScrollingLayout.focusElement.optionEntryId)
	if entryId and self.situation and self.situation.selectConversationOption then
		self.situation:selectConversationOption(entryId)
	end
end

