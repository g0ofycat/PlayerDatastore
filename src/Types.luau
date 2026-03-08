--!strict

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

export type MetaData = {
	LastSaved: number,
	ServerId: string,
	SaveCount: number,
	FirstJoined: number,
	TotalPlaytime: number,
	DataVersion: string,
	_SessionStart: number
}

return nil