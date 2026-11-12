--!nonstrict
local M = {}
M.choices = { "today", "7d", "30d" }
local hours = { ["1h"] = 1, ["6h"] = 6, ["24h"] = 24 }

function M.valid(value)
	return table.find(M.choices, value) ~= nil or hours[value] ~= nil
end

-- Search civil-day boundaries through the host timezone, including DST days.
local function midnight(at)
	local day = noctalia.formatTime("{:%Y-%m-%d}", at)
	local low, high = at - 172800, at
	while high - low > 1 do
		local mid = math.floor((low + high) / 2)
		if noctalia.formatTime("{:%Y-%m-%d}", mid) == day then
			high = mid
		else
			low = mid
		end
	end
	return high
end

function M.range(value, now)
	local finish = math.floor(now / 1000)
	local start
	if hours[value] then
		start = finish - hours[value] * 3600
	else
		local days = value == "7d" and 7 or value == "30d" and 30 or 1
		local today = midnight(finish)
		start = days == 1 and today or midnight(today + 43200 - (days - 1) * 86400)
	end
	local seconds = math.max(1, finish - start)
	local step = math.max(1, math.ceil(seconds / 24))
	return { window = value, start = start, finish = finish, seconds = seconds, step = step }
end

return M
