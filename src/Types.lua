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

return nil