--!strict

local PlayerDatastore = {}

PlayerDatastore.PlayerData = {} :: { [number]: { [any]: any } }
PlayerDatastore.ShardData = {} :: { [string]: { [any]: any } }
PlayerDatastore.GlobalData = {} :: { [string]: any }

PlayerDatastore.SessionLockHeartbeats = {} :: { [number]: boolean }
PlayerDatastore.SessionLockLost = {} :: { [number]: boolean }
PlayerDatastore.PendingShardRemovals = {} :: { [number | string]: { [string]: boolean? } }

PlayerDatastore.OperationQueues = {} :: { [number]: { thread } }
PlayerDatastore.LoadingQueues = {} :: { [number]: { thread } }

PlayerDatastore.LoadingPlayers = {} :: { [number]: boolean }

PlayerDatastore.DirtyData = {} :: { [number | string]: boolean }

PlayerDatastore.CurrentVersion = "v.1.0.0" -- // Used to track metadata version and migrations

PlayerDatastore._initialized = false
PlayerDatastore._localAheadOfMemory = false

PlayerDatastore._globalDataWaiters = {} :: { thread }

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

local Config = require("./Utility/Config")

--=========================
-- // TYPES
--=========================

local Types = require("./Utility/Types")

PlayerDatastore.MetaData = {} :: { [number | string]: Types.MetaData }
PlayerDatastore.Migrations = {} :: { [string]: { To: string, Fn: Types.MigrationFunction } }

PlayerDatastore.Presets = nil :: Types.PresetOptions?

--=========================
-- // DATASTORE
--=========================

local PlayerDataStore = DataStoreService:GetDataStore(Config.DATASTORE.DATASTORE_NAME)
local ShardedDataStore = DataStoreService:GetDataStore(Config.DATASTORE.SHARDED_DATASTORE_NAME)
local GlobalDataStore = DataStoreService:GetDataStore(Config.DATASTORE.GLOBAL_DATASTORE_NAME)
local PlayerMetaDataStore = DataStoreService:GetDataStore(Config.DATASTORE.PLAYER_METADATA_STORE_NAME)
local SnapshotDataStore = DataStoreService:GetDataStore(Config.DATASTORE.SNAPSHOT_DATASTORE_NAME)
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
			warn("reconcileData(): Type mismatch - Loaded value is a table but schema expects", typeof(schema), "; using schema default")
			return schema
		end

		return if loaded ~= nil then loaded else schema
	end

	if typeof(loaded) ~= "table" then
		return deepClone(schema)
	end

	if loaded.__sharded then
		return deepClone(loaded)
	end

	if next(schema) == nil then
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

	for isBracket, content in path:gmatch("([%[%.]?)([^%[%]%.]+)%]?") do
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

-- readGlobalField(): Reads a configured global path
-- @param data: Global data table
-- @param path: Configured global path
-- @return: any: The value at the path, or nil when absent
local function readGlobalField(data: { [string]: any }, path: string): any
	local value = resolvePath(data, path)
	return if value ~= nil then value else data[path]
end

-- setGlobalField(): Writes a nested global path
-- @param data: Global data table
-- @param path: Configured global path
-- @param value: Value to write, or nil to remove
local function setGlobalField(data: { [string]: any }, path: string, value: any): ()
	if path:find(".", 1, true) then
		data[path] = nil
	end
	setPath(data, path, value)
end

-- getPresetFields(): Gets sharded and global fields from PlayerDatastore.Presets
-- @return: ({ string }, { string }): ShardedFields, GlobalFields
local function getPresetFields(): ({ string }, { string })
	return PlayerDatastore.Presets and PlayerDatastore.Presets.ShardedFields or {}, PlayerDatastore.Presets and PlayerDatastore.Presets.GlobalFields or {}
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
-- // PRIVATE YIELD API
--=========================

-- yieldPlayerData(): Yields until a players data is loaded
-- @param user_id: number
-- @return: boolean: Whether the data was loaded
local function yieldPlayerData(user_id: number): boolean
	if PlayerDatastore.PlayerData[user_id] then return true end
	if not PlayerDatastore.LoadingPlayers[user_id] then return false end

	if not PlayerDatastore.LoadingQueues[user_id] then
		PlayerDatastore.LoadingQueues[user_id] = {}
	end

	table.insert(PlayerDatastore.LoadingQueues[user_id], coroutine.running())
	coroutine.yield()

	return PlayerDatastore.PlayerData[user_id] ~= nil
end

-- yieldGlobalData(): Yields until .Init() has completed (Config.DATASTORE.INIT_YIELD_TIME)
-- @return: boolean: Whether Init completed in time
local function yieldGlobalData(): boolean
	if PlayerDatastore._initialized then return true end

	table.insert(PlayerDatastore._globalDataWaiters, coroutine.running())
	coroutine.yield()

	return PlayerDatastore._initialized
end

--=========================
-- // PRIVATE MEMORY STORE API
--=========================

-- readMemoryGlobal(): Reads the global data key from MemoryStore
-- @return: { [string]: any }?, boolean
local function readMemoryGlobal(): ({ [string]: any }?, boolean)
	local data: { [string]: any }? = nil

	local success = pcall(function()
		data = GlobalMemoryStore:GetAsync(Config.DATASTORE.MEMORY_STORE_KEY)
	end)

	if not success then
		warn("readMemoryGlobal(): Failed to read from MemoryStore")
		return nil, success
	end

	return data, success
end

-- writeMemoryGlobal(): Atomically updates the global data key in MemoryStore
-- @param callback: (current: { [string]: any }) -> { [string]: any }: Transform function
-- @return: (boolean, boolean): Whether the write succeeded; Whether the write committed
local function writeMemoryGlobal(callback: (current: { [string]: any }) -> { [string]: any }?): (boolean, boolean)
    local committed = false

    local success = pcall(function()
        GlobalMemoryStore:UpdateAsync(Config.DATASTORE.MEMORY_STORE_KEY, function(current)
            local state = current or {}
            local result = callback(state)
            committed = result ~= nil
            return result
        end, Config.DATASTORE.MEMORY_STORE_TTL)
    end)

    if not success then
        warn("writeMemoryGlobal(): Failed to write to MemoryStore")
    end

    return success, committed
end

--=========================
-- // PRIVATE OPERATION LOCK API
--=========================

-- acquireOperationLock(): Acquires an operation lock for a user, yielding if necessary until the lock is acquired
-- @param user_id: number
-- @return: boolean: Whether the lock was acquired
local function acquireOperationLock(user_id: number): boolean
	if not PlayerDatastore.OperationQueues[user_id] then
		PlayerDatastore.OperationQueues[user_id] = {}
		return true
	end

	local queue = PlayerDatastore.OperationQueues[user_id]
	table.insert(queue, coroutine.running())
	coroutine.yield()

	return PlayerDatastore.PlayerData[user_id] ~= nil
end

-- releaseOperationLock(): Releases an operation lock for a user, resuming the next thread in the queue if there is one
-- @param user_id: number
local function releaseOperationLock(user_id: number): ()
	local queue = PlayerDatastore.OperationQueues[user_id]
	if not queue or #queue == 0 then
		PlayerDatastore.OperationQueues[user_id] = nil
		return
	end

	task.spawn(table.remove(queue, 1) :: thread)
end

--=========================
-- // PRIVATE METADATA API
--=========================

-- getMetaKey(): Returns the metadata key for a given user_id
-- @param user_id: number
-- @return: string
local function getMetaKey(user_id: number): string
	return `meta:{user_id}`
end

-- loadMetaData(): Loads metadata for a player
-- @param player: Player
-- @return: MetaData?
local function loadMetaData(player: Player): (Types.MetaData?, boolean)
	local data: Types.MetaData? = nil

	local success = pcall(function()
		local encoded = PlayerMetaDataStore:GetAsync(getMetaKey(player.UserId))
		data = encoded and HttpService:JSONDecode(encoded) or nil
	end)

	if not success then
		warn("loadMetaData(): Failed to load metadata for", player.Name)
		return nil, false
	end

	return data, true
end

