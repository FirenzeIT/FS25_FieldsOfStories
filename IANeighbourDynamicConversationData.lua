--
-- IANeighbourDynamicConversationData: open fieldwork list + per-character dynamic conversations.
--
-- Conversations live as normal conversation.xml trees under
--   conversations/dynamic/<characterId>/<topic>/[<variant>/]
-- (same branching/options as IAConversation).
--
-- The conversation engine substitutes {placeholder} tokens in entry text and resolves
-- <segment type="variable" name="..."/> audio clips using a `variableMap` that callers attach
-- to the mission table (e.g. IANeighbour:onContractCallTimeTriggered). Keys map 1:1 to the
-- placeholder names used in conversation.xml; values are either:
--   * symbolic catalog keys (canonical IAFieldwork.JobType values for jobType /
--     vehicleNameWithArticle; "needed" or nil for extraRefillNote)
--   * raw strings already formatted for display (fieldNumber, fieldNumbers, totalHectares,
--     situationId)
--
-- Symbolic placeholders pull their UI text (text / textDe) and voice suffix from
-- data/IANeighbourDynamicConversationVoices.xml. Raw-string placeholders substitute their
-- value as-is in subtitles and look up FieldNumber-range suffixes numerically when a voice
-- segment is requested.
--
-- Mission table shape used by the dynamic conversation loader:
--   {
--     config            = situation config (id, fieldwork, ...),
--     farmlandIds       = array of farmland ids (multi-field offer),
--     farmlandId        = first farmland id (single-field offer),
--     contractOpenFieldworkList = full per-row open fieldwork list (used by callbacks),
--     variableMap       = { jobType=, vehicleNameWithArticle=, extraRefillNote=,
--                           fieldNumber=, fieldNumbers=, totalHectares=, situationId= }
--   }
--

IANeighbourDynamicConversationData = {}
IANeighbourDynamicConversationData._mt = Class(IANeighbourDynamicConversationData)

IANeighbourDynamicConversationData.VOICE_CATALOG_XML = "data/IANeighbourDynamicConversationVoices.xml"
--- Dynamic conversation folder: conversations/dynamic/{characterId}/{topic}/
IANeighbourDynamicConversationData.TOPIC_FIELD_MISSION_OFFER = "field_mission_offer"
--- Same offer with only one farmland: no "half work" branches (flat conversation.xml under this topic).
IANeighbourDynamicConversationData.TOPIC_FIELD_MISSION_OFFER_SINGLE = "field_mission_offer_single"

--- Variables that share the single numeric `<FieldNumber>` catalog table (text is raw value,
--- voice suffix is looked up by clamped numeric value).
IANeighbourDynamicConversationData.NUMERIC_VARIABLE_NAMES = {
	fieldnumber = true,
	field_number = true,
	fieldnumbers = true,
	field_numbers = true,
	totalhectares = true,
	total_hectares = true,
}
IANeighbourDynamicConversationData.NUMERIC_CATALOG_KEY = "fieldnumber"

--- Catalog element names parsed from <defaults>/<character> sections. Anything outside this
--- list is ignored. Element name is also the variable name in `voiceCatalog.variables`
--- (lowercased), so adding a new placeholder family is a 3-step change: enum / mission
--- builder / catalog XML.
IANeighbourDynamicConversationData.CATALOG_VARIABLE_ELEMENTS = {
	"jobType",
	"vehicleNameWithArticle",
	"extraRefillNote",
	"FieldNumber",
}

--- Parsed defaults + per-character overlays; filled once in loadVoiceCatalogXml.
IANeighbourDynamicConversationData._catalogDefaults = nil
IANeighbourDynamicConversationData._catalogCharacterOverlays = nil
IANeighbourDynamicConversationData._catalogMergedCache = {}

local function trim(s)
	if s == nil then
		return ""
	end
	return tostring(s):match("^%s*(.-)%s*$") or ""
end

