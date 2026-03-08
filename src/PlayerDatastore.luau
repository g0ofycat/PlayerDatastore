--!strict

local PlayerDatastore = {}

PlayerDatastore.PlayerData = {} :: { [number]: { [any]: any } }
PlayerDatastore.ShardData = {} :: { [string]: { [any]: any } }
PlayerDatastore.GlobalData = {} :: { [string]: any }

PlayerDatastore.DirtyData = {} :: { [number | string]: boolean }

PlayerDatastore.CurrentVersion = "v.1.0.0"

--=========================
-- // SERVICES
--=========================

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService = game:GetService("HttpService")

--=========================
-- // MODULES
--=========================

local Config = require("./Config")

--=========================
-- // TYPES
--=========================

local Types = require("./Types")

PlayerDatastore.MetaData = {} :: { [number | string]: Types.MetaData }
PlayerDatastore.Presets = nil :: Types.PresetOptions?

--=========================
-- // SIGNAL
--=========================

local Signal = require("./Utility/Signal")

PlayerDatastore.PlayerLoadedSignals = {} :: { [number]: Signal.Signal }

--=========================
-- // DATASTORE
--=========================

local PlayerDataStore = DataStoreService:GetDataStore(Config.DATASTORE.DATASTORE_NAME)
local ShardedDataStore = DataStoreService:GetDataStore(Config.DATASTORE.SHARDED_DATASTORE_NAME)
local GlobalDataStore = DataStoreService:GetDataStore(Config.DATASTORE.GLOBAL_DATASTORE_NAME)
local PlayerMetaDataStore = DataStoreService:GetDataStore(Config.DATASTORE.PLAYER_METADATA_STORE_NAME)
local SessionLockStore = DataStoreService:GetDataStore(Config.DATASTORE.LOCK_DATASTORE_NAME)

local GlobalMemoryStore = MemoryStoreService:GetHashMap(Config.DATASTORE.GLOBAL_HASHMAP_NAME)

--=========================
-- // PRIVATE API
--=========================

-- deepClone(): Deep clones a table
-- @param tbl: The table to clone
-- @return: { [any]: any }
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

-- isSharded(): Checks to see if a table is sharded
-- @param tbl: { [any]: any }
-- @return: boolean
local function isSharded(tbl: { [any]: any }): boolean
	return type(tbl) == "table" and tbl.__sharded
end

-- reconcileData(): Reconciles the loaded data with the schema
-- @param loaded: { [any]: any }
-- @param schema: { [any]: any }
-- @return: { [any]: any }
local function reconcileData(loaded: { [any]: any }, schema: { [any]: any }): { [any]: any }
	if typeof(schema) ~= "table" then
		if typeof(loaded) == "table" then
			return schema
		end

		return loaded
	end

	if typeof(loaded) ~= "table" then
		return deepClone(schema)
	end

	if loaded.__sharded then
		return deepClone(loaded)
	end

	local result = {}

	for key, schemaValue in schema do
		result[key] = reconcileData(loaded[key], schemaValue)
	end

	return result
end

-- parseSegment(): Parses a path segment into a key / index
-- @param segment: string
-- @param isBracketed: boolean
-- @return: any
local function parseSegment(segment: string, isBracketed: boolean): any
	if isBracketed then
		local quoted = segment:match("^['\"](.+)['\"]$")
		if quoted then return quoted end

		return tonumber(segment) or segment
	end

	return tonumber(segment) or segment
end

-- getSegments(): Gets all segments from a path
-- @param path: string
-- @return: { any }
local function getSegments(path: string): { any }
	local segments = {}

	for isBracket, content in path:gmatch("([%[%%.]?)([^%[%]%.]+)%]?") do
		local bracketed = (isBracket == "[")
		table.insert(segments, parseSegment(content :: string, bracketed))
	end

	return segments
end

-- resolvePath(): Resolves a path in a table
-- @param tbl: The table to resolve the path in
-- @param path: The path to resolve
-- @return: any
local function resolvePath(tbl: any, path: string): any
	local current = tbl

	for _, key in getSegments(path) do
		if type(current) ~= "table" then return nil end

		current = current[key]
		if current == nil then return nil end
	end

	return current
end

-- setPath(): Sets a value at a path in a table
-- @param tbl: The table to set the value in
-- @param path: The path to set
-- @param value: The value to set
local function setPath(tbl: any, path: string, value: any): ()
	local segments = getSegments(path)
	local current = tbl

	for i = 1, #segments do
		local key = segments[i]

		if i == #segments then
			current[key] = value
		else
			if type(current[key]) ~= "table" then
				current[key] = {}
			end

			current = current[key]
		end
	end
