--!strict

task.wait(3) -- // short yield to load player

-- ==========================
-- // UTIL
-- ==========================

local FirstCapturedPlayer = game.Players:GetPlayers()[1]

type it_fn = { will: string, should: string, logic: () -> () }

local failed_tests: { [number]: string } = {}

local current_test = 0

-- it(): Test suite function
-- @param options: it_fn
local function it(options: it_fn): ()
	print(`TEST {current_test} - It will {options.will}; It should {options.should}`)
	local success, error_msg = xpcall(options.logic, function()
		print(debug.traceback("dbtraceback:", 3))
	end)
	if success then
		print(`🟩 {current_test} - PASSED`) -- // yes i use emojis in code
	else
		failed_tests[current_test] = error_msg :: string
		error(`🟥 {current_test} - FAILED: {error_msg}`)
	end
	current_test += 1
end

-- ==========================
-- // 1: CONFIG & INIT
-- ==========================

local Config = require(game.ServerStorage.PlayerDatastore.Utility.Config)
Config.DATASTORE.SHARD_BYTE_LIMIT = 100
Config.DATASTORE.AUTOSAVE_INTERVAL = 10

local PlayerDatastore = require(game.ServerStorage.PlayerDatastore.PlayerDatastore)

PlayerDatastore.Init({
	int = 0,
	string = "",
	boolean = false,
	table = {},
	s_table = {},
	g_table = {},
	sg_table = {}
}, {
	ShardedFields = { "s_table", "sg_table" },
	GlobalFields = { "g_table", "sg_table" }
}, {
	OnRead = function(path: string)
		print(`Signal: OnRead fired for path: {path}`)
	end,
	OnWrite = function(path: string)
		print(`Signal: OnWrite fired for path: {path}`)
	end
})

--[[
print(`--- DELETING ALL DATA... ---`)

PlayerDatastore.DeletePlayerData(FirstCapturedPlayer)

PlayerDatastore.DeleteGlobalData("g_table")
PlayerDatastore.DeleteGlobalData("sg_table")
]]

-- ==========================
-- // 2: WRITE & READ TESTS (BASIC)
-- ==========================

-- INT
it({ will = "turn 'int' to 100", should = "be 100 when reading 'int'", logic = function()
	PlayerDatastore.Write(FirstCapturedPlayer, { path = "int", transform = function(currentValue)
		return 100
	end})

	local val = PlayerDatastore.Read(FirstCapturedPlayer, "int")
	assert(val == 100, `Expected int to be 100, got {tostring(val)}`)
end})

-- STRING
it({ will = "turn 'string' to 'Hello, World!'", should = "be 'Hello, World!' when reading 'string'", logic = function()
	PlayerDatastore.Write(FirstCapturedPlayer, { path = "string", transform = function(currentValue)
		return "Hello, World!"
	end})

	local val = PlayerDatastore.Read(FirstCapturedPlayer, "string")
	assert(val == "Hello, World!", `Expected string to be 'Hello, World!', got {tostring(val)}`)
end})

-- BOOLEAN
it({ will = "turn 'boolean' to true", should = "be true when reading 'boolean'", logic = function()
	PlayerDatastore.Write(FirstCapturedPlayer, { path = "boolean", transform = function(currentValue)
		return true
	end})

	local val = PlayerDatastore.Read(FirstCapturedPlayer, "boolean")
	assert(val == true, `Expected boolean to be true, got {tostring(val)}`)
end})

-- TABLE
it({ will = "add a key-value pair to 'table'", should = "contain the key when reading 'table'", logic = function()
	PlayerDatastore.Write(FirstCapturedPlayer, { path = "table", transform = function(currentValue)
		currentValue.TestKey = "TestValue"
		return currentValue
	end})

	local val = PlayerDatastore.Read(FirstCapturedPlayer, "table")
	assert(val and val.TestKey == "TestValue", "Expected table.TestKey to be 'TestValue'")
end})

-- ==========================
-- // 3: UTIL FUNCTIONS
-- ==========================

it({ will = "test the utility function 'GetPlayerData'", should = "return a table with the correct keys", logic = function()
	local data = PlayerDatastore.GetPlayerData(FirstCapturedPlayer)
	assert(data.int == 100, `Expected int to be 100, got {tostring(data.int)}`)
	assert(data.string == "Hello, World!", `Expected string to be 'Hello, World!', got {tostring(data.string)}`)
	assert(data.boolean == true, `Expected boolean to be true, got {tostring(data.boolean)}`)
	assert(data.table and data.table.TestKey == "TestValue", "Expected table.TestKey to be 'TestValue'")
end})