local function shallowCopyMap(src)
	local out = {}
	if src ~= nil then
		for k, v in pairs(src) do
			out[k] = v
		end
	end
	return out
end

--- Parse one <defaults> or <character> section of the voice catalog XML.
--- Catalog element shape (all attributes required for a usable entry):
---   <jobType                 key="cultivate" suffix="job_cultivate" text="..." textDe="..."/>
---   <vehicleNameWithArticle  key="cultivate" suffix="ia_fieldwork_equip_cultivate" text="..." textDe="..."/>
---   <extraRefillNote         key="needed"   suffix="extra_refill_needed" text="..." textDe="..."/>
---   <FieldNumber             key="1"        suffix="fld_1" text="1" textDe="1"/>
--- @param xmlFile number GIANTS XML handle
--- @param sectionKey string e.g. "voiceCatalog.defaults" or "voiceCatalog.character(0)"
--- @return table { variables = { [varNameLower] = { [valueKey] = { suffix, text, textDe } } }, numericMin, numericMax }
local function parseVoiceCatalogSection(xmlFile, sectionKey)
	local variables = {}
	local numericMin, numericMax = nil, nil

	for _, elementName in ipairs(IANeighbourDynamicConversationData.CATALOG_VARIABLE_ELEMENTS) do
		local varKey = string.lower(elementName)
		local isNumeric = (varKey == IANeighbourDynamicConversationData.NUMERIC_CATALOG_KEY)
		local map = {}
		local idx = 0
		while true do
			local entryKey = sectionKey .. "." .. elementName .. "(" .. idx .. ")"
			local rawKey = getXMLString(xmlFile, entryKey .. "#key", nil)
			if rawKey == nil or rawKey == "" then
				break
			end
			local suffix = getXMLString(xmlFile, entryKey .. "#suffix", nil)
			local text   = getXMLString(xmlFile, entryKey .. "#text", nil)
			local textDe = getXMLString(xmlFile, entryKey .. "#textDe", nil)
			local storeKey = nil
			if isNumeric then
				local n = tonumber(trim(rawKey))
				if n ~= nil then
					storeKey = n
					if numericMin == nil or n < numericMin then numericMin = n end
					if numericMax == nil or n > numericMax then numericMax = n end
				end
			else
				storeKey = string.lower(trim(rawKey))
			end
			if storeKey ~= nil then
				map[storeKey] = {
					suffix = (suffix ~= nil and suffix ~= "") and suffix or nil,
					text   = (text   ~= nil and text   ~= "") and text   or nil,
					textDe = (textDe ~= nil and textDe ~= "") and textDe or nil,
				}
			end
			idx = idx + 1
		end
		if next(map) ~= nil then
			variables[varKey] = map
		end
	end

	return {
		named = {},
		variables = variables,
		numericMin = numericMin,
		numericMax = numericMax,
	}
end

local function mergeVariableMaps(base, overlay)
	if base == nil then return overlay end
	if overlay == nil then return base end
	local out = {}
	for varKey, entries in pairs(base) do
		out[varKey] = shallowCopyMap(entries)
	end
	for varKey, entries in pairs(overlay) do
		local merged = out[varKey] or {}
		for k, v in pairs(entries) do
			merged[k] = v
		end
		out[varKey] = merged
	end
	return out
end

local function mergeVoiceCatalogs(base, overlay)
	if base == nil then
		return overlay
	end
	if overlay == nil then
		return base
	end
	local namedOut = shallowCopyMap(base.named)
	if overlay.named ~= nil then
		for k, v in pairs(overlay.named) do
			namedOut[k] = v
		end
	end
	local variablesOut = mergeVariableMaps(base.variables, overlay.variables)
	-- Re-derive numericMin / numericMax from merged FieldNumber keys so per-character
	-- overlays that only add entries above the default range extend it correctly.
	local numericMin, numericMax = base.numericMin, base.numericMax
	local nums = variablesOut[IANeighbourDynamicConversationData.NUMERIC_CATALOG_KEY]
	if nums ~= nil then
		numericMin, numericMax = nil, nil
		for k, _ in pairs(nums) do
			if type(k) == "number" then
				if numericMin == nil or k < numericMin then numericMin = k end
				if numericMax == nil or k > numericMax then numericMax = k end
			end
		end
	end
	return {
		named = namedOut,
		variables = variablesOut,
		numericMin = numericMin,
		numericMax = numericMax,
	}
