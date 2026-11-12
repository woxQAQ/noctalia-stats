--!nonstrict
-- Magpie exports delta histograms. VictoriaMetrics preserves their points;
-- sum_over_time counts each exported batch once, including sparse idle periods.
local M = {}
local periods = require("./magpie_period.luau")
local chart = require("./magpie_chart.luau")
local enabled = noctalia.getConfig("magpie_enabled")
local endpoint = string.gsub(noctalia.getConfig("magpie_metrics_endpoint"), "/+$", "")
local service = noctalia.getConfig("magpie_service_name")
local window = noctalia.getConfig("magpie_window")
local interval = noctalia.getConfig("magpie_poll_seconds") * 1000
local busy = false
local lastRead = -math.huge
local generation = 0
local selectedProvider = nil
local knownProviders = {}
local cached = nil

local function providerOptions()
	local values = table.clone(knownProviders)
	if selectedProvider ~= nil and not table.find(values, selectedProvider) then
		table.insert(values, selectedProvider)
	end
	table.sort(values)
	return values
end

local function stateSnapshot(status, message)
	return {
		status = status,
		at = noctalia.nowMs(),
		window = window,
		error = message,
		provider = selectedProvider,
		providers = providerOptions(),
	}
end

local function field(labels, name)
	return labels[name] or labels[(string.gsub(name, "%.", "_"))]
end