-- saveMetaData(): Saves metadata for a player
-- @param player: Player
-- @note: Only writes SaveCount increment in-memory if persist succeeds
local function saveMetaData(user_id: number, player_name: string): boolean
	if PlayerDatastore.SessionLockLost[user_id] then return false end
	local existing = PlayerDatastore.MetaData[user_id]
	if not existing then return false end

    local updated: Types.MetaData = {
        LastSaved = os.time(),
        ServerId = game.JobId,
        SaveCount = existing.SaveCount + 1,
        FirstJoined = existing.FirstJoined,
        TotalPlaytime = existing.TotalPlaytime + (os.time() - (existing._SessionStart or os.time())),
		DataVersion = existing.DataVersion,
        _SessionStart = existing._SessionStart
    }

    local toPersist = {
        LastSaved = updated.LastSaved,
        ServerId = updated.ServerId,
        SaveCount = updated.SaveCount,
        FirstJoined = updated.FirstJoined,
        TotalPlaytime = updated.TotalPlaytime,
        DataVersion = updated.DataVersion
    }

    local success = pcall(function()
		PlayerMetaDataStore:SetAsync(getMetaKey(user_id), HttpService:JSONEncode(toPersist))
    end)

    if success then
		PlayerDatastore.MetaData[user_id] = updated
    else
		warn("saveMetaData(): Failed to persist metadata for", player_name)
    end

	return success
end

-- saveGlobalMetaData(): Saves global metadata
local function saveGlobalMetaData(): boolean
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

	local success = pcall(function()
		GlobalDataStore:SetAsync(
			`{Config.DATASTORE.GLOBAL_DATASTORE_KEY}:meta`,
			HttpService:JSONEncode(meta)
		)
	end)

	if success then
		PlayerDatastore.MetaData[Config.DATASTORE.GLOBAL_DATASTORE_KEY] = meta
	else
		warn("saveGlobalMetaData(): Failed to persist; SaveCount not incremented")
	end

	return success
end

--=========================
-- // PRIVATE SNAPSHOT API
--=========================

-- getSnapshotKey(): Returns the snapshot key for a given user_id
-- @param user_id: number | string
-- @return: string
local function getSnapshotKey(user_id: number | string): string
	if type(user_id) == "string" then
		return `snapshot:global`
	end

	return `snapshot:{user_id}`
end

-- loadSnapshots(): Read-only load of all snapshots for a user. Use updateSnapshots for writes.
-- @param user_id: number | string
-- @return: { [string]: Types.SnapshotEntry }
local function loadSnapshots(user_id: number | string): { [string]: Types.SnapshotEntry }
	local data: string? = nil

	local success = pcall(function()
		data = SnapshotDataStore:GetAsync(getSnapshotKey(user_id))
	end)

	if not success then
		warn("loadSnapshots(): Failed to load snapshots for", user_id)
		return {}
	end

	return data and HttpService:JSONDecode(data) or {}
end

-- updateSnapshots(): Atomically updates the snapshots for a user
-- @param user_id: number | string
-- @param updater: (snapshots: { [string]: Types.SnapshotEntry }) -> { [string]: Types.SnapshotEntry }: Transform function
-- @return: boolean: Whether the update succeeded
local function updateSnapshots(user_id: number | string, updater: (snapshots: { [string]: Types.SnapshotEntry }) -> { [string]: Types.SnapshotEntry }): boolean
	local limit = Config.DATASTORE.MAX_SNAPSHOTS_PER_KEY
	local key = getSnapshotKey(user_id)

	local success = pcall(function()
		SnapshotDataStore:UpdateAsync(key, function(existing: string?): string?
			local snapshots: { [string]: Types.SnapshotEntry } = existing and HttpService:JSONDecode(existing) or {}
			snapshots = updater(snapshots)

			local entries: { Types.MetadataSnapshotEntry } = {}
			for name, entry in snapshots do
				table.insert(entries, { Key = name, Timestamp = entry.Timestamp })
			end

			if #entries > limit then
				table.sort(entries, function(a: Types.MetadataSnapshotEntry, b: Types.MetadataSnapshotEntry) return a.Timestamp < b.Timestamp end)

				for i = 1, #entries - limit do
					snapshots[entries[i].Key] = nil
				end
			end

			return HttpService:JSONEncode(snapshots)
		end)
	end)

	if not success then
		warn("updateSnapshots(): Failed for", user_id)
	end

	return success
end

-- runMigrations(): Runs all applicable migrations on a players data
-- @param player: Player
-- @param data: { [any]: any }
-- @param loadedVersion: string
-- @return: { [any]: any }
local function runMigrations(player: Player, data: { [any]: any }, loadedVersion: string): ({ [any]: any }, boolean)
	if loadedVersion == PlayerDatastore.CurrentVersion then
		return data, true
	end

	local migrated = deepClone(data)
	local currentVersion = loadedVersion
	local didMigrate = false

	while currentVersion ~= PlayerDatastore.CurrentVersion do
		local entry = PlayerDatastore.Migrations[currentVersion]

		if not entry then
			warn("runMigrations(): No migration found from", currentVersion, "to", PlayerDatastore.CurrentVersion)
			return data, false
		end

		local snapshotKey = `pre-migration:{currentVersion}:{HttpService:GenerateGUID(false)}`

		local saved = updateSnapshots(player.UserId, function(snapshots)
			snapshots[snapshotKey] = {
				Path = "",
				Data = deepClone(migrated),
				Timestamp = os.time(),
				Version = currentVersion
			}
			return snapshots
		end)

		if not saved then
			warn("runMigrations(): Aborting migration for", player.Name, "; could not save pre-migration snapshot")
			return data, false
		end

		local migrateSuccess, result = pcall(entry.Fn, migrated)
		if not migrateSuccess then
			warn("runMigrations(): Migration function threw for", player.Name, ":", result)
			return data, false
		end

		migrated = result
		currentVersion = entry.To :: string
		didMigrate = true
	end

	if didMigrate then
		warn("runMigrations(): Migrated", player.Name, "from", loadedVersion, "to", currentVersion)
	end

	return migrated, currentVersion == PlayerDatastore.CurrentVersion
end

--=========================
-- // COMPLEX PRIVATE API
--=========================

-- getShardKey(): Returns the shard key for a given path and index
-- @param user_id: number
-- @param path: string
-- @param index: number
-- @return: string
local function getShardKey(user_id: number, path: string, index: number): string
	return `{user_id}:{path}:shard:{index}`
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
		setPath(clone, key, nil)
	end

	return clone
end

-- queueShardRemovals(): Defers obsolete shard deletion until its master record saves
-- @param owner: Player user ID or global datastore key
-- @param oldCount: Previous shard count
-- @param newCount: Replacement shard count
-- @param keyFn: Builds a persistent shard key from its index
local function queueShardRemovals(owner: number | string, oldCount: number, newCount: number, keyFn: (number) -> string): ()
	local pending = PlayerDatastore.PendingShardRemovals[owner] or {}
	for index = 1, newCount do
		pending[keyFn(index)] = nil
	end
	for index = newCount + 1, oldCount do
		pending[keyFn(index)] = true
	end
	if next(pending) then
		PlayerDatastore.PendingShardRemovals[owner] = pending
	else
		PlayerDatastore.PendingShardRemovals[owner] = nil
	end
end

-- cleanupPendingShardRemovals(): Removes queued obsolete shard keys after master save
-- @param owner: Player user ID or global datastore key
-- @return: boolean: Whether every queued shard was removed
local function cleanupPendingShardRemovals(owner: number | string): boolean
	local pending = PlayerDatastore.PendingShardRemovals[owner]
	if not pending then return true end

	local allSucceeded = true
	for shardKey in pending do
		local success = pcall(function()
			ShardedDataStore:RemoveAsync(shardKey)
		end)
		if success then
			pending[shardKey] = nil
			PlayerDatastore.ShardData[shardKey] = nil
		else
			allSucceeded = false
			warn("cleanupPendingShardRemovals(): Failed to remove", shardKey)
		end
	end

	if next(pending) == nil then
		PlayerDatastore.PendingShardRemovals[owner] = nil
	end
	return allSucceeded
end

