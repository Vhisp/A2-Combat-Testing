--!strict
-- Runtime stats configuration. Pure data, no behaviour.
-- Phase 4 covers Mana only; no other stats are defined here.

local Stats = {}

-- Maximum Mana every character generation starts with, and starts FULL at.
-- Placeholder: no skill spends Mana yet, and class values will replace this later.
Stats.BASE_MAX_MANA = 100

-- Sanity ceiling for any maximum-Mana value. Rejects absurd (but finite) values so they
-- cannot reach runtime state or overflow arithmetic.
Stats.MAX_MANA_LIMIT = 1000000

return Stats
