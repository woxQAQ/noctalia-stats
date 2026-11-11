--!nonstrict
local M = {}

function M.path()
	local command = noctalia.getConfig("collector_command")
	if string.sub(command, 1, 1) ~= "/" and string.find(command, "/", 1, true) then
		return noctalia.pluginDir() .. "/" .. command
	end
	return command
end

function M.run(arguments, callback)
	local command = M.path()
	if not noctalia.commandExists(command) then
		return false
	end
	local argv = { command }
	for _, value in ipairs(arguments) do
		table.insert(argv, value)
	end
	return noctalia.runAsync(argv, callback)
end

return M
