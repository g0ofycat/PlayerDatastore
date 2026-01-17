# PlayerDatastore (Roblox)

A high level datastore abstraction for Roblox that handles automatic yielding, sharding, and global data.
Allows instant datastore operations without manual yield handling

## Core Features

- Automatic yield handling
- Field sharding
- Global fields
- Path-based table access
- Atomic operators

## Initialization

### Basic Implementation:

Implementing a table that is **Sharded** and **Global** _(Not bound to a player, special functions)_

```lua
PlayerDatastore.Init({
	unordered_map = {},

	player_data = {
		progression = {}
	}
}, {
	ShardedFields = {
		"unordered_map"
	},
	GlobalFields = {
		"unordered_map"
	}
})
```

All available presets:

```lua
export type PresetOptions = {
	ShardedFields: { string }?, -- // { string }: Table Paths to be sharded
	GlobalFields: { string }? -- // { string }: Table Paths that aren't bound per player
}
```

### Applying Operators:

To apply changes to data in the database, you use **operators**

#### PlayerDatastore.ApplyOperator(player: Player, operation: Types.OperationType): ()

This is for non-global fields. **When a table is sharded, it: Unshards, applies changes, then reshards. If a players leaves mid-operation, then all tables marked as sharded yet not sharded get resharded. This applies to ApplyOperatorGlobal too**

```lua
PlayerDatastore.ApplyOperator(player, { value_name = "player_data.progression", operator = "INSERT", value = { ["Coins"] = 500 } }) -- // "player_data.progression" can also be ("player_data['progression']" / 'player_data["progression"]')
```

#### PlayerDatastore.Read(player: Player, table_path: string): { [any]: any }?

Read function for player-bound data.

```lua
PlayerDatastore.Read(player, "player_data.progression") -- // { ["Coins"] = 500 }
```

#### PlayerDatastore.ApplyOperatorGlobal(operation: Types.OperationType): ()

Exactly the same as **ApplyOperator** except it's not player-bound, meaning it doesn't have a player param

```lua
PlayerDatastore.ApplyOperatorGlobal({ value_name = "unordered_map", operator = "INSERT", value = { ["K"] = "V" } })
```

#### PlayerDatastore.ReadGlobal(path: string): any

Read function for non player-bound data.

```lua
PlayerDatastore.Read(player, "unordered_map") -- // { ["K"] = "V" }
```

### Operators:

All available operator types:

```lua
export type ValueOperators = "+" | "-" | "*" | "/" | "SET" | "INSERT" | "PUSH" | "DELETE"
```

Operator structure:

```lua
export type OperationType = {
	value_name: string,
	operator: ValueOperators,
	value: any
}
```

## API

The rest of the API is self-explanatory:

### Sharding (Automatically handled every operation):

```lua
-- Shard(): Enables sharding for a table path (Check Config.DATASTORE.SHARD_BYTE_LIMIT)
-- @param player: The player to shard
-- @param table_path: Path to the table
-- @param enable: Whether to enable it or not
-- @note: Disabling while having a sharded table will result in all of the tables combining, likely leading to errors
-- @note: The first entry will always be put, no matter how large it is, subsequent data will be sharded
function PlayerDatastore.Shard(player: Player, table_path: string, enable: boolean): ()
```

```lua
-- ShardGlobal(): Enables sharding for a global table path
-- @param path: The global key pointing to the table
-- @param enable: Whether to enable sharding or not
-- @note Automatically handles unshard + reshard
function PlayerDatastore.ShardGlobal(path: string, enable: boolean): ()
```

### Deletion:

```lua
-- DeletePlayerData(): Deletes a player's data
-- @param player: The player to delete data for
function PlayerDatastore.DeletePlayerData(player: Player): ()

-- DeleteGlobalData(): Deletes a global data key and its shards
-- @param path: The global key to delete
-- @note: This almost should NEVER be used, proceed with caution
function PlayerDatastore.DeleteGlobalData(path: string): ()
```

### Utility:

```lua
-- GetPlayerData(): Gets a player's data
-- @param player?: The player to get data for; else returns the entire table
-- @return { [number]: any } | any
function PlayerDatastore.GetPlayerData(player: Player?): { [number]: any } | any

-- GetShardData(): Gets a shard's data
-- @param key?: Optional Key to get shard data for; else returns the entire table
-- @return { [string]: any } | any
function PlayerDatastore.GetShardData(key: string?): { [string]: any } | any

-- GetGlobalData(): Gets the global data
-- @param table_path?: The path to the table to get; else returns the entire table
-- @return { [string]: any } | any
function PlayerDatastore.GetGlobalData(table_path: string?): { [string]: any } | any
```