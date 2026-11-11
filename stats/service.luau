--!nonstrict
local proc = require("./lib/proc.luau")
local collector = require("./lib/collector.luau")
local previous = {}
local processBaseline = nil
local processBusy = false
local lastProcessLaunch = 0
local sampling = false
local histories = {}
local sequence = 0
local interval = noctalia.getConfig("interval_seconds")
local window = noctalia.getConfig("history_seconds")
local additionalInterfaces = noctalia.getConfig("additional_interfaces")
local diskDevice = noctalia.getConfig("disk_device")
local interface = noctalia.getConfig("interface")
local diskPath = noctalia.getConfig("disk_path")
local lastProcesses = nil

local function remember(key, t, value, value2)
	local rows = histories[key] or {}
	if value == nil then
		-- A missing observation starts a new continuous segment; no false zeroes.
		rows = {}
	else
		table.insert(rows, { t = t, value = value, value2 = value2 })
		while #rows > math.ceil(window / interval) + 1 or (#rows > 0 and rows[1].t < t - window) do
			table.remove(rows, 1)
		end
	end
	histories[key] = rows
end

local function selectRow(rows, name)
	for _, row in ipairs(rows) do
		if row.name == name then
			return row
		end
	end
	if name ~= "" then
		return nil
	end
	return rows[1]
end

local function wholeDevice(name)
	return not string.match(name, "^loop")
		and not string.match(name, "^ram")
		and noctalia.fileExists("/sys/block/" .. name)
end

local function publishProcesses()
	local lease = noctalia.state.get("detail_lease")
	local now = noctalia.nowMs()
	if not lease or lease.expires < now or lease.expires > now + 10000 or lease.resource == "network" then
		processBaseline = nil
		lastProcesses = nil
		noctalia.state.set("processes", { status = "inactive" })
		return
	end
	if processBusy or now - lastProcessLaunch < math.max(2000, interval * 1000) then
		return
	end
	if not noctalia.commandExists(collector.path()) then
		noctalia.state.set("processes", { status = "missing_dependency" })
		return
	end
	processBusy = true
	lastProcessLaunch = now
	local arguments = lease.resource == "disk" and { "processes", "--io" } or { "processes" }
	local accepted = collector.run(arguments, function(result)
		processBusy = false
		if result.exitCode ~= 0 or result.timedOut or result.stdoutTruncated then
			noctalia.log(
				"process snapshot failed: "
					.. tostring(result.stderr or "")
					.. " (exit="
					.. tostring(result.exitCode)
					.. ", timeout="
					.. tostring(result.timedOut)
					.. ", truncated="
					.. tostring(result.stdoutTruncated)
					.. ")"
			)
			processBaseline = nil
			lastProcesses = nil
			noctalia.state.set("processes", { status = "error" })
			return
		end
		local raw = noctalia.json.decode(result.stdout)
		if type(raw) ~= "table" or raw.version ~= 1 or type(raw.processes) ~= "table" then
			processBaseline = nil
			lastProcesses = nil
			noctalia.state.set("processes", { status = "error" })
			return
		end
		local currentLease = noctalia.state.get("detail_lease")
		if not currentLease or currentLease.expires < noctalia.nowMs() then
			processBaseline = nil
			return
		end
		local rows
		rows, processBaseline = proc.processes(raw, processBaseline, 10)
		rows.at = noctalia.nowMs()
		lastProcesses = rows
		noctalia.state.set("processes", rows)
	end)
	if not accepted then
		processBusy = false
		noctalia.state.set("processes", { status = "error" })
	end
end

