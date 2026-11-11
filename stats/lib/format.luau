--!nonstrict
local M = {}

function M.tr(key)
	return noctalia.tr(key)
end

function M.percent(value)
	return value ~= nil and string.format("%.1f%%", value) or "—"
end

function M.bytes(value)
	if value == nil then
		return "—"
	end
	local units = { "B", "KiB", "MiB", "GiB", "TiB" }
	local i = 1
	while value >= 1024 and i < #units do
		value /= 1024
		i += 1
	end
	return string.format(value >= 100 and "%.0f %s" or "%.1f %s", value, units[i])
end

function M.rate(value)
	return value ~= nil and M.bytes(value) .. "/s" or "—"
end

function M.status(sample)
	if not sample then
		return M.tr("status.warming_up")
	end
	if sample.status == "ready" and not M.fresh(sample) then
		return M.tr("status.stale")
	end
	return M.tr("status." .. sample.status)
end

function M.fresh(sample)
	if not sample or sample.status ~= "ready" then
		return false
	end
	local age = noctalia.nowMs() - sample.at
	return age >= -1000 and age < math.max(10000, (sample.interval or 2) * 3000)
end

function M.graph(rows, percent)
	local values, values2, ceiling = {}, {}, percent and 100 or 1
	if not percent then
		for _, row in ipairs(rows) do
			ceiling = math.max(ceiling, row.value, row.value2 or 0)
		end
	end
	for _, row in ipairs(rows) do
		table.insert(values, math.clamp(row.value / ceiling, 0, 1))
		if row.value2 ~= nil then
			table.insert(values2, math.clamp(row.value2 / ceiling, 0, 1))
		end
	end
	return values, values2, ceiling
end

M.glyphs = { cpu = "cpu-usage", memory = "memory", disk = "storage", network = "arrows-transfer-up-down" }

function M.summary(resource, sample, metric)
	if not M.fresh(sample) then
		return "—", M.status(sample)
	end
	if resource == "cpu" then
		return M.percent(sample.cpu.usage), M.tr("cpu")
	end
	if resource == "memory" then
		return M.percent(sample.memory.usage), M.bytes(sample.memory.used) .. " / " .. M.bytes(sample.memory.total)
	end
	if resource == "disk" then
		if metric == "free" then
			return M.bytes(sample.disk.capacity and sample.disk.capacity.availableBytes), sample.disk.path
		end
		local row = sample.disk.selected
		if not row then
			return "—", M.tr("no_device")
		end
		return "R " .. M.rate(row.read) .. "  W " .. M.rate(row.write), row.name
	end
	local row = sample.network.selected
	if not row then
		return "—", M.tr("no_interface")
	end
	return "↓ " .. M.rate(row.rx) .. "  ↑ " .. M.rate(row.tx), row.name
end

return M
