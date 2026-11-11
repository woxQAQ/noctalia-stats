--!nonstrict
-- Interpolate presentation only; measured histories retain their real cadence.
local M = {}
local states = {}
local enabled = noctalia.getConfig("smooth_graphs")
local duration = 240

local function equal(a, b)
	if #a ~= #b then
		return false
	end
	for i, value in ipairs(a) do
		if value ~= b[i] then
			return false
		end
	end
	return true
end

local function interpolate(from, to, progress)
	local out = {}
	for i, value in ipairs(to) do
		local old = from[i] or from[#from] or value
		out[i] = old + (value - old) * progress
	end
	return out
end

local function current(state, now)
	if not state.started then
		return state.a, state.b, false
	end
	local elapsed = now - state.started
	local progress = elapsed < 0 and 1 or math.clamp(elapsed / duration, 0, 1)
	if progress >= 1 then
		state.started = nil
		return state.a, state.b, false
	end
	local eased = progress * progress * (3 - 2 * progress)
	return interpolate(state.fromA, state.a, eased), interpolate(state.fromB, state.b, eased), true
end

function M.series(key, a, b)
	b = b or {}
	local now = noctalia.nowMs()
	local state = states[key]
	if not state then
		state = { a = a, b = b }
		states[key] = state
	elseif not equal(state.a, a) or not equal(state.b, b) then
		local fromA, fromB = current(state, now)
		state =
			{ a = a, b = b, fromA = fromA, fromB = fromB, started = enabled and #fromA > 0 and #a > 0 and now or nil }
		states[key] = state
	end
	return current(state, now)
end

function M.active()
	for _, state in pairs(states) do
		local _, _, active = current(state, noctalia.nowMs())
		if active then
			return true
		end
	end
	return false
end

function M.reset()
	states = {}
end
return M