-- persistShardFields(): Persists all cached shards in the selected fields
-- @param fields: Configured sharded paths
-- @param shouldSkip: Returns true for paths owned by another data set
-- @param getTable: Resolves the in-memory value at a path
-- @param getKey: Builds a persistent shard key from a path and index
-- @return: boolean: Whether every referenced shard was persisted
local function persistShardFields(
	fields: { string },
	shouldSkip: (path: string) -> boolean,
	getTable: (path: string) -> any,
	getKey: (path: string, index: number) -> string
): boolean
	for _, path in fields do
		if shouldSkip(path) then continue end
		local field = getTable(path)
		if not isSharded(field) then continue end

		for index = 1, field.count do
			local shardKey = getKey(path, index)
			local shardData = PlayerDatastore.ShardData[shardKey]
			if not shardData then
				warn("persistShardFields(): Missing cached shard", shardKey)
				return false
			end

			local success = pcall(function()
				ShardedDataStore:SetAsync(shardKey, HttpService:JSONEncode(shardData))
			end)
			if not success then
				warn("persistShardFields(): Failed to persist shard", shardKey)
				return false
			end
		end
	end

	return true
end

--=========================
-- // PRIVATE SAVE / LOAD API
--=========================

-- saveData(): Saves the players data
-- @param player: The player to save the data for
-- @note: Shards unsharded data marked as __sharded; ApplyOperator unshards to apply operations. While doing this, the player could leave, having corrupted sharded data that may exceed the 4MB Key Limit. This fixes it
local function saveData(player: Player?, user_id: number?): boolean
	local userId = if player then player.UserId else user_id
	if not userId then return false end
	if PlayerDatastore.SessionLockLost[userId] then
		warn("saveData(): Refusing to save after session-lock ownership was lost for", userId)
		return false
	end
	local data = PlayerDatastore.PlayerData[userId]
	if not data then return false end

	local shardedFields, globalFields = getPresetFields()

	for _, table_path in shardedFields do
		local tbl = resolvePath(data, table_path)

		if type(tbl) ~= "table" or tbl.__sharded then continue end

		if not player then return false end
		warn("saveData(): Force-sharding", table_path, "for", player.Name)
		PlayerDatastore.Shard(player, table_path, true)
	end

	if not persistShardFields(
		shardedFields,
		function(path) return table.find(globalFields, path) ~= nil end,
		function(path) return resolvePath(data, path) end,
		function(path, index) return getShardKey(userId, path, index) end
	) then
		return false
	end

	local success = pcall(function()
		PlayerDataStore:SetAsync(tostring(userId), HttpService:JSONEncode(data))
	end)

	if not success then
		warn("saveData(): Failed to persist player data for", player and player.Name or userId)
		return false
	end
	if not cleanupPendingShardRemovals(userId) then return false end

	return saveMetaData(userId, player and player.Name or tostring(userId))
end

-- loadData(): Loads the players data
-- @param player: The player to load the data for
-- @return: ({ [any]: any }?, boolean); Loaded Data, if loading failed
local function loadData(player: Player): ({ [any]: any }?, boolean)
	local data: { [any]: any }? = nil

	local success = pcall(function()
		local encoded = PlayerDataStore:GetAsync(tostring(player.UserId))
		data = encoded and HttpService:JSONDecode(encoded) or nil
	end)

	if not success then
		warn("loadData(): Failed to load data for", player.Name)
		return nil, true
	end

	return data, false
end

-- saveGlobalData(): Saves global data to the GlobalDataStore
-- @note: Automatically JSON encodes the value; reshards if needed
local function saveGlobalData(): boolean
	local shardedFields, globalFields = getPresetFields()

	local liveData: { [string]: any }? = nil
	if not PlayerDatastore._localAheadOfMemory then
		local memoryReadSucceeded: boolean
		liveData, memoryReadSucceeded = readMemoryGlobal()
		if not memoryReadSucceeded then return false end
	end
    local dataToSave = {}

    for _, path in globalFields do
        local value: any = nil

		if liveData and readGlobalField(liveData, path) ~= nil then
			value = readGlobalField(liveData, path)
        else
			local tbl = resolvePath(PlayerDatastore.GlobalData, path)
            if isSharded(tbl) then
                local combined = {}
                for i = 1, tbl.count or 0 do
                    local shardKey = getShardGlobalKey(path, i)
                    local shardData = PlayerDatastore.ShardData[shardKey]
					if not shardData then
						warn("saveGlobalData(): Missing shard", shardKey)
						return false
					end
					for k, v in shardData do
						combined[k] = v
                    end
                end
                value = combined
            else
                value = tbl
            end
        end

        if value == nil then continue end

        if table.find(shardedFields, path) and type(value) == "table" then
            if not isSharded(value) then
				setGlobalField(PlayerDatastore.GlobalData, path, value)
                PlayerDatastore.ShardGlobal(path, true)
            end
			dataToSave[path] = resolvePath(PlayerDatastore.GlobalData, path)
        else
            dataToSave[path] = value
        end
    end

	if not persistShardFields(
		shardedFields,
		function(path) return table.find(globalFields, path) == nil end,
		function(path) return resolvePath(PlayerDatastore.GlobalData, path) end,
		function(path, index) return getShardGlobalKey(path, index) end
	) then
		return false
	end

	local success = pcall(function()
        GlobalDataStore:SetAsync(
            Config.DATASTORE.GLOBAL_DATASTORE_KEY,
            HttpService:JSONEncode(dataToSave)
        )
    end)

    if not success then
		warn("saveGlobalData(): Failed to persist global data")
		return false
	end
	if not cleanupPendingShardRemovals(Config.DATASTORE.GLOBAL_DATASTORE_KEY) then return false end

	return saveGlobalMetaData()
end

-- loadGlobalData(): Loads global data from the GlobalDataStore
-- @return: any: Global data
local function loadGlobalData(): (any, boolean)
	local data: any = nil

	local success = pcall(function()
		local encoded = GlobalDataStore:GetAsync(Config.DATASTORE.GLOBAL_DATASTORE_KEY)
		data = encoded and HttpService:JSONDecode(encoded) or {}
	end)

	if not success then
		warn("loadGlobalData(): Failed to load master global key")
		return {}, false
	end

	return data or {}, true
end

--=========================
-- // PRIVATE GLOBAL SYNC HELPER
--=========================

-- reshardGlobalField(): After writing a value into GlobalData, reshard if needed
-- @param table_path: string
-- @param value: any
-- @param shardedFields: { string }
local function reshardGlobalField(table_path: string, value: any, shardedFields: { string }): ()
	if not table.find(shardedFields, table_path) then return end
	if type(value) ~= "table" or value.__sharded then return end

	if next(value) then
		PlayerDatastore.ShardGlobal(table_path, true)
	else
		setPath(PlayerDatastore.GlobalData, table_path, { __sharded = true, count = 0 })
	end
end

-- syncGlobalFromMemory(): Writes liveData fields into GlobalData and reshards as needed
-- @param liveData: { [string]: any }
-- @param globalFields: { string }
-- @param shardedFields: { string }
-- @param skipNil: boolean   if true, skips fields that are nil in liveData (used during init)
local function syncGlobalFromMemory(liveData: { [string]: any }, globalFields: { string }, shardedFields: { string }, skipNil: boolean?): ()
	for _, table_path in globalFields do
		local value = readGlobalField(liveData, table_path)

		if value == nil and skipNil then continue end

		local previous = resolvePath(PlayerDatastore.GlobalData, table_path)
		local oldCount = if isSharded(previous) then previous.count or 0 else 0
		setGlobalField(PlayerDatastore.GlobalData, table_path, value)
		if value ~= nil then
			reshardGlobalField(table_path, value, shardedFields)
		end

		local updated = resolvePath(PlayerDatastore.GlobalData, table_path)
		local newCount = if isSharded(updated) then updated.count or 0 else 0
		queueShardRemovals(Config.DATASTORE.GLOBAL_DATASTORE_KEY, oldCount, newCount, function(index)
			return getShardGlobalKey(table_path, index)
		end)
	end
end

--=========================
-- // PRIVATE SHARD API
--=========================

