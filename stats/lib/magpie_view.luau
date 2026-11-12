--!nonstrict
local M = {}

function M.fresh(sample)
	local age = sample and sample.at and noctalia.nowMs() - sample.at
	return sample
		and sample.status == "ready"
		and age
		and age >= 0
		and age <= math.max(30000, noctalia.getConfig("magpie_poll_seconds") * 3000)
end

function M.message(sample)
	local status = sample and sample.status or "waiting"
	if status == "ready" then
		status = "error"
	end
	return noctalia.tr("magpie." .. status)
end

function M.count(value)
	if value == nil then
		return "—"
	end
	for _, unit in ipairs({
		{ scale = 1000000000, suffix = "G" },
		{ scale = 1000000, suffix = "M" },
		{ scale = 1000, suffix = "k" },
	}) do
		if value >= unit.scale then
			return (string.gsub(string.format("%.1f", value / unit.scale), "%.0$", "")) .. unit.suffix
		end
	end
	return string.format("%.0f", value)
end

function M.total(sample)
	return sample and (sample.input or sample.output) and ((sample.input or 0) + (sample.output or 0)) or nil
end

function M.duration(value)
	if value == nil then
		return "—"
	end
	if value < 1 then
		return string.format("%.0f ms", value * 1000)
	end
	return string.format("%.2f s", value)
end

function M.modelName(model)
	return model.model
end

function M.providerName(model)
	return model.provider ~= "" and model.provider or noctalia.tr("magpie.provider_unknown")
end

function M.modelSource(model)
	return M.providerName(model) .. " · " .. M.modelName(model)
end

return M
