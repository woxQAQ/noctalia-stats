--!nonstrict
-- Drive the consumer, bar and popup through their host boundaries with sparse
-- Magpie delta-histogram query results, including failed model attempts.
local now = 100000
local state, watchers, requests = {}, {}, {}
local config = {
	magpie_enabled = true,
	magpie_metrics_endpoint = "http://metrics.test:8428",
	magpie_service_name = "magpie",
	magpie_window = "1h",
	magpie_poll_seconds = 10,
	display = "tokens",
}
local response
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
local function vm(path)
	local env = setmetatable({}, { __index = getfenv() })
	local cache = {}
	env.noctalia = {
		getConfig = function(key)
			assert(config[key] ~= nil, key)
			return config[key]
		end,
		nowMs = function()
			return now
		end,
		formatTime = function(pattern, seconds)
			if string.find(pattern, "%Y", 1, true) then
				return "day" .. tostring(math.floor(seconds / 86400))
			end
			return string.format("%02d:%02d", math.floor(seconds / 3600) % 24, math.floor(seconds / 60) % 60)
		end,
		setUpdateInterval = function() end,
		tr = function(key)
			return (assert(TRANSLATIONS[key], key))
		end,
		openSettings = function() end,
		togglePanel = function(name)
			env.openedPanel = name
		end,
		state = {
			get = function(key)
				return state[key]
			end,
			set = function(key, value)
				state[key] = value
				for _, callback in ipairs(watchers[key] or {}) do
					callback(value)
				end
			end,
			watch = function(key, callback)
				watchers[key] = watchers[key] or {}
				table.insert(watchers[key], callback)
			end,
		},
		json = {
			encode = function(value)
				return '"' .. value .. '"'
			end,
			decode = function()
				return response
			end,
		},
		http = function(request, callback)
			assert(not request.method or request.method == "GET", "Stats consumes metrics; it must never export OTLP")
			table.insert(requests, { request = request, complete = callback })
			return true
		end,
	}
	env.ui = setmetatable({}, {
		__index = function(_, kind)
			return function(props, children)
				return { kind = kind, props = props, children = children }
			end
		end,
	})
	env.barWidget = {
		isVertical = function()
			return false
		end,
		render = function(node)
			env.bar = node
		end,
		setTooltip = function(value)
			env.tooltip = value
		end,
	}
	env.panel = {
		render = function(node)
			env.popup = node
		end,
		setWantsSecondTicks = function(value)
			env.ticks = value
		end,
		close = function()
			env.closed = true
		end,
	}
	local function load(target)
		local fn = assert(loadstring(assert(SOURCES[target], target), "@" .. target))
		local module = setmetatable({}, { __index = env })
		module.require = function(relative)
			local base = string.match(target, "^(.*)/")
			local nextPath = normalize((base and base .. "/" or "") .. relative)
			if cache[nextPath] == nil then
				cache[nextPath] = load(nextPath)
			end
			return cache[nextPath]
		end
		setfenv(fn, module)
		return fn(), module
	end
	local result, entry = load(path)
	return result, entry, env
end
local function texts(node)
	if not node then
		return ""
	end
	local out = node.props and node.props.text or ""
	for _, child in ipairs(node.children or {}) do
		out ..= " " .. texts(child)
	end
	return out
end
local function find(node, predicate)
	if predicate(node) then
		return node
	end
	for _, child in ipairs(node.children or {}) do
		local result = find(child, predicate)
		if result then
			return result
		end
	end
	return nil
end
local rows = {}
local function point(name, model, value, extra)
	local labels = { __name__ = name, ["gen_ai.request.model"] = model, ["gen_ai.provider.name"] = "provider" }
	for key, item in pairs(extra or {}) do
		labels[key] = item
	end
	table.insert(rows, { metric = labels, value = { now / 1000, tostring(value) } })
end
point("gen_ai.client.operation.duration_count", "model-a", 4)
point("gen_ai.client.operation.duration_count", "model-a", 1, { ["error.type"] = "500" })
point("gen_ai.client.operation.duration_count", "model-b", 2)
point("gen_ai.client.operation.duration_sum", "model-a", 9)
point("gen_ai.client.operation.duration_sum", "model-b", 4)
for _, p in ipairs({
	{ "model-a", "input", 1000 },
	{ "model-a", "output", 100 },
	{ "model-b", "input", 2000 },
	{ "model-b", "output", 300 },
}) do
	point("gen_ai.client.token.usage_sum", p[1], p[3], { ["gen_ai.token.type"] = p[2] })