-- shardTable(): Core shard/unshard logic, shared by Shard() and ShardGlobal()
-- @param getTbl: Reads the current table
-- @param setTbl: Writes back the result
-- @param keyFn: Produces the ShardData key for a given index
-- @param enable: boolean
-- @param label: Used in warnings
local function shardTable(getTbl: () -> { [any]: any }, setTbl: (value: any) -> (), keyFn: (index: number) -> string, enable: boolean, label: string): ()
	local tbl = getTbl()

	if type(tbl) ~= "table" then
		if enable then warn(label, ": Invalid table") end
		return
	end

	if enable then
		local limit = Config.DATASTORE.SHARD_BYTE_LIMIT
		local shards: { [number]: { [any]: any } } = {}
		local current: { [any]: any } = {}
		local shardIndex = 1
		local currentBytes = 0

		for k, v in tbl do
			if k == "__sharded" or k == "count" then continue end

			local addedSize = #HttpService:JSONEncode({ [k] = v })

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

		local actualCount = 0
		for index, shard in shards do
			actualCount = index
			PlayerDatastore.ShardData[keyFn(index)] = shard
		end

		setTbl({ __sharded = true, count = actualCount })
	else
		if not tbl.__sharded then return end

		local combined = {}

		for i = 1, tbl.count do
			local shardKey = keyFn(i)
			local shardData = PlayerDatastore.ShardData[shardKey]

			if not shardData then
				warn(label, ": Missing shard", i, "; Aborting unshard")
				return
			end

			for k, v in shardData do combined[k] = v end
		end

		for i = 1, tbl.count do
			PlayerDatastore.ShardData[keyFn(i)] = nil
		end

		setTbl(combined)
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
	local Limit = max_keys or math.huge
	local ToProcess: { number | string } = {}

	for Key in PlayerDatastore.DirtyData do
		if #ToProcess >= Limit then break end
		table.insert(ToProcess, Key)
	end

	local SaveHandlers: { [string]: (Key: number | string) -> boolean } = {
		["number"] = function(Key: number | string): boolean
			local userId = Key :: number
			if not PlayerDatastore.PlayerData[userId] then return true end
			return saveData(Players:GetPlayerByUserId(userId), userId)
		end,

		["string"] = function(_Key: number | string): boolean
			return saveGlobalData()
		end
	}

	for _, Key in ToProcess do
		if SaveHandlers[type(Key)](Key) then
			PlayerDatastore.DirtyData[Key] = nil
		end
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

	task.spawn(function()
		while true do
			task.wait(math.max(1, Config.DATASTORE.MEMORY_STORE_TTL / 3))
			writeMemoryGlobal(function(current)
				if next(current) == nil then return nil end
				return current
			end)
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
-- @return: (boolean, Types.SessionLockReturnType): Whether the lock was acquired; reason ("OK" | "CONTESTED" | "ERROR")
local function acquireSessionLock(user_id: number): (boolean, Types.SessionLockReturnType)
	local lockKey = getSessionLockKey(user_id)

	for _ = 1, Config.DATASTORE.LOCK_MAX_RETRIES do
		local acquired = false
		local contested = false
		local lock: Types.SessionEntry? = nil
		local success = pcall(function()
			lock = SessionLockStore:UpdateAsync(lockKey, function(existing: Types.SessionEntry?): Types.SessionEntry?
				if existing then
					local isOurs = existing.JobID == game.JobId
					local isStale = (os.time() - (existing.Timestamp or 0)) > Config.DATASTORE.LOCK_STALE_THRESHOLD

					if not isOurs and not isStale then
						contested = true
						return nil
					end
				end

				acquired = true
				return { JobID = game.JobId, Timestamp = os.time() }
			end)
		end)

		if success and acquired and lock and lock.JobID == game.JobId then
			PlayerDatastore.SessionLockLost[user_id] = nil
			PlayerDatastore.SessionLockHeartbeats[user_id] = true
			task.spawn(function()
				while PlayerDatastore.SessionLockHeartbeats[user_id] do
					task.wait(math.max(1, Config.DATASTORE.LOCK_STALE_THRESHOLD / 3))
					if not PlayerDatastore.SessionLockHeartbeats[user_id] then break end

					local renewed = false
					local lost = false
					for attempt = 1, Config.DATASTORE.LOCK_MAX_RETRIES do
						local renewedLock: Types.SessionEntry? = nil
						local belongsElsewhere = false
						local renewalSuccess = pcall(function()
							renewedLock = SessionLockStore:UpdateAsync(lockKey, function(existing: Types.SessionEntry?): Types.SessionEntry?
								if existing and existing.JobID ~= game.JobId then
									belongsElsewhere = true
									return nil
								end
								return { JobID = game.JobId, Timestamp = os.time() }
							end)
						end)

						if renewalSuccess and renewedLock and renewedLock.JobID == game.JobId then
							renewed = true
							break
						end
						if belongsElsewhere or (renewedLock and renewedLock.JobID ~= game.JobId) then
							lost = true
							break
						end
						if attempt < Config.DATASTORE.LOCK_MAX_RETRIES then
							task.wait(Config.DATASTORE.LOCK_RETRY_INTERVAL)
						end
					end

					if lost or not renewed then
						PlayerDatastore.SessionLockHeartbeats[user_id] = nil
						PlayerDatastore.SessionLockLost[user_id] = true
						local player = Players:GetPlayerByUserId(user_id)
						if player then
							warn("acquireSessionLock(): Could not renew session lock for", player.Name)
							player:Kick("[PlayerDatastore]: Your data session could not be secured. Please rejoin.")
						end
						break
					end
				end
			end)

			return true, "OK"
		end
		if success and contested then return false, "CONTESTED" end

		task.wait(Config.DATASTORE.LOCK_RETRY_INTERVAL)
	end

	return false, "ERROR"
end

-- releaseSessionLock(): Releases the session lock for a player
-- @param user_id: number
local function releaseSessionLock(user_id: number): ()
	PlayerDatastore.SessionLockHeartbeats[user_id] = nil
	pcall(function()
		SessionLockStore:UpdateAsync(getSessionLockKey(user_id), function(existing: Types.SessionEntry?): Types.SessionEntry?
			if existing and existing.JobID == game.JobId then return nil end
			return existing
		end)
	end)
end

--=========================
-- // PRIVATE UTILITY API
--=========================

-- readGlobalLocalFallback(): Reads global data from local cache, unsharding if needed
-- @param path: string
-- @return: any
local function readGlobalLocalFallback(path: string): any
    local shardedPath = findShardedPath(PlayerDatastore.GlobalData, path)
    if not shardedPath then
        return resolvePath(PlayerDatastore.GlobalData, path)
    end

    local tbl = resolvePath(PlayerDatastore.GlobalData, shardedPath)
    local combined = {}

    for i = 1, tbl.count do
        local shardKey = getShardGlobalKey(shardedPath, i)
        local shardData = PlayerDatastore.ShardData[shardKey]
		if not shardData then return nil end
		for k, v in shardData do combined[k] = v end
    end

    if shardedPath == path then return combined end

    local remainingPath = path:match("^" .. shardedPath:gsub("%.", "%%.") .. "%.(.*)" ) or ""
    return resolvePath(combined, remainingPath)
end

-- cleanupLoadingState(): Cleans up the loading state for a user, resuming any threads waiting on load
-- @param user_id: number
local function cleanupLoadingState(user_id: number): ()
    PlayerDatastore.LoadingPlayers[user_id] = nil

    local loadQueue = PlayerDatastore.LoadingQueues[user_id]
    if loadQueue then
        for _, thread in loadQueue do
            task.spawn(thread)
        end

        PlayerDatastore.LoadingQueues[user_id] = nil
    end
end

-- cleanupOperationQueues(): Resumes any threads waiting on operation locks and clears user_id in OperationQueues
-- @param user_id: number
local function cleanupOperationQueues(user_id: number): ()
	local queue = PlayerDatastore.OperationQueues[user_id]
	if not queue then return end

	for _, thread in queue do
		task.spawn(thread)
	end

	PlayerDatastore.OperationQueues[user_id] = nil
end

-- cleanupGlobalDataWaiters(): Resumes any threads waiting on global data load and clears the waiters list
local function cleanupGlobalDataWaiters(): ()
	for _, thread in PlayerDatastore._globalDataWaiters do
		task.spawn(thread)
	end

	table.clear(PlayerDatastore._globalDataWaiters)
end

--=========================
-- // PRIVATE INIT API
--=========================

-- onPlayerAdded(): Handles PlayerAdded and everything player data related
-- @param player: Player
-- @param data_table: { [any]: any }: The template data table for the player
-- @param globalFields: { string }: List of global fields to check for sharding
-- @param shardedFields: { string }: List of sharded fields to set up sharding for
local function onPlayerAdded(player: Player, data_table: { [any]: any }, globalFields: { string }, shardedFields: { string }): ()
	if PlayerDatastore.LoadingPlayers[player.UserId] or PlayerDatastore.PlayerData[player.UserId] then
		return
	end

	PlayerDatastore.LoadingPlayers[player.UserId] = true

	local locked, lockReason = acquireSessionLock(player.UserId)

	if not Players:GetPlayerByUserId(player.UserId) then
		if locked then releaseSessionLock(player.UserId) end
		PlayerDatastore.MetaData[player.UserId] = nil
		cleanupLoadingState(player.UserId)
		return
	end

	if not locked then
		if lockReason == "CONTESTED" then
			player:Kick("[PlayerDatastore]: Your data is still being saved from another server. Please rejoin in a moment.")
		else
			player:Kick("[PlayerDatastore]: Could not verify your session due to a temporary error. Please rejoin.")
		end

		warn("onPlayerAdded(): Failed to acquire lock for", player.Name, "- Reason:", lockReason)

		PlayerDatastore.MetaData[player.UserId] = nil
		cleanupLoadingState(player.UserId)
		return
	end

	if PlayerDatastore.PlayerData[player.UserId] then
		warn("onPlayerAdded(): PlayerData still present for", player.Name, ". Kicking")
		player:Kick("[PlayerDatastore]: Your previous session is still being saved. Please rejoin in a moment.")

		releaseSessionLock(player.UserId)

		PlayerDatastore.MetaData[player.UserId] = nil
		cleanupLoadingState(player.UserId)
		return
	end

	local loadedMeta, metaLoadSucceeded = loadMetaData(player)
	if not metaLoadSucceeded then
		player:Kick("[PlayerDatastore]: Failed to load your metadata. Please rejoin.")
		releaseSessionLock(player.UserId)
		cleanupLoadingState(player.UserId)
		return
	end

	PlayerDatastore.MetaData[player.UserId] = {
		LastSaved = loadedMeta and loadedMeta.LastSaved or os.time(),
		ServerId = game.JobId,
		SaveCount = loadedMeta and loadedMeta.SaveCount or 0,
		FirstJoined = loadedMeta and loadedMeta.FirstJoined or os.time(),
		TotalPlaytime = loadedMeta and loadedMeta.TotalPlaytime or 0,
		DataVersion = loadedMeta and loadedMeta.DataVersion or PlayerDatastore.CurrentVersion,
		_SessionStart = os.time()
	}

	local data, loadFailed = loadData(player)

	if not Players:GetPlayerByUserId(player.UserId) then
		releaseSessionLock(player.UserId)

		PlayerDatastore.MetaData[player.UserId] = nil
		cleanupLoadingState(player.UserId)
		return
	end

	if loadFailed then
		player:Kick("[PlayerDatastore]: Failed to load your data. Please rejoin.")

		releaseSessionLock(player.UserId)

		PlayerDatastore.MetaData[player.UserId] = nil
		cleanupLoadingState(player.UserId)
		return
	end

	local playerTemplate = stripGlobalFields(data_table, globalFields)
	PlayerDatastore.PlayerData[player.UserId] = data and reconcileData(data, playerTemplate) or playerTemplate
	local initializedShardDefaults = false
	local shardLoadFailed = false
	local loadedShardKeys: { string } = {}

	for _, table_path in shardedFields do
		if shardLoadFailed then break end
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
			PlayerDatastore.Shard(player, table_path, true)
			initializedShardDefaults = true
			continue
		end

		for i = 1, tbl.count do
			local shardKey = getShardKey(player.UserId, table_path, i)

			local success, shardDataOrError = pcall(function()
				return ShardedDataStore:GetAsync(shardKey)
			end)

			if not success then
				warn(`[PlayerDatastore]: Shard load failed for {player.Name} | key={shardKey} | error={shardDataOrError}`)
				shardLoadFailed = true
				break
			end

			if not shardDataOrError then
				warn(`[PlayerDatastore]: Missing shard {shardKey} for {player.Name}`)
				shardLoadFailed = true
				break
			end

			local decodeSuccess, decoded = pcall(HttpService.JSONDecode, HttpService, shardDataOrError)
			if not decodeSuccess then
				warn(`[PlayerDatastore]: JSON decode failed for shard {shardKey} | player={player.Name}`)
				shardLoadFailed = true
				break
			end

			PlayerDatastore.ShardData[shardKey] = decoded
			table.insert(loadedShardKeys, shardKey)
		end
	end

	if shardLoadFailed then
		for _, shardKey in loadedShardKeys do
			PlayerDatastore.ShardData[shardKey] = nil
		end
		PlayerDatastore.PlayerData[player.UserId] = nil
		PlayerDatastore.MetaData[player.UserId] = nil
		releaseSessionLock(player.UserId)
		player:Kick("[PlayerDatastore]: Failed to load all of your data. Please rejoin.")
		cleanupLoadingState(player.UserId)
		return
	end

	if initializedShardDefaults then
		markDirty(player.UserId)
	end

	if loadedMeta then
		local loadedVersion = loadedMeta.DataVersion or PlayerDatastore.CurrentVersion

		if loadedVersion ~= PlayerDatastore.CurrentVersion then
			for _, table_path in shardedFields do
				if table.find(globalFields, table_path) then continue end
				PlayerDatastore.Shard(player, table_path, false)
			end

			local migratedData, migrationSucceeded = runMigrations(
				player,
				PlayerDatastore.PlayerData[player.UserId],
				loadedVersion
			)
			PlayerDatastore.PlayerData[player.UserId] = migratedData

			if migrationSucceeded then
				PlayerDatastore.MetaData[player.UserId].DataVersion = PlayerDatastore.CurrentVersion
				markDirty(player.UserId)
			end

			for _, table_path in shardedFields do
				if table.find(globalFields, table_path) then continue end
				PlayerDatastore.Shard(player, table_path, true)
			end
		end
	end

	cleanupLoadingState(player.UserId)
end

-- onGlobalSetup(): Loads and sets up everything global related
-- @param data_table: { [any]: any }: The template data table for the player
-- @param globalFields: { string }: List of global fields to check for sharding
-- @param shardedFields: { string }: List of sharded fields to set up sharding for
local function onGlobalSetup(data_table: { [any]: any }, globalFields: { string }, shardedFields: { string }): boolean
	local globalData, globalLoadSucceeded = loadGlobalData()
	if not globalLoadSucceeded then return false end
	local globalMeta: Types.MetaData? = nil

	local metaSuccess = pcall(function()
		local raw = GlobalDataStore:GetAsync(`{Config.DATASTORE.GLOBAL_DATASTORE_KEY}:meta`)
		if not raw then return end

		globalMeta = HttpService:JSONDecode(raw)
	end)

	if metaSuccess and globalMeta then
		PlayerDatastore.MetaData[Config.DATASTORE.GLOBAL_DATASTORE_KEY] = globalMeta
	end

	local globalMemoryState = {}
	local shardLoadFailed = false

	for _, table_path in globalFields do
		if shardLoadFailed then break end
		local loadedValue = globalData[table_path]
		local defaultValue = resolvePath(data_table, table_path)

		if defaultValue == nil then
			warn("onGlobalSetup(): Global field not found in data template:", table_path)
			continue
		end

		local reconciled: { [any]: any } = {}

		if type(loadedValue) == "table" and loadedValue.__sharded then
			local combined = {}

			for i = 1, loadedValue.count or 0 do
				local shardKey = getShardGlobalKey(table_path, i)

				local success, shardData = pcall(function()
					return ShardedDataStore:GetAsync(shardKey)
				end)

				if not success then
					warn(`[PlayerDatastore] Global shard load failed for {table_path} | key={shardKey} | error={shardData}`)
					shardLoadFailed = true
					break
				end

				if not shardData then
					warn(`[PlayerDatastore] Global shard missing for {table_path} | key={shardKey}`)
					shardLoadFailed = true
					break
				end

				local decodeSuccess, decoded = pcall(HttpService.JSONDecode, HttpService, shardData)
				if not decodeSuccess then
					warn(`[PlayerDatastore] Global shard JSON decode failed for {shardKey}`)
					shardLoadFailed = true
					break
				end
				for k, v in decoded do
					combined[k] = v
				end
			end

			reconciled = combined
		else
			reconciled = reconcileData(loadedValue, defaultValue)
		end

		setGlobalField(PlayerDatastore.GlobalData, table_path, reconciled)

		if table.find(shardedFields, table_path) and not reconciled.__sharded then
			if next(reconciled) then
				PlayerDatastore.ShardGlobal(table_path, true)
			else
				setPath(PlayerDatastore.GlobalData, table_path, {
					__sharded = true,
					count = 0
				})
			end
		end

		setGlobalField(globalMemoryState, table_path, reconciled)
	end

	if shardLoadFailed then
		return false
	end

	local syncedFromMemory: { [string]: any }? = nil

	writeMemoryGlobal(function(current): { [string]: any }?
		if not current or next(current) == nil then
			return globalMemoryState
		end

		syncedFromMemory = current

		return nil
	end)

	if syncedFromMemory then
		local diskCounts: { [string]: number } = {}
		for _, table_path in globalFields do
			local tbl = resolvePath(PlayerDatastore.GlobalData, table_path)
			if isSharded(tbl) then
				diskCounts[table_path] = tbl.count or 0
			end
		end

		syncGlobalFromMemory(syncedFromMemory, globalFields, shardedFields, true)

		for table_path, oldCount in diskCounts do
			local newTbl = resolvePath(PlayerDatastore.GlobalData, table_path)
			local newCount = isSharded(newTbl) and (newTbl.count or 0) or 0

			for i = newCount + 1, oldCount do
				PlayerDatastore.ShardData[getShardGlobalKey(table_path, i)] = nil
			end
		end
	end

	return true
end

--=========================
-- // PUBLIC API
--=========================

-- Init(): Initialize the datastore handler
-- @param data_table: { [any]: any }
-- @param presets: Types.PresetOptions?
function PlayerDatastore.Init(data_table: { [any]: any }, presets: Types.PresetOptions?): ()
	if PlayerDatastore._initialized then
		warn("Init(): PlayerDatastore is already initialized")
		return
	end

	PlayerDatastore.Presets = presets

	local shardedFields: { string } = presets and presets.ShardedFields or {}
	local globalFields: { string } = presets and presets.GlobalFields or {}
	if not onGlobalSetup(data_table, globalFields, shardedFields) then
		error("Init(): Global shard load failed; initialization aborted")
	end

	Players.PlayerAdded:Connect(function(player)
		onPlayerAdded(player, data_table, globalFields, shardedFields)
	end)

	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player, data_table, globalFields, shardedFields)
	end

	Players.PlayerRemoving:Connect(function(player)
		PlayerDatastore.LoadingPlayers[player.UserId] = nil

		local saved: boolean
		if PlayerDatastore.DirtyData[player.UserId] then
			saved = saveData(player, player.UserId)
		else
			saved = saveMetaData(player.UserId, player.Name)
		end

		if saved then
			PlayerDatastore.DirtyData[player.UserId] = nil
			releaseSessionLock(player.UserId)
			PlayerDatastore.PlayerData[player.UserId] = nil
			PlayerDatastore.MetaData[player.UserId] = nil
		else
			markDirty(player.UserId)
			warn("PlayerRemoving: Retaining unsaved data for retry", player.Name)
		end

		cleanupLoadingState(player.UserId)
		cleanupOperationQueues(player.UserId)
	end)

	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			if not PlayerDatastore.PlayerData[player.UserId] then
				releaseSessionLock(player.UserId)
				continue
			end

			local saved: boolean
			if PlayerDatastore.DirtyData[player.UserId] then
				saved = saveData(player, player.UserId)
			else
				saved = saveMetaData(player.UserId, player.Name)
			end

			if saved then
				PlayerDatastore.DirtyData[player.UserId] = nil
				releaseSessionLock(player.UserId)
			else
				markDirty(player.UserId)
				warn("BindToClose: Could not fully save data for", player.Name)
			end

			cleanupOperationQueues(player.UserId)
		end

		for attempt = 1, Config.DATASTORE.LOCK_MAX_RETRIES do
			flushDirty()
			if next(PlayerDatastore.DirtyData) == nil then break end
			if attempt < Config.DATASTORE.LOCK_MAX_RETRIES then
				task.wait(Config.DATASTORE.LOCK_RETRY_INTERVAL)
			end
		end

		for _, player in Players:GetPlayers() do
			if not PlayerDatastore.DirtyData[player.UserId] then
				releaseSessionLock(player.UserId)
			end
		end
	end)

	PlayerDatastore._initialized = true

	cleanupGlobalDataWaiters()

	startAutosave()
