--
-- FS25 - Fields of Stories - Map Initialization Job
--
-- When no map configuration exists for the active map, this job runs once:
-- finds a safe spawn position (e.g. trade dealer / selling point), spawns a
-- Kodiaq there and puts the player inside the vehicle.
--

IAMapInitJob = {}
IAMapInitJob.MAP_REFERENCE_STEP_LIMIT = 200
IAMapInitJob.MAP_REFERENCE_MAX_DEPTH = 50
IAMapInitJob._mt = Class(IAMapInitJob)

-- Kodiaq vehicle filename (from scenario)
IAMapInitJob.KODIAQ_XML = "data/vehicles/skoda/kodiaq/kodiaq.xml"
-- Price used to identify the map-init Kodiaq (and set on spawn)
IAMapInitJob.INIT_VEHICLE_PRICE = 0

-- Default fallback spawn (map center, above terrain)
IAMapInitJob.DEFAULT_SPAWN_X = 0
IAMapInitJob.DEFAULT_SPAWN_Z = 0
IAMapInitJob.DEFAULT_SPAWN_OFFSET_Y = 0.5
IAMapInitJob.DEFAULT_ROTATION_Y = 0

-- When true, logs every ReferenceNode / Shape / TransformGroup visited while parsing the map .i3d XML (very verbose).
-- Same traversal log is also emitted when IANeighbours.debug is true (no need to set this flag).
IAMapInitJob.debugParseMapI3dXml = false

function IAMapInitJob.new(ianeighboursRef)
	local self = setmetatable({}, IAMapInitJob._mt)
	self.ianeighbours = ianeighboursRef
	self.started = false
	self.finished = false
	self.vehicleSpawned = false
	self.vehicle = nil
	self.mapNodesDebugRequested = false
	return self
end

--- Returns true if the given vehicle is the map-init Kodiaq (same config and init price).
--- @param vehicle table vehicle object (e.g. from getCurrentVehicle())
--- @return boolean
function IAMapInitJob.isInitVehicle(vehicle)
	if vehicle == nil or vehicle.isDeleted then
		return false
	end
	local cfg = vehicle.configFileName
	local price = (vehicle.getPrice and vehicle:getPrice()) or vehicle.price
	return cfg == IAMapInitJob.KODIAQ_XML and price == IAMapInitJob.INIT_VEHICLE_PRICE
end

--- Called every frame from IANeighbours:update. Runs pending actions (e.g. map nodes debug when requested via Shift+F6).
function IAMapInitJob:update(dt)
	if self.ianeighbours == nil then
		return
	end
	if self.mapNodesDebugRequested then
		self.mapNodesDebugRequested = false
		self:addDebugPointsForAllMapNodes()
	end
	if IAMapInitJob._mapReferenceLoadState then
		IAMapInitJob._advanceMapReferenceLoad()
	end
end

--- After XML-derived map nodes are listed for Shift+F6, add runtime scene nodes under resolved locked TransformGroups
--- (nested i3d content is often absent from the map .i3d walk or not addressable as separate ReferenceNodes).
-- @param table combined - Array of target entries (modified in place): XML nodes already inserted with type = "node"
-- @param table options - maxDistanceFromPlayer (number), playerX, playerZ (optional, for distance filter)
function IAMapInitJob.appendRuntimeDescendantsUnderResolvedLockedGroups(combined, options)
	if combined == nil or getNumOfChildren == nil or getChildAt == nil or getWorldTranslation == nil then
		return
	end
	options = options or {}
	local maxDist = options.maxDistanceFromPlayer
	local playerX, playerZ = options.playerX, options.playerZ
	local maxDistSq = (maxDist and maxDist > 0) and (maxDist * maxDist) or nil
	local function inRangeXZ(wx, wz)
		if maxDistSq == nil or playerX == nil or playerZ == nil or wx == nil or wz == nil then
			return true
		end
		local dx, dz = wx - playerX, wz - playerZ
		return (dx * dx + dz * dz) <= maxDistSq
	end
	local mapRoot = IAMapInitJob.getMapRootNode and IAMapInitJob.getMapRootNode()
	if mapRoot == nil or not entityExists(mapRoot) or IAMapInitJob.collectRuntimeMapNodes == nil or IAMapInitJob.findRuntimeNodeForXmlEntry == nil then
		return
	end
	local runtimeNodes = IAMapInitJob.collectRuntimeMapNodes(mapRoot)
	local seenEngineIds = {}
	for _, e in ipairs(combined) do
		if e.type == "node" and e.nodeId ~= nil then
			seenEngineIds[e.nodeId] = true
		end
	end
	local appended = 0
	local maxDepth = 48
	local function tryAddSceneNode(nodeId)
		if nodeId == nil or not entityExists(nodeId) or seenEngineIds[nodeId] then
			return
		end
		local nm = (getName and getName(nodeId)) or ""
		if nm == "" or string.find(nm, "%.gdm") or string.sub(nm, 1, 3) == "LOD" then
			return
		end
		local wx, wy, wz = getWorldTranslation(nodeId)
		if wx == nil or wz == nil or not inRangeXZ(wx, wz) then
			return
		end
		seenEngineIds[nodeId] = true
		local rx, ry, rz = getRotation(nodeId)
		local rot = (rx ~= nil and ry ~= nil and rz ~= nil) and { x = rx, y = ry, z = rz } or nil
		table.insert(combined, {
			type = "node",
			id = tostring(nodeId),
			name = nm,
			nodeName = nm,
			position = { x = wx, y = wy or 0, z = wz },
			rotation = rot,
			nodeId = nodeId,
			resolvedRuntimeNodeId = nodeId,
			runtimeDescendantOfLockedGroup = true
		})
		appended = appended + 1
	end
	local function visitDescendants(nodeId, depth)
		if nodeId == nil or not entityExists(nodeId) or depth > maxDepth then
			return
		end
		local n = getNumOfChildren(nodeId)
		for i = 0, n - 1 do
			local ch = getChildAt(nodeId, i)
			if ch ~= nil and entityExists(ch) then
				tryAddSceneNode(ch)
				visitDescendants(ch, depth + 1)
			end
		end
	end
	-- Only XML-derived rows are locked roots; appended descendants must not be scanned again as roots.
	local nXmlNodes = #combined
	for i = 1, nXmlNodes do
		local e = combined[i]
		if e.type == "node" and e.lockedGroup == true then
			local rt = IAMapInitJob.findRuntimeNodeForXmlEntry(e, runtimeNodes, nil)
			if rt ~= nil and entityExists(rt) then
				visitDescendants(rt, 0)
			end
		end
	end
	if IANeighbours and IANeighbours.debug and appended > 0 then
		print(string.format("--- IAMapInitJob.appendRuntimeDescendantsUnderResolvedLockedGroups() - Added %d scene nodes under locked groups (in range)", appended))
	end
end

