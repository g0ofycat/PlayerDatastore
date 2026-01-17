--!strict

local PlayerDatastore = {}

PlayerDatastore.PlayerData = {} :: { [number]: { [any]: any } }
PlayerDatastore.ShardData = {} :: { [string]: { [any]: any } }
PlayerDatastore.GlobalData = {} :: { [string]: any }

PlayerDatastore.GlobalLocks = {} :: { [string]: boolean }

--=========================
-- // SERVICES
--=========================

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

--=========================
-- // MODULES
--=========================

local Types = require("./Types")
local Config = require("./Config")

--=========================
-- // SIGNAL
--=========================

local Signal = require("./Utility/Signal")

PlayerDatastore.Signal = Signal.new() :: Signal.Signal
PlayerDatastore.Presets = nil :: Types.PresetOptions?

--=========================
-- // DATASTORE
--=========================

local PlayerDataStore = DataStoreService:GetDataStore(Config.DATASTORE.DATASTORE_NAME)
local ShardedDataStore = DataStoreService:GetDataStore(Config.DATASTORE.SHARDED_DATASTORE_NAME)
local GlobalDataStore = DataStoreService:GetDataStore(Config.DATASTORE.GLOBAL_DATASTORE_NAME)

--=========================
-- // PRIVATE API
--=========================

-- deepClone(): Deep clones a table
-- @param tbl: The table to clone
-- @return { [any]: any }
local function deepClone(tbl: { any }): any
	if type(tbl) ~= "table" then
		return tbl
	end

	local result = {}

	for k, v in tbl do
		result[k] = deepClone(v)
	end

	return result
end

-- estimateBytes(): Estimates the number of bytes a value will take in memory
-- @param value: The value to estimate
-- @return number
local function estimateBytes(value: any): number
	local t = typeof(value)

	if t == "string" then
		return #value
	elseif t == "number" then
		return 8
	elseif t == "boolean" then
		return 1
	elseif t == "table" then
		local bytes = 0
		for k, v in value do
			bytes += estimateBytes(k)
			bytes += estimateBytes(v)
		end
		return bytes
	else
		return 0
	end
end

-- isSharded(): Checks to see if a table is sharded
-- @param tbl: { [any]: any }
-- @return boolean
local function isSharded(tbl: { [any]: any }): boolean
	return type(tbl) == "table" and tbl.__sharded
end

-- reconcileData(): Reconciles the loaded data with the schema
-- @param loaded: { [any]: any }
-- @param schema: { [any]: any }
-- @return { [any]: any }
local function reconcileData(loaded: { [any]: any }, schema: { [any]: any }): { [any]: any }
	local result = table.clone(schema)

	for key, loadedValue in loaded do
		local schemaValue = schema[key]

		if typeof(loadedValue) == "table" and loadedValue.__sharded then
			result[key] = deepClone(loadedValue)
		elseif typeof(loadedValue) == "table" and typeof(schemaValue) == "table" then
			result[key] = reconcileData(loadedValue, schemaValue)
		else
			result[key] = loadedValue
		end
	end

	return result
end

-- resolvePath(): Resolves a path in a table
-- @param tbl: The table to resolve the path in
-- @param path: The path to resolve
-- @return any
local function resolvePath(tbl: any, path: string): any
	if not string.find(path, "%.") then
		return tbl[path]
	end

	local current = tbl

	for key in string.gmatch(path, "%[(['\"])([^'\"]+)%1%]|([^%.%[]+)") do
		local actualKey = key:match("%[(['\"])([^'\"]+)%1%]")

		if not actualKey then
			actualKey = key
		end

		if type(current) ~= "table" then
			return nil
		end

		current = current[actualKey]
	end

	return current
end