local function encode(value)
	return (string.gsub(value, "[^%w%-_%.~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function query(duration, chartOnly)
	local names = chartOnly
			and "gen_ai[._]client[._](operation[._]duration(_seconds)?_count|token[._]usage(_tokens?)?_sum)"
		or "gen_ai[._]client[._](operation[._]duration(_seconds)?_(count|sum|bucket)|token[._]usage(_tokens?)?_sum)"
	local parts = {}
	for _, label in ipairs({ "service.name", "service_name" }) do
		local selector = "{__name__=~"
			.. noctalia.json.encode(names)
			.. ","
			.. noctalia.json.encode(label)
			.. "="
			.. noctalia.json.encode(service)
			.. "}"
		table.insert(parts, "sum_over_time(" .. selector .. "[" .. duration .. "]) keep_metric_names")
	end
	return table.concat(parts, " or ")
end

local function durationQuantile(buckets, intervalBuckets)
	local rows = {}
	for bound, count in pairs(buckets) do
		table.insert(rows, { bound = bound, count = count })
	end
	table.sort(rows, function(a, b)
		return a.bound < b.bound
	end)
	if intervalBuckets then
		local cumulative = 0
		for _, row in ipairs(rows) do
			cumulative += row.count
			row.count = cumulative
		end
	end
	local count = #rows > 0 and rows[#rows].count or 0
	if count <= 0 then
		return nil
	end
	local target, previousCount, previousBound = count * 0.95, 0, 0
	for _, row in ipairs(rows) do
		if row.count >= target then
			if row.bound == math.huge then
				return previousBound, true
			end
			local portion = row.count > previousCount and (target - previousCount) / (row.count - previousCount) or 0
			return previousBound + (row.bound - previousBound) * portion, false
		end
		previousCount, previousBound = row.count, row.bound
	end
	return nil
end

local function decode(rows, range, selection, at)
	local totals = {
		errors = 0,
		models = {},
		window = range.window,
		service = service,
		start = range.start,
		finish = range.finish,
	}
	local groups, buckets = {}, {}
	local intervalBuckets = false
	local accepted = 0
	for _, row in ipairs(rows) do
		local labels = type(row.metric) == "table" and row.metric or {}
		local name = labels.__name__ or ""
		local value = type(row.value) == "table" and tonumber(row.value[2]) or nil
		local provider = field(labels, "gen_ai.provider.name") or ""
		if value and value >= 0 and value < math.huge and (selection == nil or selection == provider) then
			local model = field(labels, "gen_ai.request.model") or "—"
			local key = provider .. "\0" .. model
			local group = groups[key]
			if not group then
				group = { model = model, provider = provider, errors = 0 }
				groups[key] = group
			end
			if string.find(name, "token", 1, true) and string.sub(name, -4) == "_sum" then
				local kind = field(labels, "gen_ai.token.type")
				if kind == "input" or kind == "output" then
					totals[kind] = (totals[kind] or 0) + value
					group[kind] = (group[kind] or 0) + value
					accepted += 1
				end
			elseif string.find(name, "duration", 1, true) then
				if string.sub(name, -6) == "_count" then
					totals.calls = (totals.calls or 0) + value
					group.calls = (group.calls or 0) + value
					local failure = field(labels, "error.type")
					if failure and failure ~= "" then
						totals.errors += value
						group.errors += value
					end
					accepted += 1
				elseif string.sub(name, -4) == "_sum" then
					totals.seconds = (totals.seconds or 0) + value
					group.seconds = (group.seconds or 0) + value
					accepted += 1
				elseif string.sub(name, -7) == "_bucket" then
					local upper = labels.le
					if labels.vmrange then
						upper = string.match(labels.vmrange, "%.%.%.(.+)$")
						intervalBuckets = true
					end
					local bound = upper == "+Inf" and math.huge or tonumber(upper)
					if bound then
						buckets[bound] = (buckets[bound] or 0) + value
					end
				end
			end
		end
	end
	for _, group in pairs(groups) do
		if group.calls or group.input or group.output then
			table.insert(totals.models, group)
		end
	end
	table.sort(totals.models, function(a, b)
		local av, bv = (a.input or 0) + (a.output or 0), (b.input or 0) + (b.output or 0)
		if av ~= bv then
			return av > bv
		end
		if a.model ~= b.model then
			return a.model < b.model
		end
		return a.provider < b.provider
	end)
	if totals.calls and totals.calls > 0 and totals.seconds then
		totals.mean = totals.seconds / totals.calls
	end
	totals.p95, totals.p95Capped = durationQuantile(buckets, intervalBuckets)
	totals.at = at or noctalia.nowMs()
	totals.status = accepted > 0 and "ready" or "empty"
	return totals
end

local function publishSelection()
	local snapshot = selectedProvider == nil and cached.all
		or decode(cached.rows, cached.range, selectedProvider, cached.all.at)
	snapshot.provider = selectedProvider
	snapshot.providers = providerOptions()
	noctalia.state.set("magpie", snapshot)
end

local function failure(message)
	noctalia.state.set("magpie", stateSnapshot("error", message))
end

function M.refresh(force)
	if not enabled then
		noctalia.state.set("magpie", stateSnapshot("disabled"))
		return
	end
	local now = noctalia.nowMs()
	if busy or (not force and now >= lastRead and now - lastRead < interval) then
		return
	end
	lastRead = now
	if not string.match(endpoint, "^https?://[^/%s]+") or not periods.valid(window) then
		failure("invalid Magpie query configuration")
		return
	end
	busy = true
	local range = periods.range(window, now)
	local requestGeneration = generation
	local accepted = noctalia.http({
		url = endpoint
			.. "/api/v1/query?query="
			.. encode(query(tostring(range.seconds) .. "s"))
			.. "&time="
			.. tostring(range.finish),
		follow_redirects = false,
	}, function(result)
		busy = false
		if requestGeneration ~= generation then
			M.refresh(true)
			return
		end
		if not result.ok or result.status ~= 200 then
			failure("metrics query HTTP " .. tostring(result.status))
			return
		end
		local raw = noctalia.json.decode(result.body)
		if
			type(raw) ~= "table"
			or raw.status ~= "success"
			or type(raw.data) ~= "table"
			or raw.data.resultType ~= "vector"
			or type(raw.data.result) ~= "table"
			or raw.isPartial == true
		then
			failure("invalid or partial metrics query response")
			return
		end
		local snapshot = decode(raw.data.result, range)
		cached = { rows = raw.data.result, range = range, all = snapshot }
		local seen = {}
		knownProviders = {}
		for _, model in ipairs(snapshot.models) do
			if not seen[model.provider] then
				seen[model.provider] = true
				table.insert(knownProviders, model.provider)
			end
		end
		publishSelection()
		-- The distribution retains every provider. Filtering this shared data
		-- in the panel makes switching immediate and safe during HTTP callbacks.
		chart.fetch(endpoint, query, range, snapshot)
	end)
	if not accepted then
		busy = false
		failure("metrics request was not accepted")
	end
end

function M.selectWindow(value)
	if not periods.valid(value) then
		return
	end
	if value ~= window then
		window = value
		generation += 1
		cached = nil
		noctalia.state.set("magpie_chart", nil)
		noctalia.state.set("magpie", stateSnapshot("waiting"))
	end
	M.refresh(true)
end

function M.selectProvider(value)
	if type(value) ~= "table" then
		return
	end
	local provider
	if value.all == true then
		provider = nil
	elseif type(value.provider) == "string" then
		provider = value.provider
	else
		return
	end
	if provider == selectedProvider then
		return
	end
	selectedProvider = provider
	local current = noctalia.state.get("magpie")
	if cached and cached.range.window == window and current and current.status ~= "error" then
		publishSelection()
	else
		noctalia.state.set("magpie", stateSnapshot("waiting"))
		M.refresh(true)
	end
end

function M.status()
	local snapshot = noctalia.state.get("magpie")
	local distribution = noctalia.state.get("magpie_chart")
	return {
		panelError = noctalia.state.get("magpie_panel_error"),
		chartStatus = distribution and distribution.status,
		chartError = distribution and distribution.error,
		endpoint = endpoint,
		service = service,
		provider = selectedProvider,
		providers = providerOptions(),
		window = window,
		busy = busy,
		status = snapshot and snapshot.status or "waiting",
		error = snapshot and snapshot.error,
	}
end

return M
