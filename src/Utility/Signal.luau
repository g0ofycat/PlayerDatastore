--!strict
--!native
--!optimize 2

--=========================
-- // TYPES
--=========================

local Types = require("./Types")

--=========================
-- // SIGNAL
--=========================

local free: thread? = nil

-- call(): Runs a handler on the cached runner, then marks the runner as free again
-- @param fn: The handler function to run
-- @param ...: The arguments passed through to the handler
local function call(fn: (...any) -> (), ...: any): ()
	local t = free
	free = nil
	fn(...)
	free = t
end

-- loop(): Body of the runner thread, runs handlers forever and yields between calls
-- @param ...: The first handler and its arguments, later calls arrive through yield
local function loop(...: any): ()
	call(...)
	while true do
		call(coroutine.yield())
	end
end

-- new(): Creates a new signal
-- @return: Signal
local function new(): Types.Signal
	return { head = nil }
end

-- connect(): Connects a handler to a signal, newest connections run first
-- @param s: The signal to connect to
-- @param fn: The handler called whenever the signal fires
-- @return: Connection
local function connect(s: Types.Signal, fn: (...any) -> ()): Types.Connection
	local head = s.head
	local c: Types.Connection = { fn = fn, sig = s, next = head, prev = nil }
	if head then head.prev = c end
	s.head = c
	return c
end

-- fire(): Calls every connected handler with the given arguments
-- @param s: The signal to fire
-- @param ...: The arguments passed to every handler
local function fire(s: Types.Signal, ...: any): ()
	local c = s.head
	while c do
		local fn = c.fn
		if fn then
			local t = free
			if not t then
				t = coroutine.create(loop)
				free = t
			end
			task.spawn(t :: thread, fn, ...)
		end
		c = c.next
	end
end

return { new = new, connect = connect, fire = fire }