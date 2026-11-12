--!nonstrict
local view = require("./lib/magpie_view.luau")
local periods = require("./lib/magpie_period.luau")
local opened = false
local chartMetric = "tokens"
local providerOpen = false
local colors = { "primary", "secondary", "tertiary" }
local render
local function tr(key)
	return noctalia.tr(key)
end
local function label(text, props)
	props = props or {}
	props.text = text
	props.fontSize = props.fontSize or 12
	return ui.label(props)
end
local function color(index)
	return colors[(index - 1) % #colors + 1]
end
local function card(children)
	return ui.column(
		{ fill = "surface", radius = 8, padding = 6, gap = 5, border = "on_surface/0.12", borderWidth = 1 },
		children
	)
end
local function refresh()
	noctalia.state.set("magpie_refresh", noctalia.nowMs())
end
local function lease()
	noctalia.state.set("magpie_chart_lease", noctalia.nowMs() + 5000)
end
local function choices(window)
	local options = table.clone(periods.choices)
	if not table.find(options, window) then
		table.insert(options, window)
	end
	local items = {}
	for _, value in ipairs(options) do
		table.insert(
			items,
			ui.button({
				text = table.find(periods.choices, value) and tr("magpie.window." .. value) or value,
				variant = value == window and "outline" or "ghost",
				controlSize = "sm",
				flexGrow = 1,
				onClick = function()
					providerOpen = false
					noctalia.state.set("magpie_window_request", value)
				end,
			})
		)
	end
	return ui.row({ gap = 2, align = "center" }, items)
end

local function providerSelector(sample)
	local providers = sample and sample.providers or {}
	local options = {
		{ text = tr("magpie.providers_all"), value = { all = true }, selected = not sample or sample.provider == nil },
	}
	local title = options[1].text
	for _, provider in ipairs(providers) do
		local text = provider ~= "" and provider or tr("magpie.provider_unknown")
		local selected = sample.provider == provider
		table.insert(options, { text = text, value = { provider = provider }, selected = selected })
		if selected then
			title = text
		end
	end
	local children = {
		ui.row({ gap = 6, align = "center" }, {
			label(tr("magpie.provider"), { fontSize = 11, color = "on_surface_variant" }),
			ui.row({
				key = "magpie-provider",
				flexGrow = 1,
				gap = 6,
				height = 28,
				paddingH = 8,
				align = "center",
				radius = 6,
				border = "on_surface/0.12",
				borderWidth = 1,
				onClick = (#options > 1 or providerOpen) and function()
					providerOpen = not providerOpen
					render()
				end or nil,
			}, {
				label(title, { flexGrow = 1, maxLines = 1, baseline = "inkCentered" }),
				ui.glyph({
					name = providerOpen and "chevron-up" or "chevron-down",
					size = 12,
					color = "on_surface_variant",
				}),
			}),
		}),
	}
	if providerOpen then
		local items = {}
		for index, option in ipairs(options) do
			table.insert(
				items,
				ui.button({
					key = "magpie-provider-option-" .. tostring(index - 1),
					text = option.text,
					glyph = option.selected and "check" or nil,
					variant = "ghost",
					contentAlign = "start",
					controlSize = "sm",
					height = 28,
					onClick = function()
						providerOpen = false
						noctalia.state.set("magpie_provider_request", option.value)
						render()
					end,
				})
			)
		end
		table.insert(
			children,
			ui.column({
				key = "magpie-provider-menu",
				fill = "surface",
				radius = 6,
				border = "on_surface/0.12",
				borderWidth = 1,
				padding = 3,
			}, {
				ui.scroll(
					{ key = "magpie-provider-options", height = math.min(#items, 5) * 28, gap = 0, padding = 0 },
					items
				),
			})
		)
	end
	return ui.column({ gap = 3 }, children)
end

local function summary(sample)
	local function cell(name, value, details, hint)
		local children = {
			label(name, { fontSize = 10, color = "on_surface_variant" }),
			label(value, { fontSize = 19, fontWeight = "medium", maxLines = 1 }),
		}
		for _, text in ipairs(details) do
			table.insert(children, label(text, { fontSize = 9, color = "on_surface_variant", maxLines = 2 }))
		end
		return ui.column({ gap = 2, flexGrow = 1, tooltip = hint }, children)
	end
	local errorRate = sample.calls and sample.calls > 0 and string.format("%.1f%%", sample.errors / sample.calls * 100)
		or "—"
	return card({
		ui.row({ gap = 6, align = "start" }, {
			cell("Token", view.count(view.total(sample)), {
				tr("magpie.input_cached") .. " " .. view.count(sample.input),
				tr("magpie.output_short") .. " " .. view.count(sample.output),
			}, tr("magpie.input_help")),
			cell(
				tr("magpie.calls_short"),
				view.count(sample.calls),
				{ tr("magpie.attempts") },
				tr("magpie.calls_help")
			),
			cell(
				tr("magpie.mean"),
				view.duration(sample.mean),
				{ "p95 " .. (sample.p95Capped and "≥ " or "") .. view.duration(sample.p95) }
			),
			cell(tr("magpie.errors"), view.count(sample.calls and sample.errors), { errorRate }),
		}),
	})
end

local function chartContent(sample)
	local tabs = {}
	for _, kind in ipairs({ "tokens", "calls" }) do
		table.insert(
			tabs,
			ui.button({
				text = kind == "tokens" and "Token" or tr("magpie.calls_short"),
				variant = chartMetric == kind and "outline" or "ghost",
				controlSize = "sm",
				onClick = function()
					providerOpen = false
					chartMetric = kind
					render()
				end,
			})
		)
	end
	local children = { ui.row({ gap = 2 }, tabs) }
	local chart = noctalia.state.get("magpie_chart")
	if not view.fresh(chart) or chart.window ~= sample.window then
		table.insert(
			children,
			label(
				tr(chart and chart.status == "error" and "magpie.chart_error" or "magpie.chart_loading"),
				{ fontSize = 11, color = "on_surface_variant" }
			)
		)
		return children
	end
	local visibleSeries = {}
	for _, series in ipairs(chart.series) do
		if sample.provider == nil or sample.provider == series.provider then
			table.insert(visibleSeries, series)
		end
	end
	local count, maximum = 0, 0
	local totals = {}
	for _, series in ipairs(visibleSeries) do
		count = math.max(count, #series[chartMetric])
		for index, value in ipairs(series[chartMetric]) do
			totals[index] = (totals[index] or 0) + value
		end
	end
	for _, value in ipairs(totals) do
		maximum = math.max(maximum, value)
	end
	local modelIndices = {}
	for index, model in ipairs(sample.models) do
		modelIndices[model.provider .. "\0" .. model.model] = index
	end
	local columns = {}
	for index = 1, count do
		local segments = {}
		for _, series in ipairs(visibleSeries) do
			local modelIndex = modelIndices[series.provider .. "\0" .. series.model] or 1
			local value = series[chartMetric][index] or 0
			if value > 0 and maximum > 0 then
				table.insert(
					segments,
					1,
					ui.box({
						height = value / maximum * 92,
						fill = color(modelIndex),
						tooltip = view.modelSource(series) .. " " .. view.count(value),
					})
				)
			end
		end
		table.insert(
			columns,
			ui.column({
				height = 92,
				flexGrow = 1,
				width = 0,
				justify = "end",
				gap = 0,
				tooltip = view.count(totals[index] or 0),
			}, segments)
		)
	end
	local pattern = chart.finish - chart.start > 86400 and "{:%m-%d}" or "{:%H:%M}"
	table.insert(
		children,
		ui.row({ gap = 5, align = "start" }, {
			ui.column({ height = 92, justify = "space_between", align = "end" }, {
				label(view.count(maximum), { fontSize = 9, color = "on_surface_variant" }),
				label(view.count(maximum / 2), { fontSize = 9, color = "on_surface_variant" }),
				label("0", { fontSize = 9, color = "on_surface_variant" }),
			}),
			ui.column({ gap = 3, flexGrow = 1 }, {
				ui.row({ gap = 2, height = 92, align = "end" }, columns),
				ui.row({ justify = "space_between" }, {
					label(noctalia.formatTime(pattern, chart.start), { fontSize = 9, color = "on_surface_variant" }),
					label(
						noctalia.formatTime(pattern, (chart.start + chart.finish) / 2),
						{ fontSize = 9, color = "on_surface_variant" }
					),
					label(noctalia.formatTime(pattern, chart.finish), { fontSize = 9, color = "on_surface_variant" }),
				}),
			}),
		})
	)
	return children
end

local function metricValue(model)
	if chartMetric == "calls" then
		return model.calls
	end
	return view.total(model)
end

local function modelRows(sample)
	local total = metricValue(sample) or 0
	local models, indices = table.clone(sample.models), {}
	for index, model in ipairs(sample.models) do
		indices[model] = index
	end
	if chartMetric == "calls" then
		table.sort(models, function(a, b)
			if (a.calls or 0) ~= (b.calls or 0) then
				return (a.calls or 0) > (b.calls or 0)
			end
			if a.model ~= b.model then
				return a.model < b.model
			end
			return a.provider < b.provider
		end)
	end
	local rows = {}
	for index, model in ipairs(models) do
		if index > 8 then
			break
		end
		local amount = metricValue(model)
		local palette = color(indices[model])
		local share = total > 0 and (amount or 0) / total or 0
		local mean = model.calls and model.calls > 0 and model.seconds and model.seconds / model.calls or nil
		table.insert(
			rows,
			ui.column({ gap = 3 }, {
				ui.row({ gap = 6, align = "center", tooltip = view.modelSource(model) }, {
					ui.box({ width = 7, height = 7, radius = 2, fill = palette }),
					label(view.modelName(model), { flexGrow = 1, maxLines = 1 }),
					label(view.count(amount), { fontWeight = "medium", textAlign = "end" }),
				}),
				ui.progress({ progress = share, height = 4, fill = palette }),
				ui.row({ gap = 6, justify = "space_between", align = "center" }, {
					label(
						view.providerName(model),
						{ fontSize = 10, color = "on_surface_variant", maxWidth = 110, maxLines = 1 }
					),
					label(
						(
							chartMetric == "calls" and ("Token " .. view.count(view.total(model)))
							or (view.count(model.calls) .. " " .. tr("magpie.calls_short"))
						)
							.. " · "
							.. tr("magpie.mean")
							.. " "
							.. view.duration(mean)
							.. " · "
							.. (amount and total > 0 and string.format("%.0f%%", share * 100) or "—"),
						{
							fontSize = 10,
							color = "on_surface_variant",
							maxLines = 1,
							textAlign = "end",
						}
					),
				}),
			})
		)
	end
	return rows
end

render = function()
	if not opened then
		return
	end
	local sample = noctalia.state.get("magpie")
	local window = sample and sample.window or noctalia.getConfig("magpie_window")
	local body = {}
	if view.fresh(sample) then
		table.insert(body, summary(sample))
		local ok, detail = pcall(chartContent, sample)
		if ok then
			noctalia.state.set("magpie_panel_error", nil)
		else
			noctalia.state.set("magpie_panel_error", tostring(detail))
			detail = { label(tr("magpie.chart_error"), { color = "on_surface_variant" }) }
		end
		for _, node in ipairs(modelRows(sample)) do
			table.insert(detail, node)
		end
		table.insert(body, card(detail))
	else
		table.insert(body, label(view.message(sample), { color = "on_surface_variant", maxLines = 3 }))
	end
	panel.render(ui.column({ padding = 4, gap = 5, flexGrow = 1 }, {
		ui.row({ gap = 6, align = "center" }, {
			ui.glyph({ name = "sparkles", color = "on_surface_variant" }),
			label("Magpie", { flexGrow = 1, fontSize = 14, fontWeight = "medium", baseline = "inkCentered" }),
			ui.button({
				glyph = "refresh",
				tooltip = tr("magpie.refresh"),
				variant = "ghost",
				controlSize = "sm",
				onClick = refresh,
			}),
			ui.button({
				glyph = "settings",
				tooltip = tr("settings"),
				variant = "ghost",
				controlSize = "sm",
				onClick = function()
					noctalia.openSettings()
				end,
			}),
			ui.button({
				glyph = "x",
				tooltip = tr("close"),
				variant = "ghost",
				controlSize = "sm",
				onClick = function()
					panel.close()
				end,
			}),
		}),
		choices(window),
		providerSelector(sample),
		ui.scroll({ key = "magpie-body", flexGrow = 1, gap = 6, padding = 0 }, body),
	}))
end

function onOpen()
	opened = true
	panel.setWantsSecondTicks(true)
	lease()
	refresh()
	render()
end
function onClose()
	providerOpen = false
	opened = false
	panel.setWantsSecondTicks(false)
	noctalia.state.set("magpie_chart_lease", nil)
end
function onSecondTick()
	lease()
	render()
end
function onExit()
	onClose()
end
noctalia.state.watch("magpie", render)
noctalia.state.watch("magpie_chart", render)