end

-- findShardedPath(): Finds the sharded path for a value
-- @param data: { [any]: any }
-- @param valueName: string
-- @return: string?
local function findShardedPath(data: { [any]: any }, valueName: string): string?
	local pathParts = string.split(valueName, ".")
	local deepestPath: string? = nil

	for i = 1, #pathParts do
		local testPath = table.concat(pathParts, ".", 1, i)
		local testTable = resolvePath(data, testPath)

		if isSharded(testTable) then
			deepestPath = testPath
		end
	end

	return deepestPath
end

--=========================
-- // PRIVATE MEMORY STORE API
--=========================

-- readMemoryGlobal(): Reads the global data key from MemoryStore
-- @return: { [string]: any }?
local function readMemoryGlobal(): { [string]: any }?
	local data = nil

	local success = pcall(function()
		data = GlobalMemoryStore:GetAsync(Config.DATASTORE.MEMORY_STORE_KEY)
	end)

	if not success then
		warn("readMemoryGlobal(): Failed to read from MemoryStore")
		return nil
	end

	return data
end

-- writeMemoryGlobal(): Atomically updates the global data key in MemoryStore
-- @param callback: (current: { [string]: any }) -> { [string]: any }: Transform function
-- @return: boolean: Whether the write succeeded
local function writeMemoryGlobal(callback: (current: { [string]: any }) -> { [string]: any }?): boolean
	local success = pcall(function()
		GlobalMemoryStore:UpdateAsync(Config.DATASTORE.MEMORY_STORE_KEY, function(current)
			local state = current or {}
			return callback(state)
		end, Config.DATASTORE.MEMORY_STORE_TTL)
	end)

	if not success then
		warn("writeMemoryGlobal(): Failed to write to MemoryStore")
	end

	return success
end

--=========================
-- // PRIVATE METADATA API
--=========================

-- getMetaKey(): Returns the metadata key for a given userId
-- @param userId: number
-- @return: string
local function getMetaKey(userId: number): string
	return `meta:{userId}`
end

-- loadMetaData(): Loads metadata for a player
-- @param player: Player
-- @return: MetaData?
local function loadMetaData(player: Player): Types.MetaData?
	local data: string? = nil

	local success = pcall(function()
		data = PlayerMetaDataStore:GetAsync(getMetaKey(player.UserId))
	end)

	if not success then
		warn("loadMetaData(): Failed to load metadata for", player.Name)
		return nil
	end

	return data and HttpService:JSONDecode(data) or nil
end

-- saveMetaData(): Saves metadata for a player
-- @param player: Player
local function saveMetaData(player: Player): ()
	local existing = PlayerDatastore.MetaData[player.UserId]
	if not existing then return end

	local updated: Types.MetaData = {
		LastSaved = os.time(),
		ServerId = game.JobId,
		SaveCount = existing.SaveCount + 1,
		FirstJoined = existing.FirstJoined,
		TotalPlaytime = existing.TotalPlaytime + (os.time() - (existing._SessionStart or os.time())),
		DataVersion = PlayerDatastore.CurrentVersion,
		_SessionStart = existing._SessionStart
	}

	PlayerDatastore.MetaData[player.UserId] = updated

	pcall(function()
		PlayerMetaDataStore:SetAsync(getMetaKey(player.UserId), HttpService:JSONEncode(updated))
	end)
end

-- saveGlobalMetaData(): Saves global metadata
local function saveGlobalMetaData(): ()
	local existing = PlayerDatastore.MetaData[Config.DATASTORE.GLOBAL_DATASTORE_KEY]

	local meta: Types.MetaData = {
		LastSaved = os.time(),
		ServerId = game.JobId,
		SaveCount = (existing and existing.SaveCount or 0) + 1,
		FirstJoined = existing and existing.FirstJoined or os.time(),
		TotalPlaytime = 0,
		DataVersion = PlayerDatastore.CurrentVersion,
		_SessionStart = 0
	}

	PlayerDatastore.MetaData[Config.DATASTORE.GLOBAL_DATASTORE_KEY] = meta

	pcall(function()
		GlobalDataStore:SetAsync(
			`{Config.DATASTORE.GLOBAL_DATASTORE_KEY}:meta`,
			HttpService:JSONEncode(meta)
		)
	end)
end

--=========================
-- // PRIVATE SAVE / LOAD API
--=========================

