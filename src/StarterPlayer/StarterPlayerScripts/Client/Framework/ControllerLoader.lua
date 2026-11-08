--!strict
-- Client mirror of ServiceLoader. Same two-phase contract so both sides read the same.
-- Controllers receive dependencies by injection and never require each other directly.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage.Shared.Net)

local ControllerLoader = {}

type Controller = {
	Init: (({ [string]: any }) -> ())?,
	Start: (() -> ())?,
	Destroy: (() -> ())?,
}

type Registration = {
	name: string,
	controller: Controller,
}

local registrations: { Registration } = {}
local registry: { [string]: Controller } = {}
local started = false

function ControllerLoader.Register(name: string, controller: Controller): ()
	assert(not started, `Cannot register '{name}' after the loader has started`)
	assert(registry[name] == nil, `Controller '{name}' is already registered`)
	registry[name] = controller
	table.insert(registrations, { name = name, controller = controller })
end

function ControllerLoader.Get(name: string): Controller
	local controller = registry[name]
	assert(controller ~= nil, `Controller '{name}' is not registered`)
	return controller
end

function ControllerLoader.Start(): ()
	assert(not started, "ControllerLoader.Start called twice")

	local deps: { [string]: any } = {
		Net = Net,
		ControllerLoader = ControllerLoader,
	}
	for name, controller in registry do
		deps[name] = controller
	end

	for _, registration in registrations do
		local init = registration.controller.Init
		if init then
			local ok, err = pcall(init, deps)
			if not ok then
				error(`Controller '{registration.name}' failed Init: {err}`, 0)
			end
		end
	end

	for _, registration in registrations do
		local startFn = registration.controller.Start
		if startFn then
			local ok, err = pcall(startFn)
			if not ok then
				error(`Controller '{registration.name}' failed Start: {err}`, 0)
			end
		end
	end

	started = true
	print(`[ControllerLoader] started {#registrations} controller(s)`)
end

function ControllerLoader.Destroy(): ()
	for index = #registrations, 1, -1 do
		local registration = registrations[index]
		local destroy = registration.controller.Destroy
		if destroy then
			pcall(destroy)
		end
	end
	table.clear(registrations)
	table.clear(registry)
	started = false
end

return ControllerLoader
