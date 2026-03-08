--!strict

--=========================
-- // OPERATIONS
--=========================

local OPERATION_CASES: { [string]: (any, any) -> any } = {
	["+"] = function(a: number, b: number): number return a + b end,
	["-"] = function(a: number, b: number): number return a - b end,
	["*"] = function(a: number, b: number): number return a * b end,
	["/"] = function(a: number, b: number): number return a / b end,
	["SET"] = function(a: number, b: number): number return b end,

	-- @operator INSERT: Inserts a KV pair into a KV pair table
	-- @param a: { [any]: any }
	-- @param b: { [any]: any }
	-- @return a
	["INSERT"] = function(a: { [any]: any }, b: { [any]: any }): { [any]: any }
		for k, v in b do
			a[k] = v
		end

		return a
	end,

	-- @operator PUSH: table.insert(); Use for arrays
	-- @param a: { any }
	-- @param b: any
	-- @return a
	["PUSH"] = function(a: { any }, b: any): { any }
		table.insert(a, b)

		return a
	end,

	-- @operator DELETE: Deletes a key from a table
	-- @param a: { [any]: any }
	-- @param b: any
	-- @return a
	["DELETE"] = function(a: { [any]: any }, b: any): { [any]: any }
		a[b] = nil

		return a
	end
}

--=========================
-- // RETURN
--=========================

return {
	DATASTORE = {
		DATASTORE_NAME = "PlayerDatastore", -- // string: Name of the datastore
		SHARDED_DATASTORE_NAME = "ShardDatastore", -- // string: Name of the sharded datastore
		GLOBAL_DATASTORE_NAME = "GlobalDatastore", -- // string: Name of the global datastore
		LOCK_DATASTORE_NAME = "SessionLocks", -- // string: Name of the lock datastore
		PLAYER_METADATA_STORE_NAME = "PlayerMetaDatastore", -- // string: Name of the player metadata datastore (Global data metadata stored in GLOBAL_DATASTORE_NAME)
		SNAPSHOT_DATASTORE_NAME = "SnapshotDatastore", -- // string: Name of the snapshot datastore

		GLOBAL_HASHMAP_NAME = "GlobalMemoryData", -- // string: MemoryStoreHashMap that will solve conflicts between multiple server .ApplyOperatorGlobal() calls
		GLOBAL_DATASTORE_KEY = "GlobalData", -- // string: Key where all global data is stored
		MEMORY_STORE_KEY = "GlobalMemory", -- // string: Key for MemoryStore to solve global data conflicts

		SHARD_BYTE_LIMIT = 1000000, -- // number: Amount of bytes to intake before starting a new key; (JSON Encoded, Per Char)

		AUTOSAVE_INTERVAL = 30, -- // number: Time in seconds between each autosave
		MAX_KEYS_PER_AUTOSAVE = 50, -- // number: Max amount of keys to save per autosave

		INIT_YIELD_TIME = 5, -- // number: Time in seconds to wait for everything to be initalized

		LOCK_MAX_RETRIES = 3, -- // number: Amount of times to retry acquiring a lock before kicking the player
		LOCK_RETRY_INTERVAL = 2, -- // number: Time in seconds between each lock retry

		MEMORY_STORE_TTL = 3600, -- // number: Time in seconds for MemoryStore entries to live before expiring

		LOCK_STALE_THRESHOLD = 120, -- // number: Time in seconds for a lock to be considered stale

		MAX_SNAPSHOTS_PER_KEY = 10, -- // number: Max amount of snapshots to keep per key; Old snapshots are removed when limit is reached
	},

	OPERATION_CASES = OPERATION_CASES
}