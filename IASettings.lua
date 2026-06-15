--
-- FS25 - InteractiveNeighbours - Mod Settings
--
-- @Interface: 1.0.0.0
-- @Author: AirFoxTwo
--
-- Single-file mod settings: persistence, savegame state, gameplay helpers and
-- the in-game General Settings page UI for one global setting (contract phone
-- calls per in-game day).
--
-- Player setting: modSettings/FS25_FIELDS_OF_STORIES/settings.xml
-- Savegame state: IANeighbours_outbound.xml (daily counter + day key)
--

IASettings = {}

IASettings.SETTINGS_FILE_NAME = "settings.xml"

-- 1-based UI option index → cap; -1 means "unlimited" (no cap).
IASettings.CONTRACT_CALLS_PER_DAY_CAPS = { 0, 1, 2, 3, 4, -1 }
IASettings.CONTRACT_CALLS_PER_DAY_LABELS = {
	"ia_settings_contractCallsPerDay_none",
	"ia_settings_contractCallsPerDay_1",
	"ia_settings_contractCallsPerDay_2",
	"ia_settings_contractCallsPerDay_3",
	"ia_settings_contractCallsPerDay_4",
	"ia_settings_contractCallsPerDay_unlimited",
}
IASettings.CONTRACT_CALLS_PER_DAY_DEFAULT_INDEX = 3  -- "2 per day"

IASettings.contractCallsPerDayIndex = IASettings.CONTRACT_CALLS_PER_DAY_DEFAULT_INDEX
IASettings._initialized = false
IASettings._uiRegistered = false

-- In-memory daily counter; resets when the in-game calendar day rolls over.
IASettings._contractCallsDayKey = nil
IASettings._contractCallsDayCount = 0

local function clampIndex(v)
	local n = #IASettings.CONTRACT_CALLS_PER_DAY_CAPS
	v = tonumber(v) or IASettings.CONTRACT_CALLS_PER_DAY_DEFAULT_INDEX
	if v < 1 or v > n then
		v = IASettings.CONTRACT_CALLS_PER_DAY_DEFAULT_INDEX
	end
	return math.floor(v)
end

local function getCurrentDayKey()
	if g_currentMission == nil or type(getEnvironmentYearMonthDayInPeriod) ~= "function" then
		return nil
	end
	local y, m, d = getEnvironmentYearMonthDayInPeriod()
	if y == nil or m == nil or d == nil then
		return nil
	end
	return tostring(y) .. "_" .. tostring(m) .. "_" .. tostring(d)
end

local function refreshDayCounter()
	local key = getCurrentDayKey()
	if key == nil then
		return
	end
	if IASettings._contractCallsDayKey ~= key then
		IASettings._contractCallsDayKey = key
		IASettings._contractCallsDayCount = 0
	end
end

-- ============================================================================
-- Gameplay API (consumed by IAGameLoopHelper)
-- ============================================================================

--- @return number cap (0..N) or -1 for unlimited.
function IASettings.getContractCallsPerDayCap()
	return IASettings.CONTRACT_CALLS_PER_DAY_CAPS[clampIndex(IASettings.contractCallsPerDayIndex)]
end

--- @return boolean true if a new contract call ring is still allowed today.
function IASettings.canTriggerContractCallNow()
	refreshDayCounter()
	local cap = IASettings.getContractCallsPerDayCap()
	if cap < 0 then return true end
	if cap == 0 then return false end
	return IASettings._contractCallsDayCount < cap
end

--- Call after a contract call ring was actually shown to the player.
function IASettings.recordContractCallTriggered()
	refreshDayCounter()
	IASettings._contractCallsDayCount = (IASettings._contractCallsDayCount or 0) + 1
end

-- ============================================================================
-- Persistence (modSettings/FS25_FIELDS_OF_STORIES/settings.xml)
-- ============================================================================

local function settingsFilePath()
	local dir = (g_modSettingsDirectory or "") .. "FS25_FIELDS_OF_STORIES/"
	if folderExists ~= nil and not folderExists(dir) and createFolder ~= nil then
		createFolder(dir)
	end
	return dir .. IASettings.SETTINGS_FILE_NAME
end

function IASettings.load()
	local path = settingsFilePath()
	if fileExists ~= nil and fileExists(path) then
		local xml = loadXMLFile("IASettings", path)
		if xml ~= nil and xml ~= 0 then
			local idx = getXMLInt(xml, "IASettings.contractCallsPerDay#index")
			if idx ~= nil then
				IASettings.contractCallsPerDayIndex = clampIndex(idx)
			end
			delete(xml)
		end
	end
	IASettings._initialized = true
end

function IASettings.save()
	IASettings.contractCallsPerDayIndex = clampIndex(IASettings.contractCallsPerDayIndex)
	local xml = createXMLFile("IASettings_save", settingsFilePath(), "IASettings")
	if xml == nil or xml == 0 then return end
	setXMLInt(xml, "IASettings.contractCallsPerDay#index", IASettings.contractCallsPerDayIndex)
	setXMLInt(xml, "IASettings.contractCallsPerDay#cap", IASettings.getContractCallsPerDayCap())
	saveXMLFile(xml)
	delete(xml)
end

function IASettings.initialize()
	if not IASettings._initialized then
		IASettings.load()
	end
end

-- ============================================================================
-- Savegame runtime state (IANeighbours_outbound.xml)
-- ============================================================================