it({ will = "test the utility function 'GetShardData'", should = "return a table with the correct keys", logic = function()
	local sharded_data = PlayerDatastore.GetShardData(FirstCapturedPlayer, "s_table")
	assert(sharded_data ~= {}, "Expected s_table to be {} since it hasn't been set yet")
end})

it({ will = "test the utility function 'GetGlobalData'", should = "return a table with the correct keys", logic = function()
	local global_data = PlayerDatastore.GetGlobalData("g_table")
	assert(global_data ~= {}, "Expected g_table to be {} since it hasn't been set yet")
end})

it({ will = "test the utility function 'GetMetadata'", should = "return a table with the correct keys", logic = function()
	local metadata = PlayerDatastore.GetMetadata(FirstCapturedPlayer)
	assert(metadata ~= nil, "Expected metadata to be a table")
	assert(metadata._SessionStart ~= nil, "Expected metadata to have a _SessionStart key")
end})

-- ==========================
-- // 4: SHARD & GLOBAL OPS
-- ==========================

it({ will = "write and read from a global field 'g_table'", should = "contain the updated global data", logic = function()
    local success = PlayerDatastore.WriteGlobal({
        path = "g_table",
        transform = function(currentValue)
            currentValue.GlobalKey = "GlobalValue"
            return currentValue
        end
    })
    assert(success, "Expected WriteGlobal to commit successfully")

    local val = PlayerDatastore.ReadGlobal("g_table")
    assert(val and val.GlobalKey == "GlobalValue", "Expected g_table.GlobalKey to be 'GlobalValue'")
end})

it({ will = "write and read from a sharded player field 's_table'", should = "persist and load sharded player data correctly", logic = function()
    PlayerDatastore.Write(FirstCapturedPlayer, {
        path = "s_table",
        transform = function(currentValue)
            currentValue.ShardKey = "ShardValue"
            return currentValue
        end
    })

    local val = PlayerDatastore.Read(FirstCapturedPlayer, "s_table")
    assert(val and val.ShardKey == "ShardValue", "Expected s_table.ShardKey to be 'ShardValue'")
end})

it({ will = "write and read from a sharded global field 'sg_table'", should = "persist and load sharded global data correctly", logic = function()
    local success = PlayerDatastore.WriteGlobal({
        path = "sg_table",
        transform = function(currentValue)
            currentValue.ShardedGlobalKey = "ShardedGlobalValue"
            return currentValue
        end
    })
    assert(success, "Expected WriteGlobal for sharded field to commit successfully")

    local val = PlayerDatastore.ReadGlobal("sg_table")
    assert(val and val.ShardedGlobalKey == "ShardedGlobalValue", "Expected sg_table.ShardedGlobalKey to be 'ShardedGlobalValue'")
end})

-- ==========================
-- // 5: VERSIONING & SNAPSHOTS
-- ==========================

it({ will = "create a snapshot of the 'int' path", should = "successfully create and list the snapshot", logic = function()
    PlayerDatastore.CreateSnapshot("test-snapshot", "int", FirstCapturedPlayer)
    local snapshots = PlayerDatastore.ListSnapshots(FirstCapturedPlayer)
    assert(snapshots and snapshots["test-snapshot"] ~= nil, "Expected 'test-snapshot' to exist in player snapshots")
end})

it({ will = "restore a snapshot of 'int' after mutating it", should = "revert 'int' back to its snapshotted value", logic = function()
    -- Mutate 'int'
    PlayerDatastore.Write(FirstCapturedPlayer, {
        path = "int",
        transform = function(currentValue)
            return 999
        end
    })
    assert(PlayerDatastore.Read(FirstCapturedPlayer, "int") == 999, "Expected int to be updated to 999")

    -- Restore snapshot
    PlayerDatastore.RestoreSnapshot("test-snapshot", FirstCapturedPlayer)
    local val = PlayerDatastore.Read(FirstCapturedPlayer, "int")
    assert(val == 100, `Expected int to be restored back to 100, got {tostring(val)}`)
end})

it({ will = "delete the created snapshot", should = "remove the snapshot from the player's snapshot list", logic = function()
    PlayerDatastore.DeleteSnapshot("test-snapshot", FirstCapturedPlayer)
    local snapshots = PlayerDatastore.ListSnapshots(FirstCapturedPlayer)
    assert(snapshots == nil or snapshots["test-snapshot"] == nil, "Expected 'test-snapshot' to be deleted")
end})

print(`--- ALL TESTS PASSED ---`)