--!nonstrict
-- The image reconciler reloads on a path change. Two atomic SVG slots per gauge
-- keep its source fresh without accumulating files or writing every UI tick.
local M = {}
local cache = {}
local directory
local initialized = false
local reportedFailure = false

local function xml(text)
	local escaped = string.gsub(
		string.gsub(string.gsub(string.gsub(tostring(text), "&", "&amp;"), "<", "&lt;"), ">", "&gt;"),
		'"',
		"&quot;"
	)
	return escaped
end

local function color(role)
	return noctalia.getColor(role) or (role == "on_surface" and "#808080" or "#3584e4")
end

local function svg(props)
	local circumference = 2 * math.pi * 42
	local foreground = color("on_surface")
	local shape = props.shape or "ring"
	local track
	if shape == "pie" then
		track = string.format('<circle cx="50" cy="50" r="42" fill="%s" fill-opacity="0.14"/>', foreground)
	elseif shape == "gauge" then
		track = string.format(
			'<path d="M20.30152 79.69848 A42 42 0 1 1 79.69848 79.69848" fill="none" stroke="%s" stroke-opacity="0.14" stroke-width="9" stroke-linecap="round"/>',
			foreground
		)
	else
		track = string.format(
			'<circle cx="50" cy="50" r="42" fill="none" stroke="%s" stroke-opacity="0.14" stroke-width="7"/>',
			foreground
		)
	end
	local parts = { '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">', track }
	if props.value ~= nil then
		local remaining = math.clamp(props.value, 0, 1)
		local offset = 0
		local segments = props.segments or { { value = remaining, color = props.color or "primary" } }
		for _, segment in ipairs(segments) do
			local fraction = math.min(remaining, math.max(0, segment.value))
			if fraction > 0 then
				if shape == "ring" then
					table.insert(
						parts,
						string.format(
							'<circle cx="50" cy="50" r="42" fill="none" stroke="%s" stroke-width="7" stroke-linecap="%s" stroke-dasharray="%.5f %.5f" stroke-dashoffset="%.5f" transform="rotate(-90 50 50)"/>',
							color(segment.color),
							props.segments and "butt" or "round",
							fraction * circumference,
							(1 - fraction) * circumference,
							-offset * circumference
						)
					)
				elseif shape == "pie" and fraction >= 1 then
					table.insert(
						parts,
						string.format('<circle cx="50" cy="50" r="42" fill="%s"/>', color(segment.color))
					)
				else
					local span = shape == "gauge" and 270 or 360
					local origin = shape == "gauge" and 135 or -90
					local start, finish =
						math.rad(origin + offset * span), math.rad(origin + (offset + fraction) * span)
					local x1, y1 = 50 + 42 * math.cos(start), 50 + 42 * math.sin(start)
					local x2, y2 = 50 + 42 * math.cos(finish), 50 + 42 * math.sin(finish)
					local arc = string.format(
						"M%.5f %.5f A42 42 0 %d 1 %.5f %.5f",
						x1,
						y1,
						fraction * span > 180 and 1 or 0,
						x2,
						y2
					)
					if shape == "pie" then
						table.insert(
							parts,
							string.format(
								'<path d="M50 50 L%.5f %.5f %s Z" fill="%s"/>',
								x1,
								y1,
								string.sub(arc, string.find(arc, " A", 1, true) + 1),
								color(segment.color)
							)
						)
					else
						table.insert(
							parts,
							string.format(
								'<path d="%s" fill="none" stroke="%s" stroke-width="9" stroke-linecap="round"/>',
								arc,
								color(segment.color)
							)
						)
					end
				end
			end
			offset += fraction
			remaining -= fraction
		end
	end
	table.insert(
		parts,
		string.format(
			'<text x="50" y="51" text-anchor="middle" dominant-baseline="central" font-family="sans-serif" font-size="%d" font-weight="500" fill="%s">%s</text></svg>',
			props.fontSize or 22,
			foreground,
			xml(props.text)
		)
	)
	return table.concat(parts)
end

local function imagePath(id, source)
	local old = cache[id]
	if old and old.source == source then
		return old.path
	end
	if not initialized then
		initialized = true
		local runtime = noctalia.getenv("XDG_RUNTIME_DIR")
		local base = runtime and runtime ~= "" and runtime .. "/noctalia-stats" or noctalia.pluginDataDir()
		if base then
			local path = base .. "/gauges"
			if noctalia.mkdirAll(path) then
				directory = path
			end
		end
	end
	if not directory then
		if not reportedFailure then
			noctalia.log("could not create gauge SVG cache directory")
			reportedFailure = true
		end
		return nil
	end
	-- A revision also changes the image identity: coalesced UI renders must reload
	-- even if two updates have already brought the file path back to its old slot.
	local revision = (noctalia.state.get("gauge_revision_" .. id) or 0) + 1
	local slot = revision % 2
	local path = directory .. "/" .. id .. "-" .. tostring(slot) .. ".svg"
	local temporary = path .. ".tmp"
	if not noctalia.writeFile(temporary, source) or not noctalia.renameFile(temporary, path) then
		if not reportedFailure then
			noctalia.log("could not update gauge SVG cache")
			reportedFailure = true
		end
		return nil
	end
	noctalia.state.set("gauge_revision_" .. id, revision)
	cache[id] = { source = source, path = path, revision = revision }
	return path
end

function M.image(props)
	local path = imagePath(props.id, svg(props))
	local size = props.size or 72
	local picture = path
			and ui.image({
				key = props.id .. "_image_" .. tostring(cache[props.id].revision),
				path = path,
				width = size,
				height = size,
				fit = "contain",
			})
		or ui.label({ text = props.text, height = size, fontSize = 23, textAlign = "center" })
	return picture
end

function M.render(props)
	local picture = M.image(props)
	return ui.column({ key = props.id, flexGrow = 1, gap = 1, align = "center", tooltip = props.tooltip }, {
		picture,
		ui.label({ text = props.label, fontSize = 11, color = "on_surface_variant" }),
	})
end

return M