end

-- Read(): Reads the players data, unshards if sharded
-- @param player: The player to read the data for
-- @param table_path: The path to the table to read
-- @return: { [any]: any }
function PlayerDatastore.Read(player: Player, table_path: string): { [any]: any }?
	yieldPlayerData(player.UserId)

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

			if not shardData then
				warn("Read(): Missing shard", shardKey, "for", player.Name)
				return nil
			end

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

-- ApplyOperator(): Applies an operation to a players data
-- @param player: The player who is doing the operation
-- @param operation: Types.OperationType (value_name, value = transform)
function PlayerDatastore.ApplyOperator(player: Player, operation: Types.OperationType): ()
	yieldPlayerData(player.UserId)
	if PlayerDatastore.SessionLockLost[player.UserId] then
		warn("ApplyOperator(): Refusing operation after session-lock ownership was lost for", player.Name)
		return
	end

	local ok = acquireOperationLock(player.UserId)
	if not ok then return end

	local data = PlayerDatastore.PlayerData[player.UserId]
	if not data then
		warn("ApplyOperator(): No data for player:", player.Name, "; Operation dropped")
		releaseOperationLock(player.UserId)
		return
	end

	local shardedPath = findShardedPath(data, operation.value_name)
	local prevShardCount = 0

	if shardedPath then
		local shardedTable = resolvePath(data, shardedPath)
		prevShardCount = shardedTable.count or 0
		local combined = {}
		local missingShard = false

		for i = 1, prevShardCount do
			local shardKey = getShardKey(player.UserId, shardedPath, i)
			local shardData = PlayerDatastore.ShardData[shardKey]

			if not shardData then
				missingShard = true
				break
			end
			for k, v in shardData do combined[k] = v end
		end

		if missingShard then
			warn("ApplyOperator(): Missing shard for", player.Name, "; operation dropped")
			releaseOperationLock(player.UserId)
			return
		end

		for i = 1, prevShardCount do
			PlayerDatastore.ShardData[getShardKey(player.UserId, shardedPath, i)] = nil
		end

		setPath(data, shardedPath, combined)
	end

	local success, failure = pcall(function()
		local currentValue = resolvePath(data, operation.value_name)
		if currentValue == nil then
			error(`ApplyOperator(): Couldn't find value: {operation.value_name}`)
		end

		local newValue = operation.value(currentValue)
		setPath(data, operation.value_name, newValue)
	end)

	if not success then
		warn("ApplyOperator(): Failed to apply operation for", player.Name, ":", failure)

		if shardedPath then
			PlayerDatastore.Shard(player, shardedPath, true)
		end

		releaseOperationLock(player.UserId)
		return
	end

	markDirty(player.UserId)

	if shardedPath then
		PlayerDatastore.Shard(player, shardedPath, true)

		local newTable = resolvePath(data, shardedPath)
		local newCount = newTable and newTable.count or 0
		queueShardRemovals(player.UserId, prevShardCount, newCount, function(index)
			return getShardKey(player.UserId, shardedPath, index)
		end)
	end

	releaseOperationLock(player.UserId)
