--- Basic IA job.
--- Every IA job should be derived from this job.
---@class IAAIJob : AIJob
---@field namedParameters table
---@field jobTypeIndex number
---@field isDirectStart boolean
---@field getTaskByIndex function
---@field addNamedParameter function
---@field addTask function
---@field currentTaskIndex number
---@field superClass function
---@field getIsLooping function
---@field resetTasks function
---@field skipCurrentTask function
---@field tasks table
---@field groupedParameters table
---@field isServer boolean
---@field helperIndex number

IAAIJob = {}
IAAIJob._mt = Class(IAAIJob)
function IAAIJob:init(isServer)
	self.isDirectStart = false
	self:setupJobParameters()
	self:setupTasks(isServer)
    self.groupedParameters = {}
end 

---@param task IAAITask
function IAAIJob:removeTask(task)
	if task.taskIndex then
		table.remove(self.tasks, task.taskIndex)
		for i = #self.tasks, task.taskIndex, -1 do 
			self.tasks[i].taskIndex = self.tasks[i].taskIndex - 1
		end
	end
	task.taskIndex = nil
end

--- Setup all tasks.
function IAAIJob:setupTasks(isServer)
	self.driveToTask = AITaskDriveTo.new(isServer, self)
	self:addTask(self.driveToTask)
end

--- Setup all job parameters.
--- For now every job has these parameters in common.
function IAAIJob:setupJobParameters()
	self.vehicleParameter = AIParameterVehicle.new()
    --self.vehicle = self.vehicleParameter
	local vehicleGroup = AIParameterGroup.new(g_i18n:getText("ai_parameterGroupTitleVehicle"))
	vehicleGroup:addParameter(self.vehicleParameter)
	table.insert(self.groupedParameters, vehicleGroup)
end

--- Optional to create custom IA job parameters.
function IAAIJob:setupIAJobParameters(jobParameters)
	self.iaJobParameters = jobParameters
	self.iaJobParameters:validateSettings()
end

--- Is the ai job allowed to finish ?
--- This entry point allowes us to catch giants stop conditions.
---@param message table Stop reason can be used to reverse engineer the cause.
---@return boolean
function IAAIJob:isFinishingAllowed(message)
	return true
end

--- Gets the first task to start with.
function IAAIJob:getStartTaskIndex()
	if self.currentTaskIndex ~= 0 or self.isDirectStart or self:isTargetReached() then
		-- skip Giants driveTo
		-- TODO: this isn't very nice as we rely here on the derived classes to add more tasks
		return 2
	end
	if self.driveToTask.x == nil then 
		if IANeighbours ~= nil and IANeighbours.debug then
			print("--- IAAIJob:getStartTaskIndex() - Drive to task was skipped, as no valid start position is set!")
		end
		return 2
	end
	return 1
end

function IAAIJob:getNextTaskIndex()
	if self:getIsLooping() and self.currentTaskIndex >= #self.tasks then 
		--- Makes sure the giants task is skipped
		return self:getStartTaskIndex()
	end
	return AIJob.getNextTaskIndex(self)
end

--- Should the giants path finder job be skipped?
function IAAIJob:isTargetReached()
	if not self.iaJobParameters or not self.iaJobParameters.startPosition then 
		return true
	end
	local vehicle = self.vehicleParameter:getVehicle()
	local x, _, z = getWorldTranslation(vehicle.rootNode)
	local tx, tz = self.iaJobParameters.startPosition:getPosition()
	if tx == nil or tz == nil then 
		return true
	end
	local targetReached = MathUtil.vector2Length(x - tx, z - tz) < 3

	return targetReached
end

function IAAIJob:onPreStart()
	--- override
end

function IAAIJob:start(farmId)
	self:onPreStart()
	--- If we use more than the base game helper limit, 
	--- than we have to reuse already used helper indices.
	if #g_helperManager.availableHelpers > 0 then 
		self.helperIndex = g_helperManager:getRandomHelper().index
	else 
		self.helperIndex = g_helperManager:getRandomIndex()
	end
	self.startedFarmId = farmId
	self.isRunning = true
	if self.isServer then
		self.currentTaskIndex = 0
		local vehicle = self.vehicleParameter:getVehicle()

		vehicle:createAgent(self.helperIndex)
		vehicle:aiJobStarted(self, self.helperIndex, farmId)
	end
