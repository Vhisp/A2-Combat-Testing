--!strict
-- Character lifecycle ONLY: spawn, death, removal, respawn.
-- No health, stats, class, resources, targeting, or combat - those are later phases.
-- Reaches PlayerService through injected deps, never by requiring it, so there is no cycle.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local CharacterTypes = require(ReplicatedStorage.Shared.Types.Character)

local IS_STUDIO = RunService:IsStudio()

local CharacterService = {}

local deps: { [string]: any } = {}

local states: { [Player]: CharacterTypes.CharacterState } = {}
-- Monotonic per-player spawn counter. A handler captures the value it was created
-- under and no-ops if the counter has moved on, so stale character events can never
-- mutate the state of a newer character.
local generations: { [Player]: number } = {}

local globalConnections: { RBXScriptConnection } = {}
local playerConnections: { [Player]: { RBXScriptConnection } } = {}
local characterConnections: { [Player]: { RBXScriptConnection } } = {}

local function log(...: any): ()
	if IS_STUDIO then
		print("[CharacterService]", ...)
	end
end

local function clearCharacterConnections(player: Player): ()
	local connections = characterConnections[player]
	if not connections then
		return
	end
	for _, connection in connections do
		connection:Disconnect()
	end
	characterConnections[player] = nil
end

local function clearPlayerConnections(player: Player): ()
	local connections = playerConnections[player]
	if not connections then
		return
	end
	for _, connection in connections do
		connection:Disconnect()
	end
	playerConnections[player] = nil
end

-- Idempotent teardown of everything owned by one player.
local function clearPlayer(player: Player): ()
	clearCharacterConnections(player)
	clearPlayerConnections(player)
	states[player] = nil
	generations[player] = nil
end

local function setReady(player: Player, ready: boolean): ()
	local playerService = deps.PlayerService
	if playerService then
		playerService.SetReady(player, ready)
	end
end

-- Binds a freshly spawned character. Safe to call twice for the same character.
local function bindCharacter(player: Player, character: Model): ()
	-- Idempotency: if this exact character is already tracked, do nothing.
	local existing = states[player]
	if existing and existing.character == character then
		return
	end

	-- New generation for the new character. Any handler still holding the previous
	-- generation is now stale and will ignore its own events.
	local generation = (generations[player] or 0) + 1
	generations[player] = generation

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		humanoid = character:WaitForChild("Humanoid", 5)
	end

	-- The wait yielded: re-check that this spawn is still the current one.
	if generations[player] ~= generation or player.Character ~= character then
		log(`abandoned stale spawn for {player.Name} (generation {generation})`)
		return
	end

	if not humanoid or not humanoid:IsA("Humanoid") then
		log(`no Humanoid on new character for {player.Name}`)
		return
	end

	-- Replace any previous character's connections and state.
	clearCharacterConnections(player)

	states[player] = {
		player = player,
		character = character,
		humanoid = humanoid,
		generation = generation,
		spawnedAt = os.clock(),
	}

	local connections: { RBXScriptConnection } = {}

	table.insert(connections, humanoid.Died:Connect(function()
		-- Stale guard: ignore a death belonging to a superseded character.
		if generations[player] ~= generation then
			return
		end
		log(`died: {player.Name} (generation {generation})`)
		setReady(player, false)
	end))

	characterConnections[player] = connections

	setReady(player, true)
	log(`spawned: {player.Name} (generation {generation})`)
end

local function onCharacterRemoving(player: Player, character: Model): ()
	local current = states[player]
	-- Only clear if the character being removed is the one we currently track.
	-- A late removal event for an old character must not wipe the new one's state.
	if not current or current.character ~= character then
		log(`ignored removal of non-current character for {player.Name}`)
		return
	end

	clearCharacterConnections(player)
	states[player] = nil
	setReady(player, false)
	log(`removed: {player.Name} (generation {current.generation})`)
end

local function onPlayerAdded(player: Player)
	-- Defensive: never attach a second set of connections for the same player.
	clearPlayerConnections(player)

	local connections: { RBXScriptConnection } = {}
	table.insert(connections, player.CharacterAdded:Connect(function(character)
		bindCharacter(player, character)
	end))
	table.insert(connections, player.CharacterRemoving:Connect(function(character)
		onCharacterRemoving(player, character)
	end))
	playerConnections[player] = connections

	-- The player may already have a character (late Start, or join race).
	local character = player.Character
	if character then
		bindCharacter(player, character)
	end
end

function CharacterService.Init(injected: { [string]: any }): ()
	deps = injected
end

function CharacterService.Start(): ()
	table.insert(globalConnections, Players.PlayerAdded:Connect(onPlayerAdded))
	table.insert(globalConnections, Players.PlayerRemoving:Connect(function(player)
		clearPlayer(player)
		log(`player left, cleared character state: {player.Name}`)
	end))

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

-- Read-only accessors for later systems (combat, targeting).
function CharacterService.GetState(player: Player): CharacterTypes.CharacterState?
	return states[player]
end

function CharacterService.GetCharacter(player: Player): Model?
	local state = states[player]
	return state and state.character or nil
end

function CharacterService.Destroy(): ()
	for _, connection in globalConnections do
		connection:Disconnect()
	end
	table.clear(globalConnections)

	-- Collect keys first: clearPlayer mutates playerConnections during the loop.
	local trackedPlayers: { Player } = {}
	for player in playerConnections do
		table.insert(trackedPlayers, player)
	end
	for _, player in trackedPlayers do
		clearPlayer(player)
	end

	table.clear(states)
	table.clear(generations)
	table.clear(playerConnections)
	table.clear(characterConnections)
end

return CharacterService
