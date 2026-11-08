--!strict
-- Targeting UI tuning. Pure data, no behaviour, no dependencies.
-- Frame layout, health bar look, both Highlight styles, and the optional
-- BillboardGui settings live here so the prototype can be revised in one place.

local TargetingUI = {}

-- ScreenGui container name.
TargetingUI.SCREEN_GUI = {
	NAME = "TargetingUI",
}

-- Screen-space combat target frame.
TargetingUI.FRAME = {
	POSITION = UDim2.new(0.5, 0, 0, 16),
	ANCHOR_POINT = Vector2.new(0.5, 0),
	SIZE = UDim2.new(0, 260, 0, 64),
	BACKGROUND_COLOR = Color3.fromRGB(20, 20, 20),
	BACKGROUND_TRANSPARENCY = 0.35,
}

-- Target name label.
TargetingUI.NAME = {
	POSITION = UDim2.new(0, 10, 0, 6),
	SIZE = UDim2.new(1, -20, 0, 22),
	FONT = Enum.Font.SourceSansBold,
	TEXT_SIZE = 18,
	TEXT_COLOR = Color3.fromRGB(255, 255, 255),
}

-- Health bar (background + fill).
TargetingUI.HEALTH_BAR = {
	POSITION = UDim2.new(0, 10, 0, 32),
	SIZE = UDim2.new(1, -20, 0, 14),
	BACKGROUND_COLOR = Color3.fromRGB(50, 50, 50),
	FILL_COLOR = Color3.fromRGB(200, 60, 60),
}

-- Current / max health text.
TargetingUI.HEALTH_TEXT = {
	POSITION = UDim2.new(0, 10, 0, 48),
	SIZE = UDim2.new(1, -20, 0, 14),
	FONT = Enum.Font.SourceSans,
	TEXT_SIZE = 13,
	TEXT_COLOR = Color3.fromRGB(230, 230, 230),
}

-- Combat target Highlight: clear, strong outline.
TargetingUI.COMBAT_HIGHLIGHT = {
	ENABLED = true,
	NAME = "CombatHighlight",
	FILL_COLOR = Color3.fromRGB(255, 80, 80),
	FILL_TRANSPARENCY = 0.6,
	OUTLINE_COLOR = Color3.fromRGB(255, 40, 40),
	OUTLINE_TRANSPARENCY = 0,
	DEPTH_MODE = Enum.HighlightDepthMode.AlwaysOnTop,
}

-- Interaction target Highlight: subtle, visually distinct from combat.
TargetingUI.INTERACT_HIGHLIGHT = {
	ENABLED = true,
	NAME = "InteractHighlight",
	FILL_COLOR = Color3.fromRGB(80, 160, 255),
	FILL_TRANSPARENCY = 0.85,
	OUTLINE_COLOR = Color3.fromRGB(120, 200, 255),
	OUTLINE_TRANSPARENCY = 0.4,
	DEPTH_MODE = Enum.HighlightDepthMode.Occluded,
}

-- Optional floating BillboardGui. Disabled by default: the screen-space frame
-- is the primary source of name/health. Enable later without restructuring.
TargetingUI.BILLBOARD = {
	ENABLED = false,
	NAME = "TargetBillboard",
	SIZE = UDim2.new(0, 200, 0, 32),
	STUDS_OFFSET = Vector3.new(0, 3, 0),
	ALWAYS_ON_TOP = false,
	TEXT_SIZE = 14,
	TEXT_COLOR = Color3.fromRGB(255, 255, 255),
	BACKGROUND_COLOR = Color3.fromRGB(20, 20, 20),
	BACKGROUND_TRANSPARENCY = 0.4,
}

return TargetingUI
