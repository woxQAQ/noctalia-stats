--!nonstrict
-- Each scenario drives complete entry VMs through the public host boundary.
local state, watchers = {}, {}
local now, uptime, tick = 100000, 100, 0
local monitor, missingCollector, rejectReads = true, false, false
local frameTicks = false
local processFails = false
local processLaunches = 0
local processResult = nil
local rendered = {}
local imageFiles = {}
local svgWrites = 0
local palette = {
	primary = "#3584e4",
	secondary = "#e01b24",
	tertiary = "#ff7800",
	on_surface = "#242424",
	on_surface_variant = "#666666",
}
local maxFrequency = 4000
local files = {}
local envs = {}
local configs = {
	interval_seconds = 2,
	history_seconds = 30,
	magpie_enabled = false,
	magpie_metrics_endpoint = "http://localhost:8428",
	magpie_service_name = "magpie",
	magpie_window = "1h",
	magpie_poll_seconds = 10,
	collector_command = "bin/noctalia-stats-collector",
	additional_interfaces = {},
	show_ipv6 = false,
	public_ip_enabled = true,
	public_ip_endpoint = "https://api.ipify.org",
	smooth_graphs = true,
	capacity_display = "both",
	disk_device = "",
	interface = "",
	disk_path = "/",
	display = "both",
	disk_metric = "free",
	network_layout = "stacked",
}

local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, item in pairs(value) do
		result[key] = copy(item)
	end
	return result
end

local function normalize(path)
	local parts = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return table.concat(parts, "/")
end

local function vm(path, vertical)
	local env = setmetatable({}, { __index = getfenv() })
	local cache = {}
	local function load(path)
		local fn, err = loadstring(assert(SOURCES[path], path), "@" .. path)
		assert(fn, err)
		local moduleEnv = setmetatable({}, { __index = env })
		moduleEnv.require = function(relative)
			local base = string.match(path, "^(.*)/")
			local target = normalize((base and base .. "/" or "") .. relative)
			if cache[target] == nil then
				cache[target] = load(target)
			end
			return cache[target]
		end
		setfenv(fn, moduleEnv)
		local result = fn()
		return result, moduleEnv
	end
	env.noctalia = {
		getConfig = function(key)
			assert(configs[key] ~= nil, key)
			return configs[key]
		end,
		setUpdateInterval = function() end,
		nowMs = function()
			return now
		end,
		systemStats = function()
			return monitor
					and { cpu = { tempC = 50, freqMhz = 3200, maxFreqMhz = maxFrequency }, loadAvg = { 1, 2, 3 } }
				or nil
		end,
		diskMounts = function()
			return { { path = "/", source = "/dev/vda1", filesystem = "ext4" } }
		end,
		diskStats = function()
			return monitor and { usagePercent = 25, totalBytes = 100000, availableBytes = 75000 } or nil
		end,
		fileExists = function(path)
			return path == "/sys/block/vda"
		end,
		readFileAsync = function(path, cb)
			if rejectReads then
				return false
			end
			cb(files[path], nil)
			return true
		end,
		getenv = function(key)
			return key == "XDG_RUNTIME_DIR" and "/runtime" or nil
		end,
		getColor = function(role)
			return palette[role]
		end,
		mkdirAll = function()
			return true
		end,
		writeFile = function(path, contents)
			svgWrites += 1
			imageFiles[path] = contents
			return true
		end,
		renameFile = function(from, to)
			imageFiles[to] = imageFiles[from]
			imageFiles[from] = nil
			return true
		end,
		pluginDir = function()
			return "/plugin"
		end,
		commandExists = function(name)
			return string.find(name, "noctalia-stats-collector", 1, true) ~= nil and not missingCollector
		end,
		runAsync = function(argv, cb)
			assert(type(argv) == "table", "subprocess must use direct argv")
			processLaunches += 1
			cb({
				exitCode = processFails and 1 or 0,
				stdout = argv[2] == "network" and "network-fixture" or "process-fixture",
				timedOut = false,
			})
			return true
		end,
		http = function(request, callback)
			assert(string.sub(request.url, 1, 8) == "https://")
			callback({ ok = true, status = 200, body = "198.51.100.8\n" })
			return true
		end,
		json = {
			decode = function(raw)
				if raw == "network-fixture" then
					return { version = 1, interfaces = { eth0 = { ipv4 = "192.168.1.2", ipv6 = "2001:db8::1" } } }
				end
				return copy(processResult)
			end,
		},
		tr = function(key)
			return TRANSLATIONS[key] or error("missing translation " .. key)
		end,
		log = function() end,
		openSettings = function() end,
		togglePanel = function(id)
			assert(id == "woxQAQ/stats:details")
		end,
		state = {
			get = function(key)
				return copy(state[key])
			end,
			set = function(key, value)
				state[key] = copy(value)
				for _, cb in ipairs(watchers[key] or {}) do
					cb(copy(value))
				end
			end,
			watch = function(key, cb)
				watchers[key] = watchers[key] or {}
				table.insert(watchers[key], cb)
			end,
		},
	}
	env.ui = setmetatable({}, {
		__index = function(_, kind)
			return function(props, children)
				assert(props.fontSize == nil or type(props.fontSize) == "number", "fontSize must be numeric")
				assert(props.text == nil or type(props.text) == "string", "text must be a string")
				if kind == "graph" then
					for _, series in ipairs({ props.values or {}, props.values2 or {} }) do
						for _, value in ipairs(series) do
							assert(value >= 0 and value <= 1, "graph range")
						end
					end
				end
				return { kind = kind, props = props, children = children or {} }
			end
		end,
	})
	env.barWidget = {
		isVertical = function()
			return vertical == true
		end,
		render = function(tree)
			rendered[path] = tree
		end,
		setTooltip = function() end,
	}
	env.panel = {
		render = function(tree)
			rendered[path] = tree
		end,
		setWantsSecondTicks = function() end,
		setNeedsFrameTick = function(value)
			frameTicks = value
		end,
		close = function() end,
	}
	local _, entry = load(path)
	table.insert(envs, entry)
	return entry
