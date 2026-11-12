--!nonstrict
local view = require("./lib/magpie_view.luau")
local display = noctalia.getConfig("display")

local function render()
	local sample = noctalia.state.get("magpie")
	local data = view.fresh(sample) and sample or nil
	local items
	if barWidget.isVertical() then
		items = { ui.glyph({ name = "sparkles" }) }
	elseif display == "tokens" then
		local function line(direction, value)
			return ui.row({ gap = 3, height = 12, align = "center" }, {
				ui.glyph({ name = direction, size = 10, width = 10 }),
				ui.label({
					text = view.count(value),
					fontSize = 11,
					height = 12,
					minWidth = 44,
					textAlign = "end",
					baseline = "inkCentered",
				}),
			})
		end
		items = {
			ui.column(
				{ gap = 0, height = 24 },
				{ line("arrow-up", data and data.input), line("arrow-down", data and data.output) }
			),
		}
	elseif display == "mini" then
		items = {
			ui.column({ gap = 0, height = 24, align = "center" }, {
				ui.label({
					text = "Magpie",
					fontSize = 11,
					height = 12,
					baseline = "inkCentered",
					color = "on_surface_variant",
				}),
				ui.label({ text = view.count(view.total(data)), fontSize = 11, height = 12, baseline = "inkCentered" }),
			}),
		}
	else
		items = {
			ui.glyph({ name = "sparkles" }),
			ui.label({ text = view.count(view.total(data)), baseline = "inkCentered" }),
		}
	end
	barWidget.render(ui.row({ gap = 4, align = "center" }, items))
	barWidget.setTooltip(data and {
		{ "Magpie", noctalia.tr("magpie.window." .. data.window) },
		{
			noctalia.tr("magpie.provider"),
			data.provider == nil and noctalia.tr("magpie.providers_all") or view.providerName(data),
		},
		{ noctalia.tr("magpie.calls"), view.count(data.calls) },
		{ noctalia.tr("magpie.input"), view.count(data.input) },
		{ noctalia.tr("magpie.output"), view.count(data.output) },
	} or { { "Magpie", view.message(sample) } })
end

function update()
	render()
end
function onClick()
	noctalia.togglePanel("woxQAQ/stats:magpie-details")
end
noctalia.state.watch("magpie", render)
noctalia.setUpdateInterval(1000)
render()
