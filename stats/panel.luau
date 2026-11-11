--!nonstrict
local f = require("./lib/format.luau")
local gauge = require("./lib/gauge.luau")
local collector = require("./lib/collector.luau")
local charts = require("./lib/charts.luau")
local showIpv6 = noctalia.getConfig("show_ipv6")
local publicEnabled = noctalia.getConfig("public_ip_enabled")
local publicEndpoint = noctalia.getConfig("public_ip_endpoint")
local publicAddresses = {}
local lastPublicRead = -math.huge
local publicRoute
local publicGeneration = 0
local extraMemory = false
local frameElapsed = 0
local resource = "cpu"
local opened = false
local resources = { "cpu", "memory", "disk", "network" }
local addresses = {}
local addressBusy = false
local lastAddressRead = -math.huge
local render

local function label(text, props)
	props = props or {}
	props.text = text
	props.fontSize = props.fontSize or 12
	return ui.label(props)
end

local function note(text)
	return label(text, { color = "on_surface_variant", fontSize = 11, maxLines = 3 })
end

local function metric(name, value, color)
	return ui.row({ justify = "space_between", gap = 8, align = "center" }, {
		label(name, { color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
		label(value, { fontWeight = "medium", color = color, textAlign = "end" }),
	})
end

local function section(name, hint)
	return ui.row({ gap = 6, align = "center", paddingV = 1, tooltip = hint }, {
		ui.separator({ flexGrow = 1, orientation = "horizontal" }),
		label(name, { fontSize = 11, color = "on_surface_variant" }),
		ui.separator({ flexGrow = 1, orientation = "horizontal" }),
	})
end

local function legend(name, value, color)
	return ui.row({ gap = 6, align = "center" }, {
		ui.box({ width = 7, height = 7, radius = 2, fill = color }),
		label(name, { flexGrow = 1 }),
		label(value, { fontWeight = "medium", textAlign = "end" }),
	})
end

local function headline(name, value, color)
	return ui.column({ gap = 3, flexGrow = 1, align = "center" }, {
		label(value, { fontSize = 23, fontWeight = "medium", color = color }),
		label(name, { fontSize = 11, color = "on_surface_variant" }),
	})
end

local function lease()
	noctalia.state.set("detail_lease", { resource = resource, expires = noctalia.nowMs() + 5000 })
end

local function readPublicAddresses()
	if not publicEnabled then
		return
	end
	local snapshot = noctalia.state.get("snapshot")
	local route = snapshot and snapshot.network and snapshot.network.defaultInterface
	if route ~= publicRoute then
		publicRoute = route
		lastPublicRead = -math.huge
	end
	local elapsed = noctalia.nowMs() - lastPublicRead
	if elapsed >= 0 and elapsed < 60000 then
		return
	end
	lastPublicRead = noctalia.nowMs()
	publicGeneration += 1
	local generation = publicGeneration
	publicAddresses = {}
	local function lookup(key, url)
		if string.sub(url, 1, 8) ~= "https://" then
			return
		end
		noctalia.http({ url = url }, function(result)
			if generation ~= publicGeneration then
				return
			end
			if result.ok and result.status == 200 then
				local value = string.match(result.body, "^%s*(%S+)%s*$")
				local valid = value and #value <= 45
				if key == "ipv4" and valid then
					local count = 0
					for part in string.gmatch(value, "[^.]+") do
						local n = tonumber(part)
						if not n or n < 0 or n > 255 or n % 1 ~= 0 then
							valid = false
						end
						count += 1
					end
					valid = valid and count == 4 and string.match(value, "^%d+%.%d+%.%d+%.%d+$")
				elseif valid then
					valid = string.match(value, "^[%x:]+$") and string.find(value, ":", 1, true)
				end
				if valid then
					publicAddresses[key] = value
				end
			end
			if opened then
				render()
			end
		end)
	end
	lookup("ipv4", publicEndpoint)
	if showIpv6 then
		lookup("ipv6", "https://api6.ipify.org")
	end
end

local function readAddresses()
	if resource ~= "network" then
		return
	end
	readPublicAddresses()
	local elapsed = noctalia.nowMs() - lastAddressRead
	if addressBusy or (elapsed >= 0 and elapsed < 30000) then
		return
	end
	lastAddressRead = noctalia.nowMs()
	addressBusy = true
	local accepted = collector.run({ "network" }, function(result)
		addressBusy = false
		addresses = {}
		if result.exitCode == 0 and not result.stdoutTruncated then
			local raw = noctalia.json.decode(result.stdout)
			if type(raw) == "table" and raw.version == 1 and type(raw.interfaces) == "table" then
				addresses = raw.interfaces
			end
		end
		if opened then
			render()
		end
	end)
	if not accepted then
		addressBusy = false
	end
end

local function pressure(sample)
	local psi = sample.pressure[resource]
	if not psi or psi.status ~= "ready" then
		return note(f.tr("psi_unavailable"))
	end
	return ui.column({ tooltip = f.tr("psi_hint") }, {
		metric(f.tr("psi_some"), psi.some and f.percent(psi.some.avg10) or "—"),
	})
end

local function history(compact)
	local rows = noctalia.state.get("history_" .. resource) or {}
	local percent = resource == "cpu" or resource == "memory"
	local v1, v2, ceiling = f.graph(rows, percent)
	local sample = noctalia.state.get("snapshot")
	local identity = resource
	if sample and resource == "disk" and sample.disk.selected then
		identity ..= ":" .. sample.disk.selected.id
	end
	if sample and resource == "network" and sample.network.selected then
		identity ..= ":" .. sample.network.selected.name
	end
	v1, v2 = charts.series(identity, v1, v2)
	local seconds = #rows >= 2 and rows[#rows].t - rows[1].t or 0
	local children = compact and {} or { section(f.tr("usage_history")) }
	if #v1 >= 2 then
		table.insert(
			children,
			ui.graph({
				key = "graph_" .. resource,
				values = v1,
				values2 = v2,
				color = "primary",
				color2 = "secondary",
				height = compact and 64 or 76,
				fillOpacity = 0.55,
				lineWidth = 1,
			})
		)
		table.insert(
			children,
			ui.row({ justify = "space_between" }, {
				note(string.format(f.tr("history_span"), seconds)),
				note(percent and "0–100%" or "0–" .. f.rate(ceiling)),
			})
		)
	else
		table.insert(
			children,
			ui.column({ height = compact and 64 or 76, justify = "center", align = "center" }, {
				note(f.tr("history_warming")),
			})
		)
	end
	return ui.column({ key = "history_" .. resource, flexGrow = compact and 1 or nil, gap = 3 }, children)
end

local function processRows()
	local data = noctalia.state.get("processes")
	local hint = f.tr(resource == "cpu" and "cpu_process_hint" or resource == "memory" and "rss_hint" or "io_hint")
	local rows = { section(f.tr("top_processes"), hint) }
	if not data or data.status == "inactive" then
		table.insert(rows, note(f.tr("process_warming")))
		return ui.column({ gap = 4 }, rows)
	end
	local age = data.at and noctalia.nowMs() - data.at
	if (data.status ~= "ready" and data.status ~= "warming_up") or not age or age < 0 or age > 10000 then
		table.insert(
			rows,
			note(
				f.tr("status." .. ((data.status == "ready" or data.status == "warming_up") and "stale" or data.status))
			)
		)
		return ui.column({ gap = 4 }, rows)
	end
	local list = resource == "memory" and data.memory or resource == "disk" and data.io or data.cpu
	local function columns(name, first, second, header, key, tooltip)
		local cells = {
			label(name, {
				flexGrow = 1,
				maxWidth = resource == "disk" and 160 or 250,
				maxLines = 1,
				color = header and "on_surface_variant" or nil,
				fontSize = header and 10 or 12,
			}),
		}
		if resource == "disk" then
			table.insert(
				cells,
				label(first, {
					width = 83,
					textAlign = "end",
					fontSize = header and 10 or 11,
					color = header and "primary" or nil,
				})
			)
			table.insert(
				cells,
				label(second, {
					width = 83,
					textAlign = "end",
					fontSize = header and 10 or 11,
					color = header and "secondary" or nil,
				})
			)
		else
			table.insert(
				cells,
				label(first, {
					width = 76,
					textAlign = "end",
					fontSize = header and 10 or 12,
					color = header and "on_surface_variant" or nil,
				})
			)
		end
		return ui.row(
			{ key = key, gap = 6, align = "center", minHeight = header and 14 or 18, tooltip = tooltip },
			cells
		)
	end
	table.insert(
		rows,
		columns(
			f.tr("process_name"),
			f.tr(resource == "disk" and "read" or resource == "cpu" and "cpu" or "rss"),
			f.tr("write"),
			true
		)
	)
	if #list == 0 then
		table.insert(rows, note(f.tr("process_warming")))
	end
	for _, row in ipairs(list) do
		local value = resource == "cpu" and f.percent(row.cpu)
			or resource == "memory" and f.bytes(row.rss)
			or f.rate(row.read)
		table.insert(
			rows,
			columns(row.name, value, f.rate(row.write), false, row.id, "PID " .. tostring(row.pid) .. "\n" .. hint)
		)
	end
	if data.denied > 0 or (resource == "disk" and data.ioDenied > 0) then
		table.insert(rows, note(string.format(f.tr("process_coverage"), data.count, data.denied, data.ioDenied)))
	end
	return ui.column({ key = "processes_" .. resource, gap = 2, tooltip = hint }, rows)
end

local function coreBars(cores)
	local rows, batch = {}, {}
	for _, core in ipairs(cores) do
		table.insert(
			batch,
			ui.column({
				key = core.id,
				flexGrow = 1,
				height = 30,
				justify = "end",
				radius = 2,
				fill = "on_surface/0.06",
				tooltip = core.id .. "  " .. f.percent(core.usage),
			}, { ui.box({ height = 30 * core.usage / 100, fill = "primary", radius = 2 }) })
		)
		if #batch == 16 then
			table.insert(rows, ui.row({ gap = 3 }, batch))
			batch = {}
		end
	end
	if #batch > 0 then
		table.insert(rows, ui.row({ gap = 3 }, batch))
	end
	return ui.column({ key = "cores", gap = 3, tooltip = f.tr("logical_cores") }, rows)
end

local function cpuContent(sample)
	local c = sample.cpu
	local frequencyRatio
	if c.freq and c.maxFreq and c.maxFreq > 0 then
		frequencyRatio = c.freq / c.maxFreq
	end
	local summary = ui.row({ gap = 8, align = "center", paddingV = 2 }, {
		gauge.render({
			id = "cpu_temperature",
			label = f.tr("temperature"),
			size = 64,
			text = c.temp and string.format("%.0f°C", c.temp) or "—",
			value = c.temp and c.temp / 100,
			tooltip = f.tr("temperature_scale"),
		}),
		gauge.render({
			id = "cpu_usage",
			label = f.tr("usage"),
			size = 84,
			text = f.percent(c.usage),
			value = c.usage and c.usage / 100,
			segments = {
				{ value = (c.user or 0) / 100, color = "primary" },
				{ value = (c.system or 0) / 100, color = "secondary" },
				{ value = math.max(0, (c.usage or 0) - (c.user or 0) - (c.system or 0)) / 100, color = "primary" },
			},
			tooltip = f.tr("cpu_usage_hint"),
		}),
		gauge.render({
			id = "cpu_frequency",
			label = f.tr("frequency") .. " (GHz)",
			size = 64,
			text = c.freq and string.format("%.2f", c.freq / 1000) or "—",
			value = frequencyRatio,
			tooltip = frequencyRatio and string.format(f.tr("frequency_scale"), c.maxFreq / 1000)
				or f.tr("frequency_scale_missing"),
		}),
	})
	local details = {
		section(f.tr("details")),
		legend(f.tr("user"), f.percent(c.user), "primary"),
		legend(f.tr("system"), f.percent(c.system), "secondary"),
		legend(
			f.tr("idle"),
			c.usage and f.percent(math.max(0, 100 - c.usage - (c.iowait or 0))) or "—",
			"on_surface_variant"
		),
		metric(f.tr("iowait"), f.percent(c.iowait)),
		metric(
			f.tr("uptime"),
			string.format(
				f.tr("uptime_value"),
				math.floor(sample.t / 86400),
				math.floor(sample.t % 86400 / 3600),
				math.floor(sample.t % 3600 / 60)
			)
		),
		pressure(sample),
	}
	if c.load then
		table.insert(details, section(f.tr("average_load")))
		for i, value in ipairs(c.load) do
			table.insert(details, metric(f.tr(({ "load_1", "load_5", "load_15" })[i]), string.format("%.2f", value)))
		end
	end
	return { summary, history(), coreBars(c.cores), ui.column({ gap = 4 }, details), processRows() }
end

local function memoryContent(sample)
	local m = sample.memory
	local psi = sample.pressure.memory
	local psiValue = psi and psi.status == "ready" and psi.some and psi.some.avg10 or nil
	local segments, strip = {}, {}
	for _, part in ipairs(m.breakdown or {}) do
		table.insert(segments, { value = part.bytes / m.total, color = part.color })
		table.insert(
			strip,
			ui.box({
				width = 0,
				flexGrow = part.bytes / m.total,
				height = 7,
				fill = part.color,
				tooltip = f.tr(part.id) .. ": " .. f.bytes(part.bytes),
			})
		)
	end
	if m.total and #segments > 0 then
		table.insert(
			strip,
			ui.box({ width = 0, flexGrow = m.available / m.total, height = 7, fill = "on_surface/0.14" })
		)
	end
	local details = { section(f.tr("details"), f.tr("memory_breakdown_hint")), metric(f.tr("used"), f.bytes(m.used)) }
	if #strip > 0 then
		table.insert(details, ui.row({ key = "memory_composition", height = 7, gap = 0 }, strip))
		for _, part in ipairs(m.breakdown) do
			table.insert(details, legend(f.tr(part.id), f.bytes(part.bytes), part.color))
		end
	else
		table.insert(details, note(f.tr("memory_breakdown_unavailable")))
	end
	table.insert(details, legend(f.tr("available"), f.bytes(m.available), "on_surface/0.14"))
	table.insert(details, metric("Swap", f.bytes(m.swapUsed) .. " / " .. f.bytes(m.swapTotal)))
	table.insert(details, pressure(sample))
	table.insert(
		details,
		ui.button({
			text = f.tr(extraMemory and "less_details" or "more_details"),
			controlSize = "sm",
			variant = "ghost",
			onClick = function()
				extraMemory = not extraMemory
				render()
			end,
		})
	)
	if extraMemory then
		for _, item in ipairs({
			{ "cached", m.cached },
			{ "buffers", m.buffers },
			{ "slab", m.slab },
			{ "reclaimable", m.reclaimable },
			{ "zswap", m.zswap },
		}) do
			table.insert(details, metric(f.tr(item[1]), f.bytes(item[2])))
		end
	end
	return {
		ui.row({ gap = 8, align = "center", paddingV = 2 }, {
			gauge.render({
				id = "memory_pressure",
				label = "PSI · 10 s",
				size = 64,
				text = f.percent(psiValue),
				value = psiValue and psiValue / 100,
				color = "secondary",
				tooltip = f.tr("psi_hint"),
			}),
			gauge.render({
				id = "memory_usage",
				label = f.tr("usage"),
				size = 84,
				text = f.percent(m.usage),
				value = m.usage and m.usage / 100,
				segments = #segments > 0 and segments or nil,
				tooltip = f.tr("memory_breakdown_hint"),
			}),
			ui.column({ flexGrow = 1, gap = 5 }, {
				metric(f.tr("used"), f.bytes(m.used)),
				metric(f.tr("total"), f.bytes(m.total)),
			}),
		}),
		history(),
		ui.column({ gap = 4, tooltip = f.tr("memory_breakdown_hint") }, details),
		processRows(),
	}
end

local function transferSummary(row, disk)
	return ui.row({ gap = 8, paddingV = 2 }, {
		headline(f.tr(disk and "read" or "download"), f.rate(row and (disk and row.read or row.rx)), "primary"),
		headline(f.tr(disk and "write" or "upload"), f.rate(row and (disk and row.write or row.tx)), "secondary"),
	})
end

local function capacity(path, source, data)
	local rows = { metric(path, data and f.percent(data.usagePercent) or "—") }
	if data then
		table.insert(rows, ui.progress({ progress = data.usagePercent / 100, height = 5, fill = "primary" }))
		table.insert(rows, metric(f.bytes(data.availableBytes) .. " " .. f.tr("available"), f.bytes(data.totalBytes)))
	end
	return ui.column({ gap = 4, tooltip = source }, rows)
end

local function diskContent(sample)
	local d = sample.disk
	local selected = d.selected
	local capacitySource
	for _, mount in ipairs(d.mounts) do
		if mount.path == d.path then
			capacitySource = mount.source .. " (" .. mount.filesystem .. ")"
			break
		end
	end
	local details = {
		section(f.tr("details"), f.tr("disk_scope_hint")),
		metric("IOPS", selected and selected.iops and string.format("%.0f", selected.iops) or "—"),
		metric(f.tr("device_busy"), f.percent(selected and selected.busy)),
		pressure(sample),
		section(f.tr("filesystems")),
		capacity(d.path, capacitySource, d.capacity),
	}
	for _, mount in ipairs(d.mounts) do
		if mount.path ~= d.path then
			table.insert(details, capacity(mount.path, mount.source, mount.capacity))
		end
	end
	local rows = {
		ui.column({ key = "disk_io", gap = 4 }, {
			section(f.tr("io_activity"), f.tr("disk_scope_hint")),
			metric(f.tr("block_device"), selected and selected.name or "—"),
			ui.row({ gap = 8, align = "center" }, {
				ui.column({ width = 106, gap = 8 }, {
					ui.column({ gap = 1 }, {
						label(f.tr("read"), { color = "primary", fontSize = 11 }),
						label(f.rate(selected and selected.read), { fontSize = 14 }),
					}),
					ui.column({ gap = 1 }, {
						label(f.tr("write"), { color = "secondary", fontSize = 11 }),
						label(f.rate(selected and selected.write), { fontSize = 14 }),
					}),
				}),
				history(true),
			}),
		}),
		ui.column({ gap = 4 }, details),
		processRows(),
	}
	if #d.devices > 1 then
		local others = { section(f.tr("other_devices"), f.tr("disk_scope_hint")) }
		for _, row in ipairs(d.devices) do
			if not selected or row.id ~= selected.id then
				table.insert(others, metric(row.name, "R " .. f.rate(row.read) .. "  W " .. f.rate(row.write)))
			end
		end
		table.insert(rows, ui.column({ gap = 4 }, others))
	end
	return rows
end

local function interfaceDetails(row, primary)
	local rows = {
		section(primary and f.tr("interface_details") or row.name, f.tr("network_scope_hint")),
		metric(f.tr("interface_name"), row.name),
		metric(f.tr("download"), f.rate(row.rx), "primary"),
		metric(f.tr("upload"), f.rate(row.tx), "secondary"),
		metric(f.tr("total_download"), f.bytes(row.rxTotal)),
		metric(f.tr("total_upload"), f.bytes(row.txTotal)),
	}
	local address = addresses[row.name] or {}
	table.insert(rows, metric(f.tr("local_ipv4"), address.ipv4 or "—"))
	if showIpv6 then
		table.insert(
			rows,
			ui.row({ gap = 8 }, {
				label(f.tr("local_ipv6"), { color = "on_surface_variant", fontSize = 11 }),
				label(address.ipv6 or "—", { flexGrow = 1, maxLines = 2, textAlign = "end", fontSize = 11 }),
			})
		)
	end
	return ui.column({ gap = 4 }, rows)
end

local function networkContent(sample)
	local selected = sample.network.selected
	local rows =
		{ transferSummary(selected, false), note(selected and selected.name or f.tr("no_interface")), history() }
	if selected then
		table.insert(rows, interfaceDetails(selected, true))
	end
	for _, row in ipairs(sample.network.interfaces) do
		if not selected or row.name ~= selected.name then
			table.insert(rows, interfaceDetails(row, false))
		end
	end
	if publicEnabled then
		table.insert(
			rows,
			ui.column({ gap = 4, tooltip = f.tr("public_ip_hint") }, {
				section(f.tr("public_addresses")),
				metric(f.tr("public_ipv4"), publicAddresses.ipv4 or "—"),
			})
		)
		if showIpv6 then
			table.insert(rows, metric(f.tr("public_ipv6"), publicAddresses.ipv6 or "—"))
		end
	end
	if not noctalia.commandExists(collector.path()) then
		table.insert(rows, note(f.tr("status.missing_dependency")))
	end
	table.insert(
		rows,
		ui.button({
			text = f.tr("choose_interfaces"),
			variant = "ghost",
			controlSize = "sm",
			tooltip = table.concat(sample.network.available or {}, ", "),
			onClick = function()
				noctalia.openSettings()
			end,
		})
	)
	return rows
end

local content = { cpu = cpuContent, memory = memoryContent, disk = diskContent, network = networkContent }

render = function()
	if not opened then
		return
	end
	local sample = noctalia.state.get("snapshot")
	local body
	if f.fresh(sample) then
		body = content[resource](sample)
	else
		body = { note(f.status(sample)) }
	end
	panel.render(ui.column({ gap = 4, padding = 4, flexGrow = 1 }, {
		ui.row({ gap = 6, align = "center" }, {
			ui.glyph({ name = f.glyphs[resource], color = "on_surface_variant" }),
			label(
				f.tr(resource),
				{ flexGrow = 1, fontSize = 14, fontWeight = "medium", maxLines = 1, baseline = "inkCentered" }
			),
			ui.button({
				glyph = "settings",
				tooltip = f.tr("settings"),
				variant = "ghost",
				controlSize = "sm",
				onClick = function()
					noctalia.openSettings()
				end,
			}),
			ui.button({
				glyph = "x",
				tooltip = f.tr("close"),
				variant = "ghost",
				controlSize = "sm",
				onClick = function()
					panel.close()
				end,
			}),
		}),
		ui.scroll({ key = "body_" .. resource, flexGrow = 1, gap = 3, padding = 0 }, body),
	}))
	panel.setNeedsFrameTick(charts.active())
end

function onOpen(context)
	charts.reset()
	frameElapsed = 0
	opened = true
	local requested = type(context) == "string" and table.find(resources, context) and context
	resource = requested or noctalia.state.get("selected_resource") or "cpu"
	if not table.find(resources, resource) then
		resource = "cpu"
	end
	panel.setWantsSecondTicks(true)
	lease()
	readAddresses()
	render()
end

function onClose()
	opened = false
	charts.reset()
	panel.setNeedsFrameTick(false)
	noctalia.state.set("detail_lease", nil)
end

function onExit()
	onClose()
end

function update()
	if opened then
		lease()
		readAddresses()
		render()
	end
end

function onFrameTick(deltaMs)
	if not opened then
		return
	end
	frameElapsed += tonumber(deltaMs) or 0
	if frameElapsed >= 33 then
		frameElapsed %= 33
		render()
	end
end

noctalia.state.watch("snapshot", render)
noctalia.state.watch("processes", render)
