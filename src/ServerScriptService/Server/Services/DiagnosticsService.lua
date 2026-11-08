--!strict
-- Development diagnostics only. Proves the request pipeline end to end:
-- throttling -> shape check -> detailed validation -> typed handler -> reply to one player.
-- Gates verbose logging to Studio. Ships inert on a live server.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local NetTypes = require(ReplicatedStorage.Shared.Types.Net)

local IS_STUDIO = RunService:IsStudio()

local DiagnosticsService = {}

local deps: { [string]: any } = {}
local connections: { RBXScriptConnection } = {}

local function log(...: any): ()
	if IS_STUDIO then
		print("[DiagnosticsService]", ...)
	end
end

-- One generic rejection for every failure mode: validation, throttle, or malformed
-- payload. The client cannot tell them apart, and no detail is ever sent back.
local function reject(player: Player, detail: string): ()
	if IS_STUDIO then
		warn(`[DiagnosticsService] rejected {player.Name}: {detail}`)
	end
	local result: NetTypes.DiagnosticsResult = {
		protocol = Constants.PROTOCOL_VERSION,
		ok = false,
		reason = Constants.GENERIC_REJECTION,
	}
	deps.Net.FireClient(Constants.REMOTES.DiagnosticsResult, player, result)
end

function DiagnosticsService.Init(injected: { [string]: any }): ()
	deps = injected
end

function DiagnosticsService.Start(): ()
	local net = deps.Net
	local validate = deps.Validate
	local rateLimiter = deps.RateLimiter

	local connection = net.OnServerRequest(Constants.REMOTES.RequestDiagnostics, function(player: Player, payload: any)
		-- 1. Global throttle FIRST, before inspecting the payload at all.
		--    Protects against malformed-request spam.
		if not rateLimiter.Check(player, "Global") then
			reject(player, "global throttle")
			return
		end

		-- 2. Structural shape check.
		local shapeResult = validate.RequestShape(payload)
		if not shapeResult.ok then
			reject(player, shapeResult.reason or "shape")
			return
		end

		-- 3. Action-specific throttle, after the action string is known safe to read.
		if not rateLimiter.Check(player, "Diagnostics") then
			reject(player, "diagnostics throttle")
			return
		end

		-- 4. Detailed per-action validation.
		local detailResult = validate.DiagnosticsRequest(payload)
		if not detailResult.ok then
			reject(player, detailResult.reason or "detail")
			return
		end

		-- 5. Typed handler.
		local request = validate.AsDiagnosticsRequest(payload)
		local echoedText: string? = nil
		if request.action == "echo" and request.text ~= nil then
			echoedText = request.text
		end

		local result: NetTypes.DiagnosticsResult = {
			protocol = Constants.PROTOCOL_VERSION,
			ok = true,
			echoedText = echoedText,
			serverTime = os.clock(),
			echoedClientTime = request.clientTime,
		}

		deps.Net.FireClient(Constants.REMOTES.DiagnosticsResult, player, result)
		log(`ok from {player.Name}, action={request.action}, echoedClientTime={request.clientTime}`)
	end)

	table.insert(connections, connection)
end

function DiagnosticsService.Destroy(): ()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

return DiagnosticsService
