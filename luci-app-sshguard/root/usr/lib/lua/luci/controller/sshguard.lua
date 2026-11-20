module("luci.controller.sshguard", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/sshguard") then
		return
	end
	entry({"admin", "services", "sshguard"}, cbi("sshguard"), _("SSH 登录预警"), 60).dependent = true
	entry({"admin", "services", "sshguard", "status"}, call("action_status")).leaf = true
end

function action_status()
	local running = (luci.sys.call("pgrep -f /usr/bin/sshguard.sh >/dev/null 2>&1") == 0)
	luci.http.prepare_content("application/json")
	luci.http.write_json({ running = running })
end
