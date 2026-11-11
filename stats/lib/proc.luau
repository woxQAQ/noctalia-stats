--!nonstrict
-- Linux counters retain their identities until a new baseline replaces them.
local M = {}

local function words(line)
	local out = {}
	for word in string.gmatch(line, "%S+") do
		table.insert(out, word)
	end
	return out
end

local function delta(value, previous, elapsed)
	if value == nil or previous == nil or elapsed == nil or elapsed <= 0 or elapsed > 15 or value < previous then
		return nil
	end
	return (value - previous) / elapsed
end
M.rate = delta

function M.cpu(text, previous)
	local counters, cores, result = {}, {}, {}
	for line in string.gmatch(text, "[^\n]+") do
		local w = words(line)
		if w[1] == "cpu" or string.match(w[1] or "", "^cpu%d+$") then
			local c = { total = 0 }
			for i = 2, 9 do
				c.total += tonumber(w[i]) or 0
			end
			c.idle = (tonumber(w[5]) or 0) + (tonumber(w[6]) or 0)
			c.user = (tonumber(w[2]) or 0) + (tonumber(w[3]) or 0)
			c.system = (tonumber(w[4]) or 0) + (tonumber(w[7]) or 0) + (tonumber(w[8]) or 0)
			c.iowait = tonumber(w[6]) or 0
			counters[w[1]] = c
			local old = previous and previous[w[1]]
			if
				old
				and c.total > old.total
				and c.idle >= old.idle
				and c.user >= old.user
				and c.system >= old.system
				and c.iowait >= old.iowait
			then
				local total = c.total - old.total
				local row = {
					id = w[1],
					usage = math.clamp(100 * (1 - (c.idle - old.idle) / total), 0, 100),
					user = 100 * (c.user - old.user) / total,
					system = 100 * (c.system - old.system) / total,
					iowait = 100 * (c.iowait - old.iowait) / total,
				}
				if w[1] == "cpu" then
					result = row
				else
					table.insert(cores, row)
				end
			end
		end
	end
	result.cores = cores
	result.status = result.usage ~= nil and "ready" or "warming_up"
	return result, counters
end

function M.memory(text)
	local fields = {}
	for key, value in string.gmatch(text, "([%w_()]+):%s+(%d+)") do
		fields[key] = tonumber(value) * 1024
	end
	if not fields.MemTotal or not fields.MemAvailable or fields.MemTotal <= 0 then
		return { status = "error" }
	end
	local used = fields.MemTotal - fields.MemAvailable
	local kernel = fields.SUnreclaim
		and (fields.SUnreclaim + (fields.KernelStack or 0) + (fields.PageTables or 0) + (fields.Percpu or 0))
	local breakdown, known = {}, 0
	for _, part in ipairs({
		{ id = "anonymous", bytes = fields.AnonPages, color = "primary" },
		{ id = "shared_memory", bytes = fields.Shmem, color = "secondary" },
		{ id = "kernel_memory", bytes = kernel, color = "tertiary" },
	}) do
		if part.bytes then
			known += part.bytes
			table.insert(breakdown, part)
		end
	end
	if known <= used then
		table.insert(breakdown, { id = "other_used", bytes = used - known, color = "on_surface_variant" })
	else
		-- MemAvailable is an estimate. A transient inconsistent snapshot cannot
		-- be presented as a precise additive partition of used memory.
		breakdown = {}
	end
	return {
		status = "ready",
		total = fields.MemTotal,
		available = fields.MemAvailable,
		used = used,
		usage = 100 * used / fields.MemTotal,
		breakdown = breakdown,
		kernel = kernel,
		zswap = fields.Zswap,
		anonymous = fields.AnonPages,
		cached = fields.Cached,
		buffers = fields.Buffers,
		slab = fields.Slab,
		reclaimable = fields.SReclaimable,
		shmem = fields.Shmem,
		swapTotal = fields.SwapTotal,
		swapUsed = (fields.SwapTotal or 0) - (fields.SwapFree or 0),
	}
end