--- Load map nodes and placeables in range, pass combined list to IAPlacesLoader for display and focus (Shift+F6). Called from :update when requested.
function IAMapInitJob:addDebugPointsForAllMapNodes()
	if g_currentMission == nil or g_currentMission.terrainRootNode == nil or self.ianeighbours == nil then
		if IANeighbours and IANeighbours.debug then
			print("--- IAMapInitJob:addDebugPointsForAllMapNodes() - No mission, terrainRootNode or ianeighbours")
		end
		return
	end
	local maxDistanceFromPlayer = 15  -- nodes and placeables within this distance (world units) from the player
	local playerX, playerZ = nil, nil
	if g_localPlayer then
		local v = g_localPlayer.getCurrentVehicle and g_localPlayer:getCurrentVehicle()
		if v ~= nil and v.rootNode ~= nil and entityExists(v.rootNode) then
			playerX, _, playerZ = getWorldTranslation(v.rootNode)
		end
		if (playerX == nil or playerZ == nil) and g_localPlayer.getPosition then
			playerX, _, playerZ = g_localPlayer:getPosition()
		end
	end
	local nodes = IAMapInitJob.getAllMapNodesWithTransform({ maxDistanceFromPlayer = maxDistanceFromPlayer })
	local combined = {}
	-- Add node entries with type = "node"
	for _, entry in ipairs(nodes) do
		if entry.position and entry.position.x ~= nil and entry.position.y ~= nil and entry.position.z ~= nil then
			local nm = entry.name or ""
			if not string.find(nm, "%.gdm") and string.sub(nm, 1, 3) ~= "LOD" then
				entry.type = "node"
				table.insert(combined, entry)
			end
		end
	end
	IAMapInitJob.appendRuntimeDescendantsUnderResolvedLockedGroups(combined, {
		maxDistanceFromPlayer = maxDistanceFromPlayer,
		playerX = playerX,
		playerZ = playerZ
	})
	-- Add placeables (optionally filtered by distance)
	local loader = self.ianeighbours.placesLoader
	local placeableSystem = g_currentMission and g_currentMission.placeableSystem
	if placeableSystem and placeableSystem.placeables and loader then
		for _, p in ipairs(placeableSystem.placeables) do
			if p ~= nil and p.rootNode ~= nil then
				local x, y, z = loader:getPlaceablePosition(p)
				if x ~= nil and z ~= nil then
					local inRange = true
					if playerX ~= nil and playerZ ~= nil and maxDistanceFromPlayer then
						local dx = x - playerX
						local dz = z - playerZ
						inRange = (dx * dx + dz * dz) <= (maxDistanceFromPlayer * maxDistanceFromPlayer)
					end
					if inRange then
						local rot = loader:getPlaceableRotation(p)
						local label = (p.getName and p:getName()) or p.configFileName or p.typeName or "placeable"
						if type(label) ~= "string" then label = tostring(label) end
						table.insert(combined, {
							type = "placeable",
							placeable = p,
							position = { x = x, y = y or 0, z = z },
							rotation = rot,
							label = label
						})
					end
				end
			end
		end
	end
	if self.ianeighbours.placesLoader then
		self.ianeighbours.placesLoader:setDisplayedRelativeTargets(combined)
	end
	if IANeighbours and IANeighbours.debug then
		print(string.format("--- IAMapInitJob:addDebugPointsForAllMapNodes() - Displayed %d relative targets (nodes + placeables)", #combined))
	end
end

--- Try to get the map's main i3d file path (for parsing referenceId -> filename).
-- Tries missionInfo.loadingMapBaseDirectory, mission XML's <map>/<filename>, then data/maps/<mapId>/<mapId>.i3d.
-- @return string|nil path if file exists, nil otherwise



---- FEHLER:
---2026-04-19 22:43:44.067 --- IAXMLHelper:bootstrapFirstRunMapPlaces() - Bootstrapping places from placeablePlaces.xml
---2026-04-19 22:43:44.069 --- IAMapInitJob.getMapReferenceData() - mapId: FS25_Am_NOK.Am Nord-Ostsee-Kanal
---2026-04-19 22:43:44.069 --- IAMapInitJob.getMapReferenceData() - path: nil
---2026-04-19 22:43:44.069 Error: Running LUA method 'mouseEvent'.
---C:/Users/leonn/AppData/Local/Packages/GIANTSSoftware.FarmingSimulator25PC_fa8jxm5fj0esw/LocalCache/Local/mods/FS25_Fields_of_Stories/IAMapInitJob.lua:565: attempt to get length of a nil value

local function resolveMissionMapXMLPath(missionInfo)
	if missionInfo == nil then
		return nil
	end
	local mapXMLFilename = missionInfo.mapXMLFilename
	local baseDirectory = missionInfo.baseDirectory
	if mapXMLFilename == nil or mapXMLFilename == "" or baseDirectory == nil or baseDirectory == "" then
		return nil
	end
	return Utils.getFilename(mapXMLFilename, baseDirectory)
end

local function resolveMissionMapI3dFromXml(missionInfo)
	local xmlPath = resolveMissionMapXMLPath(missionInfo)
	local baseDirectory = missionInfo and missionInfo.baseDirectory
	if xmlPath == nil or xmlPath == "" or not fileExists(xmlPath) then
		return nil
	end
	local xmlFile = loadXMLFile("IAMapInitJobMapXml", xmlPath)
	if xmlFile == nil or xmlFile == 0 then
		return nil
	end
	local filename = getXMLString(xmlFile, "map.filename", nil)
	delete(xmlFile)
	if filename == nil or filename == "" then
		return nil
	end
	return Utils.getFilename(filename, baseDirectory)
end



function IAMapInitJob.getMapI3dPath()
	if g_currentMission == nil or g_currentMission.missionInfo == nil or g_currentMission.missionInfo.mapId == nil then
		return nil
	end
	local mapId = g_currentMission.missionInfo.mapId
	local missionInfo = g_currentMission.missionInfo
	local candidatePaths = {}
	local loadingBase = missionInfo.loadingMapBaseDirectory
	if loadingBase ~= nil and loadingBase ~= "" then
		table.insert(candidatePaths, loadingBase .. "/" .. mapId .. ".i3d")
		table.insert(candidatePaths, loadingBase .. "/map.i3d")
	end
	local xmlDerivedPath = resolveMissionMapI3dFromXml(missionInfo)
	if xmlDerivedPath ~= nil and xmlDerivedPath ~= "" then
		table.insert(candidatePaths, xmlDerivedPath)
	end
	for _, path in ipairs(candidatePaths) do
		if path ~= nil and path ~= "" and fileExists(path) then
			return path
		end
	end
	-- Fallback: game data path (empty string often resolves to game root in FS)
	local p3 = "data/maps/" .. mapId .. "/" .. mapId .. ".i3d"
	if fileExists(p3) then return p3 end
	local p4 = "data/maps/" .. mapId .. "/map.i3d"
	if fileExists(p4) then return p4 end
	return nil
end

local function parseXYZ(str)
	if str == nil or str == "" then
		return nil
	end
	local parts = {}
	for token in str:gmatch("%S+") do
		table.insert(parts, token)
	end
	if #parts < 3 then
		return nil
	end
	local x, y, z = tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3])
	if x and y and z then
		return { x = x, y = y, z = z }
	end
	return nil