end

-- DeletePlayerData(): Deletes a players data
-- @param player: The player to delete data for
-- @note: This will kick the player after deleting their data, use with caution
function PlayerDatastore.DeletePlayerData(player: Player): ()
	yieldPlayerData(player.UserId)
	if PlayerDatastore.SessionLockLost[player.UserId] then
		warn("DeletePlayerData(): Refusing deletion after session-lock ownership was lost for", player.Name)
		return
	end

	local user_id = player.UserId

	cleanupOperationQueues(player.UserId)

	local shardedFields, globalFields = getPresetFields()

	for _, table_path in shardedFields do
		if table.find(globalFields, table_path) then continue end

		local data = PlayerDatastore.PlayerData[user_id]
		if data then
			local tbl = resolvePath(data, table_path)
			if not isSharded(tbl) then continue end

			for i = 1, tbl.count do
				local shardKey = getShardKey(user_id, table_path, i)
				PlayerDatastore.ShardData[shardKey] = nil

				pcall(function()
					ShardedDataStore:RemoveAsync(shardKey)
				end)
			end
		end
	end

	PlayerDatastore.DirtyData[user_id] = nil
	PlayerDatastore.PlayerData[user_id] = nil
	PlayerDatastore.MetaData[user_id] = nil

	pcall(function()
		PlayerDataStore:RemoveAsync(tostring(user_id))
	end)

	pcall(function()
		PlayerMetaDataStore:RemoveAsync(getMetaKey(user_id))
	end)

	releaseSessionLock(player.UserId)
	player:Kick("[PlayerDatastore]: Your data has been deleted. Please rejoin.")
