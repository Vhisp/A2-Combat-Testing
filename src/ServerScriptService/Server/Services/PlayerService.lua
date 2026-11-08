--!strict
-- Player lifecycle and runtime state ONLY.
-- Deliberately absent in Phase 0: persistence, DataStore, resource regeneration,
-- stats, currency, inventory. Those arrive with their own milestones.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local PlayerTypes = require(ReplicatedStorage.Shared.Types.Player)

local PlayerService = {}

local RunService = game:GetService("RunService")
local IS_STUDIO = RunService:IsStudio()

local states: { [Player]: PlayerTypes.PlayerState } = {}
local connections: { RBXScriptConnection } = {}

-- Injected by ServiceLoader. Dependencies arrive here, never via module-scope requires.
local deps: { [string]: any } = {}

local function createState(player: Player): PlayerTypes.PlayerState
	local state: PlayerTypes.PlayerState = {
		userId = player.UserId,
		player = player,
		joinedAt = os.clock(),
		ready = false,
	}
	states[player] = state
	return state
end

function PlayerService.Init(injected: { [string]: any }): ()
	deps = injected
end

function PlayerService.Start(): ()
	local rateLimiter = deps.RateLimiter

	local function onPlayerAdded(player: Player)
		createState(player)
		if rateLimiter then
			rateLimiter.Reset(player)
		end
		if IS_STUDIO then
			print(`[PlayerService] joined: {player.Name} ({player.UserId})`)
		end
	end

	local function onPlayerRemoving(player: Player)
		states[player] = nil
		if rateLimiter then
			rateLimiter.Clear(player)
		end
		if IS_STUDIO then
			print(`[PlayerService] left: {player.Name}`)
		end
	end

	table.insert(connections, Players.PlayerAdded:Connect(onPlayerAdded))
	table.insert(connections, Players.PlayerRemoving:Connect(onPlayerRemoving))

	-- Handle players who joined before this service started (Studio play solo, etc).
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

function PlayerService.GetState(player: Player): PlayerTypes.PlayerState?
	return states[player]
end

function PlayerService.IsReady(player: Player): boolean
	local state = states[player]
	return state ~= nil and state.ready
end

-- Readiness is driven by CharacterService: true once a character is bound, false on
-- death, removal, or leave. PlayerService only stores the flag.
function PlayerService.SetReady(player: Player, ready: boolean): ()
	local state = states[player]
	if state then
		state.ready = ready
	end
end

function PlayerService.Destroy(): ()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	table.clear(states)
end

return PlayerService