-- saveData(): Saves the players data
-- @param player: The player to save the data for
-- @note Shards unsharded data marked as __sharded; ApplyOperator unshards to apply operations. While doing this, the player could leave, having corrupted sharded data that may exceed the 4MB Key Limit. This fixes it
local function saveData(player: Player): ()
	local data = PlayerDatastore.PlayerData[player.UserId]
	if not data then return end

	local shardedFields: { string } = PlayerDatastore.Presets and PlayerDatastore.Presets.ShardedFields or {}

	for _, table_path in shardedFields do
		local tbl = resolvePath(data, table_path)

		if type(tbl) ~= "table" or tbl.__sharded then continue end

		warn("saveData(): Force-sharding", table_path, "for", player.Name)
		PlayerDatastore.Shard(player, table_path, true)
	end

	pcall(function()
		PlayerDataStore:SetAsync(tostring(player.UserId), HttpService:JSONEncode(data))
	end)

	saveMetaData(player)
end

-- loadData(): Loads the players data
-- @param player: The player to load the data for
-- @return: { [any]: any }?
local function loadData(player: Player): { [any]: any }?
	local data

	local success = pcall(function()
		data = PlayerDataStore:GetAsync(tostring(player.UserId))
	end)

	if not success then
		warn("loadData(): Failed to load data for", player.Name)
		return nil
	end

	if data then
		return HttpService:JSONDecode(data)
	end

	return nil
end

-- saveGlobalData(): Saves global data to the GlobalDataStore
-- @note Automatically JSON encodes the value; reshards if needed
local function saveGlobalData(): ()
	local globalFields: { string } = PlayerDatastore.Presets and PlayerDatastore.Presets.GlobalFields or {}
	local shardedFields: { string } = PlayerDatastore.Presets and PlayerDatastore.Presets.ShardedFields or {}

	local liveData = readMemoryGlobal() or PlayerDatastore.GlobalData
	local dataToSave = {}

	for _, path in globalFields do
		local value = liveData[path]
		if value == nil then continue end

		if type(value) == "table" and table.find(shardedFields, path) then
			PlayerDatastore.GlobalData[path] = value
			PlayerDatastore.ShardGlobal(path, true)
			dataToSave[path] = PlayerDatastore.GlobalData[path]
		else
			dataToSave[path] = value
		end
	end

	pcall(function()
		GlobalDataStore:SetAsync(
			Config.DATASTORE.GLOBAL_DATASTORE_KEY,
			HttpService:JSONEncode(dataToSave)
		)
	end)

	saveGlobalMetaData()
end

-- loadGlobalData(): Loads global data from the GlobalDataStore
-- @return: any: Global data
local function loadGlobalData(): any
	local data

	local success = pcall(function()
		data = GlobalDataStore:GetAsync(Config.DATASTORE.GLOBAL_DATASTORE_KEY)
	end)

	if not success then
		warn("loadGlobalData(): Failed to load master global key")
		return {}
	end

	return data and HttpService:JSONDecode(data) or {}
end

--=========================
-- // COMPLEX PRIVATE API
--=========================

-- getShardKey(): Returns the shard key for a given path and index
-- @param userId: number
-- @param path: string
-- @param index: number
-- @return: string
local function getShardKey(userId: number, path: string, index: number): string
	return `{userId}:{path}:shard:{index}`
end

-- getShardGlobalKey(): Returns the global shard key for a given path and index
-- @param path: string
-- @param index: number
-- @return: string
local function getShardGlobalKey(path: string, index: number): string
	return `global:{path}:shard:{index}`
end

-- stripGlobalFields(): Removes from PlayerData if their name is in GlobalFields
-- @param data_table: { [any]: any }
-- @param globalFields: { string }
-- @return: { [any]: any }
local function stripGlobalFields(data_table: { [any]: any }, globalFields: { string }): { [any]: any }
	local clone = deepClone(data_table)

	for _, key in globalFields do
		clone[key] = nil
	end

	return clone
end

--=========================
-- // PRIVATE SHARD API
--=========================

-- collectExistingShards(): Collects all existing shard keys for a user
-- @param user_id: number
-- @param shardedFields: { string }
-- @param globalFields: { string }
-- @return: { string }
local function collectExistingShards(user_id: number, shardedFields: { string }, globalFields: { string }): { string }
	local shardKeys: { string } = {}

	for _, table_path in shardedFields do
		if table.find(globalFields, table_path) then continue end

		local data = PlayerDatastore.PlayerData[user_id]
		if not data then continue end

		local tbl = resolvePath(data, table_path)
		if not isSharded(tbl) then continue end

		for i = 1, tbl.count or 0 do
			local shardKey = getShardKey(user_id, table_path, i)

			if PlayerDatastore.ShardData[shardKey] then
				table.insert(shardKeys, shardKey)
			end
		end
	end

	return shardKeys