end
for _, p in ipairs({ { "1", 2 }, { "2", 6 }, { "4", 7 }, { "+Inf", 7 } }) do
	point("gen_ai.client.operation.duration_bucket", "model-a", p[2], { le = p[1] })
end
response = { status = "success", data = { resultType = "vector", result = rows } }
local consumer = vm("lib/magpie.luau")
consumer.refresh()
assert(#requests == 1)
local query = string.gsub(requests[1].request.url, "%%(%x%x)", function(hex)
	return string.char(tonumber(hex, 16))
end)
assert(
	string.find(query, "sum_over_time", 1, true) and not string.find(query, "increase(", 1, true),
	"sparse delta batches are summed without counter extrapolation"
)
assert(string.find(query, '"service.name"="magpie"', 1, true))
consumer.refresh(true)
assert(#requests == 1, "only one metrics query may be in flight")
requests[1].complete({ ok = true, status = 200, body = "metrics" })
assert(state.magpie.status == "ready" and state.magpie.calls == 7)
assert(state.magpie.input == 3000 and state.magpie.output == 400)
assert(state.magpie.errors == 1 and state.magpie.mean == 13 / 7)
assert(math.abs(state.magpie.p95 - 3.3) < 0.00001)
assert(state.magpie.models[1].model == "model-b")
consumer.refresh()
assert(#requests == 1, "poll cadence applies after successful queries")
consumer.refresh(true)
requests[2].complete({ ok = true, status = 200, body = "metrics" })
assert(
	state.magpie.calls == 7 and state.magpie.input == 3000,
	"polling the same window must not count a delta batch twice"
)
for _, style in ipairs({ "tokens", "value", "mini" }) do
	config.display = style
	local _, entry, env = vm("magpie.luau")
	assert(env.bar and env.tooltip)
	entry.onClick()
	assert(env.openedPanel == "woxQAQ/stats:magpie-details")
end
local _, popup, panelEnv = vm("magpie_panel.luau")
popup.onOpen()
assert(panelEnv.ticks and string.find(texts(panelEnv.popup), "model-b", 1, true))
assert(string.find(texts(panelEnv.popup), "3k", 1, true))
now += 31000
popup.onSecondTick()
assert(string.find(texts(panelEnv.popup), TRANSLATIONS["magpie.error"], 1, true), "stale snapshots cannot look current")
popup.onClose()
assert(not panelEnv.ticks)

consumer.refresh(true)
requests[#requests].complete({ ok = false, status = 503 })
assert(state.magpie.status == "error")
consumer.refresh(true)
response = { status = "success", data = { resultType = "vector", result = {} } }
requests[#requests].complete({ ok = true, status = 200, body = "metrics" })
assert(state.magpie.status == "empty" and state.magpie.calls == nil, "missing metrics are not zero calls")
consumer.refresh(true)
response = { status = "success", isPartial = true, data = { resultType = "vector", result = rows } }
requests[#requests].complete({ ok = true, status = 200, body = "metrics" })
assert(state.magpie.status == "error", "partial storage results cannot silently undercount usage")
-- Opening the popup leases a bounded range query and a separate partial bucket.
-- Late OTLP arrivals must not be rejected against an older headline snapshot.
response = { status = "success", data = { resultType = "vector", result = rows } }
watchers.magpie_window_request = { consumer.selectWindow }
watchers.magpie_provider_request = { consumer.selectProvider }
consumer.selectWindow("today")
requests[#requests].complete({ ok = true, status = 200, body = "metrics" })
assert(state.magpie.start == 0 and state.magpie.finish == 131, "today starts at local midnight, not 24 hours ago")
popup.onOpen()
consumer.refresh(true)
requests[#requests].complete({ ok = true, status = 200, body = "metrics" })
local rangeRequest = requests[#requests]
assert(string.find(rangeRequest.request.url, "/api/v1/query_range?", 1, true))
local matrix = {}
for _, item in ipairs({
	{ "model-a", "token.usage_sum", 1000 },
	{ "model-b", "token.usage_sum", 2100 },
	{ "model-a", "operation.duration_count", 6 },
	{ "model-b", "operation.duration_count", 1 },
}) do
	table.insert(matrix, {
		metric = {
			__name__ = "gen_ai.client." .. item[2],
			["gen_ai.request.model"] = item[1],
			["gen_ai.provider.name"] = "provider",
		},
		values = { { 6, tostring(item[3]) } },
	})
end
response = { status = "success", data = { resultType = "matrix", result = matrix } }
rangeRequest.complete({ ok = true, status = 200, body = "chart" })
assert(string.find(requests[#requests].request.url, "/api/v1/query?", 1, true))
local tail = {}
for _, item in ipairs({
	{ "model-a", "token.usage_sum", 100 },
	{ "model-b", "token.usage_sum", 200 },
	{ "model-a", "operation.duration_count", 1 },
	{ "model-b", "operation.duration_count", 1 },
}) do
	table.insert(tail, {
		metric = {
			__name__ = "gen_ai.client." .. item[2],
			["gen_ai.request.model"] = item[1],
			["gen_ai.provider.name"] = "provider",
		},
		value = { 131, tostring(item[3]) },
	})
end
response = { status = "success", data = { resultType = "vector", result = tail } }
requests[#requests].complete({ ok = true, status = 200, body = "tail" })
assert(state.magpie_chart.status == "ready")
local recordedCalls = 0
for _, value in ipairs(state.magpie_chart.series[2].calls) do
	recordedCalls += value
end
assert(recordedCalls == 7, "late arrivals may exceed the earlier headline; the chart must remain available")
assert(#state.magpie_chart.series[1].calls <= 24)
assert(state.magpie_chart.series[1].calls[#state.magpie_chart.series[1].calls] == 1)
assert(state.magpie_chart.series[1].tokens[#state.magpie_chart.series[1].tokens] == 200)
assert(string.find(texts(panelEnv.popup), "model-b", 1, true))
local callsTab = assert(find(panelEnv.popup, function(node)
	return node.kind == "button" and node.props.text == TRANSLATIONS["magpie.calls_short"]
end))
callsTab.props.onClick()
local callsText = texts(panelEnv.popup)
assert(
	string.find(callsText, "model-a", 1, true) < string.find(callsText, "model-b", 1, true),
	"model ranking follows the selected chart metric"
)
assert(
	find(panelEnv.popup, function(node)
		return node.props and node.props.tooltip == "provider · model-b 1"
	end),
	"chart switches from tokens to calls without another query"
)
popup.onClose()
response = { status = "success", data = { resultType = "vector", result = rows } }
consumer.refresh(true)
local previousRequest = requests[#requests]
local weekButton = assert(find(panelEnv.popup, function(node)
	return node.kind == "button" and node.props.text == TRANSLATIONS["magpie.window.7d"]
end))
weekButton.props.onClick()
assert(state.magpie.status == "waiting" and state.magpie.window == "7d")
previousRequest.complete({ ok = true, status = 200, body = "metrics" })
assert(state.magpie.status == "waiting", "an old period response cannot overwrite the new selection")
requests[#requests].complete({ ok = true, status = 200, body = "metrics" })
assert(state.magpie.window == "7d" and state.magpie.start == -6 * 86400)
-- Identical qualified model names remain distinct across providers, both in
-- aggregation and in visible provider labels / chart identities.
rows = {}
for _, provider in ipairs({ "provider-a", "provider-b" }) do
	local b = provider == "provider-b"
	point(
		"gen_ai.client.operation.duration_count",
		"codex/shared",
		2,
		{ ["gen_ai.provider.name"] = provider, ["error.type"] = b and "500" or nil }
	)
	point("gen_ai.client.operation.duration_sum", "codex/shared", b and 8 or 2, { ["gen_ai.provider.name"] = provider })
	for _, bucket in ipairs({ { "1", b and 0 or 2 }, { "4", 2 }, { "+Inf", 2 } }) do
		point(
			"gen_ai.client.operation.duration_bucket",
			"codex/shared",
			bucket[2],
			{ ["gen_ai.provider.name"] = provider, le = bucket[1] }
		)
	end
	point(
		"gen_ai.client.token.usage_sum",
		"codex/shared",
		100,
		{ ["gen_ai.provider.name"] = provider, ["gen_ai.token.type"] = "input" }
	)
end
response = { status = "success", data = { resultType = "vector", result = rows } }
consumer.refresh(true)
requests[#requests].complete({ ok = true, status = 200, body = "metrics" })
assert(#state.magpie.models == 2 and state.magpie.calls == 4)
assert(state.magpie.models[1].provider ~= state.magpie.models[2].provider)
popup.onOpen()
local providerText = texts(panelEnv.popup)
assert(string.find(providerText, "provider-a", 1, true) and string.find(providerText, "provider-b", 1, true))
assert(find(panelEnv.popup, function(node)
	return node.props and node.props.tooltip == "provider-a · codex/shared"
end))
assert(find(panelEnv.popup, function(node)
	return node.props and node.props.tooltip == "provider-b · codex/shared"
end))
assert(
	not string.find(providerText, "provider-a/codex/shared", 1, true),
	"provider is displayed separately, not as a fabricated model prefix"
)
-- A provider selector filters all summaries and the shared distribution,
-- retaining other choices and the original sample age without another request.
panelEnv.noctalia.state.set("magpie_chart", {
	status = "ready",
	at = state.magpie.at,
	window = state.magpie.window,
	start = state.magpie.start,
	finish = state.magpie.finish,
	series = {
		{ provider = "provider-a", model = "codex/shared", tokens = { 100 }, calls = { 2 } },
		{ provider = "provider-b", model = "codex/shared", tokens = { 100 }, calls = { 2 } },
	},
})
local function selector()
	return assert(find(panelEnv.popup, function(node)
		return node.kind == "row" and node.props.key == "magpie-provider"
	end))
end
local function menuOptions()
	local options = find(panelEnv.popup, function(node)
		return node.props and node.props.key == "magpie-provider-options"
	end)
	if not options then
		selector().props.onClick()
		options = assert(find(panelEnv.popup, function(node)
			return node.props and node.props.key == "magpie-provider-options"
		end))
	end
	return options.children
end
local function selectionInfo()
	local options, info = menuOptions(), { options = {} }
	for index, option in ipairs(options) do
		table.insert(info.options, option.props.text)
		if option.props.glyph == "check" then
			info.selectedIndex = index - 1
		end
	end
	selector().props.onClick()
	return info
end
local function chooseProvider(index)
	menuOptions()[index + 1].props.onClick()
	assert(not find(panelEnv.popup, function(node)
		return node.props and node.props.key == "magpie-provider-menu"
	end), "choosing a provider closes its options")
end
local info = selectionInfo()
assert(#info.options == 3 and info.selectedIndex == 0)
local beforeSwitch, sourceAt = #requests, state.magpie.at
chooseProvider(1)
assert(#requests == beforeSwitch and state.magpie.at == sourceAt)
assert(state.magpie.provider == "provider-a" and state.magpie.calls == 2 and state.magpie.errors == 0)
assert(state.magpie.mean == 1 and math.abs(state.magpie.p95 - 0.95) < 0.00001)
info = selectionInfo()
assert(#state.magpie.models == 1 and #info.options == 3 and info.selectedIndex == 1)
assert(not string.find(texts(panelEnv.popup), "provider-b", 1, true))
assert(not find(panelEnv.popup, function(node)
	return node.props and node.props.tooltip == "provider-b · codex/shared 2"
end), "the chart is filtered along with model rows")
consumer.refresh(true)
local inFlight = requests[#requests]
chooseProvider(2)
assert(state.magpie.provider == "provider-b" and state.magpie.mean == 4 and state.magpie.errors == 2)
assert(math.abs(state.magpie.p95 - 3.85) < 0.00001)
popup.onClose()
inFlight.complete({ ok = true, status = 200, body = "metrics" })
assert(
	state.magpie.provider == "provider-b" and #state.magpie.providers == 2,
	"an in-flight all-provider response respects the current selection"
)
popup.onOpen()
chooseProvider(0)
assert(state.magpie.provider == nil and state.magpie.calls == 4 and state.magpie.mean == 2.5)
assert(#state.magpie.models == 2 and #selectionInfo().options == 3)
popup.onClose()
local count = #requests
config.magpie_enabled = false
local disabled = vm("lib/magpie.luau")
disabled.refresh(true)
assert(#requests == count and state.magpie.status == "disabled")
print(
	"PASS: Magpie delta usage, model ranking, p95, retries, bounded polling, complete bar/popup lifecycle and failure states"
)