local function publish(files, host)
	local t = tonumber(string.match(files.uptime or "", "^(%S+)"))
	if not t then
		previous = {}
		histories = {}
		noctalia.state.set("snapshot", { status = "error", at = noctalia.nowMs() })
		return
	end
	local elapsed = previous.t and t - previous.t
	if elapsed and (elapsed <= 0 or elapsed > math.min(15, interval * 2.5)) then
		previous = {}
		histories = {}
		elapsed = nil
	end
	local cpu, cpuCounters
	if files.cpu then
		cpu, cpuCounters = proc.cpu(files.cpu, previous.cpu)
	else
		cpu = { status = "error", cores = {} }
	end
	cpu.temp = host.cpu and host.cpu.tempC
	cpu.freq = host.cpu and host.cpu.freqMhz
	cpu.maxFreq = host.cpu and host.cpu.maxFreqMhz
	cpu.load = host.loadAvg
	local memory = files.memory and proc.memory(files.memory) or { status = "error" }
	local disks, diskCounters = {}, nil
	if files.disks then
		disks, diskCounters = proc.disks(files.disks, previous.disks, elapsed, wholeDevice)
	end
	local network, networkCounters = {}, nil
	if files.network then
		network, networkCounters = proc.network(files.network, previous.network, elapsed)
	end
	local defaultInterface, bestMetric = "", math.huge
	for line in string.gmatch(files.route or "", "[^\n]+") do
		local fields = {}
		for word in string.gmatch(line, "%S+") do
			table.insert(fields, word)
		end
		local flags, metric = tonumber(fields[4] or "", 16), tonumber(fields[7] or "")
		if
			fields[2] == "00000000"
			and fields[8] == "00000000"
			and flags
			and bit32.band(flags, 1) == 1
			and metric
			and metric < bestMetric
		then
			defaultInterface, bestMetric = fields[1], metric
		end
	end
	local selectedDisk = selectRow(disks, diskDevice)
	local selectedNetwork = selectRow(network, interface ~= "" and interface or defaultInterface)
	if not selectedNetwork and interface == "" then
		selectedNetwork = network[1]
	end
	local mounts = {}
	for _, mount in ipairs(noctalia.diskMounts()) do
		local capacity = noctalia.diskStats(mount.path)
		table.insert(
			mounts,
			{ path = mount.path, source = mount.source, filesystem = mount.filesystem, capacity = capacity }
		)
	end
	local capacity = noctalia.diskStats(diskPath)
	local disk = { devices = disks, selected = selectedDisk, mounts = mounts, path = diskPath, capacity = capacity }
	local visibleInterfaces = {}
	for _, row in ipairs(network) do
		if (selectedNetwork and row.name == selectedNetwork.name) or table.find(additionalInterfaces, row.name) then
			table.insert(visibleInterfaces, row)
		end
	end
	local availableInterfaces = {}
	for _, row in ipairs(network) do
		table.insert(availableInterfaces, row.name)
	end
	local net = {
		interfaces = visibleInterfaces,
		selected = selectedNetwork,
		available = availableInterfaces,
		defaultInterface = defaultInterface,
	}
	sequence += 1
	remember("cpu", t, cpu.usage)
	remember("memory", t, memory.usage)
	local alive = { cpu = true, memory = true }
	for _, row in ipairs(disks) do
		local key = "disk:" .. row.id
		alive[key] = true
		remember(key, t, row.read, row.write)
	end
	for _, row in ipairs(visibleInterfaces) do
		local key = "net:" .. row.name
		alive[key] = true
		remember(key, t, row.rx, row.tx)
	end
	for key in pairs(histories) do
		if not alive[key] then
			histories[key] = nil
		end
	end
	local sample = {
		status = "ready",
		at = noctalia.nowMs(),
		t = t,
		sequence = sequence,
		interval = interval,
		cpu = cpu,
		memory = memory,
		disk = disk,
		network = net,
		pressure = {
			cpu = proc.pressure(files.psiCpu),
			memory = proc.pressure(files.psiMemory),
			disk = proc.pressure(files.psiIo),
		},
	}
	previous = { t = t, cpu = cpuCounters, disks = diskCounters, network = networkCounters }
	noctalia.state.set("history_cpu", histories.cpu)
	noctalia.state.set("history_memory", histories.memory)
	noctalia.state.set("history_disk", selectedDisk and histories["disk:" .. selectedDisk.id] or {})
	noctalia.state.set("history_network", selectedNetwork and histories["net:" .. selectedNetwork.name] or {})
	noctalia.state.set("snapshot", sample)
end

function update()
	if sampling then
		return
	end
	local host = noctalia.systemStats()
	if not host then
		previous, histories, processBaseline = {}, {}, nil
		lastProcesses = nil
		noctalia.state.set("snapshot", { status = "disabled", at = noctalia.nowMs() })
		noctalia.state.set("processes", { status = "inactive" })
		return
	end
	if lastProcesses and noctalia.nowMs() - lastProcesses.at > 10000 then
		lastProcesses = nil
		processBaseline = nil
		noctalia.state.set("processes", { status = "stale" })
	end
	publishProcesses()
	sampling = true
	local tasks = {
		{ "uptime", "/proc/uptime" },
		{ "cpu", "/proc/stat" },
		{ "memory", "/proc/meminfo" },
		{ "disks", "/proc/diskstats" },
		{ "network", "/proc/net/dev" },
		{ "route", "/proc/net/route" },
		{ "psiCpu", "/proc/pressure/cpu" },
		{ "psiMemory", "/proc/pressure/memory" },
		{ "psiIo", "/proc/pressure/io" },
	}
	local files = {}
	local index = 0
	local function nextRead()
		index += 1
		local task = tasks[index]
		if not task then
			sampling = false
			publish(files, host)
			return
		end
		local accepted = noctalia.readFileAsync(task[2], function(contents)
			files[task[1]] = contents
			nextRead()
		end)
		if not accepted then
			nextRead()
		end
	end
	nextRead()
end

function onIpc(event)
	if event ~= "diagnose" then
		return
	end
	local root = noctalia.getenv("XDG_RUNTIME_DIR") or noctalia.pluginDataDir()
	if not root then
		return
	end
	local directory = root .. "/noctalia-stats"
	if not noctalia.mkdirAll(directory) then
		return
	end
	local snapshot = noctalia.state.get("snapshot")
	local processes = noctalia.state.get("processes")
	noctalia.writeFile(
		directory .. "/diagnostics.json",
		noctalia.json.encode({
			at = noctalia.nowMs(),
			collector = collector.path(),
			executable = noctalia.commandExists(collector.path()),
			sampling = sampling,
			processBusy = processBusy,
			snapshotStatus = snapshot and snapshot.status,
			snapshotAgeMs = snapshot and noctalia.nowMs() - snapshot.at,
			processStatus = processes and processes.status,
			processCount = processes and processes.count,
			processAgeMs = processes and processes.at and noctalia.nowMs() - processes.at,
		}, true)
	)
end

noctalia.setUpdateInterval(interval * 1000)
noctalia.state.set("snapshot", { status = "warming_up", at = noctalia.nowMs() })
noctalia.state.set("processes", { status = "inactive" })
update()