end

-- saveShards(): Saves all shards given a list of shard keys
-- @param shardKeys: { string }
local function saveShards(shardKeys: { string }): ()
	for _, shardKey in shardKeys do
		task.spawn(function()
			local shardData = PlayerDatastore.ShardData[shardKey]
			if not shardData then return end

			pcall(function()
				ShardedDataStore:SetAsync(shardKey, HttpService:JSONEncode(shardData))
			end)
		end)
	end
end

-- saveShardsSync(): Synchronous shard save, used in BindToClose so writes finish before lock release
-- @param shardKeys: { string }
local function saveShardsSync(shardKeys: { string }): ()
	for _, shardKey in shardKeys do
		local shardData = PlayerDatastore.ShardData[shardKey]
		if not shardData then continue end

		pcall(function()
			ShardedDataStore:SetAsync(shardKey, HttpService:JSONEncode(shardData))
		end)
	end
end

--=========================
-- // PRIVATE AUTOSAVE API
--=========================

-- markDirty(): Marks a key as having unsaved changes
-- @param key: Player.UserId OR Config.DATASTORE.GLOBAL_DATASTORE_KEY for global data
local function markDirty(key: number | string): ()
	PlayerDatastore.DirtyData[key] = true
end

-- flushDirty(): Saves all dirty keys and clears them from DirtyData
-- @param max_keys: Optional capacity on how many keys to save this cycle (default: all)
-- @return: number: Amount of keys flushed
local function flushDirty(max_keys: number?): number
	local shardedFields: { string } = PlayerDatastore.Presets and PlayerDatastore.Presets.ShardedFields or {}
	local globalFields: { string } = PlayerDatastore.Presets and PlayerDatastore.Presets.GlobalFields or {}
	local Limit = max_keys or math.huge
	local ToProcess: { number | string } = {}

	for Key in PlayerDatastore.DirtyData do
		if #ToProcess >= Limit then break end
		table.insert(ToProcess, Key)
	end

	local SaveHandlers: { [string]: (Key: number | string) -> () } = {
		["number"] = function(Key: number | string): ()
			local Player = Players:GetPlayerByUserId(Key :: number)
			if not Player or not PlayerDatastore.PlayerData[Key :: number] then return end

			local ShardKeys = collectExistingShards(Key :: number, shardedFields, globalFields)
			saveShards(ShardKeys)

			saveData(Player)
		end,

		["string"] = function(_Key: number | string): ()
			saveGlobalData()
		end
	}

	for _, Key in ToProcess do
		SaveHandlers[type(Key)](Key)
		PlayerDatastore.DirtyData[Key] = nil
	end

	return #ToProcess
end

-- startAutosave(): Starts the autosave loop
local function startAutosave(): ()
	task.spawn(function()
		while true do
			task.wait(Config.DATASTORE.AUTOSAVE_INTERVAL)
			local flushed = flushDirty(Config.DATASTORE.MAX_KEYS_PER_AUTOSAVE)

			print(`startAutosave(): Flushed {flushed} keys`)
		end
	end)
end

--=========================
-- // PRIVATE SESSION LOCK API
--=========================

-- getSessionLockKey(): Returns the session lock key for a given user_id
-- @param user_id: number
-- @return: string
local function getSessionLockKey(user_id: number): string
	return `session:{user_id}:lock`
end

-- acquireSessionLock(): Atomically acquires a session lock for a player
-- @param user_id: number
-- @return: boolean: Whether the lock was acquired
local function acquireSessionLock(user_id: number): boolean
	local lockKey = getSessionLockKey(user_id)
	local acquired = false

	for attempt = 1, Config.DATASTORE.LOCK_MAX_RETRIES do
		local success = pcall(function()
			SessionLockStore:UpdateAsync(lockKey, function(existingLock): string?
				if existingLock and existingLock ~= game.JobId then
					return nil
				end

				acquired = true

				return game.JobId
			end)
		end)

		if success and acquired then
			return true
		end

		if success and not acquired then
			return false
		end

		task.wait(Config.DATASTORE.LOCK_RETRY_INTERVAL)
	end

	return false
end

-- releaseSessionLock(): Releases the session lock for a player
-- @param user_id: number
local function releaseSessionLock(user_id: number): ()
	pcall(function()
		SessionLockStore:RemoveAsync(getSessionLockKey(user_id))
	end)
end

--=========================
-- // PRIVATE SIGNAL API
--=========================

