--!nonstrict
local metric = noctalia.getConfig("disk_metric")
local capacityDisplay = noctalia.getConfig("capacity_display")
local ioDisplay = noctalia.getConfig("display")
local display = metric == "free" and capacityDisplay or ioDisplay
local widget = require("./lib/widget.luau").mount("disk", { metric = metric, display = display })
update = widget.update
onClick = widget.click