end

function IAAIJob:stop(aiMessage)
	if not self.isServer then 
		AIJob.stop(self, aiMessage)
		return
	end
	local vehicle = self.vehicleParameter:getVehicle()
	vehicle:deleteAgent()
	vehicle:aiJobFinished()
	vehicle:resetIAAllActiveInfoTexts()
	local driveStrategy = vehicle:getIADriveStrategy()
	if not aiMessage then 
		print("--- IAAIJob:stop() - No valid ai message given!")
		if driveStrategy then
			driveStrategy:onFinished()
		end
		AIJob.stop(self, aiMessage)
		return
	end
	local releaseMessage, hasFinished, event, isOnlyShownOnPlayerStart = 
		g_infoTextManager:getInfoTextDataByAIMessage(aiMessage)
	if releaseMessage then 
		if IANeighbours ~= nil and IANeighbours.debug then
			print("--- IAAIJob:stop() - Stopped with release message %s", tostring(releaseMessage))
		end
	end
	if releaseMessage and not vehicle:getIsControlled() and not isOnlyShownOnPlayerStart then
		--- Only shows the info text, if the vehicle is not entered.
		--- TODO: Add check if passing to ad is active maybe?
		vehicle:setIAInfoTextActive(releaseMessage)
	end
	AIJob.stop(self, aiMessage)
	if event then
		SpecializationUtil.raiseEvent(vehicle, event)
	end
	if driveStrategy then
		driveStrategy:onFinished(hasFinished)
	end
	g_messageCenter:unsubscribeAll(self)
end

--- Updates the parameter values.
function IAAIJob:applyCurrentState(vehicle, mission, farmId, isDirectStart)
	-- the only thing this does, is setting self.isDirectStart
	AIJob.applyCurrentState(self, vehicle, mission, farmId, isDirectStart)
	self.vehicleParameter:setVehicle(vehicle)
	if not self.iaJobParameters or not self.iaJobParameters.startPosition then 
		return
	end
	if not vehicle then 
		print("--- IAAIJob:applyCurrentState() - Vehicle is null!")
		return
	end
	local x, z, _ = self.iaJobParameters.startPosition:getPosition()
	local angle = self.iaJobParameters.startPosition:getAngle()

	local snappingAngle = vehicle:getDirectionSnapAngle()
	local terrainAngle = math.pi / math.max(g_currentMission.fieldGroundSystem:getGroundAngleMaxValue() + 1, 4)
	snappingAngle = math.max(snappingAngle, terrainAngle)

	self.iaJobParameters.startPosition:setSnappingAngle(snappingAngle)

	if x == nil or z == nil then
		x, _, z = getWorldTranslation(vehicle.rootNode)
	end

	if angle == nil then
		local dirX, _, dirZ = localDirectionToWorld(vehicle.rootNode, 0, 0, 1)
		angle = MathUtil.getYRotationFromDirection(dirX, dirZ)
	end
	
	self.iaJobParameters.startPosition:setPosition(x, z)
	self.iaJobParameters.startPosition:setAngle(angle)

end

--- Can the vehicle be used for this job?
function IAAIJob:getIsAvailableForVehicle(vehicle, iaJobsAllowed)
	return iaJobsAllowed
end

function IAAIJob:getTitle()
	local vehicle = self.vehicleParameter:getVehicle()

	if vehicle ~= nil then
		return vehicle:getName()
	end

	return ""
end

--- Applies the parameter values to the tasks.
function IAAIJob:setValues()
	self:resetTasks()

	local vehicle = self.vehicleParameter:getVehicle()

	self.driveToTask:setVehicle(vehicle)

	local angle = self.iaJobParameters.startPosition:getAngle()
	local x, z = self.iaJobParameters.startPosition:getPosition()
	if angle ~= nil and x ~= nil then
		local dirX, dirZ = MathUtil.getDirectionFromYRotation(angle)
		self.driveToTask:setTargetDirection(0, 0)
		self.driveToTask:setTargetPosition(50,50)
	end