-- waitForSignal(): Rare case when signal isn't set up yet
-- @param user_id: number
-- @param yield_time: Max time to yield for the signal to be set up
-- @return: Signal.Signal?
local function waitForSignal(user_id: number, yield_time: number): Signal.Signal?
	local deadline = os.clock() + yield_time

	while not PlayerDatastore.PlayerLoadedSignals[user_id] do
		if os.clock() >= deadline then return nil end
		if not PlayerDatastore.PlayerData[user_id] then return nil end

		task.wait()
	end

	return PlayerDatastore.PlayerLoadedSignals[user_id]
end

--=========================
-- // PRIVATE INIT API
--=========================

-- onPlayerAdded(): Handles PlayerAdded, loading data and setting up sharding
-- @param player: Player
-- @param data_table: { [any]: any }: The template data table for the player
-- @param globalFields: { string }: List of global fields to check for sharding
-- @param shardedFields: { string }: List of sharded fields to set up sharding for
local function onPlayerAdded(player: Player, data_table: { [any]: any }, globalFields: { string }, shardedFields: { string }): ()
	PlayerDatastore.PlayerLoadedSignals[player.UserId] = Signal.new()

	local locked = acquireSessionLock(player.UserId)
	if not locked then
		warn("onPlayerAdded(): Session lock held by another server, kicking:", player.Name)

		player:Kick("[PlayerDatastore]: Your data is still being saved from another server. Please rejoin in a moment.")
		PlayerDatastore.PlayerLoadedSignals[player.UserId]:FireDeferred()
		PlayerDatastore.PlayerLoadedSignals[player.UserId] = nil

		return
	end

	local loadedMeta = loadMetaData(player)

	PlayerDatastore.MetaData[player.UserId] = {
		LastSaved = loadedMeta and loadedMeta.LastSaved or os.time(),
		ServerId = game.JobId,
		SaveCount = loadedMeta and loadedMeta.SaveCount or 0,
		FirstJoined = loadedMeta and loadedMeta.FirstJoined or os.time(),
		TotalPlaytime = loadedMeta and loadedMeta.TotalPlaytime or 0,
		DataVersion = PlayerDatastore.CurrentVersion,
		_SessionStart = os.time()
	}

	local data = loadData(player)
	local playerTemplate = stripGlobalFields(data_table, globalFields)
	local reconciled: { [any]: any }

	if data then
		reconciled = reconcileData(data, playerTemplate)
	else
		reconciled = playerTemplate
	end

	PlayerDatastore.PlayerData[player.UserId] = reconciled

	for _, table_path in shardedFields do
		if table.find(globalFields, table_path) then continue end

		local tbl = resolvePath(PlayerDatastore.PlayerData[player.UserId], table_path)

		if tbl == nil then
			warn("onPlayerAdded(): Sharded field not found in data template:", table_path)
			continue
		end

		if type(tbl) ~= "table" then
			warn("onPlayerAdded(): Sharded field is not a table:", table_path)
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

	PlayerDatastore.PlayerLoadedSignals[player.UserId]:FireDeferred()
end

--=========================
-- // PUBLIC API
--=========================