end

local function observation(step, start)
	tick = step
	uptime = 100 + step * 2
	now = uptime * 1000
	files = {
		["/proc/uptime"] = tostring(uptime) .. " 1\n",
		["/proc/stat"] = string.format(
			"cpu %d 0 0 %d 0 0 0 0 0 0\ncpu0 %d 0 0 %d 0 0 0 0 0 0\ncpu3 %d 0 0 %d 0 0 0 0 0 0\n",
			100 + step * 40,
			900 + step * 160,
			50 + step * 20,
			450 + step * 80,
			50 + step * 20,
			450 + step * 80
		),
		["/proc/meminfo"] = "MemTotal: 1000 kB\nMemAvailable: 750 kB\nCached: 200 kB\nAnonPages: 100 kB\nShmem: 25 kB\nSUnreclaim: 15 kB\nKernelStack: 2 kB\nPageTables: 3 kB\nZswap: 5 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n",
		["/proc/diskstats"] = string.format(
			"252 0 vda %d 0 %d 0 %d 0 %d 0 0 %d 0\n252 1 vda1 1 0 1 0 1 0 1 0 0 1 0\n",
			10 + step * 2,
			100 + step * 4,
			10 + step,
			100 + step * 8,
			100 + step * 200
		),
		["/proc/net/dev"] = string.format(
			" eth0: %d 0 0 0 0 0 0 0 %d 0 0 0 0 0 0 0\n docker0: 99999999 0 0 0 0 0 0 0 88888888 0 0 0 0 0 0 0\n",
			10000 + step * 2048,
			10000 + step * 1024
		),
		["/proc/net/route"] = "docker0 00000000 01010101 0003 0 0 1000 00000000\neth0 00000000 01010101 0003 0 0 100 00000000\n",
		["/proc/pressure/cpu"] = "some avg10=1.00 avg60=0.5 avg300=0.1 total=1000\n",
		["/proc/pressure/memory"] = "some avg10=0.00 avg60=0 avg300=0 total=0\n",
		["/proc/pressure/io"] = "some avg10=2.00 avg60=1 avg300=0 total=1000\n",
	}
	processResult = {
		version = 1,
		sampledAt = uptime,
		scanMs = 4,
		denied = 2,
		ioDenied = 3,
		processes = {
			{
				pid = 42,
				name = "worker ) name",
				start = start or "1",
				cpuSeconds = 1 + step,
				rssBytes = 2048,
				readBytes = 100 + step * 100,
				writeBytes = 100 + step * 200,
			},
		},
	}
end