-- setPath(): Sets a value at a path in a table
-- @param tbl: The table to set the value in
-- @param path: The path to set
-- @param value: The value to set
local function setPath(tbl: any, path: string, value: any): ()
	if not string.find(path, "%.") then
		tbl[path] = value
		return
	end

	local keys = {}

	for match in string.gmatch(path, "%[(['\"])([^'\"]+)%1%]|([^%.%[]+)") do
		local key = match:match("%[(['\"])([^'\"]+)%1%]") or match

		if key and key ~= "" then
			table.insert(keys, key)
		end
	end

	local current = tbl

	for i = 1, #keys - 1 do
		if type(current[keys[i]]) ~= "table" then
			return
		end

		current = current[keys[i]]
	end

	current[keys[#keys]] = value
end

-- findShardedPath(): Finds the sharded path for a value
-- @param data: { [any]: any }
-- @param valueName: string
-- @return string?
local function findShardedPath(data: { [any]: any }, valueName: string): string?
	local pathParts = string.split(valueName, ".")

	for i = 1, #pathParts do
		local testPath = table.concat(pathParts, ".", 1, i)
		local testTable = resolvePath(data, testPath)

		if not isSharded(testTable) then continue end

		return testPath
	end

	return nil
end

-- loadData(): Loads the players data
-- @param player: The player to load the data for
-- @return Data?
local function loadData<Data>(player: Player): Data?
	local data

	local success, err = pcall(function()
		data = PlayerDataStore:GetAsync(player.UserId)
	end)

	if not success then
		warn("loadData(): Failed to load data for", player.Name, err)
		return
	end

	if data then
		return HttpService:JSONDecode(data)
	end

	return nil
end

-- saveData(): Saves the players data
-- @param player: The player to save the data for
-- @note Shards unsharded data marked as __sharded; ApplyOperator unshards to apply operations. While doing this, the player could leave, having corrupted sharded data that may exceed the 4MB Key Limit. This fixes it
local function saveData(player: Player): ()
	local data = PlayerDatastore.PlayerData[player.UserId]
	if not data then return end

	local shardedFields: { string } = PlayerDatastore.Presets and PlayerDatastore.Presets.ShardedFields or {}

	for _, table_path in shardedFields do
		local tbl = resolvePath(data, table_path)

		if type(tbl) == "table" and not tbl.__sharded then
			PlayerDatastore.Shard(player, table_path, true)
		end
	end

	pcall(function()
		PlayerDataStore:SetAsync(player.UserId, HttpService:JSONEncode(data))
	end)
end

-- loadGlobalData(): Loads a global value from the GlobalDataStore
-- @param path: The global key to load
-- @return any: The decoded value or nil if not found
local function loadGlobalData(path: string): any
	local data

	local success, err = pcall(function()
		data = GlobalDataStore:GetAsync(path)
	end)

	if not success then
		warn("loadGlobalData(): Failed to load global key", path, err)
		return nil
	end

	if data then
		return HttpService:JSONDecode(data)
	end

	return nil
end

-- saveGlobalData(): Saves a global value to the GlobalDataStore
-- @param path: The global key to save
-- @note Automatically JSON encodes the value; reshards if needed
local function saveGlobalData(path: string): ()
	local tbl = PlayerDatastore.GlobalData[path]

	if type(tbl) == "table" then
		PlayerDatastore.ShardGlobal(path, true)
	end

	pcall(function()
		GlobalDataStore:SetAsync(path, HttpService:JSONEncode(PlayerDatastore.GlobalData[path]))
	end)
end

--=========================
-- // COMPLEX PRIVATE API
--=========================

-- getShardKey(): Returns the shard key for a given path and index
-- @param userId: number
-- @param path: string
-- @param index: number
-- @return string
local function getShardKey(userId: number, path: string, index: number): string
	return `{userId}:{path}:shard:{index}`
end

-- getShardGlobalKey(): Returns the global shard key for a given path and index
-- @param path: string
-- @param index: number
-- @return string
local function getShardGlobalKey(path: string, index: number): string
	return `global:{path}:shard:{index}`
end

-- encodeSize(): Get JSON Encoded Size of a table
-- @param tbl: any
-- @return number
local function encodeSize(tbl: any): number
	return #HttpService:JSONEncode(tbl)
end

-- stripGlobalFields(): Removes from PlayerData if their name is in GlobalFields
-- @param data_table: { [any]: any }
-- @param globalFields: { string }
-- @return { [any]: any }
local function stripGlobalFields(data_table: { [any]: any }, globalFields: { string }): { [any]: any }
	local clone = deepClone(data_table)

	for _, key in globalFields do
		clone[key] = nil
	end

	return clone
end

--=========================
-- // PUBLIC API
--=========================

-- Init(): Initialize the datastore handler
-- @param data_table: { [any]: any }
-- @param presets: Types.PresetOptions
function PlayerDatastore.Init(data_table: { [any]: any }, presets: Types.PresetOptions): ()
	PlayerDatastore.Presets = presets

	local shardedFields: { string } = presets.ShardedFields or {}
	local globalFields: { string } = presets.GlobalFields or {}

	Players.PlayerAdded:Connect(function(player)
		local data = loadData(player)
		local filteredData = stripGlobalFields(data_table, globalFields)

		local templateData = stripGlobalFields(data_table, globalFields)

		if data then
			PlayerDatastore.PlayerData[player.UserId] = reconcileData(data, templateData)
		else
			PlayerDatastore.PlayerData[player.UserId] = table.clone(templateData)
		end

		for _, table_path in shardedFields do
			if table.find(globalFields, table_path) then
				continue
			end

			local tbl = resolvePath(PlayerDatastore.PlayerData[player.UserId], table_path)

			if type(tbl) ~= "table" then
				continue
			end

			if not tbl.__sharded then
				setPath(PlayerDatastore.PlayerData[player.UserId], table_path, {
					__sharded = true,
					count = 0
				})
				continue
			end

			for i = 1, tbl.count do
				local shardKey = getShardKey(player.UserId, table_path, i)

				pcall(function()
					local shardData = ShardedDataStore:GetAsync(shardKey)
					if shardData then
						PlayerDatastore.ShardData[shardKey] = HttpService:JSONDecode(shardData)
					end
				end)
			end
		end

		PlayerDatastore.Signal:Fire(player)
		Config.FLAGS.PlayerDataLoaded:FireDeferred()
	end)

	for _, table_path in globalFields do
		local globalData = loadGlobalData(table_path)

		if not globalData then
			PlayerDatastore.GlobalData[table_path] = {}
			continue
		end

		PlayerDatastore.GlobalData[table_path] = globalData

		if not isSharded(globalData) then
			continue
		end

		for i = 1, globalData.count do
			local shardKey = getShardGlobalKey(table_path, i)

			pcall(function()
				local shardData = ShardedDataStore:GetAsync(shardKey)
				if shardData then
					PlayerDatastore.ShardData[shardKey] = HttpService:JSONDecode(shardData)
				end
			end)
		end
	end

	Config.FLAGS.GlobalDataLoaded:FireDeferred()

	Players.PlayerRemoving:Connect(function(player)
		for _, table_path in shardedFields do
			if table.find(globalFields, table_path) then continue end

			local data = PlayerDatastore.PlayerData[player.UserId]
			if not data then continue end

			local tbl = resolvePath(data, table_path)
			if not isSharded(tbl) then
				continue
			end

			for i = 1, tbl.count or 0 do
				local shardKey = getShardKey(player.UserId, table_path, i)

				local shardData = PlayerDatastore.ShardData[shardKey]
				if shardData then
					pcall(function()
						ShardedDataStore:SetAsync(shardKey, HttpService:JSONEncode(shardData))
					end)
				end
			end
		end

		saveData(player)
		PlayerDatastore.PlayerData[player.UserId] = nil
	end)

	game:BindToClose(function()
		local shardedFields: { string } = PlayerDatastore.Presets and PlayerDatastore.Presets.ShardedFields or {}
		local globalFields: { string } = PlayerDatastore.Presets and PlayerDatastore.Presets.GlobalFields or {}

		for _, player in Players:GetPlayers() do
			local userId = player.UserId

			for _, table_path in shardedFields do
				if table.find(globalFields, table_path) then continue end

				local tbl = resolvePath(PlayerDatastore.PlayerData[userId], table_path)
				if not isSharded(tbl) then
					continue
				end

				for i = 1, tbl.count do
					local shardKey = getShardKey(userId, table_path, i)

					local shardData = PlayerDatastore.ShardData[shardKey]
					if shardData then
						pcall(function()
							ShardedDataStore:SetAsync(shardKey, HttpService:JSONEncode(shardData))
						end)
					end
				end
			end

			saveData(player)
		end

		for _, table_path in globalFields do
			local tbl = resolvePath(PlayerDatastore.GlobalData, table_path)

			if not isSharded(tbl) then
				saveGlobalData(table_path)
				continue
			end

			for i = 1, tbl.count do
				local shardKey = getShardGlobalKey(table_path, i)

				local shardData = PlayerDatastore.ShardData[shardKey]
				if shardData then
					pcall(function()
						ShardedDataStore:SetAsync(shardKey, HttpService:JSONEncode(shardData))
					end)
				end
			end

			saveGlobalData(table_path)
		end
	end)
end

-- Read(): Reads the player's data, unshards if sharded
-- @param player: The player to read the data for
-- @param table_path: The path to the table to read
-- @return { [any]: any }
function PlayerDatastore.Read(player: Player, table_path: string): { [any]: any }?
	Config.FLAGS.PlayerDataLoaded:DeferredWait()

	local data = PlayerDatastore.PlayerData[player.UserId]
	if not data then
		warn("Read(): Couldn't find data for player:", player.Name)
		return
	end

	local shardedPath = findShardedPath(data, table_path)

	if shardedPath then
		local shardedTable = resolvePath(data, shardedPath)
		local combined = {}

		for i = 1, shardedTable.count do
			local shardKey = getShardKey(player.UserId, shardedPath, i)
			local shardData = PlayerDatastore.ShardData[shardKey]

			if not shardData then continue end

			for k, v in shardData do
				combined[k] = v
			end
		end

		if shardedPath == table_path then
			return combined
		else
			local remainingPath = string.sub(table_path, #shardedPath + 2)
			return resolvePath(combined, remainingPath)
		end
	end

	local tbl = resolvePath(data, table_path)
	if type(tbl) ~= "table" then return end

	return tbl
end

-- ApplyOperator(): Applies an operation to a player's data
-- @param player: The player who is doing the operation
-- @param operation: Types.OperationType (value_name, operator, value)
function PlayerDatastore.ApplyOperator(player: Player, operation: Types.OperationType): ()
	Config.FLAGS.PlayerDataLoaded:DeferredWait()

	local data = PlayerDatastore.PlayerData[player.UserId]

	if not data then
		warn("ApplyOperator(): Couldn't find data for player:", player.Name)
		return
	end

	local shardedPath = findShardedPath(data, operation.value_name)

	if shardedPath then
		local shardedTable = resolvePath(data, shardedPath)
		local combined = {}

		for i = 1, shardedTable.count do
			local shardKey = getShardKey(player.UserId, shardedPath, i)
			local shardData = PlayerDatastore.ShardData[shardKey]

			if shardData then
				for k, v in shardData do
					combined[k] = v
				end
			end

			PlayerDatastore.ShardData[shardKey] = nil
		end

		setPath(data, shardedPath, combined)
	end

	local success, err = pcall(function()
		local currentValue = resolvePath(data, operation.value_name)

		if currentValue == nil then
			error(`ApplyOperator(): Couldn't find value: {operation.value_name}`)
		end

		local newValue = Config.OPERATION_CASES[operation.operator](currentValue, operation.value)

		setPath(data, operation.value_name, newValue)
	end)

	if not success then
		warn("ApplyOperator():", err)
		return
	end

	if shardedPath then
		PlayerDatastore.Shard(player, shardedPath, true)
	end

	PlayerDatastore.Signal:Fire(player)
end

-- DeletePlayerData(): Deletes a player's data
-- @param player: The player to delete data for
function PlayerDatastore.DeletePlayerData(player: Player): ()
	Config.FLAGS.PlayerDataLoaded:DeferredWait()

	local userId = player.UserId

	local shardedFields: { string } = PlayerDatastore.Presets and PlayerDatastore.Presets.ShardedFields or {}
	local globalFields: { string } = PlayerDatastore.Presets and PlayerDatastore.Presets.GlobalFields or {}

	for _, table_path in shardedFields do
		if table.find(globalFields, table_path) then 
			continue 
		end

		local data = PlayerDatastore.PlayerData[userId]

		if data then
			local tbl = resolvePath(data, table_path)
			if not isSharded(tbl) then continue end

			for i = 1, tbl.count do
				local shardKey = getShardKey(userId, table_path, i)

				pcall(function()
					ShardedDataStore:RemoveAsync(shardKey)
				end)

				PlayerDatastore.ShardData[shardKey] = nil
			end
		end
	end

	pcall(function()
		PlayerDataStore:RemoveAsync(userId)
	end)

	PlayerDatastore.PlayerData[userId] = nil
end

-- DeleteGlobalData(): Deletes a global data key and its shards
-- @param path: The global key to delete
-- @note: This almost should NEVER be used, proceed with caution
function PlayerDatastore.DeleteGlobalData(path: string): ()
	Config.FLAGS.GlobalDataLoaded:DeferredWait()

	local globalFields: { string } = PlayerDatastore.Presets and PlayerDatastore.Presets.GlobalFields or {}

	if not table.find(globalFields, path) then
		warn("DeleteGlobalData(): Path is not a valid global field:", path)
		return
	end

	local tbl = PlayerDatastore.GlobalData[path]

	if isSharded(tbl) then
		for i = 1, tbl.count do
			local shardKey = getShardGlobalKey(path, i)

			pcall(function()
				ShardedDataStore:RemoveAsync(shardKey)
			end)

			PlayerDatastore.ShardData[shardKey] = nil
		end
	end

	pcall(function()
		GlobalDataStore:RemoveAsync(path)
	end)

	PlayerDatastore.GlobalData[path] = nil
end

--=========================
-- // COMPLEX OPERATIONS
--=========================

-- Shard(): Enables sharding for a table path (Check Config.DATASTORE.SHARD_BYTE_LIMIT); Do not touch this if you don't know what you're doing. Yes Zeke, I am talking specifically about you                  :sob:
-- @param player: The player to shard
-- @param table_path: Path to the table
-- @param enable: Whether to enable it or not
-- @note: Disabling while having a sharded table will result in all of the tables combining, likely leading to errors
-- @note: The first entry will always be put, no matter how large it is, subsequent data will be sharded
function PlayerDatastore.Shard(player: Player, table_path: string, enable: boolean): ()
	local data = PlayerDatastore.PlayerData[player.UserId]

	if not data then
		warn("Shard(): Couldn't find data for player:", player.Name)
		return
	end

	local tbl = resolvePath(data, table_path)

	if type(tbl) ~= "table" then
		warn("Shard(): Invalid table path")
		return 
	end

	if enable then
		if tbl.__sharded then
			for i = 1, (tbl.count or 0) do
				local shardKey = getShardKey(player.UserId, table_path, i)
				PlayerDatastore.ShardData[shardKey] = nil
			end
		end

		local limit = Config.DATASTORE.SHARD_BYTE_LIMIT
		local shards = {}
		local current = {}
		local shardIndex = 1

		local currentBytes = 0

		for k, v in tbl do
			if k == "__sharded" or k == "count" then continue end

			local entryBytes = estimateBytes(k) + estimateBytes(v)

			if currentBytes + entryBytes > limit then
				if next(current) then
					shards[shardIndex] = current
					shardIndex += 1
				end

				current = {}
				currentBytes = 0
			end

			current[k] = v
			currentBytes += entryBytes
		end

		if next(current) then
			shards[shardIndex] = current
		end

		for index, shard in shards do
			local shardKey = getShardKey(player.UserId, table_path, index)
			PlayerDatastore.ShardData[shardKey] = shard
		end

		setPath(data, table_path, {
			__sharded = true,
			count = shardIndex
		})
	else
		if not tbl.__sharded then
			return
		end

		local combined = {}

		for i = 1, tbl.count do
			local shardKey = getShardKey(player.UserId, table_path, i)
			local shardData = PlayerDatastore.ShardData[shardKey]

			if not shardData then return end

			for k, v in shardData do
				combined[k] = v
			end
		end

		setPath(data, table_path, combined)
	end
end

-- ShardGlobal(): Enables sharding for a global table path
-- @param path: The global key pointing to the table
-- @param enable: Whether to enable sharding or not
-- @note Automatically handles unshard + reshard
function PlayerDatastore.ShardGlobal(path: string, enable: boolean): ()
	local tbl = PlayerDatastore.GlobalData[path]
	if type(tbl) ~= "table" then return end

	if enable then
		if tbl.__sharded then
			for i = 1, (tbl.count or 0) do
				local shardKey = getShardGlobalKey(path, i)
				PlayerDatastore.ShardData[shardKey] = nil
			end
		end

		local limit = Config.DATASTORE.SHARD_BYTE_LIMIT
		local shards = {}
		local current = {}
		local shardIndex = 1
		local currentBytes = 0

		for k, v in PlayerDatastore.GlobalData[path] do
			if k == "__sharded" or k == "count" then continue end

			local entryBytes = estimateBytes(k) + estimateBytes(v)

			if currentBytes + entryBytes > limit then
				if next(current) then
					shards[shardIndex] = current
					shardIndex += 1
				end

				current = {}
				currentBytes = 0
			end

			current[k] = v
			currentBytes += entryBytes
		end

		if next(current) then
			shards[shardIndex] = current
		end

		for i, shard in shards do
			local shardKey = getShardGlobalKey(path, i)
			PlayerDatastore.ShardData[shardKey] = shard
		end

		setPath(PlayerDatastore.GlobalData, path, {
			__sharded = true,
			count = shardIndex
		})
	else
		if not tbl.__sharded then
			return
		end

		local combined = {}

		for i = 1, tbl.count do
			local shardKey = getShardGlobalKey(path, i)
			local shardData = PlayerDatastore.ShardData[shardKey]

			if shardData then
				for k, v in shardData do
					combined[k] = v
				end
			end

			PlayerDatastore.ShardData[shardKey] = nil
		end

		setPath(PlayerDatastore.GlobalData, path, combined)
	end
end

--=========================
-- // GLOBAL OPERATIONS
--=========================

-- ReadGlobal(): Reads a global table or value, unshards if needed
-- @param path: The global key or nested path to read
-- @return any: The value stored globally
function PlayerDatastore.ReadGlobal(path: string): any
	Config.FLAGS.GlobalDataLoaded:DeferredWait()

	local data = PlayerDatastore.GlobalData

	local shardedPath = findShardedPath(data, path)

	if shardedPath then
		local shardedTable = resolvePath(data, shardedPath)
		local combined = {}

		for i = 1, shardedTable.count do
			local shardKey = getShardGlobalKey(shardedPath, i)
			local shardData = PlayerDatastore.ShardData[shardKey]

			if shardData then
				for k, v in shardData do
					combined[k] = v
				end
			end
		end

		if shardedPath == path then
			return combined
		else
			local remainingPath = string.sub(path, #shardedPath + 2)
			return resolvePath(combined, remainingPath)
		end
	end

	local value = resolvePath(data, path)

	return value
end

-- ApplyOperatorGlobal(): Applies an operation to a global table
-- @param operation: Types.OperationType (value_name, operator, value)
function PlayerDatastore.ApplyOperatorGlobal(operation: Types.OperationType): ()
	Config.FLAGS.GlobalDataLoaded:DeferredWait()

	local shardedFields: { string } = PlayerDatastore.Presets and PlayerDatastore.Presets.ShardedFields or {}
	local globalFields: { string } = PlayerDatastore.Presets and PlayerDatastore.Presets.GlobalFields or {}

	if not PlayerDatastore.GlobalData then
		warn("ApplyOperatorGlobal(): GlobalData not initialized")
		return
	end

	local rootKey = nil
	local pathParts = string.split(operation.value_name, ".")

	if table.find(globalFields, pathParts[1]) then
		rootKey = pathParts[1]
	else
		warn("ApplyOperatorGlobal(): Path doesn't start with a valid global field:", operation.value_name)
		return
	end

	if PlayerDatastore.GlobalLocks[rootKey] then
		warn("ApplyOperatorGlobal(): Operation already in progress for", rootKey)
		return
	end

	PlayerDatastore.GlobalLocks[rootKey] = true

	local rootTable = PlayerDatastore.GlobalData[rootKey]

	if not rootTable then
		warn("ApplyOperatorGlobal(): Root global key not found:", rootKey)
		PlayerDatastore.GlobalLocks[rootKey] = false
		return
	end

	if isSharded(rootTable) then
		local combined = {}

		for i = 1, rootTable.count do
			local shardKey = getShardGlobalKey(rootKey, i)
			local shardData = PlayerDatastore.ShardData[shardKey]

			if shardData then
				for k, v in shardData do
					combined[k] = v
				end
			end

			PlayerDatastore.ShardData[shardKey] = nil
		end

		PlayerDatastore.GlobalData[rootKey] = combined
	end

	local success, err = pcall(function()
		local currentValue = resolvePath(PlayerDatastore.GlobalData, operation.value_name)

		if currentValue == nil then
			error(`ApplyOperatorGlobal(): Couldn't find value: {operation.value_name}`)
		end

		local newValue = Config.OPERATION_CASES[operation.operator](currentValue, operation.value)
		setPath(PlayerDatastore.GlobalData, operation.value_name, newValue)
	end)

	if not success then
		warn("ApplyOperatorGlobal():", err)
		PlayerDatastore.GlobalLocks[rootKey] = false
		return
	end

	if table.find(shardedFields, rootKey) then
		PlayerDatastore.ShardGlobal(rootKey, true)
	end

	PlayerDatastore.GlobalLocks[rootKey] = false
end

--=========================
-- // UTILITY API
--=========================

-- GetPlayerData(): Gets a player's data
-- @param player?: The player to get data for; else returns the entire table
-- @return { [number]: any } | any
function PlayerDatastore.GetPlayerData(player: Player?): { [number]: any } | any
	Config.FLAGS.PlayerDataLoaded:DeferredWait()

	return if player then PlayerDatastore.PlayerData[player.UserId] else PlayerDatastore.PlayerData
end

-- GetShardData(): Gets a shard's data
-- @param key?: Optional Key to get shard data for; else returns the entire table
-- @return { [string]: any } | any
function PlayerDatastore.GetShardData(key: string?): { [string]: any } | any
	Config.FLAGS.PlayerDataLoaded:DeferredWait()
	Config.FLAGS.GlobalDataLoaded:DeferredWait()

	return if key then PlayerDatastore.ShardData[key] else PlayerDatastore.ShardData
end

-- GetGlobalData(): Gets the global data
-- @param table_path?: The path to the table to get; else returns the entire table
-- @return { [string]: any } | any
function PlayerDatastore.GetGlobalData(table_path: string?): { [string]: any } | any
	Config.FLAGS.GlobalDataLoaded:DeferredWait()

	return if table_path then PlayerDatastore.GlobalData[table_path] else PlayerDatastore.GlobalData
end

return PlayerDatastore