-- Init(): Initialize the datastore handler
-- @param data_table: { [any]: any }
-- @param presets: Types.PresetOptions?
function PlayerDatastore.Init(data_table: { [any]: any }, presets: Types.PresetOptions?): ()
	PlayerDatastore.Presets = presets

	local shardedFields: { string } = presets and presets.ShardedFields or {}
	local globalFields: { string } = presets and presets.GlobalFields or {}

	Players.PlayerAdded:Connect(function(player)
		onPlayerAdded(player, data_table, globalFields, shardedFields)
	end)

	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player, data_table, globalFields, shardedFields)
	end

	local globalData = loadGlobalData()
	local globalMemoryState = {}

	for _, table_path in globalFields do
		local loadedValue = globalData[table_path]
		local defaultValue = resolvePath(data_table, table_path)

		if defaultValue == nil then
			warn("Init(): Global field not found in data template:", table_path)
			continue
		end

		local reconciled: { [any]: any } = {}

		if type(loadedValue) == "table" and loadedValue.__sharded then
			local combined = {}

			for i = 1, loadedValue.count or 0 do
				local shardKey = getShardGlobalKey(table_path, i)

				pcall(function()
					local shardData = ShardedDataStore:GetAsync(shardKey)
					if not shardData then return end

					local decoded = HttpService:JSONDecode(shardData)
					for k, v in decoded do
						combined[k] = v
					end
				end)
			end

			reconciled = combined
		else
			reconciled = reconcileData(loadedValue, defaultValue)
		end

		PlayerDatastore.GlobalData[table_path] = reconciled
		globalMemoryState[table_path] = reconciled
	end

	local existingMemory = readMemoryGlobal()

	if not existingMemory then
		local written = writeMemoryGlobal(function()
			return globalMemoryState
		end)

		if not written then
			warn("Init(): Failed to seed MemoryStore with global data")
		end
	else
		for _, table_path in globalFields do
			if existingMemory[table_path] == nil then continue end

			PlayerDatastore.GlobalData[table_path] = existingMemory[table_path]
		end
	end

	Config.FLAGS.GlobalDataLoaded:FireDeferred()

	Players.PlayerRemoving:Connect(function(player)
		if PlayerDatastore.DirtyData[player.UserId] then
			local shardKeys = collectExistingShards(player.UserId :: number, shardedFields, globalFields)
			saveShards(shardKeys)
			saveData(player)

			PlayerDatastore.DirtyData[player.UserId] = nil
		end

		releaseSessionLock(player.UserId)

		local PlayerSignal = PlayerDatastore.PlayerLoadedSignals[player.UserId]

		if PlayerSignal then
			PlayerSignal:DisconnectAll()
			PlayerDatastore.PlayerLoadedSignals[player.UserId] = nil
		end

		PlayerDatastore.PlayerData[player.UserId] = nil
		PlayerDatastore.MetaData[player.UserId] = nil
	end)

	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			if PlayerDatastore.DirtyData[player.UserId] then
				local shardKeys = collectExistingShards(player.UserId, shardedFields, globalFields)
				saveShardsSync(shardKeys)
				saveData(player)

				PlayerDatastore.DirtyData[player.UserId] = nil
			end

			releaseSessionLock(player.UserId)
		end

		if PlayerDatastore.DirtyData[Config.DATASTORE.GLOBAL_DATASTORE_KEY] then
			saveGlobalData()
			PlayerDatastore.DirtyData[Config.DATASTORE.GLOBAL_DATASTORE_KEY] = nil
		end

		table.clear(PlayerDatastore.PlayerData)
		table.clear(PlayerDatastore.ShardData)
		table.clear(PlayerDatastore.GlobalData)
		table.clear(PlayerDatastore.MetaData)
		table.clear(PlayerDatastore.PlayerLoadedSignals)
	end)

	startAutosave()
end

-- Read(): Reads the player's data, unshards if sharded
-- @param player: The player to read the data for
-- @param table_path: The path to the table to read
-- @return: { [any]: any }
function PlayerDatastore.Read(player: Player, table_path: string): { [any]: any }?
	local playerSig = waitForSignal(player.UserId, Config.DATASTORE.SIGNAL_YIELD_TIME)

	if not playerSig then
		warn("Read(): Timed out waiting for load signal:", player.Name)
		return nil
	end

	playerSig:DeferredWait()

	local data = PlayerDatastore.PlayerData[player.UserId]

	if not data then
		warn("Read(): Couldn't find data for player:", player.Name)
		return nil
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
		end

		local remainingPath = table_path:match(
			"^" .. shardedPath:gsub("%.", "%%.") .. "%.(.*)"
		) or ""

		return resolvePath(combined, remainingPath)
	end

	return resolvePath(data, table_path)
end

-- ApplyOperator(): Applies an operation to a player's data
-- @param player: The player who is doing the operation
-- @param operation: Types.OperationType (value_name, operator, value)
function PlayerDatastore.ApplyOperator(player: Player, operation: Types.OperationType): ()
	local playerSig = waitForSignal(player.UserId, Config.DATASTORE.SIGNAL_YIELD_TIME)

	if not playerSig then
		warn("ApplyOperator(): Timed out waiting for load signal:", player.Name)
		return
	end

	playerSig:DeferredWait()

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

			-- // PlayerDatastore.ShardData[shardKey] = nil NOTE: No removing, PlayerRemoving / BindToClose needs it to see if data is upd, then clears it
		end

		setPath(data, shardedPath, combined)
	end

	local success = pcall(function()
		local currentValue = resolvePath(data, operation.value_name)

		if currentValue == nil then
			error(`ApplyOperator(): Couldn't find value: {operation.value_name}`)
		end

		local newValue = Config.OPERATION_CASES[operation.operator](currentValue, operation.value)

		setPath(data, operation.value_name, newValue)
	end)

	if not success then
		warn("ApplyOperator(): Failed to apply operation for player:", player.Name)
	end

	if shardedPath then
		PlayerDatastore.Shard(player, shardedPath, true)
	end

	markDirty(player.UserId)