end

-- DeleteGlobalData(): Deletes a global data key and its shards
-- @param path: The global key to delete
-- @note: This almost should NEVER be used, proceed with caution
function PlayerDatastore.DeleteGlobalData(path: string): ()
	yieldGlobalData()

	local _, globalFields = getPresetFields()

	if not table.find(globalFields, path) then
		warn("DeleteGlobalData(): Path is not a valid global field:", path)
		return
	end

	local tbl = resolvePath(PlayerDatastore.GlobalData, path)

	if isSharded(tbl) then
		queueShardRemovals(Config.DATASTORE.GLOBAL_DATASTORE_KEY, tbl.count, 0, function(index)
			return getShardGlobalKey(path, index)
		end)
	end

	setGlobalField(PlayerDatastore.GlobalData, path, nil)
	PlayerDatastore.MetaData[path] = nil

	local memorySuccess, memoryCommitted = writeMemoryGlobal(function(current): { [string]: any }
		setGlobalField(current, path, nil)
		return current
	end)

	if not memorySuccess then
		PlayerDatastore._localAheadOfMemory = true
	elseif not memoryCommitted then
		warn("DeleteGlobalData(): Deletion was not committed to MemoryStore")
		return
	end

	markDirty(Config.DATASTORE.GLOBAL_DATASTORE_KEY)
	if saveGlobalData() then
		PlayerDatastore.DirtyData[Config.DATASTORE.GLOBAL_DATASTORE_KEY] = nil
	end
end

--=========================
-- // COMPLEX OPERATIONS
--=========================

-- Shard(): Enables sharding for a table path (Check Config.DATASTORE.SHARD_BYTE_LIMIT)
-- @param player: The player to shard
-- @param table_path: Path to the table
-- @param enable: Whether to enable it
-- @note: Disabling while having a sharded table will result in all of the tables combining, likely leading to errors
-- @note: The first entry will always be put, no matter how large it is, subsequent data will be sharded
function PlayerDatastore.Shard(player: Player, table_path: string, enable: boolean): ()
	local data = PlayerDatastore.PlayerData[player.UserId]

	if not data then
		warn("Shard(): Couldn't find data for player:", player.Name)
		return
	end
	local previous = resolvePath(data, table_path)
	local oldCount = if isSharded(previous) then previous.count or 0 else 0

	shardTable(
		function() return resolvePath(data, table_path) end,
		function(value) setPath(data, table_path, value) end,
		function(index) return getShardKey(player.UserId, table_path, index) end,
		enable,
		`Shard({table_path})`
	)

	if enable then
		local updated = resolvePath(data, table_path)
		local newCount = if isSharded(updated) then updated.count or 0 else 0
		queueShardRemovals(player.UserId, oldCount, newCount, function(index)
			return getShardKey(player.UserId, table_path, index)
		end)
	end
end

-- ShardGlobal(): Enables sharding for a global table path
-- @param path: The global key pointing to the table
-- @param enable: Whether to enable sharding
-- @note: Automatically handles unshard + reshard
function PlayerDatastore.ShardGlobal(path: string, enable: boolean): ()
	local previous = resolvePath(PlayerDatastore.GlobalData, path)
	local oldCount = if isSharded(previous) then previous.count or 0 else 0
	shardTable(
		function() return resolvePath(PlayerDatastore.GlobalData, path) end,
		function(value) setPath(PlayerDatastore.GlobalData, path, value) end,
		function(index) return getShardGlobalKey(path, index) end,
		enable,
		`ShardGlobal({path})`
	)

	if enable then
		local updated = resolvePath(PlayerDatastore.GlobalData, path)
		local newCount = if isSharded(updated) then updated.count or 0 else 0
		queueShardRemovals(Config.DATASTORE.GLOBAL_DATASTORE_KEY, oldCount, newCount, function(index)
			return getShardGlobalKey(path, index)
		end)
	end
end

--=========================
-- // GLOBAL OPERATIONS
--=========================

-- ReadGlobal(): Reads a global table or value, unshards if needed
-- @param path: The global key or nested path to read
-- @return: any: The value stored globally
function PlayerDatastore.ReadGlobal(path: string): any
    yieldGlobalData()

    if PlayerDatastore._localAheadOfMemory then
        return readGlobalLocalFallback(path)
    end

    local liveData, fetchOk = readMemoryGlobal()

    if not fetchOk then
        warn("ReadGlobal(): MemoryStore fetch failed, falling back to local cache")
        return readGlobalLocalFallback(path)
    end

    if not liveData then
        return readGlobalLocalFallback(path)
    end

	return readGlobalField(liveData, path)
end

