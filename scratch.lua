--- The surface that `/forge-verify` and `/forge-circuit` build on.
---
--- A blueprint pasted onto chunks that have never been generated places
--- nothing at all, and says nothing about it: there is simply no ground to
--- build on, and the call returns an empty list. That is exactly how the first
--- version reported "0 placed" for a blueprint the player could paste by hand
--- without trouble. So generating the ground first is not a refinement here,
--- it is the difference between working and not.

local M = {}

local NAME = "forge-scratch"
local CHUNK = 32

--- The scratch surface, created on first use.
---
--- Lab tiles because they are flat, buildable and free of decoration; day
--- frozen because a circuit run must not be measuring the time of day.
function M.surface()
    local surface = game.surfaces[NAME]
    if not surface then
        surface = game.create_surface(NAME, { width = 2000, height = 2000 })
        surface.generate_with_lab_tiles = true
        surface.always_day = true
        surface.freeze_daytime = true
    end
    return surface
end

--- Empty it, so one run cannot see what the previous run left behind.
function M.clear(surface)
    for _, entity in pairs(surface.find_entities()) do
        entity.destroy()
    end
end

--- Generate the ground the blueprint is about to be built on.
---
---@param surface LuaSurface
---@param entities table|nil blueprint entities, in blueprint coordinates
---@param origin table where the blueprint will be pasted
function M.prepare(surface, entities, origin)
    local reach = 0
    for _, entry in pairs(entities or {}) do
        local position = entry.position or { x = 0, y = 0 }
        reach = math.max(reach, math.abs(position.x), math.abs(position.y))
    end

    -- A square of chunks around the paste point, wide enough for the whole
    -- blueprint and one chunk of slack, since an entity can reach past the
    -- position it is recorded at.
    surface.request_to_generate_chunks(origin, math.ceil(reach / CHUNK) + 1)
    surface.force_generate_chunk_requests()
end

return M