end

local function localToWorld(parentWx, parentWy, parentWz, parentYawDeg, localTx, localTy, localTz, localRyDeg)
	local yawRad = (parentYawDeg or 0) * (math.pi / 180)
	local c, s = math.cos(yawRad), math.sin(yawRad)
	local wx = (parentWx or 0) + (localTx or 0) * c - (localTz or 0) * s
	local wy = (parentWy or 0) + (localTy or 0)
	local wz = (parentWz or 0) + (localTx or 0) * s + (localTz or 0) * c
	local wyDeg = (parentYawDeg or 0) + (localRyDeg or 0)
	return wx, wy, wz, wyDeg
end

local function copyHierarchyPath(path)
	local copied = {}
	if path then
		for _, idx in ipairs(path) do
			copied[#copied + 1] = idx
		end
	end
	return copied
end

local function collectMapFileIdToFilename(xmlFile, logXml)
	local mapping = {}
	local fileIndex = 0
	while true do
		local key = "i3d.Files.File(" .. fileIndex .. ")"
		local filename = getXMLString(xmlFile, key .. "#filename", nil) or getXMLString(xmlFile, key .. "#name", nil)
		local idStr = getXMLString(xmlFile, key .. "#fileId", nil)
		if filename == nil and idStr == nil then
			break
		end
		if filename ~= nil and idStr ~= nil then
			mapping[idStr] = filename
			if logXml then
				print("--- I3D walk FILE fileId=" .. tostring(idStr) .. " filename=" .. tostring(filename))
			end
		end
		fileIndex = fileIndex + 1
	end
	return mapping
end

local function createMapReferenceStackEntry(basePath, depth, parentWx, parentWy, parentWz, parentYawDeg, parentPath, insideLockedSubtree)
	return {
		basePath = basePath,
		depth = depth or 0,
		parentWx = parentWx or 0,
		parentWy = parentWy or 0,
		parentWz = parentWz or 0,
		parentYawDeg = parentYawDeg or 0,
		parentPath = parentPath or {},
		insideLockedSubtree = insideLockedSubtree == true,
		stage = "Refs",
		refIndex = 0,
		shapeIndex = 0,
		tgIndex = 0
	}
end

local function createMapReferenceState(path, mapId, logXml)
	if path == nil or path == "" or not fileExists(path) then
		return nil, "mapPathInvalid"
	end
	local xmlFile = loadXMLFile("mapI3dRef", path)
	if xmlFile == nil or xmlFile == 0 then
		return nil, "loadFailed"
	end
	local state = {
		path = path,
		mapId = mapId,
		xmlFile = xmlFile,
		refByNodeId = {},
		fileIdToFilename = {},
		logXml = logXml == true,
		stack = {},
		maxDepth = IAMapInitJob.MAP_REFERENCE_MAX_DEPTH
	}
	state.fileIdToFilename = collectMapFileIdToFilename(xmlFile, state.logXml)
	table.insert(state.stack, createMapReferenceStackEntry("i3d.Scene", 0, 0, 0, 0, 0, {}, false))
	return state
end

local function finalizeMapReferenceState(state)
	if state == nil then
		return {}
	end
	if state.logXml then
		local storedCount = 0
		for _ in pairs(state.refByNodeId or {}) do
			storedCount = storedCount + 1
		end
		print("--- IAMapInitJob.finalizeMapReferenceState() storedNodeEntries=" .. tostring(storedCount) .. " file=" .. tostring(state.path))
	end
	if state.xmlFile and state.xmlFile ~= 0 then
		delete(state.xmlFile)
		state.xmlFile = nil
	end
	local result = state.refByNodeId or {}
	state.refByNodeId = nil
	state.stack = nil
	return result
end

local function processReferenceNodes(state, entry)
	local xmlFile = state.xmlFile
	local key = entry.basePath .. ".ReferenceNode(" .. entry.refIndex .. ")"
	local refIdStr = getXMLString(xmlFile, key .. "#referenceId", nil)
	local nodeIdStr = getXMLString(xmlFile, key .. "#nodeId", nil)
	local nameStr = getXMLString(xmlFile, key .. "#name", nil)
	if refIdStr == nil and nodeIdStr == nil then
		entry.stage = "Shapes"
		return false
	end
	entry.refIndex = entry.refIndex + 1
	if refIdStr ~= nil and nodeIdStr ~= nil then
		local nodeId = tonumber(nodeIdStr)
		if nodeId then
			local translation = parseXYZ(getXMLString(xmlFile, key .. "#translation", nil)) or { x = 0, y = 0, z = 0 }
			local rotation = parseXYZ(getXMLString(xmlFile, key .. "#rotation", nil)) or { x = 0, y = 0, z = 0 }
			local wx, wy, wz, wyDeg = localToWorld(entry.parentWx, entry.parentWy, entry.parentWz, entry.parentYawDeg,
				translation.x, translation.y, translation.z, rotation.y)
			state.refByNodeId[nodeId] = {
				referenceId = refIdStr,
				referenceFilename = state.fileIdToFilename[refIdStr],
				nodeName = nameStr,
				translation = { x = wx, y = wy, z = wz },
				rotation = { x = rotation.x, y = wyDeg, z = rotation.z },
				localTranslation = { x = translation.x, y = translation.y, z = translation.z },
				localRotation = { x = rotation.x, y = rotation.y, z = rotation.z },
				hierarchyPath = entry.parentPath,
				underLockedGroup = entry.insideLockedSubtree or nil
			}
			if state.logXml then
				print(string.format("--- I3D walk REF stored idx=%d nodeId=%s refId=%s name=%s file=%s key=%s",
					entry.refIndex - 1, tostring(nodeId), tostring(refIdStr), tostring(nameStr),
					tostring(state.fileIdToFilename[refIdStr]), tostring(key)))
			end
		end
	end
	return true
end

local function processShapeNodes(state, entry)
	local xmlFile = state.xmlFile
	local key = entry.basePath .. ".Shape(" .. entry.shapeIndex .. ")"
	local shapeNodeIdStr = getXMLString(xmlFile, key .. "#nodeId", nil)
	local shapeNameStr = getXMLString(xmlFile, key .. "#name", nil)
	if shapeNodeIdStr == nil and shapeNameStr == nil then
		entry.stage = "TGs"
		return false
	end
	entry.shapeIndex = entry.shapeIndex + 1
	if shapeNodeIdStr ~= nil and shapeNameStr ~= nil and shapeNameStr ~= "" then
		local nodeId = tonumber(shapeNodeIdStr)
		if nodeId then
			local translation = parseXYZ(getXMLString(xmlFile, key .. "#translation", nil))
			local rotation = parseXYZ(getXMLString(xmlFile, key .. "#rotation", nil))
			if translation then
				if rotation == nil then
					rotation = { x = 0, y = 0, z = 0 }
				end
				local wx, wy, wz, wyDeg = localToWorld(entry.parentWx, entry.parentWy, entry.parentWz, entry.parentYawDeg,
					translation.x, translation.y, translation.z, rotation.y)
				state.refByNodeId[nodeId] = {
					name = shapeNameStr,
					nodeName = shapeNameStr,
					translation = { x = wx, y = wy, z = wz },
					rotation = { x = rotation.x, y = wyDeg, z = rotation.z },
					localTranslation = { x = translation.x, y = translation.y, z = translation.z },
					localRotation = { x = rotation.x, y = rotation.y, z = rotation.z },
					hierarchyPath = entry.parentPath,
					isShape = true,
					underLockedGroup = entry.insideLockedSubtree or nil
				}
				if state.logXml then
					print(string.format("--- I3D walk SHAPE stored idx=%d nodeId=%s name=%s key=%s",
						entry.shapeIndex - 1, tostring(nodeId), tostring(shapeNameStr), tostring(key)))
				end
			elseif state.logXml then
				print("--- I3D walk SHAPE skip-no-translation idx=" .. tostring(entry.shapeIndex - 1) .. " key=" .. tostring(key))
			end
		elseif state.logXml then
			print("--- I3D walk SHAPE skip-bad-nodeId idx=" .. tostring(entry.shapeIndex - 1) .. " key=" .. tostring(key))
		end
	end
	return true
end

local function processTransformGroups(state, entry)
	local xmlFile = state.xmlFile
	local key = entry.basePath .. ".TransformGroup(" .. entry.tgIndex .. ")"
	local tgName = getXMLString(xmlFile, key .. "#name", nil)
	local tgNodeIdStr = getXMLString(xmlFile, key .. "#nodeId", nil)
	local tgTranslation = getXMLString(xmlFile, key .. "#translation", nil)
	local hasContent = tgName ~= nil or tgNodeIdStr ~= nil or tgTranslation ~= nil
	if not hasContent then
		table.remove(state.stack)
		return false
	end
	local currentIndex = entry.tgIndex
	entry.tgIndex = entry.tgIndex + 1
	local tgTrans = parseXYZ(tgTranslation)
	local tgRot = parseXYZ(getXMLString(xmlFile, key .. "#rotation", nil))
	if tgRot == nil then
		tgRot = { x = 0, y = 0, z = 0 }
	end
	local childWx, childWy, childWz, childYawDeg = entry.parentWx, entry.parentWy, entry.parentWz, entry.parentYawDeg
	if tgTrans then
		childWx, childWy, childWz, childYawDeg = localToWorld(entry.parentWx, entry.parentWy, entry.parentWz, entry.parentYawDeg,
			tgTrans.x, tgTrans.y, tgTrans.z, tgRot.y)
	end
	local childPath = copyHierarchyPath(entry.parentPath)
	childPath[#childPath + 1] = currentIndex
	local locked = getXMLString(xmlFile, key .. "#lockedgroup", nil)
	local isLockedTg = locked == "true"
	if state.logXml then
		print(string.format("--- I3D walk TG idx=%d depth=%d name=%s locked=%s key=%s",
			currentIndex, entry.depth, tostring(tgName), tostring(isLockedTg), tostring(key)))
	end
	if isLockedTg and tgNodeIdStr ~= nil and tgName ~= nil and tgName ~= "" then
		local nodeId = tonumber(tgNodeIdStr)
		if nodeId then
			local lt = tgTrans or { x = 0, y = 0, z = 0 }
			state.refByNodeId[nodeId] = {
				name = tgName,
				nodeName = tgName,
				translation = { x = childWx, y = childWy, z = childWz },
				rotation = { x = tgRot.x, y = childYawDeg, z = tgRot.z },
				localTranslation = { x = lt.x, y = lt.y, z = lt.z },
				localRotation = { x = tgRot.x, y = tgRot.y, z = tgRot.z },
				hierarchyPath = childPath,
				lockedGroup = true,
				underLockedGroup = entry.insideLockedSubtree or nil
			}
			if state.logXml then
				print(string.format("--- I3D walk TG locked stored nodeId=%s name=%s key=%s",
					tostring(nodeId), tostring(tgName), tostring(key)))
			end
		elseif state.logXml then
			print("--- I3D walk TG locked skip-bad-nodeId key=" .. tostring(key))
		end
	end
	if entry.depth >= state.maxDepth then
		if state.logXml then
			print(string.format("--- I3D walk SKIP depth>=%d for %s", state.maxDepth, tostring(key)))
		end
		return true
	end
	local childEntry = createMapReferenceStackEntry(key, entry.depth + 1, childWx, childWy, childWz, childYawDeg, childPath, entry.insideLockedSubtree or isLockedTg)
	table.insert(state.stack, childEntry)
	return true
end

local function processNextMapReferenceStackEntry(state)
	local stack = state.stack
	local entry = stack[#stack]
	if entry == nil then
		return true, false
	end
	if entry.stage == "Refs" then
		local consumed = processReferenceNodes(state, entry)
		return false, consumed
	elseif entry.stage == "Shapes" then
		local consumed = processShapeNodes(state, entry)
		return false, consumed
	elseif entry.stage == "TGs" then
		local consumed = processTransformGroups(state, entry)
		return false, consumed
	else
		table.remove(stack)
		return false, false
	end
end

local function advanceMapReferenceState(state, stepLimit)
	stepLimit = stepLimit or IAMapInitJob.MAP_REFERENCE_STEP_LIMIT
	local processed = 0
	while processed < stepLimit do
		local finished, consumed = processNextMapReferenceStackEntry(state)
		if finished then
			return true
		end
		if consumed then
			processed = processed + 1
		end
	end
	return false
end

local function cancelBackgroundMapReferenceState()
	local state = IAMapInitJob._mapReferenceLoadState
	if state == nil then
		return
	end
	if state.xmlFile and state.xmlFile ~= 0 then
		delete(state.xmlFile)
	end
	IAMapInitJob._mapReferenceLoadState = nil
end

local function completeBackgroundMapReferenceState(state)
	local data = finalizeMapReferenceState(state)
	IAMapInitJob._mapReferenceLoadState = nil
	IAMapInitJob._mapRefData = data
	IAMapInitJob._mapRefDataMapId = state.mapId
	if state.logXml and IANeighbours and IANeighbours.debug then
		local entryCount = 0
		for _ in pairs(data or {}) do
			entryCount = entryCount + 1
		end
		print("--- IAMapInitJob._mapReferenceLoadState complete mapId=" .. tostring(state.mapId) .. " entries=" .. tostring(entryCount))
	end
end

--- Parse map i3d XML to build nodeId -> { referenceId, referenceFilename, translation, rotation }.
--- I3D has ReferenceNode (referenceId, nodeId, translation, rotation) and Files section (file handle -> filename).
--- @param string path path to the map .i3d file
--- @return table nodeId -> { referenceId, referenceFilename [, translation = {x,y,z} [, rotation = {x,y,z} ]] } (or nil if parse fails)
function IAMapInitJob.parseMapI3dReferenceData(path)
	local logXml = (IANeighbours and IANeighbours.debug == true) and (IAMapInitJob.debugParseMapI3dXml == true)
	local state, err = createMapReferenceState(path, nil, logXml)
	if not state then
		if IANeighbours and IANeighbours.debug then
			print("--- IAMapInitJob.parseMapI3dReferenceData() - Failed to load: " .. tostring(err))
		end
		return nil
	end
	while true do
		local finished = advanceMapReferenceState(state, math.huge)
		if finished then
			break
		end
	end
	return finalizeMapReferenceState(state)
end

function IAMapInitJob._startMapReferenceLoad(path, mapId)
	cancelBackgroundMapReferenceState()
	local state, err = createMapReferenceState(path, mapId, (IANeighbours and IANeighbours.debug == true) and (IAMapInitJob.debugParseMapI3dXml == true))
	if not state then
		if IANeighbours and IANeighbours.debug then
			print("--- IAMapInitJob._startMapReferenceLoad() - Failed to load " .. tostring(path) .. " err=" .. tostring(err))
		end
		return nil
	end
	IAMapInitJob._mapReferenceLoadState = state
	return state
end

function IAMapInitJob._advanceMapReferenceLoad(stepLimit)
	local state = IAMapInitJob._mapReferenceLoadState
	if state == nil then
		return
	end
	local finished = advanceMapReferenceState(state, stepLimit)
	if finished then
		completeBackgroundMapReferenceState(state)
	end
end

function IAMapInitJob.isMapReferenceDataReady()
	return IAMapInitJob._mapRefData ~= nil and IAMapInitJob._mapRefDataMapId ~= nil and IAMapInitJob._mapReferenceLoadState == nil
end

function IAMapInitJob.isMapReferenceDataLoading()
	return IAMapInitJob._mapReferenceLoadState ~= nil
end
-- Cached map reference data (nodeId -> referenceId, referenceFilename, translation, rotation). Cleared when map changes.
IAMapInitJob._mapRefData = nil
IAMapInitJob._mapRefDataMapId = nil
IAMapInitJob._mapReferenceLoadState = nil

--- Get (and cache) map i3d reference data for the current map. Returns nodeId -> { referenceId, referenceFilename [, translation, rotation ] }.
function IAMapInitJob.getMapReferenceData()
	local mapId = g_currentMission and g_currentMission.missionInfo and g_currentMission.missionInfo.mapId
	if IANeighbours and IANeighbours.debug then	
		print("--- IAMapInitJob.getMapReferenceData() - mapId: " .. tostring(mapId))
	end
	if mapId == nil then
		return nil
	end
	if IAMapInitJob._mapRefData ~= nil and IAMapInitJob._mapRefDataMapId == mapId then
		if IANeighbours and IANeighbours.debug then
			print("--- IAMapInitJob.getMapReferenceData() - returning cached mapRefData")
		end
		return IAMapInitJob._mapRefData
	end
	local state = IAMapInitJob._mapReferenceLoadState
	IAprintDebug("IAMapInitJob.getMapReferenceData()","state: " .. tostring(state),nil,nil,nil)
	if state ~= nil then
		if state.mapId ~= mapId then
			cancelBackgroundMapReferenceState()
			state = nil
		else
			IAMapInitJob._advanceMapReferenceLoad()
			return nil
		end
	end
	local path = IAMapInitJob.getMapI3dPath()
	if IANeighbours and IANeighbours.debug then
		print("--- IAMapInitJob.getMapReferenceData() - path: " .. tostring(path))
	end
	if path == nil then
		return nil
	end
	local started = IAMapInitJob._startMapReferenceLoad(path, mapId)
	if not started then
		IAMapInitJob._mapRefData = {}
		IAMapInitJob._mapRefDataMapId = mapId
		return IAMapInitJob._mapRefData
	end
	IAMapInitJob._advanceMapReferenceLoad()
	return nil
end

--- Returns an array of map nodes with name, position and rotation from map i3d reference data.
-- Data comes from getMapReferenceData() (parsed map I3D XML). No scene-graph walk.
-- @param table options optional: maxDistanceFromPlayer (number) only include nodes within this distance from player
-- @return table[] array of { id, name, position, rotation, nodeId [, referenceId [, referenceFilename ]] } (rotation in radians)
function IAMapInitJob.getAllMapNodesWithTransform(options)
	options = options or {}
	local maxDistanceFromPlayer = options.maxDistanceFromPlayer

	local playerX, playerY, playerZ = nil, nil, nil
	if maxDistanceFromPlayer and maxDistanceFromPlayer > 0 and g_localPlayer and g_localPlayer.getPosition then
		playerX, playerY, playerZ = g_localPlayer:getPosition()
	end

	if g_currentMission == nil then
		return {}
	end
	IAprintDebug("IAMapInitJob.getAllMapNodesWithTransform()","getMapReferenceData()",nil,nil,nil)
	local mapRefData = IAMapInitJob.getMapReferenceData()
	IAprintDebug("IAMapInitJob.getAllMapNodesWithTransform()","mapRefData: " .. tostring(mapRefData and #mapRefData or 0),nil,nil,nil)
	if mapRefData == nil or next(mapRefData) == nil then
		return {}
	end

	local list = {}
	for nodeId, ref in pairs(mapRefData) do
		local x, y, z = ref.translation and ref.translation.x, ref.translation and ref.translation.y, ref.translation and ref.translation.z
		if x ~= nil and z ~= nil then
			local skip = false
			if maxDistanceFromPlayer and maxDistanceFromPlayer > 0 and playerX ~= nil and playerZ ~= nil then
				local dx, dz = x - playerX, z - playerZ
				if dx * dx + dz * dz > maxDistanceFromPlayer * maxDistanceFromPlayer then 
					skip = true 
				end
			end
			if not skip then
				local rx, ry, rz = nil, nil, nil
				if ref.rotation then
					local deg2rad = math.pi / 180
					rx = ref.rotation.x and ref.rotation.x * deg2rad or 0
					ry = ref.rotation.y and ref.rotation.y * deg2rad or 0
					rz = ref.rotation.z and ref.rotation.z * deg2rad or 0
				end
				-- Locked groups use ref.name; ReferenceNodes use ref.referenceFilename; nodeName is I3D #name for matching at runtime
				local displayName = (ref.name and ref.name ~= "") and ref.name or (ref.referenceFilename or "")
				local entry = {
					id = tostring(nodeId),
					name = displayName,
					nodeName = ref.nodeName,
					position = { x = x, y = y or 0, z = z },
					rotation = (rx ~= nil and ry ~= nil and rz ~= nil) and { x = rx, y = ry, z = rz } or nil,
					nodeId = nodeId,
					localTranslation = ref.localTranslation,
					localRotation = ref.localRotation,
					hierarchyPath = ref.hierarchyPath
				}
				if ref.lockedGroup then entry.lockedGroup = true end
				if ref.underLockedGroup then entry.underLockedGroup = true end
				if ref.referenceId ~= nil then entry.referenceId = ref.referenceId end
				if ref.referenceFilename ~= nil and ref.referenceFilename ~= "" then entry.referenceFilename = ref.referenceFilename end
				table.insert(list, entry)
			end
		end
	end
	return list
end

--- Build an xmlEntry table for findRuntimeNodeForXmlEntry from cached map I3D reference data (same shape as getAllMapNodesWithTransform entries).
-- @param number nodeIdNum - Key in getMapReferenceData()
-- @param table ref - Value from getMapReferenceData()[nodeIdNum]
-- @return table|nil xmlEntry
function IAMapInitJob.buildXmlEntryFromMapRef(nodeIdNum, ref)
	if nodeIdNum == nil or ref == nil then
		return nil
	end
	local x, y, z = ref.translation and ref.translation.x, ref.translation and ref.translation.y, ref.translation and ref.translation.z
	if x == nil or z == nil then
		return nil
	end
	local rx, ry, rz = nil, nil, nil
	if ref.rotation then
		local deg2rad = math.pi / 180
		rx = ref.rotation.x and ref.rotation.x * deg2rad or 0
		ry = ref.rotation.y and ref.rotation.y * deg2rad or 0
		rz = ref.rotation.z and ref.rotation.z * deg2rad or 0
	end
	local displayName = (ref.name and ref.name ~= "") and ref.name or (ref.referenceFilename or "")
	local entry = {
		id = tostring(nodeIdNum),
		name = displayName,
		nodeName = ref.nodeName,
		position = { x = x, y = y or 0, z = z },
		rotation = (rx ~= nil and ry ~= nil and rz ~= nil) and { x = rx, y = ry, z = rz } or nil,
		nodeId = nodeIdNum,
		localTranslation = ref.localTranslation,
		localRotation = ref.localRotation,
		hierarchyPath = ref.hierarchyPath
	}
	if ref.lockedGroup then entry.lockedGroup = true end
	if ref.underLockedGroup then entry.underLockedGroup = true end
	if ref.referenceId ~= nil then entry.referenceId = ref.referenceId end
	if ref.referenceFilename ~= nil and ref.referenceFilename ~= "" then entry.referenceFilename = ref.referenceFilename end
	return entry
end

--- Get the main map root node (same as MapObjectsHider: g_currentMission.maps[1]). Use this for traversing map nodes at runtime, not terrainRootNode.
--- @return number|nil - Map root node id or nil
function IAMapInitJob.getMapRootNode()
	if g_currentMission == nil or g_currentMission.maps == nil or g_currentMission.maps[1] == nil then
		return nil
	end
	local root = g_currentMission.maps[1]
	if entityExists(root) then
		return root
	end
	return nil
end

local TRANSLATION_MATCH_EPS = 0.01
local ROTATION_MATCH_EPS_DEG = 0.5

--- Collect all nodes under root with name, local translation, local rotation and hierarchy path (for matching to XML ref data).
--- @param number rootNode - Scene root (e.g. from getMapRootNode())
--- @param number maxNodes - Max nodes to collect (default 50000)
--- @return table[] - Array of { nodeId, name, localTranslation, localRotationDeg, hierarchyPath }
function IAMapInitJob.collectRuntimeMapNodes(rootNode, maxNodes)
	maxNodes = maxNodes or 1000000
	if rootNode == nil or not entityExists(rootNode) then
		return {}
	end
	local list = {}
	local function visit(node, path)
		if #list >= maxNodes then return end
		if node == nil or not entityExists(node) then return end
		local name = getName and getName(node) or ""
		local tx, ty, tz = getTranslation(node)
		local rx, ry, rz = getRotation(node)
		if tx ~= nil and tz ~= nil then
			local entry = {
				nodeId = node,
				name = (name and name ~= "") and name or "",
				localTranslation = { x = tx, y = ty or 0, z = tz },
				localRotationDeg = (rx ~= nil and ry ~= nil and rz ~= nil) and { x = math.deg(rx), y = math.deg(ry), z = math.deg(rz) } or nil,
				hierarchyPath = path and path or {}
			}
			table.insert(list, entry)
		end
		local n = getNumOfChildren(node)
		for i = 0, n - 1 do
			if #list >= maxNodes then return end
			local child = getChildAt(node, i)
			local childPath = {}
			if path then for _, idx in ipairs(path) do childPath[#childPath + 1] = idx end end
			childPath[#childPath + 1] = i
			visit(child, childPath)
		end
	end
	visit(rootNode, {})
	return list
end

--- Match one XML ref entry (from getAllMapNodesWithTransform) to a runtime node by name + local translation (+ optional local rotation and hierarchy).
--- @param table xmlEntry - Entry with nodeName or name, localTranslation, localRotation (degrees), optional hierarchyPath
--- @param table runtimeNodes - Array from collectRuntimeMapNodes
--- @param table excludedNodeIds - Optional set of nodeIds already used (so same node is not matched twice)
--- @return number|nil - Runtime nodeId or nil
function IAMapInitJob.findRuntimeNodeForXmlEntry(xmlEntry, runtimeNodes, excludedNodeIds)
	if xmlEntry == nil or runtimeNodes == nil then return nil end
	excludedNodeIds = excludedNodeIds or {}
	-- Prefer I3D #name (nodeName) for matching; fallback to display name (referenceFilename or locked name)
	local nameToMatch = (xmlEntry.nodeName and xmlEntry.nodeName ~= "") and xmlEntry.nodeName or xmlEntry.name
	if nameToMatch == nil or nameToMatch == "" then return nil end
	local altNameToMatch = (xmlEntry.name and xmlEntry.name ~= "") and xmlEntry.name or nil
	local loc = xmlEntry.localTranslation
	local locRot = xmlEntry.localRotation
	-- Under locked TransformGroups the runtime scene index path often does not match the map I3D; match by name + local transform only.
	local xmlPath = xmlEntry.hierarchyPath
	if xmlEntry.underLockedGroup then
		xmlPath = nil
	end
	if loc == nil then return nil end
	-- Collect all name+translation+rotation matches; duplicate map assets (two gasStation01) share local transforms and often tie on hierarchy.
	local candidates = {}
	for _, r in ipairs(runtimeNodes) do
		if not excludedNodeIds[r.nodeId] then
			local nameOk = (r.name and (r.name == nameToMatch or (altNameToMatch and r.name == altNameToMatch)))
			if nameOk then
				local rt = r.localTranslation
				if rt and math.abs((rt.x or 0) - (loc.x or 0)) <= TRANSLATION_MATCH_EPS
					and math.abs((rt.y or 0) - (loc.y or 0)) <= TRANSLATION_MATCH_EPS
					and math.abs((rt.z or 0) - (loc.z or 0)) <= TRANSLATION_MATCH_EPS then
					local rotMatch = true
					if locRot and r.localRotationDeg then
						local rd = r.localRotationDeg
						if math.abs((rd.y or 0) - (locRot.y or 0)) > ROTATION_MATCH_EPS_DEG then
							rotMatch = false
						end
					end
					if rotMatch then
						local hierarchyOk = false
						if xmlPath and #xmlPath > 0 and r.hierarchyPath and #r.hierarchyPath >= #xmlPath then
							hierarchyOk = true
							for i = 1, #xmlPath do
								if r.hierarchyPath[i] ~= xmlPath[i] then hierarchyOk = false break end
							end
						end
						candidates[#candidates + 1] = { nodeId = r.nodeId, hierarchyOk = hierarchyOk }
					end
				end
			end
		end
	end
	if #candidates == 0 then
		return nil
	end
	local pool = candidates
	if xmlPath and #xmlPath > 0 then
		local tier1 = {}
		for _, c in ipairs(candidates) do
			if c.hierarchyOk then
				tier1[#tier1 + 1] = c
			end
		end
		if #tier1 > 0 then
			pool = tier1
		end
	end
	local pos = xmlEntry.position
	if pos ~= nil and pos.x ~= nil and pos.z ~= nil and getWorldTranslation ~= nil and entityExists ~= nil then
		local bestId, bestDistSq = nil, math.huge
		for _, c in ipairs(pool) do
			local nid = c.nodeId
			if nid ~= nil and entityExists(nid) then
				local wx, _, wz = getWorldTranslation(nid)
				if wx ~= nil and wz ~= nil then
					local dx, dz = wx - pos.x, wz - pos.z
					local dSq = dx * dx + dz * dz
					if dSq < bestDistSq then
						bestDistSq = dSq
						bestId = nid
					end
				end
			end
		end
		if bestId ~= nil then
			return bestId
		end
	end
	for _, c in ipairs(pool) do
		if c.hierarchyOk then
			return c.nodeId
		end
	end
	return pool[1].nodeId
end

--- Try to get a safe spawn position, preferring trade dealer / selling point
--- @return number x, number y, number z, number rotationY (radians)
function IAMapInitJob.getSafeSpawnPosition()
	local x, y, z = IAMapInitJob.DEFAULT_SPAWN_X, nil, IAMapInitJob.DEFAULT_SPAWN_Z
	local rotationY = IAMapInitJob.DEFAULT_ROTATION_Y

	if IANeighbours and IANeighbours.debug then
		print("--- IAMapInitJob.getSafeSpawnPosition() ENTRY")
	end

	-- 1) Try reset places (e.g. dealer spawn points)
	local resetPlaces = g_currentMission:getResetPlaces()
	if IANeighbours and IANeighbours.debug then
		print("--- IAMapInitJob.getSafeSpawnPosition() getResetPlaces: " .. tostring(resetPlaces == nil and "nil" or (#resetPlaces .. " places")))
	end
	if resetPlaces ~= nil then
		for i, place in ipairs(resetPlaces) do
			if place ~= nil and place.startX ~= nil and place.startZ ~= nil then
				x = place.startX
				z = place.startZ
				y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + IAMapInitJob.DEFAULT_SPAWN_OFFSET_Y
				rotationY = 0
				if IANeighbours and IANeighbours.debug then
					print("--- IAMapInitJob.getSafeSpawnPosition() USING reset place[" .. tostring(i) .. "] x=" .. tostring(x) .. " y=" .. tostring(y) .. " z=" .. tostring(z))
				end
				return x, y, z, rotationY
			end
		end
		if IANeighbours and IANeighbours.debug then
			print("--- IAMapInitJob.getSafeSpawnPosition() no valid reset place (all nil x/z)")
		end
	end

	-- Fallback: use default position with terrain height so return value is always valid
	if g_terrainNode and x and z then
		y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + IAMapInitJob.DEFAULT_SPAWN_OFFSET_Y
	end
	return x, y, z, rotationY
end

--- Compute world position and yaw rotation from a spline sample: offset position to the right of the spline and rotation from forward direction.
--- @param number x,y,z - Position on spline
--- @param number xNext,yNext,zNext - Next position along spline (for forward direction)
--- @param number rightOffsetM - Meters to offset position to the right (default 1.5)
--- @return number|nil px, number|nil py, number|nil pz - Offset position (nil if invalid)
--- @return number|nil rotationYaw - Yaw in radians (nil if invalid)
--- @return number dx, number dy, number dz - Forward direction normalized (for direction indicator)
function IAMapInitJob.positionAndRotationFromSplineSample(x, y, z, xNext, yNext, zNext, rightOffsetM)
	rightOffsetM = rightOffsetM or 1.5
	if x == nil or z == nil or xNext == nil or zNext == nil then
		return nil, nil, nil, nil, 0, 0, 0
	end
	local dx = xNext - x
	local dz = zNext - z
	local lenXZ = math.sqrt(dx * dx + dz * dz)
	if lenXZ < 0.001 then
		return nil, nil, nil, nil, 0, 0, 0
	end
	local rightScale = rightOffsetM / lenXZ
	local offsetX = -dz * rightScale
	local offsetZ = dx * rightScale
	local px = x + offsetX
	local py = y or 0
	local pz = z + offsetZ
	local rotationYaw = math.atan2(dx, dz)
	local dy = (yNext or y or 0) - (y or 0)
	local len3 = math.sqrt(dx * dx + dy * dy + dz * dz)
	if len3 > 0.001 then
		dx, dy, dz = dx / len3, dy / len3, dz / len3
	else
		dx, dy, dz = dx / lenXZ, 0, dz / lenXZ
	end
	return px, py, pz, rotationYaw, dx, dy, dz
end

--- Collect roadside places from traffic splines, sell_point from selling stations, and vehicle-shop spawn slots (type workshop) from storeSpawnPlaces; save once to map places XML.
--- Delegates to IAPlacesLoader:addPlacesFromTrafficSplines / addPlacesFromSellingStations / addPlacesFromStoreSpawnPlaces (skipSave, single save at end).
--- @param table ianeighbours - IANeighbours instance with placesLoader and xmlHelper
--- @return number - Number of auto places added (roadside + sell_point + workshop spawn from vehicle shop)
function IAMapInitJob.saveAutoPlaces(ianeighbours)
	if ianeighbours == nil or g_currentMission == nil or g_currentMission.missionInfo == nil or g_currentMission.missionInfo.mapId == nil then
		return 0
	end
	local mapId = g_currentMission.missionInfo.mapId
	if ianeighbours.xmlHelper == nil then
		return 0
	end
	if ianeighbours.places == nil then
		ianeighbours.places = {}
	end
	local added = 0
	local loader = ianeighbours.placesLoader
	if loader ~= nil and loader.addPlacesFromTrafficSplines ~= nil then
		added = added + loader:addPlacesFromTrafficSplines({ skipSave = true })
	end
	if loader ~= nil and loader.addPlacesFromSellingStations ~= nil then
		added = added + loader:addPlacesFromSellingStations({ skipSave = true })
	end
	if loader ~= nil and loader.addPlacesFromStoreSpawnPlaces ~= nil then
		added = added + loader:addPlacesFromStoreSpawnPlaces({ skipSave = true })
	end
	if added > 0 and ianeighbours.xmlHelper then
		if ianeighbours.debug then
			print("--- saveMapConfigToFile caller: IAMapInitJob.saveAutoPlaces mapId=" .. tostring(mapId) .. " added=" .. tostring(added))
		end
		ianeighbours.xmlHelper:saveMapConfigToFile(mapId)
		if ianeighbours.debug then
			print("--- IAMapInitJob.saveAutoPlaces() - Saved " .. tostring(added) .. " auto places (roadside + selling stations + vehicle shop workshop spawn) to fields_of_stories_" .. tostring(mapId) .. ".xml")
		end
	end
	return added
end

--- Start the initialization: spawn Kodiaq at safe position and put player in it
--- Only runs on server; client will see the spawned vehicle and player state
function IAMapInitJob:start()
	if IANeighbours and IANeighbours.debug then
		print("--- IAMapInitJob:start() ENTRY started=" .. tostring(self.started) .. " g_server=" .. tostring(g_server ~= nil))
	end

	if self.started then
		if IANeighbours and IANeighbours.debug then
			print("--- IAMapInitJob:start() already started, skip")
		end
		return
	end
	if g_server == nil then
		if IANeighbours and IANeighbours.debug then
			print("--- IAMapInitJob:start() SKIP (client)")
		end
		self.finished = true
		return
	end
	if g_currentMission == nil or g_currentMission.vehicleSystem == nil then
		if IANeighbours and IANeighbours.debug then
			print("--- IAMapInitJob:start() SKIP mission=" .. tostring(g_currentMission ~= nil) .. " vehicleSystem=" .. tostring(g_currentMission and g_currentMission.vehicleSystem ~= nil))
		end
		return
	end

	self.started = true
	local x, y, z, rotationY = IAMapInitJob.getSafeSpawnPosition()
	if IANeighbours and IANeighbours.debug then
		print("--- IAMapInitJob:start() spawn position x=" .. tostring(x) .. " y=" .. tostring(y) .. " z=" .. tostring(z) .. " rotationY=" .. tostring(rotationY))
	end

	-- Before spawning: check if a vehicle with this XML and price 96 already exists (from previous init)
	local existingVehicle = nil
	if g_currentMission.vehicleSystem.vehicles ~= nil then
		for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
			if vehicle ~= nil and not vehicle.isDeleted then
				local cfg = vehicle.configFileName
				local price = (vehicle.getPrice and vehicle:getPrice()) or vehicle.price
				if cfg == IAMapInitJob.KODIAQ_XML and price == IAMapInitJob.INIT_VEHICLE_PRICE then
					existingVehicle = vehicle
					break
				end
			end
		end
	end

	if existingVehicle ~= nil then
		if IANeighbours and IANeighbours.debug then
			print("--- IAMapInitJob:start() found existing init vehicle uniqueId=" .. tostring(existingVehicle.uniqueId) .. ", using it (no spawn)")
		end
		self.vehicle = existingVehicle
		-- Optionally move to safe position and put player in it
		if existingVehicle.rootNode ~= nil then
			setTranslation(existingVehicle.rootNode, x, y, z)
			setRotation(existingVehicle.rootNode, 0, rotationY, 0)
		end
		if g_localPlayer ~= nil and existingVehicle.requestToEnter ~= nil then
			existingVehicle:requestToEnter(g_localPlayer)
		elseif g_currentMission.requestToEnterVehicle ~= nil and g_localPlayer ~= nil and g_localPlayer.connection ~= nil then
			g_currentMission:requestToEnterVehicle(g_localPlayer.connection, existingVehicle)
		end
		self.finished = true
		return
	end

	local data = VehicleLoadingData.new()
	data:setFilename(IAMapInitJob.KODIAQ_XML)
	data:setPosition(x, y, z)
	data:setRotation(0, rotationY, 0)
	data:setOwnerFarmId(1) -- player farm
	if data.setPrice ~= nil then
		data:setPrice(IAMapInitJob.INIT_VEHICLE_PRICE)
	end
	if IANeighbours and IANeighbours.debug then
		print("--- IAMapInitJob:start() calling data:load() for " .. tostring(IAMapInitJob.KODIAQ_XML))
	end

	local jobSelf = self
	local asyncCallback = function(_, vehicle, loadingState)
		if IANeighbours and IANeighbours.debug then
			print("--- IAMapInitJob asyncCallback loadingState=" .. tostring(loadingState) .. " vehicle=" .. tostring(vehicle ~= nil) .. " vehicle[1]=" .. tostring(vehicle and vehicle[1] ~= nil))
		end
		if loadingState ~= VehicleLoadingState.OK or vehicle == nil or vehicle[1] == nil then
			if IANeighbours and IANeighbours.debug then
				print("--- IAMapInitJob: vehicle load FAILED loadingState=" .. tostring(loadingState))
			end
			jobSelf.finished = true
			return
		end

		local v = vehicle[1]
		jobSelf.vehicleSpawned = true
		v.price = IAMapInitJob.INIT_VEHICLE_PRICE
		if IANeighbours and IANeighbours.debug then
			print("--- IAMapInitJob: vehicle loaded uniqueId=" .. tostring(v.uniqueId) .. " price=" .. tostring(IAMapInitJob.INIT_VEHICLE_PRICE))
		end

		-- Ensure position/rotation (in case load used different origin)
		if v.rootNode ~= nil then
			setTranslation(v.rootNode, x, y, z)
			setRotation(v.rootNode, 0, rotationY, 0)
		end
		if g_localPlayer ~= nil and v.requestToEnter ~= nil then
			v:requestToEnter(g_localPlayer)
		elseif g_currentMission.requestToEnterVehicle ~= nil and g_localPlayer ~= nil and g_localPlayer.connection ~= nil then
			g_currentMission:requestToEnterVehicle(g_localPlayer.connection, v)
		end
		jobSelf.vehicle = v
		jobSelf.finished = true
	end

	data:load(asyncCallback)
end

--- Returns true if the job has finished (success or failure)
function IAMapInitJob:isFinished()
	return self.finished
end
