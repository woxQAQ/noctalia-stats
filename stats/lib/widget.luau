--!nonstrict
local f = require("./format.luau")
local gauge = require("./gauge.luau")
local charts = require("./charts.luau")
local M = {}

function M.mount(resource, options)
	options = options or {}
	local display = options.display or noctalia.getConfig("display")
	local lastIdentity
	local function render()
		local sample = noctalia.state.get("snapshot")
		local fresh = f.fresh(sample)
		local value, detail = f.summary(resource, sample, options.metric)
		local vertical = barWidget.isVertical()
		local capacityMode = resource == "disk" and options.metric == "free"
		local capacity = fresh and resource == "disk" and sample.disk.capacity or nil
		local selected = fresh and resource == "network" and sample.network.selected or nil
		local identity = resource
		if fresh and resource == "disk" then
			identity ..= ":" .. (capacityMode and sample.disk.path or sample.disk.selected and sample.disk.selected.id or "missing")
		end
		if fresh and resource == "network" then
			identity ..= ":" .. (selected and selected.name or "missing")
		end
		if not fresh or identity ~= lastIdentity then
			charts.reset()
			lastIdentity = identity
		end
		local rows = fresh and noctalia.state.get("history_" .. resource) or {}
		local v1, v2 = f.graph(rows or {}, resource == "cpu" or resource == "memory")
		local ratio, segments
		if fresh and (resource == "cpu" or resource == "memory") then
			ratio = sample[resource].usage and sample[resource].usage / 100
		end
		if capacity and capacity.totalBytes > 0 then
			ratio = capacity.availableBytes / capacity.totalBytes
		end
		if fresh and resource == "memory" and #(sample.memory.breakdown or {}) > 0 then
			segments = {}
			for _, part in ipairs(sample.memory.breakdown) do
				table.insert(segments, { value = part.bytes / sample.memory.total, color = part.color })
			end
		end
		local function icon()
			return ui.glyph({ name = f.glyphs[resource] })
		end
		local function text(textValue, props)
			props = props or {}
			props.text = textValue
			return ui.label(props)
		end
		local function stack(first, second, title)
			local alignment = title and "center" or "end"
			return ui.column({ gap = 0, height = 24, minWidth = 40 }, {
				text(first, {
					fontSize = 11,
					height = 12,
					textAlign = alignment,
					baseline = "inkCentered",
					color = title and "on_surface_variant" or nil,
				}),
				text(second, {
					fontSize = 11,
					height = 12,
					textAlign = alignment,
					baseline = "inkCentered",
					fontWeight = "medium",
				}),
			})
		end
		local function speeds()
			local function line(key, direction, speed)
				return ui.row({ key = key, gap = 3, height = 12, align = "center" }, {
					ui.glyph({ name = direction, size = 10, width = 10 }),
					text(
						f.rate(speed),
						{ fontSize = 11, height = 12, width = 74, textAlign = "end", baseline = "inkCentered" }
					),
				})
			end
			return ui.column({ gap = 0, height = 24 }, {
				line("rx", "arrow-down", selected and selected.rx),
				line("tx", "arrow-up", selected and selected.tx),
			})
		end
		local function values()
			if resource == "network" and options.layout == "stacked" and not vertical then
				return { speeds() }
			end
			if vertical then
				return { icon() }
			end
			-- Match the glyph's measured ink centering instead of mixing it with
			-- the label's default cap-height centering.
			return { icon(), text(value, { baseline = "inkCentered" }) }
		end
		local function plot(fill)
			if capacityMode then
				return ui.progress({
					progress = math.clamp(ratio or 0, 0, 1),
					visible = ratio ~= nil,
					width = 36,
					height = 4,
					fill = "primary",
				})
			end
			local a, b = charts.series(identity, v1, v2)
			return ui.graph({
				values = a,
				values2 = b,
				color = "primary",
				color2 = "secondary",
				width = vertical and 22 or 46,
				height = vertical and 36 or 20,
				fillOpacity = fill and 0.55 or 0,
				lineWidth = 1,
			})
		end
		local function bars()
			local columns = {}
			if resource == "cpu" and fresh then
				for _, core in ipairs(sample.cpu.cores) do
					table.insert(
						columns,
						ui.column({
							width = 3,
							height = 20,
							justify = "end",
							fill = "on_surface/0.10",
							tooltip = core.id .. " " .. f.percent(core.usage),
						}, { ui.box({ height = core.usage / 5, fill = "primary" }) })
					)
				end
			elseif ratio ~= nil then
				local pieces = {}
				if segments then
					for _, segment in ipairs(segments) do
						table.insert(pieces, ui.box({ height = 20 * segment.value, fill = segment.color }))
					end
				else
					table.insert(pieces, ui.box({ height = 20 * math.clamp(ratio, 0, 1), fill = "primary" }))
				end
				table.insert(
					columns,
					ui.column({ width = 8, height = 20, justify = "end", fill = "on_surface/0.10" }, pieces)
				)
			else
				for i = math.max(1, #v1 - 11), #v1 do
					local pair = {
						ui.column(
							{ width = 3, height = 20, justify = "end" },
							{ ui.box({ height = 20 * v1[i], fill = "primary" }) }
						),
					}
					if v2[i] then
						table.insert(
							pair,
							ui.column(
								{ width = 3, height = 20, justify = "end" },
								{ ui.box({ height = 20 * v2[i], fill = "secondary" }) }
							)
						)
					end
					table.insert(columns, ui.row({ gap = 0, align = "end" }, pair))
				end
			end
			return { ui.row({ gap = 1, align = "end" }, columns) }
		end
		local function round(shape)
			return {
				gauge.image({
					id = "bar_" .. resource .. "_" .. display .. "_" .. (options.metric or "usage"),
					shape = shape,
					size = 24,
					value = ratio,
					segments = segments,
					text = "",
				}),
			}
		end
		local styles = {
			value = values,
			mini = function()
				return { stack(f.tr(resource), value, true) }
			end,
			speed = function()
				return vertical and { icon() } or { speeds() }
			end,
			memory = function()
				return {
					stack(
						f.tr("used") .. " " .. f.bytes(fresh and sample.memory.used or nil),
						f.tr("available") .. " " .. f.bytes(fresh and sample.memory.available or nil)
					),
				}
			end,
			graph = function()
				return { plot(true) }
			end,
			line = function()
				return { plot(false) }
			end,
			both = function()
				local nodes = values()
				table.insert(nodes, plot(true))
				return nodes
			end,
			bars = bars,
			ring = function()
				return round("ring")
			end,
			pie = function()
				return round("pie")
			end,
			gauge = function()
				return round("gauge")
			end,
		}
		local children = not fresh and values() or assert(styles[display], "unknown widget style: " .. display)()
		barWidget.render((vertical and ui.column or ui.row)({ gap = 4, align = "center" }, children))
		local tooltip = { { f.tr(capacityMode and "available" or resource), value }, { f.tr("source"), detail } }
		if capacityMode and capacity then
			table.insert(tooltip, { f.tr("total"), f.bytes(capacity.totalBytes) })
		end
		barWidget.setTooltip(tooltip)
		noctalia.setUpdateInterval(charts.active() and 33 or 2000)
	end
	noctalia.state.watch("snapshot", render)
	render()
	return {
		update = render,
		click = function()
			noctalia.state.set("selected_resource", resource)
			noctalia.togglePanel("woxQAQ/stats:details")
		end,
	}
end
return M
