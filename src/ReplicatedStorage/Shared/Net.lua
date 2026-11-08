--!strict
-- The ONLY module permitted to create or fetch Remote instances.
-- Deliberately thin: transport only. No validation, no rate limiting, no policy.
-- Security enforcement lives server-side in Framework.Validate and Framework.RateLimiter.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Constants = require(script.Parent.Config.Constants)

local IS_SERVER = RunService:IsServer()

local Net = {}

local remotesFolder: Folder? = nil

local function getRemotesFolder(): Folder
	if remotesFolder then
		return remotesFolder
	end
	if IS_SERVER then
		local existing = ReplicatedStorage:FindFirstChild(Constants.FOLDERS.Remotes)
		if existing and existing:IsA("Folder") then
			remotesFolder = existing
		else
			local folder = Instance.new("Folder")
			folder.Name = Constants.FOLDERS.Remotes
			folder.Parent = ReplicatedStorage
			remotesFolder = folder
		end
	else
		local resolved = ReplicatedStorage:WaitForChild(Constants.FOLDERS.Remotes, Constants.REMOTE_RESOLVE_TIMEOUT)
		if not resolved or not resolved:IsA("Folder") then
			error(
				`Net: '{Constants.FOLDERS.Remotes}' folder did not replicate from the server within {Constants.REMOTE_RESOLVE_TIMEOUT}s. `
					.. "The server creates it at startup - check that Server.Bootstrap ran and that no server error stopped the ServiceLoader.",
				2
			)
		end
		remotesFolder = resolved
	end
	return remotesFolder :: Folder
end

-- Server: create the declared RemoteEvents once. Safe to call repeatedly.
function Net.EnsureAllRemotes(): ()
	assert(IS_SERVER, "Net.EnsureAllRemotes is server-only")
	local folder = getRemotesFolder()
	for _, remoteName in Constants.REMOTES do
		if not folder:FindFirstChild(remoteName) then
			local event = Instance.new("RemoteEvent")
			event.Name = remoteName
			event.Parent = folder
		end
	end
end

-- Both sides: resolve a declared RemoteEvent by name.
function Net.GetRemote(remoteName: string): RemoteEvent
	local folder = getRemotesFolder()
	if IS_SERVER then
		local existing = folder:FindFirstChild(remoteName)
		if not existing or not existing:IsA("RemoteEvent") then
			error(`RemoteEvent '{remoteName}' was not declared at startup`, 2)
		end
		return existing
	end
	local existing = folder:WaitForChild(remoteName, Constants.REMOTE_RESOLVE_TIMEOUT)
	if not existing or not existing:IsA("RemoteEvent") then
		error(
			`Net: RemoteEvent '{remoteName}' did not replicate within {Constants.REMOTE_RESOLVE_TIMEOUT}s. `
				.. `It is declared in Constants.REMOTES - confirm the name matches and the server created it.`,
			2
		)
	end
	return existing
end

-- Server: bind an inbound handler. The handler receives (player, payload).
function Net.OnServerRequest(remoteName: string, handler: (Player, any) -> ()): RBXScriptConnection
	assert(IS_SERVER, "Net.OnServerRequest is server-only")
	local remote = Net.GetRemote(remoteName)
	return remote.OnServerEvent:Connect(handler)
end

-- Server: reply to one player only.
function Net.FireClient(remoteName: string, player: Player, payload: any): ()
	assert(IS_SERVER, "Net.FireClient is server-only")
	Net.GetRemote(remoteName):FireClient(player, payload)
end

-- Client: send an inbound request to the server.
function Net.FireServer(remoteName: string, payload: any): ()
	assert(not IS_SERVER, "Net.FireServer is client-only")
	Net.GetRemote(remoteName):FireServer(payload)
end

-- Client: bind a server reply handler.
function Net.OnClientEvent(remoteName: string, handler: (any) -> ()): RBXScriptConnection
	assert(not IS_SERVER, "Net.OnClientEvent is client-only")
	return Net.GetRemote(remoteName).OnClientEvent:Connect(handler)
end

return Net