observation(0)
local service = vm("service.luau")
assert(state.snapshot.cpu.status == "warming_up")
assert(state.snapshot.memory.usage == 25)
assert(#state.snapshot.disk.devices == 1, "partitions must not duplicate whole devices")
assert(#state.history_cpu == 0)
local cpuWidget = vm("cpu.luau")
vm("cpu.luau", true)
vm("memory.luau")
vm("disk.luau")
vm("network.luau")
assert(processLaunches == 0, "closed panels must not scan processes")
cpuWidget.onClick()
local panelEntry = vm("panel.luau")
panelEntry.onOpen()
observation(1)
service.update()
assert(state.processes.status == "warming_up")
observation(2)
panelEntry.update()
service.update()
assert(math.abs(state.snapshot.cpu.usage - 20) < 0.0001)
assert(state.snapshot.cpu.cores[2].id == "cpu3", "sparse CPU ids must survive")
assert(state.snapshot.disk.selected.read == 1024)
assert(state.snapshot.disk.selected.write == 2048)
assert(state.snapshot.network.selected.rx == 1024)
assert(
	#state.snapshot.network.interfaces == 1 and state.snapshot.network.interfaces[1].name == "eth0",
	"only the monitored interface is visible by default"
)
assert(#state.snapshot.network.available == 2)
local partition = 0
for _, part in ipairs(state.snapshot.memory.breakdown) do
	partition += part.bytes
end
assert(partition == state.snapshot.memory.used, "memory ring groups must add up to used memory")
assert(state.snapshot.pressure.cpu.some.avg10 == 1)
assert(state.processes.cpu[1].cpu == 50)
assert(state.processes.io[1].write == 100)
assert(state.processes.memory[1].rss == 2048)
assert(#state.history_cpu == 2, "multiple widgets must not create extra samples")
assert(frameTicks, "new chart samples request a short presentation transition")
now += 300
panelEntry.onFrameTick("300")
assert(not frameTicks, "chart transitions stop when settled")
assert(#state.history_cpu == 2, "animation never fabricates measured history samples")

-- Each bar entry chooses its resource before the corresponding popup opens.
local function findControl(node, kind, key)
	if node.kind == kind and (not key or node.props.key == key) then
		return node
	end
	for _, child in ipairs(node.children) do
		local found = findControl(child, kind, key)
		if found then
			return found
		end
	end
	return nil
end
local function gaugeSvg(id)
	local column = assert(findControl(rendered["panel.luau"], "column", id), "gauge belongs in the real popup tree")
	local image = assert(findControl(column, "image"))
	return assert(imageFiles[image.props.path])
end
local cpuRing = gaugeSvg("cpu_usage")
assert(string.find(cpuRing, "stroke-dasharray", 1, true), "CPU usage must draw a measured arc")
assert(string.find(cpuRing, ">20.0%</text>", 1, true))
local beforeGaugeRefresh = svgWrites
panelEntry.update()
assert(svgWrites == beforeGaugeRefresh, "unchanged data must not rewrite gauge files on UI ticks")
local beforeImage = findControl(findControl(rendered["panel.luau"], "column", "cpu_usage"), "image")
palette.primary = "#26a269"
panelEntry.update()
assert(string.find(gaugeSvg("cpu_usage"), palette.primary, 1, true), "gauges follow live palette changes")
palette.primary = "#9141ac"
panelEntry.update()
local afterImage = findControl(findControl(rendered["panel.luau"], "column", "cpu_usage"), "image")
assert(beforeImage.props.path == afterImage.props.path)
assert(beforeImage.props.key ~= afterImage.props.key, "coalesced updates still invalidate the native image")

local speedColumn = assert(findControl(rendered["network.luau"], "column"))
assert(
	speedColumn.children[1].props.key == "rx" and speedColumn.children[2].props.key == "tx",
	"download and upload share one column"
)
assert(findControl(speedColumn.children[1], "glyph").props.name == "arrow-down")
assert(findControl(speedColumn.children[1], "label").props.text == "1.0 KiB/s")
assert(findControl(speedColumn.children[2], "glyph").props.name == "arrow-up")
assert(findControl(speedColumn.children[2], "label").props.text == "512 B/s")
local capacityBar = assert(findControl(rendered["disk.luau"], "progress"))
assert(capacityBar.props.progress == 0.75, "capacity mode shows available space, not I/O activity")
assert(findControl(rendered["disk.luau"], "graph") == nil)

local function collectTexts(node, values)
	values = values or {}
	if node.kind == "label" then
		values[node.props.text] = true
	end
	for _, child in ipairs(node.children) do
		collectTexts(child, values)
	end
	return values
end
for _, name in ipairs({ "cpu", "memory", "disk", "network" }) do
	panelEntry.onClose()
	local widget = vm(name .. ".luau")
	widget.onClick()
	panelEntry.onOpen()
	panelEntry.update()
	assert(state.selected_resource == name)
	assert(state.detail_lease.resource == name, "opening a resource renews the matching collector demand")
	assert(rendered["panel.luau"].kind == "column")
	if name == "network" then
		local text = collectTexts(rendered["panel.luau"])
		assert(text["192.168.1.2"] and text["198.51.100.8"], "local and public IP are distinct fields")
		assert(not text["2001:db8::1"], "IPv6 is hidden by default")
	end
	if name == "disk" then
		assert(
			findControl(rendered["panel.luau"], "column", "disk_io"),
			"rates and history share the disk activity component"
		)
	end
	if name == "memory" then
		assert(string.find(gaugeSvg("memory_usage"), ">25.0%</text>", 1, true))
		assert(
			string.find(gaugeSvg("memory_usage"), palette.tertiary, 1, true),
			"memory ring includes the kernel allocation segment"
		)
		assert(findControl(rendered["panel.luau"], "row", "memory_composition"))
		assert(
			not string.find(gaugeSvg("memory_pressure"), "stroke-dasharray", 1, true),
			"zero pressure has no colored arc"
		)
	end
end
state.selected_resource = "cpu"
panelEntry.onOpen()
observation(3, "2")
panelEntry.update()
service.update()
assert(#state.processes.cpu == 0, "reused PID needs a fresh identity baseline")

-- Counter resets produce no negative samples or false idle observations.
observation(0, "2")
panelEntry.update()
service.update()
assert(state.snapshot.cpu.status == "warming_up")
assert(#state.history_cpu == 0)
assert(state.snapshot.network.selected.rx == nil)

panelEntry.onClose()
assert(not frameTicks, "closing the popup stops animation frame callbacks")
local before = processLaunches
observation(4)
service.update()
assert(processLaunches == before, "closing the panel stops process scans")
assert(state.processes.status == "inactive")

-- Expired leases recover from panel crashes without requiring onClose.
state.detail_lease = { resource = "cpu", expires = now - 1 }
observation(5)
service.update()
assert(processLaunches == before)

monitor = false
service.update()
assert(state.snapshot.status == "disabled")
cpuWidget.update()
monitor = true
observation(6)
service.update()
assert(state.snapshot.cpu.status == "warming_up", "enable starts a new counter baseline")

rejectReads = true
observation(7)
service.update()
assert(state.snapshot.status == "error", "rejected reads must finish the batch")
rejectReads = false
observation(8)
service.update()
assert(state.snapshot.cpu.status == "warming_up")

missingCollector = true
state.selected_resource = "cpu"
panelEntry.onOpen()
observation(9)
panelEntry.update()
service.update()
assert(state.processes.status == "missing_dependency")

-- Long suspend gaps start new histories instead of joining unrelated intervals.
observation(50)
panelEntry.update()
service.update()
assert(state.snapshot.cpu.status == "warming_up")
assert(#state.history_cpu == 0)
missingCollector = false
processFails = true
observation(51)
panelEntry.update()
service.update()
assert(state.processes.status == "error", "collector failure is visible without breaking basic metrics")
processFails = false
panelEntry.onClose()

observation(52)
files["/proc/diskstats"] = ""
files["/proc/net/dev"] = ""
service.update()
assert(state.snapshot.disk.selected == nil)
assert(state.snapshot.network.selected == nil)
assert(#state.history_disk == 0 and #state.history_network == 0, "removed devices cannot retain a live chart")
for step = 53, 75 do
	observation(step)
	service.update()
end
assert(#state.history_cpu <= 16, "history is bounded by the configured time window")

configs.disk_device = "missing-device"
configs.interface = "missing-interface"
local configuredService = vm("service.luau")
observation(76)
configuredService.update()
assert(state.snapshot.disk.selected == nil, "an explicit device never falls back")
assert(state.snapshot.network.selected == nil, "an explicit interface never falls back")
maxFrequency = nil
observation(77)
configuredService.update()
state.selected_resource = "cpu"
panelEntry.onOpen()
assert(
	not string.find(gaugeSvg("cpu_frequency"), "stroke-dasharray", 1, true),
	"unknown frequency ceiling cannot imply a percentage"
)
local imageCount = 0
for path in pairs(imageFiles) do
	assert(not string.match(path, "%.tmp$"), "atomic writes leave no temporary files")
	imageCount += 1
end
assert(imageCount <= 10, "five popup gauges use at most two files each")

configs.interface = "eth0"
configs.disk_device = ""
configs.additional_interfaces = { "docker0" }
local selectedService = vm("service.luau")
observation(78)
selectedService.update()
observation(79)
selectedService.update()
assert(#state.snapshot.network.interfaces == 2, "additional interfaces are explicitly selected")
assert(state.snapshot.network.selected.rx == 1024, "extra interfaces do not alter the monitored speed")
for name, styles in pairs(STYLES) do
	local widgetResource = name == "disk_io" and "disk" or name
	configs.disk_metric = name == "disk_io" and "io" or "free"
	for _, style in ipairs(styles) do
		configs.display = style
		configs.capacity_display = style
		vm(widgetResource .. ".luau")
		local tree = rendered[widgetResource .. ".luau"]
		assert(#tree.children > 0, "every declared style renders real content")
		if style == "ring" or style == "pie" or style == "gauge" then
			assert(findControl(tree, "image"))
		end
		if style == "graph" or style == "line" then
			local graph = assert(findControl(tree, "graph"))
			assert((graph.props.fillOpacity > 0) == (style == "graph"))
		end
	end
end

print(
	"PASS: service, multi-widget, panel, counters, PID reuse, leases, disabled monitor, read failure, missing dependency, suspend, collector failure, device removal, bounded history, explicit selection"
)
