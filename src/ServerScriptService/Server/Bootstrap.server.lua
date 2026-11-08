--!strict
-- The ONLY server entry point. Wires the loader, registers services in dependency
-- order, and starts them. Contains no gameplay logic.

local ServerScriptService = game:GetService("ServerScriptService")

local ServerRoot = ServerScriptService:WaitForChild("Server", 10)
local Framework = ServerRoot:WaitForChild("Framework", 10)
local Services = ServerRoot:WaitForChild("Services", 10)

local ServiceLoader = require(Framework:WaitForChild("ServiceLoader", 10))

-- Registration order IS the Init and Start order. Dependencies must come first.
-- PlayerService is registered before CharacterService, which consumes it via deps.
ServiceLoader.Register("PlayerService", require(Services:WaitForChild("PlayerService", 10)))
ServiceLoader.Register("CharacterService", require(Services:WaitForChild("CharacterService", 10)))
-- RuntimeStatsService consumes PlayerService and CharacterService via deps, so it is
-- registered right after them. Existing services keep their relative order.
ServiceLoader.Register("RuntimeStatsService", require(Services:WaitForChild("RuntimeStatsService", 10)))
ServiceLoader.Register("TargetingService", require(Services:WaitForChild("TargetingService", 10)))
ServiceLoader.Register("DiagnosticsService", require(Services:WaitForChild("DiagnosticsService", 10)))
-- CombatService consumes PlayerService, CharacterService, and TargetingService via deps,
-- so it is registered after all three. Appended last to leave existing order unchanged.
ServiceLoader.Register("CombatService", require(Services:WaitForChild("CombatService", 10)))
-- SkillService consumes PlayerService, CharacterService, TargetingService, and
-- CombatService via deps, so it is registered after all four. Appended last to leave
-- existing order unchanged.
ServiceLoader.Register("SkillService", require(Services:WaitForChild("SkillService", 10)))
-- Action-combat prototype: consumes Net, RateLimiter, PlayerService, CharacterService,
-- CombatService (ResolveHit), and Targeting via deps. Appended last, existing order unchanged.
ServiceLoader.Register("ActionCombatService", require(Services:WaitForChild("ActionCombatService", 10)))

ServiceLoader.Start()
