--!strict

local Signal = {}

Signal.__index = Signal

--=========================
-- // TYPES
--=========================

export type Connection = {
	Disconnect: (self: Connection) -> (),
	IsConnected: (self: Connection) -> boolean
}

export type Signal = {
	_listeners: { [number]: (...any) -> () },
	_nextId: number,
	_deferred: boolean?,
	_deferredArgs: { any }?,

	Connect: (self: Signal, (...any) -> ()) -> Connection,
	Once: (self: Signal, (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
	FireDeferred: (self: Signal, ...any) -> (),
	Wait: (self: Signal) -> (...any),
	DeferredWait: (self: Signal) -> (...any),
	DisconnectAll: (self: Signal) -> ()
}

--=========================
-- // PUBLIC API
--=========================

-- new(): Constructor for Signal
function Signal.new(): Signal
	local self: any = setmetatable({}, Signal)

	self._listeners = {}

	self._nextId = 0

	self._deferred = false
	self._deferredArgs = nil

	return self
end

-- Connect(): Connect a function
-- @param fn: The function to connect
-- @return Connection
function Signal:Connect(fn: (...any) -> ()): Connection
	if type(fn) ~= "function" then
		error("Connect(): Expected function", 2)
	end

	self._nextId = self._nextId :: number + 1

	local id = self._nextId
	self._listeners[id] = fn

	local signal = self
	local disconnected = false

	local connection: Connection = {} :: any

	function connection:Disconnect()
		if not disconnected then
			signal._listeners[id] = nil
			disconnected = true
		end
	end

	function connection:IsConnected()
		return not disconnected
	end

	return connection
end

-- Once(): Connect a one-time listener
-- @param fn: The function to call once
-- @return Connection
function Signal:Once(fn: (...any) -> ()): Connection
	local conn: Connection

	conn = self:Connect(function(...)
		conn:Disconnect()
		fn(...)
	end)

	return conn
end

-- Fire(): Fire a signal
-- @param Variadic
function Signal:Fire(...: any): ()
	local snapshot = {}

	for _, fn in self._listeners :: { [number]: (...any) -> () } do
		snapshot[#snapshot + 1] = fn
	end

	for _, fn in snapshot do
		task.spawn(fn, ...)
	end
end

-- FireDeferred(): Fire a signal and mark it as deferred (stores args for DeferredWait)
-- @param ...: any
function Signal:FireDeferred(...: any): ()
	self._deferred = true
	self._deferredArgs = { ... }

	self:Fire(...)
end

-- Wait(): Yield until this Signal fires
-- @return ...any
function Signal:Wait(): ...any
	local co = coroutine.running()

	if not co then
		error("Wait(): Must be called from a coroutine", 2)
	end

	local result: { any } = {}
	local conn: Connection

	conn = self:Connect(function(...)
		result = { ... }
		conn:Disconnect()
		coroutine.resume(co)
	end)

	coroutine.yield()

	return table.unpack(result)
end

-- DeferredWait(): If already fired with FireDeferred, return immediately. Otherwise, wait
-- @return ...any
function Signal:DeferredWait(): ...any
	if self._deferred and self._deferredArgs then
		return table.unpack(self._deferredArgs :: { any })
	end

	return self:Wait()
end

-- DisconnectAll(): Disconnect all listeners
function Signal:DisconnectAll(): ()
	for k in self._listeners do
		self._listeners[k] = nil
	end
end

return Signal