function IASettings.saveStateToOutboundXML(xmlFile, rootKey)
	if xmlFile == nil or rootKey == nil then
		return
	end
	refreshDayCounter()
	if IASettings._contractCallsDayKey ~= nil then
		local key = rootKey .. ".settings.contractCallsPerDayState"
		setXMLString(xmlFile, key .. "#dayKey", IASettings._contractCallsDayKey)
		setXMLInt(xmlFile, key .. "#count", IASettings._contractCallsDayCount or 0)
	end
end

function IASettings.loadStateFromOutboundXML(xmlFile, rootKey)
	if xmlFile == nil or rootKey == nil then
		return
	end
	local key = rootKey .. ".settings.contractCallsPerDayState"
	local dayKey = getXMLString(xmlFile, key .. "#dayKey", nil)
	local count = getXMLInt(xmlFile, key .. "#count", nil)
	if dayKey ~= nil and count ~= nil then
		IASettings._contractCallsDayKey = dayKey
		IASettings._contractCallsDayCount = math.max(0, count)
	end
	refreshDayCounter()
end

-- ============================================================================
-- In-game settings UI (Pause menu → General settings)
-- ----------------------------------------------------------------------------
-- Clones the base game's existing sectionHeader + multiVolumeVoiceBox templates
-- to add one section "Fields of Stories" with one multi-choice control
-- "Contract phone calls per day". No external helper required.
-- ============================================================================

local function recursivelyAssignFocusIds(element)
	if element == nil then return end
	element.focusId = FocusManager:serveAutoFocusId()
	for _, child in pairs(element.elements) do
		recursivelyAssignFocusIds(child)
	end
end

local function applyContractCallsPerDayToUI()
	if IASettings._uiOption ~= nil then
		IASettings._uiOption:setState(clampIndex(IASettings.contractCallsPerDayIndex))
	end
end

--- MultiTextOptionElement callback: invoked with `IASettings` as `self`.\n
function IASettings.onContractCallsPerDayChanged(self, newState)
	IASettings.contractCallsPerDayIndex = clampIndex(newState)
	IASettings.save()
end

local function buildSectionHeader(settingsPage)
	for _, elem in ipairs(settingsPage.gameSettingsLayout.elements) do
		if elem.name == "sectionHeader" then
			local section = elem:clone(settingsPage.gameSettingsLayout)
			section:setText(g_i18n:getText("ia_settings_section_title"))
			section.focusId = FocusManager:serveAutoFocusId()
			table.insert(settingsPage.controlsList, section)
			return section
		end
	end
end

local function buildChoiceControl(settingsPage)
	local box = settingsPage.multiVolumeVoiceBox:clone(settingsPage.gameSettingsLayout)
	recursivelyAssignFocusIds(box)
	box.id = "ia_settings_contractCallsPerDayBox"

	local option = box.elements[1]
	option.id = "ia_settings_contractCallsPerDay"
	option.target = IASettings
	option:setCallback("onClickCallback", "onContractCallsPerDayChanged")
	option:setDisabled(false)
	-- Workaround: FocusManager filters callbacks by target.name matching the page name.
	IASettings.name = settingsPage.name

	local texts = {}
	for _, key in ipairs(IASettings.CONTRACT_CALLS_PER_DAY_LABELS) do
		table.insert(texts, g_i18n:getText(key))
	end
	option:setTexts(texts)

	box.elements[2]:setText(g_i18n:getText("ia_settings_contractCallsPerDay_title"))
	option.elements[1]:setText(g_i18n:getText("ia_settings_contractCallsPerDay_info"))

	table.insert(settingsPage.controlsList, box)
	IASettings._uiBox = box
	IASettings._uiOption = option
end

--- Idempotent; safe to call from every InGameMenu.onMenuOpened.\n
function IASettings.registerInGameMenuSettings()
	if IASettings._uiRegistered then
		applyContractCallsPerDayToUI()
		return
	end
	local screen = g_gui and g_gui.screenControllers and g_gui.screenControllers[InGameMenu]
	if screen == nil or screen.pageSettings == nil then return end
	local settingsPage = screen.pageSettings
	if settingsPage.multiVolumeVoiceBox == nil or settingsPage.gameSettingsLayout == nil then
		return
	end

	IASettings.initialize()

	IASettings._uiSection = buildSectionHeader(settingsPage)
	buildChoiceControl(settingsPage)

	-- Re-apply value (and re-validate against UI) whenever the frame re-opens.
	InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(
		InGameMenuSettingsFrame.onFrameOpen, applyContractCallsPerDayToUI)

	-- Register our cloned controls with the FocusManager when a GUI gets shown.
	FocusManager.setGui = Utils.appendedFunction(FocusManager.setGui, function(_, _)
		for _, ctrl in ipairs({ IASettings._uiSection, IASettings._uiBox }) do
			if ctrl ~= nil
				and (ctrl.focusId == nil
					or not FocusManager.currentFocusData.idToElementMapping[ctrl.focusId])
			then
				FocusManager:loadElementFromCustomValues(ctrl, nil, nil, false, false)
			end
		end
		if settingsPage.gameSettingsLayout ~= nil then
			settingsPage.gameSettingsLayout:invalidateLayout()
		end
	end)

	applyContractCallsPerDayToUI()
	settingsPage.gameSettingsLayout:invalidateLayout()
	IASettings._uiRegistered = true
end
