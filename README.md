# PlayerDatastore (Roblox)

A high level datastore abstraction for Roblox that handles automatic **yielding**, **sharding**, and **global data**. Allows instant datastore operations **without manual yield handling**. This datastore also includes **Session Locking**, **Metadata**, and **Snapshots**

## Core Features

- Automatic yield handling
- Field sharding
- Global fields
- Path-based table access
- Atomic operators
- Basic Session Locking
- Player and Global Metadata
- Snapshots (Versioning to create "Snapshots" of data in which you can migrate data to the main datastores)

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
PlayerDatastore.ApplyOperator(player, { value_name = "player_data.progression", operator = "INSERT", value = { ["Coins"] = 500 } }) -- // "player_data.progression" can also be ("player_data['progression']" OR 'player_data["progression"]')
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
PlayerDatastore.ReadGlobal("unordered_map") -- // { ["K"] = "V" }
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

## Creating Snapshots and Migration:

### Snapshots

Snapshots are named backups of any path in player or global data, stored in a separate DataStore (See Config.SNAPSHOT_DATASTORE_NAME). They are created automatically before each migration step, and can also be created manually at any point. **(NOTE: CREATING SNAPSHOTS FOR SHARDED DATA UNSHARDS THEM)**

```lua
-- // Snapshot a specific path in a players data
PlayerDatastore.CreateSnapshot("pre-wipe", "player_data.progression", player)

-- // Snapshot a global field
PlayerDatastore.CreateSnapshot("pre-event", "unordered_map")
```

To restore a snapshot, pass the same name used when creating it. This overwrites the live data at the stored path:

```lua
PlayerDatastore.RestoreSnapshot("pre-wipe", player)
PlayerDatastore.RestoreSnapshot("pre-event")
```

Up to `Config.DATASTORE.MAX_SNAPSHOTS_PER_KEY` snapshots are kept per player or global key. When the limit is exceeded, the oldest snapshots by timestamp are dropped automatically

### Migration

Migrations run automatically on player load when the persisted `DataVersion` differs from `PlayerDatastore.CurrentVersion`. Before each step runs, a pre-migration snapshot is saved automatically. If the snapshot save fails, the migration is aborted and the original data is returned unchanged.

Register migrations before calling `Init()`:

```lua
PlayerDatastore.CurrentVersion = "v.1.1.0"

PlayerDatastore.RegisterMigration("v.1.0.0", "v.1.1.0", function(data)
    data.player_data.progression["Level"] = 1
    return data
end)
```

Only **linear chains** are supported, one outgoing migration per source version. Branching graphs (`v1->v2` and `v1->v3` both registered) will error at registration time.

For multi-step chains, register each step individually:

```lua
PlayerDatastore.RegisterMigration("v.1.0.0", "v.1.1.0", migrationA)
PlayerDatastore.RegisterMigration("v.1.1.0", "v.1.2.0", migrationB)
```

Players on `v.1.0.0` will run both steps in order on their next load.

## API

The rest of the API is self-explanatory:

### Sharding (Automatically handled every operation):

```lua
-- Shard(): Enables sharding for a table path (Check Config.DATASTORE.SHARD_BYTE_LIMIT)
-- @param player: The player to shard
-- @param table_path: Path to the table
-- @param enable: Whether to enable it
-- @note: Disabling while having a sharded table will result in all of the tables combining, likely leading to errors
-- @note: The first entry will always be put, no matter how large it is, subsequent data will be sharded
function PlayerDatastore.Shard(player: Player, table_path: string, enable: boolean): ()
```

```lua
-- ShardGlobal(): Enables sharding for a global table path
-- @param path: The global key pointing to the table
-- @param enable: Whether to enable sharding
-- @note: Automatically handles unshard + reshard
function PlayerDatastore.ShardGlobal(path: string, enable: boolean): ()
```

### Deletion:

```lua
-- DeletePlayerData(): Deletes a players data
-- @param player: The player to delete data for
-- @note: This will kick the player after deleting their data, use with caution
function PlayerDatastore.DeletePlayerData(player: Player): ()
```

```lua
-- DeleteGlobalData(): Deletes a global data key and its shards
-- @param path: The global key to delete
-- @note: This almost should NEVER be used, proceed with caution
function PlayerDatastore.DeleteGlobalData(path: string): ()
```

### Utility:

```lua
-- GetPlayerData(): Gets a players data
-- @param player: The player to get data for
-- @return: { [any]: any }?
function PlayerDatastore.GetPlayerData(player: Player): { [any]: any }?
```

```lua
-- GetShardData(): Gets a shards data
-- @param player: The player to check yield for
-- @param key?: Optional Key to get shard data for; else returns the entire table
-- @return: { [string]: any } | any
function PlayerDatastore.GetShardData(player: Player, key: string?): { [string]: any } | any
```

```lua
-- GetGlobalData(): Gets the global data
-- @param table_path?: The path to the table to get; else returns the entire table
-- @return: { [string]: any } | any
function PlayerDatastore.GetGlobalData(table_path: string?): { [string]: any } | any
```

```lua
PlayerDatastore.CurrentVersion = "v.1.0.0" -- // Used to track metadata version and migrations
```

### Metadata:

```lua
-- GetMetadata(): Gets metadata for a player or global data
-- @param player?: The player to get metadata for; if nil returns global metadata
-- @return: Types.MetaData?
function PlayerDatastore.GetMetadata(player: Player?): Types.MetaData?
```

### Versioning:

```lua
-- RegisterMigration(): Registers a migration function for a version transition
-- @param from_version: string
-- @param to_version: string
-- @param migration: Types.MigrationFunction
-- @note: Only linear chains are supported, one outgoing migration per source version
-- @note: If ShardedFields changed between versions, manually unshard affected fields inside the migration function before transforming them, as only current ShardedFields are automatically unsharded before migration runs
function PlayerDatastore.RegisterMigration(from_version: string, to_version: string, migration: Types.MigrationFunction): ()
```

### Snapshots:

```lua
-- CreateSnapshot(): Creates a named snapshot of a path in a players data or global data
-- @param name: string
-- @param path: string
-- @param player?: Player; if nil snapshots global data at path
function PlayerDatastore.CreateSnapshot(name: string, path: string, player: Player?): ()
```

```lua
-- RestoreSnapshot(): Restores a named snapshot, overwriting current data at that path
-- @param name: string
-- @param player?: Player; if nil restores global data
function PlayerDatastore.RestoreSnapshot(name: string, player: Player?): ()
```

```lua
-- DeleteSnapshot(): Deletes a named snapshot
-- @param name: string
-- @param player?: Player; if nil deletes from global snapshots
function PlayerDatastore.DeleteSnapshot(name: string, player: Player?): ()
```

```lua
-- ListSnapshots(): Lists all snapshots for a player or global
-- @param player?: Player; if nil lists global snapshots
-- @return: { [string]: Types.SnapshotEntry }?
function PlayerDatastore.ListSnapshots(player: Player?): { [string]: Types.SnapshotEntry }?
```