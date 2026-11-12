--!nonstrict
local M = {}
local busy = false
local function encode(value)
	return (string.gsub(value, "[^%w%-_%.~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

function M.fetch(endpoint, expression, range, snapshot)
	local lease = noctalia.state.get("magpie_chart_lease")
	if busy or not lease or lease < noctalia.nowMs() or snapshot.status ~= "ready" then
		return
	end
	local step = range.step
	local complete = math.floor(range.seconds / step)
	local covered = range.start + complete * step
	local count = complete + (covered < range.finish and 1 or 0)
	local series, byKey = {}, {}
	local function itemFor(labels)
		local model = labels["gen_ai.request.model"] or labels.gen_ai_request_model or "—"
		local provider = labels["gen_ai.provider.name"] or labels.gen_ai_provider_name or ""
		local key = provider .. "\0" .. model
		if not byKey[key] then
			local item = { model = model, provider = provider, tokens = {}, calls = {} }
			for i = 1, count do
				item.tokens[i] = 0
				item.calls[i] = 0
			end
			byKey[key] = item
			table.insert(series, item)
		end
		return byKey[key]
	end
	for _, model in ipairs(snapshot.models) do
		itemFor({ ["gen_ai.request.model"] = model.model, ["gen_ai.provider.name"] = model.provider })
	end
	local function current()
		local sample = noctalia.state.get("magpie")
		return sample and sample.at == snapshot.at and sample.window == range.window
	end
	local function fail(message)
		busy = false
		if current() then
			noctalia.state.set(
				"magpie_chart",
				{ status = "error", window = range.window, at = noctalia.nowMs(), error = message }
			)
		end
	end
	local function add(row, index, value)
		value = tonumber(value)
		if index < 1 or index > count or not value or value < 0 or value == math.huge then
			return
		end
		local labels = row.metric or {}
		local kind = string.find(labels.__name__ or "", "token", 1, true) and "tokens" or "calls"
		local item = itemFor(labels)
		item[kind][index] += value
	end
	local function publish()
		busy = false
		if current() then
			noctalia.state.set("magpie_chart", {
				status = "ready",
				at = noctalia.nowMs(),
				window = range.window,
				start = range.start,
				finish = range.finish,
				step = step,
				series = series,
			})
		end
	end
	local function query(duration)
		return 'sum by (__name__,"gen_ai.request.model","gen_ai.provider.name",gen_ai_request_model,gen_ai_provider_name) ('
			.. expression(tostring(duration) .. "s", true)
			.. ")"
	end
	local function request(path, queryText, suffix, resultType, callback)
		local accepted = noctalia.http({
			url = endpoint .. "/api/v1/" .. path .. "?query=" .. encode(queryText) .. suffix,
			follow_redirects = false,
		}, function(result)
			if not current() then
				busy = false
				return
			end
			local raw = result.ok and result.status == 200 and noctalia.json.decode(result.body) or nil
			if
				type(raw) ~= "table"
				or raw.status ~= "success"
				or raw.isPartial == true
				or type(raw.data) ~= "table"
				or raw.data.resultType ~= resultType
				or type(raw.data.result) ~= "table"
			then
				fail(
					"invalid chart response: HTTP "
						.. tostring(result.status)
						.. " "
						.. string.sub(result.body or "", 1, 256)
				)
				return
			end
			callback(raw.data.result)
		end)
		if not accepted then
			fail("chart request was not accepted")
		end
	end
	busy = true
	request(
		"query_range",
		query(step),
		"&start=" .. tostring(range.start + step) .. "&end=" .. tostring(covered) .. "&step=" .. tostring(step),
		"matrix",
		function(rows)
			for _, row in ipairs(rows) do
				for _, point in ipairs(row.values or {}) do
					local at = tonumber(point[1])
					if at then
						add(row, math.floor((at - range.start) / step + 0.5), point[2])
					end
				end
			end
			if covered < range.finish then
				-- Query the unfinished bucket directly. OTLP can arrive late between
				-- requests, so subtracting an older headline total would lose data.
				request(
					"query",
					query(range.finish - covered),
					"&time=" .. tostring(range.finish),
					"vector",
					function(tail)
						for _, row in ipairs(tail) do
							if type(row.value) == "table" then
								add(row, count, row.value[2])
							end
						end
						publish()
					end
				)
			else
				publish()
			end
		end
	)
end
return M