function M.disks(text, previous, elapsed, isWholeDevice)
	local counters, rows = {}, {}
	for line in string.gmatch(text, "[^\n]+") do
		local w = words(line)
		local name = w[3]
		if #w >= 14 and isWholeDevice(name) then
			local c = {
				id = w[1] .. ":" .. w[2],
				name = name,
				reads = tonumber(w[4]),
				readBytes = tonumber(w[6]) * 512,
				writes = tonumber(w[8]),
				writeBytes = tonumber(w[10]) * 512,
				busyMs = tonumber(w[13]),
			}
			counters[c.id] = c
			local old = previous and previous[c.id]
			if old and old.name ~= name then
				old = nil
			end
			local row = { id = c.id, name = name }
			local valid = old
				and c.reads >= old.reads
				and c.writes >= old.writes
				and c.readBytes >= old.readBytes
				and c.writeBytes >= old.writeBytes
				and c.busyMs >= old.busyMs
			if valid then
				row.read = delta(c.readBytes, old.readBytes, elapsed)
				row.write = delta(c.writeBytes, old.writeBytes, elapsed)
				row.iops = delta(c.reads + c.writes, old.reads + old.writes, elapsed)
				local busy = delta(c.busyMs, old.busyMs, elapsed)
				row.busy = busy and math.clamp(busy / 10, 0, 100)
			end
			row.status = row.read ~= nil and "ready" or "warming_up"
			table.insert(rows, row)
		end
	end
	table.sort(rows, function(a, b)
		return a.name < b.name
	end)
	return rows, counters
end

function M.network(text, previous, elapsed)
	local counters, rows = {}, {}
	for line in string.gmatch(text, "[^\n]+") do
		local name, data = string.match(line, "^%s*([^:]+):%s*(.+)$")
		if name and name ~= "lo" then
			local w = words(data)
			if #w >= 16 then
				local c = { rx = tonumber(w[1]), tx = tonumber(w[9]) }
				counters[name] = c
				local old = previous and previous[name]
				local rx, tx
				if old and c.rx >= old.rx and c.tx >= old.tx then
					rx, tx = delta(c.rx, old.rx, elapsed), delta(c.tx, old.tx, elapsed)
				end
				table.insert(rows, {
					name = name,
					rx = rx,
					tx = tx,
					rxTotal = c.rx,
					txTotal = c.tx,
					status = rx ~= nil and "ready" or "warming_up",
				})
			end
		end
	end
	table.sort(rows, function(a, b)
		return a.name < b.name
	end)
	return rows, counters
end

function M.pressure(text)
	if not text then
		return { status = "unsupported" }
	end
	local result = { status = "ready" }
	for line in string.gmatch(text, "[^\n]+") do
		local kind = string.match(line, "^(%w+)")
		local row = {}
		for key, value in string.gmatch(line, "(%w+)=(%S+)") do
			row[key] = tonumber(value)
		end
		if kind then
			result[kind] = row
		end
	end
	return result
end

function M.processes(snapshot, previous, limit)
	local elapsed = previous and snapshot.sampledAt - previous.sampledAt
	local oldById, byId, cpu, memory, io = {}, {}, {}, {}, {}
	if previous then
		oldById = previous.byId
	end
	for _, raw in ipairs(snapshot.processes) do
		local id = tostring(raw.pid) .. ":" .. raw.start
		byId[id] = raw
		local old = oldById[id]
		local row = { id = id, pid = raw.pid, name = raw.name, rss = raw.rssBytes }
		row.cpu = old and delta(raw.cpuSeconds, old.cpuSeconds, elapsed)
		if row.cpu then
			row.cpu *= 100
		end
		row.read = old and delta(raw.readBytes, old.readBytes, elapsed)
		row.write = old and delta(raw.writeBytes, old.writeBytes, elapsed)
		table.insert(memory, row)
		if row.cpu ~= nil then
			table.insert(cpu, row)
		end
		if row.read ~= nil and row.write ~= nil then
			table.insert(io, row)
		end
	end
	table.sort(cpu, function(a, b)
		if a.cpu == b.cpu then
			return a.pid < b.pid
		end
		return a.cpu > b.cpu
	end)
	table.sort(memory, function(a, b)
		if a.rss == b.rss then
			return a.pid < b.pid
		end
		return a.rss > b.rss
	end)
	table.sort(io, function(a, b)
		local av, bv = a.read + a.write, b.read + b.write
		if av == bv then
			return a.pid < b.pid
		end
		return av > bv
	end)
	for _, rows in ipairs({ cpu, memory, io }) do
		while #rows > limit do
			table.remove(rows)
		end
	end
	return {
		status = #cpu > 0 and "ready" or "warming_up",
		cpu = cpu,
		memory = memory,
		io = io,
		count = #snapshot.processes,
		denied = snapshot.denied,
		ioDenied = snapshot.ioDenied,
		scanMs = snapshot.scanMs,
	}, { sampledAt = snapshot.sampledAt, byId = byId }
end

return M