end

--- @param IANeighbour neighbour
function IANeighbourDynamicConversationData.new(neighbour)
	local self = setmetatable({}, IANeighbourDynamicConversationData._mt)
	self.neighbour = neighbour
	self.cachedOpenMissions = {}
	self.missionCacheAccumMs = 0
	self.refreshMissionIntervalMs = 60000
	self.openMissionsDirty = true
	self.initialized = false
	return self
end

function IANeighbourDynamicConversationData.loadVoiceCatalogXml()
	if IANeighbourDynamicConversationData._catalogDefaults ~= nil then
		return
	end
	IANeighbourDynamicConversationData._catalogDefaults = {
		named = {},
		variables = {},
		numericMin = nil,
		numericMax = nil,
	}
	IANeighbourDynamicConversationData._catalogCharacterOverlays = {}

	if IANeighbours == nil or IANeighbours.dir == nil then
		return
	end
	local path = Utils.getFilename(IANeighbourDynamicConversationData.VOICE_CATALOG_XML, IANeighbours.dir)
	if not fileExists(path) then
		if IANeighbours.debug then
			print("--- IANeighbourDynamicConversationData.loadVoiceCatalogXml() missing " .. tostring(path))
		end
		return
	end
	local xmlFile = loadXMLFile("IANeighbourVoiceCatalog", path)
	if xmlFile == nil then
		return
	end

	IANeighbourDynamicConversationData._catalogDefaults = parseVoiceCatalogSection(xmlFile, "voiceCatalog.defaults")

	local cIdx = 0
	while true do
		local cKey = "voiceCatalog.character(" .. cIdx .. ")"
		local cid = getXMLString(xmlFile, cKey .. "#id", nil)
		if cid == nil or cid == "" then
			break
		end
		IANeighbourDynamicConversationData._catalogCharacterOverlays[tostring(cid)] = parseVoiceCatalogSection(xmlFile, cKey)
		cIdx = cIdx + 1
	end
	delete(xmlFile)
	if IANeighbours.debug then
		print("--- IANeighbourDynamicConversationData.loadVoiceCatalogXml() OK defaults + " .. tostring(cIdx) .. " character overlays")
	end
end

--- Merged voice catalog for this neighbour (character id = neighbour.id from scenario).
-- @param IANeighbour neighbour
--- @return table
function IANeighbourDynamicConversationData.getVoiceCatalogForNeighbour(neighbour)
	IANeighbourDynamicConversationData.loadVoiceCatalogXml()
	local cid = neighbour ~= nil and neighbour.id ~= nil and tostring(neighbour.id) or "0"
	if IANeighbourDynamicConversationData._catalogMergedCache[cid] ~= nil then
		return IANeighbourDynamicConversationData._catalogMergedCache[cid]
	end
	local base = IANeighbourDynamicConversationData._catalogDefaults
	local over = IANeighbourDynamicConversationData._catalogCharacterOverlays[cid]
	local merged = mergeVoiceCatalogs(base, over)
	IANeighbourDynamicConversationData._catalogMergedCache[cid] = merged
	return merged
end

function IANeighbourDynamicConversationData:initialize()
	if self.initialized then
		return
	end
	IANeighbourDynamicConversationData.loadVoiceCatalogXml()
	self:refreshOpenMissionsCache()
	self.openMissionsDirty = false
	self.missionCacheAccumMs = 0
	self.initialized = true
end

