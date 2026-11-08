--!strict
-- Ordered service registry with a strict two-phase lifecycle.
-- Phase 1: Init(deps) on every service, in registration order.
-- Phase 2: Start() on every service, in registration order, only after all Init calls.
-- Services never require each other's modules; they receive dependencies by injection.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage.Shared.Net)

-- Framework modules injected into every service, alongside Net and the registry.
local Validate = require(script.Parent.Validate)
local RateLimiter = require(script.Parent.RateLimiter)
local Targeting = require(script.Parent.Targeting)

local ServiceLoader = {}

type Service = {
	Init: (({ [string]: any }) -> ())?,
	Start: (() -> ())?,
	Destroy: (() -> ())?,
}

type Registration = {
	name: string,
	service: Service,
}

local registrations: { Registration } = {}
local registry: { [string]: Service } = {}
local started = false

function ServiceLoader.Register(name: string, service: Service): ()
	assert(not started, `Cannot register '{name}' after the loader has started`)
	assert(registry[name] == nil, `Service '{name}' is already registered`)
	registry[name] = service
	table.insert(registrations, { name = name, service = service })
end

-- Read-only lookup, for cross-service access after Init.
function ServiceLoader.Get(name: string): Service
	local service = registry[name]
	assert(service ~= nil, `Service '{name}' is not registered`)
	return service
end

function ServiceLoader.Start(): ()
	assert(not started, "ServiceLoader.Start called twice")

	-- Remotes are declared once, before any service binds to them.
	Net.EnsureAllRemotes()

	local deps: { [string]: any } = {
		Net = Net,
		ServiceLoader = ServiceLoader,
		Validate = Validate,
		RateLimiter = RateLimiter,
		Targeting = Targeting,
	}
	for name, service in registry do
		deps[name] = service
	end

	for _, registration in registrations do
		local init = registration.service.Init
		if init then
			local ok, err = pcall(init, deps)
			if not ok then
				error(`Service '{registration.name}' failed Init: {err}`, 0)
			end
		end
	end

	for _, registration in registrations do
		local startFn = registration.service.Start
		if startFn then
			local ok, err = pcall(startFn)
			if not ok then
				error(`Service '{registration.name}' failed Start: {err}`, 0)
			end
		end
	end

	started = true
	print(`[ServiceLoader] started {#registrations} service(s)`)
end

function ServiceLoader.Destroy(): ()
	for index = #registrations, 1, -1 do
		local registration = registrations[index]
		local destroy = registration.service.Destroy
		if destroy then
			pcall(destroy)
		end
	end
	table.clear(registrations)
	table.clear(registry)
	started = false
end

return ServiceLoader
