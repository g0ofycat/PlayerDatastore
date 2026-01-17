# PlayerDatastore

database that handles sharding and yielding so u can insta call functions without doing some yield bs

also has cool api

## look:

```lua
PlayerDatastore.Init({
	ServerPool = {}
}, {
	ShardedFields = {
		"ServerPool"
	},

    GlobalFields = {
		"ServerPool"
	}
})
```

u can do this too:

```lua
PlayerDatastore.Init({
	ServerPool = {
        InnerPool = {}
    }
}, {
	ShardedFields = {
		"ServerPool.InnerPool" -- // same
	},

    GlobalFields = {
		"ServerPool['InnerPool']" -- // same
	}
})
```

and access like:


## add things to datastore:

unshards sharded fields when applying operators then reshards. if plrs leave mid operation then unsharded data thats sharded get sharded

### non-global fields:

```lua
PlayerDatastore.ApplyOperator(player, { value_name = "ServerPool", operator = "INSERT", value = { ["Key"] = 100 }})
```

### global fields:

```lua
PlayerDatastore.ApplyOperatorGlobal({ value_name = "ServerPool", operator = "INSERT", value = { ["Key"] = 100 }})
```

### types:

wow

```lua
export type OperationType = {
	value_name: string,
	operator: ValueOperators,
	value: any
}

export type ValueOperators = "+" | "-" | "*" | "/" | "SET" | "INSERT" | "PUSH" | "DELETE"

export type PresetOptions = {
	ShardedFields: { string }?, -- // { string }: Table Paths to be sharded
	GlobalFields: { string }? -- // { string }: Table Paths that aren't bound per player
}
```

all value operators

```lua
    OPERATION_CASES = {
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
	},
```

## utils:

```lua
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
```