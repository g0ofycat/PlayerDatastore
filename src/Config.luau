--!strict

--=========================
-- // SIGNAL
--=========================

local Signal = require("./Utility/Signal")

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
-- // MAIN
--=========================

return {
	DATASTORE = {
		DATASTORE_NAME = "PlayerDatastore", -- // string: Name of the datastore
		SHARDED_DATASTORE_NAME = "ShardDatastore", -- // string: Name of the sharded datastore
		GLOBAL_DATASTORE_NAME = "GlobalDatastore", -- // string: Name of the global datastore
		GLOBAL_DATASTORE_KEY = "GlobalData", -- // string: Key where all global data is stored

		SHARD_BYTE_LIMIT = 1000000 -- // number: Amount of bytes to intake before starting a new key; (JSON Encoded, Per Char)
	},

	OPERATION_CASES = OPERATION_CASES,

	FLAGS = {
		PlayerDataLoaded = Signal.new(),
		GlobalDataLoaded = Signal.new()
	}
}