local arp = require "proto.arp"

return function(env, error)

	-- luacheck: read globals parseIPAddress
	env.ip = function(str)
		error:assert(type(str) == "string",
			"Function 'ip': string expected, got %s.", type(str))
		local ip = parseIPAddress(str)
		error:assert(ip, "Invalid ip address %q.", str)
		return ip
	end

	-- luacheck: read globals parseMacAddress
	env.mac = function(str)
		error:assert(type(str) == "string",
			"Function 'mac': string expected, got %s.", type(str))
		local mac = parseMacAddress(str, true)
		error:assert(mac, "Invalid mac address %q.", str)
		return mac
	end

	-- arp(ip:ip_addr, timeout:number = 5)
	-- TODO consider deducing ip
	env.arp = function(ip, timeout)
		timeout = timeout or 5
		-- TODO input assertions

		local result
		return function()
			if timeout then
				result = arp.blockingLookup(ip, timeout)
				timeout = nil
			end
			return result
		end
	end

end
