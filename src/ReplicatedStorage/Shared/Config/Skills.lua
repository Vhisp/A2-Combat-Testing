--!strict
-- Skill definitions and temporary keybinds. Pure data, no behaviour.
-- The only require is the types-only Types/Skills module, used so the data below
-- is type-checked against SkillDefinition and SkillKeybind.
-- Skill ids are lowercase strings keyed in DEFINITIONS.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SkillTypes = require(ReplicatedStorage.Shared.Types.Skills)

local Skills = {}

local definitions: { [string]: SkillTypes.SkillDefinition } = {
	strike = {
		displayName = "Strike",
		cooldown = 1.5, -- seconds
		range = 25, -- studs
		damage = {
			power = 20,
		},
	},
}

-- Temporary development binding: Strike on the 1 key.
-- The custom action bar will replace this with assignable slots.
local keybinds: { SkillTypes.SkillKeybind } = {
	{
		key = Enum.KeyCode.One,
		skillId = "strike",
	},
}

Skills.DEFINITIONS = definitions
Skills.KEYBINDS = keybinds

return Skills
