--!strict
-- Payload types for the diagnostics round trip.
-- Types only: this module returns an empty table at runtime.

export type DiagnosticsAction = "echo" | "time"

export type DiagnosticsRequest = {
	protocol: number,
	action: DiagnosticsAction,
	text: string?,
	clientTime: number,
}

export type DiagnosticsResult = {
	protocol: number,
	ok: boolean,
	echoedText: string?,
	serverTime: number?,
	echoedClientTime: number?,
	reason: string?,
}

return {}
