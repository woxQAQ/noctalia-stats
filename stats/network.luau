--!nonstrict
local widget = require("./lib/widget.luau").mount("network", { layout = noctalia.getConfig("network_layout") })
update = widget.update
onClick = widget.click