end

--- Is the job valid?
---@param farmId number not used
function IAAIJob:validate(farmId)
	--- TODO_25
	-- self:setParamterValid(true)

	local isValid, errorMessage = self.vehicleParameter:validate()

	if not isValid then
		self.vehicleParameter:setIsValid(false)
	end

	return isValid, errorMessage
end

--- Start an asynchronous field boundary detection. Results are delivered by the callback
--- onFieldBoundaryDetectionFinished(vehicle, fieldPolygon, islandPolygons)
--- If the field position hasn't changed since the last call, the detection is skipped and this returns true.
--- In that case, the polygon from the previous run is still available from vehicle:iaGetFieldPolygon()
---@return boolean, boolean, string true if we already have a field boundary false otherwise,
--- second boolean true if the detection is still running false on error
--- error message
function IAAIJob:detectFieldBoundary()
	local vehicle = self.vehicleParameter:getVehicle()

	local tx, tz = self.iaJobParameters.fieldPosition:getPosition()
	if tx == nil or tz == nil then
		return false, false, g_i18n:getText("IA_error_not_on_field")
	end
	if vehicle:iaIsFieldBoundaryDetectionRunning() then
		return false, false, g_i18n:getText("IA_error_field_detection_still_running")
	end
	local x, z = vehicle:iaGetFieldPosition()
	if x == tx and z == tz then
		if IANeighbours ~= nil and IANeighbours.debug then
			print("--- IAAIJob:detectFieldBoundary() - Field position still at %.1f/%.1f, do not detect field boundary again", tx, tz)
		end
		return true, false, ''
	end
	if IANeighbours ~= nil and IANeighbours.debug then
		print("--- IAAIJob:detectFieldBoundary() - Field position changed to %.1f/%.1f, start field boundary detection", tx, tz)
	end
	self.foundVines = nil

	vehicle:iaDetectFieldBoundary(tx, tz, self, self.onFieldBoundaryDetectionFinished)
	-- TODO: return false and nothing, as the detection is still running?
	return false, true, g_i18n:getText('IA_error_field_detection_still_running')
end

function IAAIJob:onFieldBoundaryDetectionFinished(vehicle, fieldPolygon, islandPolygons)
	-- override in the derived classes to handle the detected field boundary
end

--- If registered, call the field boundary detection finished callback. This is to notify the frame
--- at the end of the async field detection.
--- It'll also return the result as a synchronous validate call would, and as the frame expects it, in case
--- someone calls the registered callback directly from validate()
---@return boolean isValid, string errorText
function IAAIJob:callFieldBoundaryDetectionFinishedCallback(isValid, errorTextName)
	local c = self.onFieldBoundaryDetectionFinishedCallback
	local errorText = errorTextName and g_i18n:getText(errorTextName) or ''
	if c and c.object and c.func then
		c.func(c.object, isValid, errorText)
	end
	return isValid, errorText
end

--- Register a callback for the field boundary detection finished event.
--- @param object table object to call the function on
--- @param func function function to call func(boolean isValid, string|nil errorTextName), errorTextName is the
--- name of the text in MasterTranslations.xml
function IAAIJob:registerFieldBoundaryDetectionCallback(object, func)
	self.onFieldBoundaryDetectionFinishedCallback = {object = object, func = func}
end

function IAAIJob:getIsStartable(connection)

	local vehicle = self.vehicleParameter:getVehicle()

	if vehicle == nil then
		return false, AIJobFieldWork.START_ERROR_VEHICLE_DELETED
	end

	if not g_currentMission:getHasPlayerPermission("hireAssistant", connection, vehicle:getOwnerFarmId()) then
		return false, AIJobFieldWork.START_ERROR_NO_PERMISSION
	end

	if vehicle:getIsInUse(connection) then
		return false, AIJobFieldWork.START_ERROR_VEHICLE_IN_USE
	end

	return true, AIJob.START_SUCCESS
end

