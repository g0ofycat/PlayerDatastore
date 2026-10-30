--!strict

export type WriteType = {
	path: string,
	transform: (currentValue: any) -> any
}

export type PresetOptions = {
	ShardedFields: { string }?, -- // { string }: Table Paths to be sharded
	GlobalFields: { string }? -- // { string }: Table Paths that aren't bound per player
}

export type MetaData = {
	LastSaved: number,
	ServerId: string,
	SaveCount: number,
	FirstJoined: number,
	TotalPlaytime: number,
	DataVersion: string,
	_SessionStart: number
}

export type SnapshotEntry = {
	Path: string,
	Data: { [any]: any }?, -- // nil in the index; stored under its own key
	Timestamp: number,
	Version: string,
	Key: string? -- // DataStore key holding the full entry
}

export type MetadataSnapshotEntry = { Key: string, Timestamp: number }

export type SessionEntry = { JobID: string, Timestamp: number }

export type MemoryEntry = { v: number, d: any? } -- // v: version bumped on every write; d: value, nil = deleted

export type MigrationFunction = (Data: { [any]: any }) -> { [any]: any }

export type ShardWrite = { key: string, encoded: string }

export type SessionLockReturnType = "OK" | "CONTESTED" | "ERROR"

export type Connection = {
	fn: ((...any) -> ())?,
	sig: Signal,
	next: Connection?,
	prev: Connection?
}

export type Signal = {
	head: Connection?
}

export type SignalOperations = {
	OnRead: (string) -> (),
	OnWrite: (string) -> (),
	[string]: string
}

export type SignalManager = { Signal_R: Signal, Connection_R: Connection, Signal_W: Signal, Connection_W: Connection }

return nil