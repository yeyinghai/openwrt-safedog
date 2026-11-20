local fs   = require "nixio.fs"
local sys  = require "luci.sys"

local function esc(s)
	return (tostring(s or ""):gsub("[&<>\"']", { ["&"]="&amp;", ["<"]="&lt;", [">"]="&gt;", ['"']="&quot;", ["'"]="&#39;" }))
end

local running = (sys.call("ps w | grep -v grep | grep -q '/bin/sh /usr/bin/sshguard.sh$'") == 0)
local enabled = (luci.model.uci.cursor():get("sshguard", "main", "enabled") == "1")

local css = [[
<style>
.sg-head{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin:4px 0 2px}
.sg-pill{display:inline-block;padding:3px 12px;border-radius:999px;font-size:12px;font-weight:600;line-height:20px}
.sg-on{background:#e6f7ee;color:#11845b}.sg-off{background:#fdecec;color:#c9302c}.sg-idle{background:#f1f3f5;color:#6c757d}
.sg-desc{color:#6c757d;font-size:13px}
.sg-vars{display:flex;flex-wrap:wrap;gap:8px}
.sg-var{background:#f4f6fb;border:1px solid #e3e8f2;border-radius:6px;padding:4px 10px;font-size:12px;color:#495057}
.sg-var code{color:#5e72e4;font-weight:600;margin-right:6px;background:none}
#cbi-sshguard-main input[type=text]{min-width:420px;max-width:100%}
#cbi-sshguard-main-_log .cbi-value-title{display:none}
#cbi-sshguard-main-_log .cbi-value-field{width:100%!important;margin-left:0!important;padding-left:0!important}
.sg-table{width:100%;border-collapse:collapse;font-size:13px}
.sg-table th{background:#f8f9fe;color:#525f7f;font-weight:600;text-align:left;padding:10px 12px;border-bottom:1px solid #e9ecef;white-space:nowrap}
.sg-table td{padding:10px 12px;border-bottom:1px solid #f1f3f5;vertical-align:top;color:#32325d}
.sg-table tr:hover td{background:#fafbff}
.sg-tag{display:inline-block;padding:2px 8px;border-radius:4px;font-size:12px;white-space:nowrap}
.sg-t-fail{background:#fdecec;color:#c9302c}.sg-t-ssh{background:#e8f1fd;color:#1d6fd8}
.sg-t-web{background:#efeafd;color:#6f42c1}.sg-t-test{background:#f1f3f5;color:#6c757d}.sg-t-report{background:#fff4e5;color:#b76e00}
.sg-sub{font-weight:600;color:#32325d;margin:6px 0 10px}
#cbi-sshguard-main-_bans .cbi-value-title{display:none}
#cbi-sshguard-main-_bans .cbi-value-field{width:100%!important;margin-left:0!important;padding-left:0!important}
.sg-ok{color:#11845b;white-space:nowrap}.sg-bad{color:#c9302c;white-space:nowrap}
.sg-time{white-space:nowrap;color:#8898aa}
.sg-empty{text-align:center;color:#adb5bd;padding:40px 0}
.sg-wrap{max-height:520px;overflow:auto;border:1px solid #e9ecef;border-radius:8px}
</style>]]

local status
if running then status = '<span class="sg-pill sg-on">● 运行中</span>'
elseif enabled then status = '<span class="sg-pill sg-off">● 已启用但未运行</span>'
else status = '<span class="sg-pill sg-idle">● 未启用</span>' end

m = Map("sshguard", translate("SSH 登录预警"),
	css .. '<div class="sg-head">' .. status ..
	'<span class="sg-desc">监控 SSH 与网页后台登录，暴力破解自动封禁，登录提醒与每日简报推送到 Bark</span></div>')

do
	local http = require "luci.http"
	local ip = (http.formvalue("sg_ip") or ""):match("^%s*([%x%.:]+)%s*$")
	if http.formvalue("sg_ban") then
		m.message = ip and sys.exec("/usr/bin/sshguard.sh ban " .. ip .. " 2>&1") or "请输入正确的 IP"
	elseif http.formvalue("sg_unban") then
		m.message = ip and sys.exec("/usr/bin/sshguard.sh unban " .. ip .. " 2>&1") or "请输入正确的 IP"
	elseif http.formvalue("sg_unban_all") then
		m.message = sys.exec("/usr/bin/sshguard.sh unban all 2>&1")
	end
end

s = m:section(NamedSection, "main", "sshguard")
s.addremove = false
s:tab("basic", translate("基本设置"))
s:tab("rule",  translate("预警规则"))
s:tab("ban",   translate("自动封禁"))
s:tab("report", translate("每日简报"))
s:tab("msg",   translate("推送内容"))
s:tab("log",   translate("推送记录"))

-- 基本设置
o = s:taboption("basic", Flag, "enabled", translate("启用"))
o.rmempty = false

o = s:taboption("basic", Value, "bark_url", translate("Bark 地址"),
	translate("官方：https://api.day.app/你的Key　自建：https://域名:端口/你的Key"))
o.placeholder = "https://api.day.app/xxxxxxxx"
o.rmempty = false

o = s:taboption("basic", Flag, "auto_direct", translate("自建 Bark 内网直连"),
	translate("Bark 域名指向本路由器公网 IP 时，自动按端口转发规则走内网地址（路由器自身访问不了自己的公网端口）"))
o.rmempty = false
o.default = "1"

o = s:taboption("basic", Value, "direct_addr", translate("内网地址（可选）"),
	translate("留空自动识别；手动指定填 IP:端口，例如 192.168.2.168:8666"))
o.placeholder = "自动"
o:depends("auto_direct", "1")

o = s:taboption("basic", Value, "group", translate("分组"))
o.default = "router"

o = s:taboption("basic", ListValue, "level", translate("通知级别"))
o:value("active", translate("默认"))
o:value("timeSensitive", translate("时效性（专注模式也提醒）"))
o:value("passive", translate("静默（只进通知中心）"))
o:value("critical", translate("重要警告（静音也响）"))
o.default = "timeSensitive"

o = s:taboption("basic", Value, "sound", translate("提示音"))
o.placeholder = "默认"
for _, v in ipairs({ "alarm", "bell", "birdsong", "glass", "horn", "minuet", "multiwayinvitation", "newmail", "shake", "telegraph" }) do o:value(v) end

o = s:taboption("basic", Button, "_test", translate("推送测试"), translate("修改后请先「保存并应用」再测试"))
o.inputtitle = translate("发送测试消息")
o.inputstyle = "apply"
function o.write(self, section)
	local out = sys.exec("/usr/bin/sshguard.sh test 2>&1")
	m.message = (out ~= "" and out or "❌ 无返回，请检查 Bark 地址")
end

-- 预警规则
o = s:taboption("rule", Flag, "notify_fail", translate("暴力破解预警"), translate("SSH 与网页后台的密码错误都会计数；失败次数和统计时间同时用于自动封禁"))
o.rmempty = false
o.default = "1"

o = s:taboption("rule", Value, "threshold", translate("失败次数"), translate("同一 IP 达到此次数即预警"))
o.datatype = "range(1,1000)"
o.default = "5"

o = s:taboption("rule", Value, "window", translate("统计时间"), translate("分钟"))
o.datatype = "range(1,1440)"
o.default = "10"

o = s:taboption("rule", Value, "cooldown", translate("同一 IP 预警间隔"), translate("分钟，避免同一 IP 持续刷屏"))
o.datatype = "range(0,10080)"
o.default = "60"
o:depends("notify_fail", "1")

o = s:taboption("rule", Value, "lan_prefix", translate("内网网段"), translate("该网段输错密码不算暴力破解"))
o.default = "192.168.2."

o = s:taboption("rule", Flag, "notify_success", translate("SSH 登录成功提醒"))
o.rmempty = false
o.default = "1"

o = s:taboption("rule", Flag, "notify_web_success", translate("网页后台登录成功提醒"))
o.rmempty = false
o.default = "1"

o = s:taboption("rule", Flag, "geo", translate("查询 IP 归属地"), translate("推送中的 {loc} 显示国家/省市/运营商（ip-api.com，结果缓存 7 天）"))
o.rmempty = false
o.default = "1"

o = s:taboption("rule", Flag, "notify_lan_login", translate("内网登录也提醒"), translate("关闭后只提醒外网来源的登录"))
o.rmempty = false
o.default = "1"


-- 自动封禁
o = s:taboption("ban", Flag, "ban_enabled", translate("启用自动封禁"),
	translate("同一 IP 失败次数达到「预警规则」里的阈值后，直接在防火墙丢弃它的所有连接（SSH、网页及其他端口）"))
o.rmempty = false
o.default = "1"

o = s:taboption("ban", ListValue, "ban_time", translate("封禁时长"))
for _, v in ipairs({ {"60","1 小时"}, {"360","6 小时"}, {"1440","1 天"}, {"4320","3 天"}, {"10080","7 天"}, {"43200","30 天"}, {"0","永久"} }) do o:value(v[1], v[2]) end
o.default = "1440"
o:depends("ban_enabled", "1")

o = s:taboption("ban", DynamicList, "ban_whitelist", translate("白名单"),
	translate("永不封禁。填完整 IP，或以 . 结尾的前缀（如 1.2.3.）；内网地址默认不会被封"))
o.datatype = "string"
o:depends("ban_enabled", "1")

o = s:taboption("ban", DummyValue, "_bans")
o.rawhtml = true
function o.cfgvalue()
	local rows = {}
	for l in (sys.exec("/usr/bin/sshguard.sh bans 2>/dev/null") or ""):gmatch("[^\n]+") do
		local ip, t = l:match("^(%S+)%s+(%d+)")
		if ip then rows[#rows + 1] = { ip, tonumber(t) } end
	end
	if #rows == 0 then
		return '<div class="sg-sub">当前封禁</div><div class="sg-wrap"><div class="sg-empty">当前没有被封禁的 IP</div></div>'
	end
	local h = { '<div class="sg-sub">当前封禁（' .. #rows .. ' 个）</div><div class="sg-wrap"><table class="sg-table"><tr><th>IP</th><th>归属地</th><th>剩余时间</th></tr>' }
	for _, r in ipairs(rows) do
		local loc = fs.readfile("/tmp/sshguard/geo_" .. r[1]:gsub(":", "_")) or "-"
		local t = r[2]
		local left
		if t == 0 then left = "永久"
		elseif t >= 86400 then left = string.format("%d 天 %d 小时", math.floor(t / 86400), math.floor((t % 86400) / 3600))
		elseif t >= 3600 then left = string.format("%d 小时 %d 分", math.floor(t / 3600), math.floor((t % 3600) / 60))
		else left = string.format("%d 分钟", math.ceil(t / 60)) end
		h[#h + 1] = string.format('<tr><td><code>%s</code></td><td>%s</td><td class="sg-time">%s</td></tr>', esc(r[1]), esc(loc:gsub("\n", "")), left)
	end
	h[#h + 1] = '</table></div>'
	return table.concat(h)
end

o = s:taboption("ban", DummyValue, "_ipctl", translate("手动封禁 / 解封"))
o.rawhtml = true
function o.cfgvalue()
	return '<div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">' ..
		'<input type="text" class="cbi-input-text" name="sg_ip" placeholder="例如 1.2.3.4" style="min-width:220px">' ..
		'<input type="submit" class="cbi-button cbi-button-remove" name="sg_ban" value="封禁">' ..
		'<input type="submit" class="cbi-button cbi-button-apply" name="sg_unban" value="解封">' ..
		'<input type="submit" class="cbi-button cbi-button-reset" name="sg_unban_all" value="全部解封" onclick="return confirm(\'确定解封全部 IP？\')">' ..
		'</div>'
end

-- 每日简报
o = s:taboption("report", Flag, "report_enabled", translate("启用每日简报"),
	translate("每天定时推送过去 24 小时的安全情况；统计数据保存在 /etc/sshguard，重启不丢"))
o.rmempty = false
o.default = "1"

o = s:taboption("report", ListValue, "report_hour", translate("发送时间"))
for h = 0, 23 do o:value(tostring(h), string.format("%02d:00", h)) end
o.default = "9"
o:depends("report_enabled", "1")

o = s:taboption("report", Flag, "report_top", translate("攻击最多的 IP"), translate("前 3 名及归属地"))
o.rmempty = false
o.default = "1"
o:depends("report_enabled", "1")

o = s:taboption("report", Flag, "report_login", translate("登录成功记录"))
o.rmempty = false
o.default = "1"
o:depends("report_enabled", "1")

o = s:taboption("report", Flag, "report_ban", translate("封禁统计"))
o.rmempty = false
o.default = "1"
o:depends("report_enabled", "1")

o = s:taboption("report", Flag, "report_sys", translate("路由器状态"), translate("运行时间、内存、负载、公网 IP"))
o.rmempty = false
o.default = "1"
o:depends("report_enabled", "1")

o = s:taboption("report", Button, "_report", translate("立即发送"), translate("马上推送一份简报看看效果"))
o.inputtitle = translate("发送简报")
o.inputstyle = "apply"
function o.write()
	m.message = sys.exec("/usr/bin/sshguard.sh report 2>&1")
end

-- 推送内容
o = s:taboption("msg", DummyValue, "_vars", translate("可用变量"))
o.rawhtml = true
function o.cfgvalue()
	local h = '<div class="sg-vars">'
	for _, v in ipairs({ {"{host}","路由器名称"}, {"{ip}","来源 IP"}, {"{user}","用户名"},
		{"{count}","失败次数"}, {"{minutes}","统计分钟"}, {"{loc}","IP 归属地"}, {"{ban}","封禁说明"}, {"{time}","时间"} }) do
		h = h .. '<span class="sg-var"><code>' .. v[1] .. '</code>' .. v[2] .. '</span>'
	end
	return h .. '</div>'
end

local function msg(key, label, default)
	local x = s:taboption("msg", Value, key, translate(label))
	x.default = default
	x.placeholder = default
	return x
end
msg("fail_title", "暴力破解 · 标题", "⚠️ {host} SSH 暴力破解")
msg("fail_body",  "暴力破解 · 内容", "{ip}（{loc}）在 {minutes} 分钟内失败 {count} 次，最近尝试用户：{user}。{ban}")
msg("ok_title",   "SSH 登录 · 标题", "🔐 {host} SSH 登录成功")
msg("ok_body",    "SSH 登录 · 内容", "用户 {user} 从 {ip}（{loc}）登录，时间 {time}")
msg("web_title",  "网页登录 · 标题", "🌐 {host} 网页后台登录成功")
msg("web_body",   "网页登录 · 内容", "用户 {user} 从 {ip}（{loc}）登录 LuCI，时间 {time}")

-- 推送记录
o = s:taboption("log", DummyValue, "_log")
o.rawhtml = true
function o.cfgvalue()
	local names = { fail = "暴力破解", ssh = "SSH 登录", web = "网页登录", test = "测试", report = "每日简报" }
	local rows = {}
	for line in (fs.readfile("/tmp/sshguard/history.log") or ""):gmatch("[^\n]+") do
		local t, k, st, ti, bo = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
		if t then rows[#rows + 1] = { t, k, st, ti, bo } end
	end
	if #rows == 0 then
		return '<div class="sg-wrap"><div class="sg-empty">暂无推送记录</div></div>'
	end
	local h = { '<div class="sg-wrap"><table class="sg-table"><tr><th>时间</th><th>类型</th><th>标题</th><th>内容</th><th>结果</th></tr>' }
	for i = #rows, 1, -1 do
		local r = rows[i]
		h[#h + 1] = string.format('<tr><td class="sg-time">%s</td><td><span class="sg-tag sg-t-%s">%s</span></td><td>%s</td><td>%s</td><td class="%s">%s</td></tr>',
			esc(r[1]), esc(r[2]), esc(names[r[2]] or r[2]), esc(r[4]), esc(r[5]),
			r[3] == "ok" and "sg-ok" or "sg-bad", r[3] == "ok" and "✔ 成功" or "✘ 失败")
	end
	h[#h + 1] = '</table></div>'
	return table.concat(h)
end
function o.write() end

o = s:taboption("log", Button, "_clear", translate("清空记录"))
o.inputtitle = translate("清空")
o.inputstyle = "reset"
function o.write()
	fs.remove("/tmp/sshguard/history.log")
end

return m