function IAAIJob.getIsStartErrorText(state)
	if state == AIJobFieldWork.START_ERROR_LIMIT_REACHED then
		return g_i18n:getText("ai_startStateLimitReached")
	elseif state == AIJobFieldWork.START_ERROR_VEHICLE_DELETED then
		return g_i18n:getText("ai_startStateVehicleDeleted")
	elseif state == AIJobFieldWork.START_ERROR_NO_PERMISSION then
		return g_i18n:getText("ai_startStateNoPermission")
	elseif state == AIJobFieldWork.START_ERROR_VEHICLE_IN_USE then
		return g_i18n:getText("ai_startStateVehicleInUse")
	end

	return g_i18n:getText("ai_startStateSuccess")
end

function IAAIJob:draw(map, isOverviewMap)
	
end


function IAAIJob:writeStream(streamId, connection)
	streamWriteBool(streamId, self.isDirectStart)

	if streamWriteBool(streamId, self.jobId ~= nil) then
		streamWriteInt32(streamId, self.jobId)
	end

	for _, namedParameter in ipairs(self.namedParameters) do
		namedParameter.parameter:writeStream(streamId, connection)
	end

	streamWriteUInt8(streamId, self.currentTaskIndex)

	if self.iaJobParameters then
		self.iaJobParameters:writeStream(streamId, connection)
	end
end

function IAAIJob:readStream(streamId, connection)
	self.isDirectStart = streamReadBool(streamId)

	if streamReadBool(streamId) then
		self.jobId = streamReadInt32(streamId)
	end

	for _, namedParameter in ipairs(self.namedParameters) do
		namedParameter.parameter:readStream(streamId, connection)
	end

	self.currentTaskIndex = streamReadUInt8(streamId)
	if self.iaJobParameters then
		self.iaJobParameters:validateSettings(true)
		self.iaJobParameters:readStream(streamId, connection)
	end
	if not self:getIsHudJob() then
		self:setValues()
	end
end

function IAAIJob:saveToXMLFile(xmlFile, key, usedModNames)
	AIJob.saveToXMLFile(self, xmlFile, key, usedModNames)
	if self.iaJobParameters then
		self.iaJobParameters:saveToXMLFile(xmlFile, key)
	end
	return true
end

function IAAIJob:loadFromXMLFile(xmlFile, key)
	AIJob.loadFromXMLFile(self, xmlFile, key)
	if self.iaJobParameters then
		self.iaJobParameters:validateSettings()
		self.iaJobParameters:loadFromXMLFile(xmlFile, key)
	end
end

function IAAIJob:getIAJobParameters()
	return self.iaJobParameters
end

--- Can the job be started?
function IAAIJob:getCanStartJob()
	return true
end

function IAAIJob:copyFrom(job)
	self.iaJobParameters:copyFrom(job.iaJobParameters)
end

function IAAIJob:getVehicle()
	return self.vehicleParameter:getVehicle() or self.vehicle
end

--- Makes sure that the keybinding/hud job has the vehicle.
function IAAIJob:setVehicle(v, isHudJob)
	self.vehicle = v
	self.isHudJob = isHudJob
	if self.iaJobParameters then 
		self.iaJobParameters:validateSettings()
	end
end

function IAAIJob:getIsHudJob()
	return self.isHudJob
end


function IAAIJob:getCanGenerateFieldWorkCourse()
	return false
end



--- Ugly hack to fix a mp problem from giants, where the job class can not be found.
function IAAIJob.getJobTypeIndex(aiJobTypeManager, superFunc, job)
	local ret = superFunc(aiJobTypeManager, job)
	if ret == nil then 
		if job.name then 
			return aiJobTypeManager.nameToIndex[job.name]
		end
	end
	return ret
end
AIJobTypeManager.getJobTypeIndex = Utils.overwrittenFunction(AIJobTypeManager.getJobTypeIndex ,IAAIJob.getJobTypeIndex)

--- Registers additional jobs.
function IAAIJob.registerJob(aiJobTypeManager)
	local function register(class)
		aiJobTypeManager:registerJobType(class.name, g_i18n:getText(class.jobName), class)
	end
	--register(IAAIJobBaleFinder)
	--register(IAAIJobFieldWork)
	--register(IAAIJobCombineUnloader)
	--register(IAAIJobSiloLoader)
	--register(IAAIJobBunkerSilo)
end