function IANeighbourDynamicConversationData:update(dt)
	if not self.initialized then
		return
	end
	local ms = (dt or 0)
	self.missionCacheAccumMs = self.missionCacheAccumMs + ms
	if self.missionCacheAccumMs >= self.refreshMissionIntervalMs then
		self.missionCacheAccumMs = 0
		self.openMissionsDirty = true
	end
	if self.openMissionsDirty then
		self:refreshOpenMissionsCache()
		self.openMissionsDirty = false
	end
end

function IANeighbourDynamicConversationData:refreshOpenMissionsCache()
	local n = self.neighbour
	if n == nil or IANeighbours == nil or IANeighbours.gameLoopHelper == nil then
		self.cachedOpenMissions = {}
		return
	end
	self.cachedOpenMissions = IANeighbours.gameLoopHelper:getAllOpenFieldwork(n)
end

--- @return table array of { farmlandId, config, nextCropFruitTypeIndex? }
function IANeighbourDynamicConversationData:getOpenFieldMissions()
	if not self.initialized then
		self:initialize()
	end
	if self.openMissionsDirty then
		self:refreshOpenMissionsCache()
		self.openMissionsDirty = false
	end
	return self.cachedOpenMissions
end

--- Mod-relative base folder for this neighbour and topic (variants are numeric subfolders).
-- @param string topicKey e.g. field_mission_offer
--- @return string e.g. conversations/dynamic/17/field_mission_offer
function IANeighbourDynamicConversationData:getDynamicConversationBaseDir(topicKey)
	if self.neighbour == nil or self.neighbour.id == nil or topicKey == nil or topicKey == "" then
		return nil
	end
	return "conversations/dynamic/" .. tostring(self.neighbour.id) .. "/" .. tostring(topicKey)
end

--- Load dynamic conversation.xml for one mission into an IAConversation (variant picked randomly when pickVariant true).
-- The caller is responsible for filling `mission.variableMap` (see file header).
-- @param IAConversation conversation
-- @param string topicKey folder under conversations/dynamic/<neighbourId>/
-- @param table mission (see file header)
-- @param table|nil callbacksByAction e.g. accept, decline, accept_with_equipment, accept_half, accept_half_with_equipment, after_*
-- @param boolean|nil pickVariant default true
-- @param function|nil entryAvailabilityFilter optional function(entry) -> boolean
--- @return boolean
function IANeighbourDynamicConversationData:loadDynamicConversationForMission(conversation, topicKey, mission, callbacksByAction, pickVariant, entryAvailabilityFilter)
	if conversation == nil or self.neighbour == nil or mission == nil then
		return false
	end
	if not self.initialized then
		self:initialize()
	end
	local baseDir = self:getDynamicConversationBaseDir(topicKey)
	if baseDir == nil then
		return false
	end
	local catalog = IANeighbourDynamicConversationData.getVoiceCatalogForNeighbour(self.neighbour)
	if pickVariant == nil then
		pickVariant = true
	end
	conversation.entryAvailabilityFilter = entryAvailabilityFilter
	return conversation:loadDynamicConversationFromDirectory(baseDir, pickVariant, self.neighbour, mission.variableMap or {}, catalog, callbacksByAction or {})
end

--- Create a new IAConversation instance and load the dynamic tree for one mission (caller owns lifecycle; call stop() when done).
-- @param string topicKey e.g. IANeighbourDynamicConversationData.TOPIC_FIELD_MISSION_OFFER
-- @param table mission (see file header)
-- @param table|nil callbacksByAction
-- @param function|nil entryAvailabilityFilter optional function(entry) -> boolean
-- @return IAConversation|nil
function IANeighbourDynamicConversationData:createLoadedConversationForMission(topicKey, mission, callbacksByAction, entryAvailabilityFilter)
	if IAConversation == nil then
		return nil
	end
	local conv = IAConversation.new()
	if not self:loadDynamicConversationForMission(conv, topicKey, mission, callbacksByAction, true, entryAvailabilityFilter) then
		return nil
	end
	return conv
end