end

-- DeletePlayerData(): Deletes a player's data
-- @param player: The player to delete data for
function PlayerDatastore.DeletePlayerData(player: Player): ()
	local playerSig = waitForSignal(player.UserId, Config.DATASTORE.SIGNAL_YIELD_TIME)

	if not playerSig then
		warn("DeletePlayerData(): Timed out waiting for load signal:", player.Name)
		return
	end

	playerSig:DeferredWait()

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

				PlayerDatastore.ShardData[shardKey] = nil

				pcall(function()
					ShardedDataStore:RemoveAsync(shardKey)
				end)
			end
		end
	end

	pcall(function()
		PlayerDataStore:RemoveAsync(tostring(userId))
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

			PlayerDatastore.ShardData[shardKey] = nil

			pcall(function()
				ShardedDataStore:RemoveAsync(shardKey)
			end)
		end
	end

	PlayerDatastore.GlobalData[path] = nil

	writeMemoryGlobal(function(current): { [string]: any }
		current[path] = nil
		return current
	end)

	pcall(function()
		GlobalDataStore:SetAsync(
			Config.DATASTORE.GLOBAL_DATASTORE_KEY,
			HttpService:JSONEncode(PlayerDatastore.GlobalData)
		)
	end)
end

--=========================
-- // COMPLEX OPERATIONS
--=========================

-- Shard(): Enables sharding for a table path (Check Config.DATASTORE.SHARD_BYTE_LIMIT)
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
		local oldCount = 0

		if tbl.__sharded then
			oldCount = tbl.count or 0
		end

		local limit = Config.DATASTORE.SHARD_BYTE_LIMIT
		local shards: { [number]: { [any]: any } } = {}
		local current: { [any]: any } = {}
		local shardIndex = 1
		local currentBytes = 0

		for k, v in tbl do
			if k == "__sharded" or k == "count" then continue end

			local tempForSize = { [k] = v }
			local addedSize = #HttpService:JSONEncode(tempForSize)

			if currentBytes + addedSize > limit and next(current) ~= nil then
				shards[shardIndex] = current
				shardIndex += 1
				current = {}
				currentBytes = 0
			end

			current[k] = v
			currentBytes += addedSize
		end

		if next(current) then
			shards[shardIndex] = current
		end

		for index, shard in shards do
			local shardKey = getShardKey(player.UserId, table_path, index)
			PlayerDatastore.ShardData[shardKey] = shard
		end

		for i = shardIndex + 1, oldCount do
			local orphanedKey = getShardKey(player.UserId, table_path, i)
			PlayerDatastore.ShardData[orphanedKey] = nil
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
		local oldCount = 0

		if tbl.__sharded then
			oldCount = tbl.count or 0
		end

		local limit = Config.DATASTORE.SHARD_BYTE_LIMIT
		local shards: { [number]: { [any]: any } } = {}
		local current: { [any]: any } = {}
		local shardIndex = 1
		local currentBytes = 0

		for k, v in PlayerDatastore.GlobalData[path] do
			if k == "__sharded" or k == "count" then continue end

			local tempForSize = { [k] = v }
			local addedSize = #HttpService:JSONEncode(tempForSize)

			if currentBytes + addedSize > limit and next(current) ~= nil then
				shards[shardIndex] = current
				shardIndex += 1
				current = {}
				currentBytes = 0
			end

			current[k] = v
			currentBytes += addedSize
		end

		if next(current) then
			shards[shardIndex] = current
		end

		for i, shard in shards do
			local shardKey = getShardGlobalKey(path, i)
			PlayerDatastore.ShardData[shardKey] = shard
		end

		for i = shardIndex + 1, oldCount do
			local orphanedKey = getShardGlobalKey(path, i)
			PlayerDatastore.ShardData[orphanedKey] = nil
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
		end

		setPath(PlayerDatastore.GlobalData, path, combined)
	end
end

--=========================
-- // GLOBAL OPERATIONS
--=========================

-- ReadGlobal(): Reads a global table or value, unshards if needed
-- @param path: The global key or nested path to read
-- @return: any: The value stored globally
function PlayerDatastore.ReadGlobal(path: string): any
	Config.FLAGS.GlobalDataLoaded:DeferredWait()

	local liveData = readMemoryGlobal()

	if not liveData then
		warn("ReadGlobal(): Failed to read from MemoryStore, falling back to local cache")
		return resolvePath(PlayerDatastore.GlobalData, path)
	end

	return resolvePath(liveData, path)
end

-- ApplyOperatorGlobal(): Applies an operation to a global table
-- @param operation: Types.OperationType (value_name, operator, value)
function PlayerDatastore.ApplyOperatorGlobal(operation: Types.OperationType): ()
	Config.FLAGS.GlobalDataLoaded:DeferredWait()

	local globalFields: { string } = PlayerDatastore.Presets and PlayerDatastore.Presets.GlobalFields or {}
	local pathParts = string.split(operation.value_name, ".")

	if not table.find(globalFields, pathParts[1]) then
		warn("ApplyOperatorGlobal(): Path doesn't start with a valid global field:", operation.value_name)
		return
	end

	local liveData: { [string]: any }? = nil

	local success = writeMemoryGlobal(function(current): { [string]: any }?
		local currentValue = resolvePath(current, operation.value_name)

		if currentValue == nil then
			warn("ApplyOperatorGlobal(): Couldn't find value:", operation.value_name)
			return nil
		end

		local newValue = Config.OPERATION_CASES[operation.operator](currentValue, operation.value)
		setPath(current, operation.value_name, newValue)

		liveData = current

		return current
	end)

	if not success then
		warn("ApplyOperatorGlobal(): Failed to apply global operation for path:", operation.value_name)
		return
	end

	if liveData then
		for _, table_path in globalFields do
			PlayerDatastore.GlobalData[table_path] = liveData[table_path]
		end
	end

	markDirty(Config.DATASTORE.GLOBAL_DATASTORE_KEY)
end

--=========================
-- // UTILITY API
--=========================

-- GetPlayerData(): Gets a player's data
-- @param player: The player to get data for
-- @return: { [any]: any }?
function PlayerDatastore.GetPlayerData(player: Player): { [any]: any }?
	local playerSig = waitForSignal(player.UserId, Config.DATASTORE.SIGNAL_YIELD_TIME)

	if not playerSig then
		warn("GetPlayerData(): Timed out waiting for load signal:", player.Name)
		return nil
	end

	playerSig:DeferredWait()

	return PlayerDatastore.PlayerData[player.UserId]
end

-- GetShardData(): Gets a shards data
-- @param player: The player to check the yield for
-- @param key?: Optional Key to get shard data for; else returns the entire table
-- @return: { [string]: any } | any
function PlayerDatastore.GetShardData(player: Player, key: string?): { [string]: any } | any
	local playerSig = waitForSignal(player.UserId, Config.DATASTORE.SIGNAL_YIELD_TIME)

	if not playerSig then
		warn("GetShardData(): Timed out waiting for load signal:", player.Name)
		return {}
	end

	playerSig:DeferredWait()

	Config.FLAGS.GlobalDataLoaded:DeferredWait()

	return if key then PlayerDatastore.ShardData[key] else PlayerDatastore.ShardData
end

-- GetGlobalData(): Gets the global data
-- @param table_path?: The path to the table to get; else returns the entire table
-- @return: { [string]: any } | any
function PlayerDatastore.GetGlobalData(table_path: string?): { [string]: any } | any
	Config.FLAGS.GlobalDataLoaded:DeferredWait()

	local liveData = readMemoryGlobal()

	if not liveData then
		warn("GetGlobalData(): Failed to read from MemoryStore, falling back to local cache")
		return if table_path then PlayerDatastore.GlobalData[table_path] else PlayerDatastore.GlobalData
	end

	return if table_path then liveData[table_path] else liveData
end

--=========================
-- // VERSIONING API
--=========================

-- ChangeVersion(): Changes the current version
-- @param new_version: The new version to set (default: "v.1.0.0")
function PlayerDatastore.ChangeVersion(new_version: string): ()
	PlayerDatastore.CurrentVersion = new_version
end

--=========================
-- // METADATA API
--=========================

-- GetMetaData(): Gets metadata for a player or global data
-- @param player?: The player to get metadata for; if nil returns global metadata
-- @return: Types.MetaData?
function PlayerDatastore.GetMetaData(player: Player?): Types.MetaData?
	if player then
		local playerSig = waitForSignal(player.UserId, Config.DATASTORE.SIGNAL_YIELD_TIME)

		if not playerSig then
			warn("GetMetaData(): Timed out waiting for load signal:", player.Name)
			return nil
		end

		playerSig:DeferredWait()

		return PlayerDatastore.MetaData[player.UserId]
	end

	Config.FLAGS.GlobalDataLoaded:DeferredWait()

	return PlayerDatastore.MetaData[Config.DATASTORE.GLOBAL_DATASTORE_KEY]
end

return PlayerDatastore