-- ApplyOperatorGlobal(): Applies an operation to a global table
-- @param operation: Types.OperationType (value_name, value = transform)
function PlayerDatastore.ApplyOperatorGlobal(operation: Types.OperationType): ()
	yieldGlobalData()

	local shardedFields, globalFields = getPresetFields()
	local validGlobalPath = false
	for _, globalPath in globalFields do
		local suffix = operation.value_name:sub(#globalPath + 1)
		if operation.value_name == globalPath or suffix:sub(1, 1) == "." or suffix:sub(1, 1) == "[" then
			validGlobalPath = true
			break
		end
	end

	if not validGlobalPath then
		warn("ApplyOperatorGlobal(): Path doesn't start with a valid global field:", operation.value_name)
		return
	end

	local liveData: { [string]: any }? = nil

	local success, committed = writeMemoryGlobal(function(current): { [string]: any }?
		local base: { [string]: any }

		base = {}
		for _, path in globalFields do
			local value = if PlayerDatastore._localAheadOfMemory then readGlobalLocalFallback(path) else readGlobalField(current, path)
			if value ~= nil then
				setGlobalField(base, path, value)
			end
		end

		local currentValue = resolvePath(base, operation.value_name)
		if currentValue == nil then
			warn("ApplyOperatorGlobal(): Couldn't find value:", operation.value_name)
			return nil
		end

		setPath(base, operation.value_name, operation.value(currentValue))
		liveData = base
		return base
	end)

	if not success then
		PlayerDatastore._localAheadOfMemory = true

		warn("ApplyOperatorGlobal(): MemoryStore unavailable, applying to local cache only. State may differ across servers until MemoryStore recovers")

		local shardedPath = findShardedPath(PlayerDatastore.GlobalData, operation.value_name)
		if shardedPath then
			PlayerDatastore.ShardGlobal(shardedPath, false)
			if isSharded(resolvePath(PlayerDatastore.GlobalData, shardedPath)) then
				warn("ApplyOperatorGlobal(): Missing shard for", shardedPath, "; operation dropped")
				return
			end
		end

		local currentValue = resolvePath(PlayerDatastore.GlobalData, operation.value_name)
		if currentValue == nil then
			warn("ApplyOperatorGlobal(): Couldn't find value in local cache:", operation.value_name)
			if shardedPath then PlayerDatastore.ShardGlobal(shardedPath, true) end
			return
		end

		setPath(PlayerDatastore.GlobalData, operation.value_name, operation.value(currentValue))
		if shardedPath then PlayerDatastore.ShardGlobal(shardedPath, true) end

		markDirty(Config.DATASTORE.GLOBAL_DATASTORE_KEY)
		return
	end

	if not committed then
		warn("ApplyOperatorGlobal(): Operation failed to commit, operation not applied")
		return
	end

	PlayerDatastore._localAheadOfMemory = false

	if not liveData then
		markDirty(Config.DATASTORE.GLOBAL_DATASTORE_KEY)
		return
	end

	syncGlobalFromMemory(liveData, globalFields, shardedFields)

	markDirty(Config.DATASTORE.GLOBAL_DATASTORE_KEY)
end

--=========================
-- // UTILITY API
--=========================

-- GetPlayerData(): Gets a players data
-- @param player: The player to get data for
-- @return: { [any]: any }?
function PlayerDatastore.GetPlayerData(player: Player): { [any]: any }?
	yieldPlayerData(player.UserId)
	return PlayerDatastore.PlayerData[player.UserId]
end

-- GetShardData(): Gets a shards data
-- @param player: The player to check yield for
-- @param key?: Optional Key to get shard data for; else returns the entire table
-- @return: { [string]: any } | any
function PlayerDatastore.GetShardData(player: Player, key: string?): { [string]: any } | any
	yieldPlayerData(player.UserId)
	return if key then PlayerDatastore.ShardData[key] else PlayerDatastore.ShardData
end

-- GetGlobalData(): Gets the global data
-- @param table_path?: The path to the table to get; else returns the entire table
-- @return: { [string]: any } | any
function PlayerDatastore.GetGlobalData(table_path: string?): { [string]: any } | any
    yieldGlobalData()
	return if table_path then resolvePath(PlayerDatastore.GlobalData, table_path) else PlayerDatastore.GlobalData
end

--=========================
-- // METADATA API
--=========================

-- GetMetadata(): Gets metadata for a player or global data
-- @param player?: The player to get metadata for; if nil returns global metadata
-- @return: Types.MetaData?
function PlayerDatastore.GetMetadata(player: Player?): Types.MetaData?
	if player then
		yieldPlayerData(player.UserId)
		return PlayerDatastore.MetaData[player.UserId]
	end

	yieldGlobalData()

	return PlayerDatastore.MetaData[Config.DATASTORE.GLOBAL_DATASTORE_KEY]
end

--=========================
-- // VERSIONING API
--=========================

-- RegisterMigration(): Registers a migration function for a version transition
-- @param from_version: string
-- @param to_version: string
-- @param migration: Types.MigrationFunction
-- @note: Only linear chains are supported, one outgoing migration per source version
-- @note: If ShardedFields changed between versions, manually unshard affected fields inside the migration function before transforming them, as only current ShardedFields are automatically unsharded before migration runs
function PlayerDatastore.RegisterMigration(from_version: string, to_version: string, migration: Types.MigrationFunction): ()
	if PlayerDatastore.Migrations[from_version] then
		error(`RegisterMigration(): A migration from '{from_version}' already exists. Only linear chains are supported.`)
	end

	PlayerDatastore.Migrations[from_version] = { To = to_version, Fn = migration }
end

--=========================
-- // SNAPSHOT API
--=========================

-- CreateSnapshot(): Creates a named snapshot of a path in a players data or global data (NOTE: Sharded data will be unsharded in the snapshot, and restoring will restore it as sharded)
-- @param name: string
-- @param path: string
-- @param player?: Player; if nil snapshots global data at path
function PlayerDatastore.CreateSnapshot(name: string, path: string, player: Player?): ()
	local user_id: (number | string)? = nil
	local value: any = nil

	if player then
		user_id = player.UserId
		value = PlayerDatastore.Read(player, path)
	else
		yieldGlobalData()
		user_id = Config.DATASTORE.GLOBAL_DATASTORE_KEY

		if PlayerDatastore._localAheadOfMemory then
			value = readGlobalLocalFallback(path)
		else
			local liveData, _ = readMemoryGlobal()
			value = if liveData then readGlobalField(liveData, path) else readGlobalLocalFallback(path)
		end
	end

	if value == nil then
		warn("CreateSnapshot(): Path not found:", path)
		return
	end

	local snapshot: Types.SnapshotEntry = {
		Path = path,
		Data = deepClone(value),
		Timestamp = os.time(),
		Version = PlayerDatastore.CurrentVersion
	}

	updateSnapshots(user_id :: number | string, function(snapshots)
		snapshots[name] = snapshot
		return snapshots
	end)
end

-- RestoreSnapshot(): Restores a named snapshot, overwriting current data at that path
-- @param name: string
-- @param player?: Player; if nil restores global data
function PlayerDatastore.RestoreSnapshot(name: string, player: Player?): ()
	local user_id: (number | string)? = nil

	if player then
		user_id = player.UserId
	else
		yieldGlobalData()
		user_id = Config.DATASTORE.GLOBAL_DATASTORE_KEY
	end

	local snapshots = loadSnapshots(user_id :: number | string)
	local snapshot = snapshots[name]

	if not snapshot then
		warn("RestoreSnapshot(): Snapshot not found:", name)
		return
	end

	if player then
		local data = PlayerDatastore.PlayerData[user_id :: number]
		if not data then
			warn("RestoreSnapshot(): No player data found for", player.Name)
			return
		end

		if snapshot.Path == "" then
			PlayerDatastore.PlayerData[user_id :: number] = deepClone(snapshot.Data)
		else
			setPath(data, snapshot.Path, deepClone(snapshot.Data))
		end

		local shardedFields, globalFields = getPresetFields()

		if snapshot.Path ~= "" and table.find(shardedFields, snapshot.Path) and not table.find(globalFields, snapshot.Path) then
			PlayerDatastore.Shard(player, snapshot.Path, true)
		end

		markDirty(user_id :: number | string)
	else
		local success, committed = writeMemoryGlobal(function(current): { [string]: any }
			if snapshot.Path == "" then
				return deepClone(snapshot.Data)
			end

			setGlobalField(current, snapshot.Path, deepClone(snapshot.Data))

			return current
		end)

		if not success then
			warn("RestoreSnapshot(): Failed to restore global snapshot:", name)
			return
		end

		if not committed then
			warn("RestoreSnapshot(): Operation failed to commit, operation not applied")
			return
		end

		PlayerDatastore._localAheadOfMemory = false

		local liveData, _ = readMemoryGlobal()
		if liveData then
			local shardedFields, globalFields = getPresetFields()
			syncGlobalFromMemory(liveData, globalFields, shardedFields)
		end

		markDirty(Config.DATASTORE.GLOBAL_DATASTORE_KEY)
	end
end

-- DeleteSnapshot(): Deletes a named snapshot
-- @param name: string
-- @param player?: Player; if nil deletes from global snapshots
function PlayerDatastore.DeleteSnapshot(name: string, player: Player?): ()
	local user_id: (number | string)? = nil

	if player then
		user_id = player.UserId
	else
		yieldGlobalData()
		user_id = Config.DATASTORE.GLOBAL_DATASTORE_KEY
	end

	updateSnapshots(user_id :: number | string, function(snapshots)
		if not snapshots[name] then
			warn("DeleteSnapshot(): Snapshot not found:", name)
			return snapshots
		end

		snapshots[name] = nil
		return snapshots
	end)
end

-- ListSnapshots(): Lists all snapshots for a player or global
-- @param player?: Player; if nil lists global snapshots
-- @return: { [string]: Types.SnapshotEntry }?
function PlayerDatastore.ListSnapshots(player: Player?): { [string]: Types.SnapshotEntry }?
	local user_id: (number | string)? = nil

	if player then
		user_id = player.UserId
	else
		yieldGlobalData()
		user_id = Config.DATASTORE.GLOBAL_DATASTORE_KEY
	end

	return loadSnapshots(user_id :: number | string)
end

--=========================
-- // INIT
--=========================

task.delay(Config.DATASTORE.INIT_YIELD_TIME, function()
	if PlayerDatastore._initialized then return end

	warn("PlayerDatastore: Init() was not called within INIT_YIELD_TIME; Unblocking all waiters")

	cleanupGlobalDataWaiters()
end)

return PlayerDatastore