#!/bin/sh
# luci-app-sshguard: SSH / LuCI 登录监控、暴力破解自动封禁、Bark 推送、每日安全简报
cfg() { v=$(uci -q get sshguard.main.$1); [ -n "$v" ] && echo "$v" || echo "$2"; }

BARK_URL=$(cfg bark_url "")
GROUP=$(cfg group router)
LEVEL=$(cfg level timeSensitive)
SOUND=$(cfg sound "")
THRESHOLD=$(cfg threshold 5)
WINDOW_MIN=$(cfg window 10)
COOLDOWN_MIN=$(cfg cooldown 60)
LAN_PREFIX=$(cfg lan_prefix "192.168.2.")
NOTIFY_FAIL=$(cfg notify_fail 1)
NOTIFY_OK=$(cfg notify_success 1)
NOTIFY_WEB=$(cfg notify_web_success 1)
NOTIFY_LAN_LOGIN=$(cfg notify_lan_login 1)
GEO=$(cfg geo 1)
BAN=$(cfg ban_enabled 0)
BAN_MIN=$(cfg ban_time 1440)
FAIL_TITLE=$(cfg fail_title '⚠️ {host} SSH 暴力破解')
FAIL_BODY=$(cfg fail_body '{ip}（{loc}）在 {minutes} 分钟内失败 {count} 次，最近尝试用户：{user}。{ban}')
OK_TITLE=$(cfg ok_title '🔐 {host} SSH 登录成功')
OK_BODY=$(cfg ok_body '用户 {user} 从 {ip}（{loc}）登录，时间 {time}')
WEB_TITLE=$(cfg web_title '🌐 {host} 网页后台登录成功')
WEB_BODY=$(cfg web_body '用户 {user} 从 {ip}（{loc}）登录 LuCI，时间 {time}')
AUTO_DIRECT=$(cfg auto_direct 1)
DIRECT_ADDR=$(cfg direct_addr "")
WINDOW=$((WINDOW_MIN * 60)); COOLDOWN=$((COOLDOWN_MIN * 60))

D=/tmp/sshguard; mkdir -p "$D"
P=/etc/sshguard; mkdir -p "$P"          # 持久数据：事件与封禁（路由器重启后保留）
LOG=$D/history.log
EV=$P/events.log
SET=sshguard_ban
HOST=$(uci -q get system.@system[0].hostname); [ -n "$HOST" ] || HOST=OpenWrt

esc_sed() { printf '%s' "$1" | sed 's/[\\&|]/\\&/g'; }
esc_json() { printf '%s' "$1" | awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/," "); if (NR>1) print "\\n"; print}'; }

is_lan() {
  case "$1" in "$LAN_PREFIX"*|127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*|::1|fe80:*|fd*|fc*) return 0 ;; esac
  return 1
}

# IP 归属地，结果缓存 7 天
geo() {
  ip=$1; [ -n "$ip" ] || { echo "未知"; return; }
  is_lan "$ip" && { echo "内网"; return; }
  [ "$GEO" = 1 ] || { echo "-"; return; }
  f="$D/geo_$(echo "$ip" | tr ':' '_')"
  if [ -f "$f" ] && [ $(( $(date +%s) - $(date -r "$f" +%s 2>/dev/null || echo 0) )) -lt 604800 ]; then cat "$f"; return; fi
  j=$(curl -s -m 5 "http://ip-api.com/json/$ip?lang=zh-CN&fields=status,country,regionName,city,isp")
  if [ "$(echo "$j" | jsonfilter -e '@.status' 2>/dev/null)" = success ]; then
    c=$(echo "$j" | jsonfilter -e '@.country'); r=$(echo "$j" | jsonfilter -e '@.regionName')
    t=$(echo "$j" | jsonfilter -e '@.city'); i=$(echo "$j" | jsonfilter -e '@.isp')
    [ "$c" = "中国" ] && c=""
    [ "$t" = "$r" ] && t=""
    loc=$(echo "$c $r $t" | sed 's/  */ /g; s/^ //; s/ $//')
    [ -n "$i" ] && loc="$loc · $i"
    echo "$loc" > "$f"; echo "$loc"
  else
    echo "未知"
  fi
}

render() { # 模板 ip user count loc ban
  printf '%s' "$1" | sed "s|{host}|$(esc_sed "$HOST")|g; s|{ip}|$(esc_sed "$2")|g; s|{user}|$(esc_sed "$3")|g; s|{count}|$(esc_sed "$4")|g; s|{loc}|$(esc_sed "$5")|g; s|{ban}|$(esc_sed "$6")|g; s|{minutes}|$WINDOW_MIN|g; s|{time}|$(date '+%F %T')|g"
}

# 推送地址解析到本路由器 WAN IP 时（自建 Bark 在内网），自动走端口转发的内网地址
connect_opt() {
  hp=$(echo "$BARK_URL" | sed -n 's#^[a-zA-Z]*://\([^/]*\).*#\1#p')
  host=${hp%:*}; port=${hp##*:}
  if [ "$host" = "$hp" ]; then case "$BARK_URL" in https*) port=443 ;; *) port=80 ;; esac; fi
  if [ -n "$DIRECT_ADDR" ]; then echo "--connect-to $host:$port:$DIRECT_ADDR"; return; fi
  [ "$AUTO_DIRECT" = 1 ] || return
  hip=$(nslookup "$host" 127.0.0.1 2>/dev/null | sed -n 's/^Address [0-9]*: \([0-9.]*\)$/\1/p' | grep -v '^127\.' | head -n1)
  [ -n "$hip" ] || return
  for w in $(ifstatus wan 2>/dev/null | jsonfilter -e '@["ipv4-address"][*].address' 2>/dev/null); do
    [ "$w" = "$hip" ] || continue
    sec=$(uci -q show firewall | sed -n "s/^firewall\.\(@redirect\[[0-9]*\]\)\.src_dport='$port'$/\1/p" | head -n1)
    [ -n "$sec" ] || return
    dip=$(uci -q get firewall.$sec.dest_ip); dport=$(uci -q get firewall.$sec.dest_port); [ -n "$dport" ] || dport=$port
    [ -n "$dip" ] && echo "--connect-to $host:$port:$dip:$dport"
    return
  done
}

send() { # 类型 标题 内容 -> 输出结果，写推送记录
  [ -n "$BARK_URL" ] || { echo "❌ 未填写 Bark 地址"; return 1; }
  extra=""; [ -n "$SOUND" ] && extra=",\"sound\":\"$(esc_json "$SOUND")\""
  data="{\"title\":\"$(esc_json "$2")\",\"body\":\"$(esc_json "$3")\",\"group\":\"$(esc_json "$GROUP")\",\"level\":\"$LEVEL\"$extra}"
  co=$(connect_opt)
  r=$(curl -sS -m 10 $co -X POST "$BARK_URL" -H 'Content-Type: application/json; charset=utf-8' -d "$data" 2>&1)
  case "$r" in *'"code":200'*) st=ok; echo "✅ 发送成功${co:+（经内网 $(echo "${co#* }" | cut -d: -f3-)）}" ;; *) st=fail; echo "❌ 发送失败：$r" ;; esac
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$1" "$st" "$2" "$(printf '%s' "$3" | tr '\n' ' ')" >> "$LOG"
  [ "$(wc -l < "$LOG")" -gt 200 ] && { tail -n 200 "$LOG" > "$LOG.t" && mv "$LOG.t" "$LOG"; }
}

notify() { # 类型 标题模板 内容模板 ip user count ban（后台执行，避免查归属地阻塞日志）
  ( loc=$(geo "$4")
    send "$1" "$(render "$2" "$4" "$5" "$6" "$loc" "$7")" "$(render "$3" "$4" "$5" "$6" "$loc" "$7")" >/dev/null ) &
}

event() { # 类型 ip user
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" >> "$EV"
  [ "$(wc -l < "$EV")" -gt 3000 ] && { tail -n 2000 "$EV" > "$EV.t" && mv "$EV.t" "$EV"; }
}

# ---------- 封禁 ----------
fw_ensure() {
  ipset -! create $SET hash:ip timeout 86400 2>/dev/null
  iptables -t raw -C PREROUTING -m set --match-set $SET src -j DROP 2>/dev/null || \
    iptables -t raw -I PREROUTING -m set --match-set $SET src -j DROP
}
ban_save() { ipset save $SET 2>/dev/null | grep '^add ' > "$P/ban.save"; }
whitelisted() { # 支持完整 IP，或以 . 结尾的前缀（如 1.2.3.）
  is_lan "$1" && return 0
  for w in $(uci -q get sshguard.main.ban_whitelist); do
    w=${w%\*}
    [ "$1" = "$w" ] && return 0
    case "$w" in *.) case "$1" in "$w"*) return 0 ;; esac ;; esac
  done
  return 1
}
do_ban() { # ip -> 0 已封禁
  [ "$BAN" = 1 ] || return 1
  case "$1" in *:*) return 1 ;; esac
  whitelisted "$1" && return 1
  fw_ensure
  ipset -q test $SET "$1" && return 0
  ipset -! add $SET "$1" timeout $((BAN_MIN * 60))
  ban_save; event ban "$1" ""
  # 断开已建立的连接
  command -v conntrack >/dev/null && conntrack -D -s "$1" >/dev/null 2>&1
  return 0
}
ban_text() { [ "$BAN_MIN" = 0 ] && echo "已自动永久封禁" || echo "已自动封禁 $(fmt_min $BAN_MIN)"; }
fmt_min() { m=$1; if [ $m -ge 1440 ] && [ $((m % 1440)) = 0 ]; then echo "$((m / 1440)) 天"; elif [ $m -ge 60 ] && [ $((m % 60)) = 0 ]; then echo "$((m / 60)) 小时"; else echo "$m 分钟"; fi; }

# ---------- 每日简报 ----------
report() {
  now=$(date +%s); since=$((now - 86400))
  R=$(awk -F'\t' -v s="$since" '$1 >= s' "$EV" 2>/dev/null)
  cnt() { echo "$R" | awk -F'\t' -v t="$1" '$2==t' | grep -c .; }
  sf=$(cnt sshfail); wf=$(cnt webfail); so=$(cnt sshok); wo=$(cnt webok); nb=$(cnt ban)
  nip=$(echo "$R" | awk -F'\t' '$2=="sshfail"||$2=="webfail"{print $3}' | grep . | sort -u | grep -c .)
  cur=$(ipset list $SET 2>/dev/null | sed -n '/^Members:/,$p' | grep -c '^[0-9]')
  body="🛡 攻击：SSH 失败 $sf 次，网页失败 $wf 次，来自 $nip 个 IP"
  if [ "$(cfg report_top 1)" = 1 ] && [ "$nip" -gt 0 ]; then
    body="$body
🎯 攻击最多："
    n=1
    for l in $(echo "$R" | awk -F'\t' '$2=="sshfail"||$2=="webfail"{print $3}' | grep . | sort | uniq -c | sort -rn | head -n 3 | awk '{print $2"|"$1}'); do
      body="$body
  $n. ${l%|*}（$(geo "${l%|*}")）${l#*|} 次"; n=$((n + 1))
    done
  fi
  if [ "$(cfg report_login 1)" = 1 ]; then
    body="$body
🔐 登录成功：SSH $so 次，网页 $wo 次"
    last=$(echo "$R" | awk -F'\t' '$2=="sshok"||$2=="webok"' | tail -n 1)
    if [ -n "$last" ]; then
      lip=$(echo "$last" | cut -f3); lu=$(echo "$last" | cut -f4); lt=$(echo "$last" | cut -f2 | sed 's/sshok/SSH/; s/webok/网页/')
      body="$body
  最近：$lu@$lip（$(geo "$lip")）$lt $(date -d @"$(echo "$last" | cut -f1)" '+%m-%d %H:%M' 2>/dev/null)"
    fi
  fi
  [ "$(cfg report_ban 1)" = 1 ] && body="$body
🚫 封禁：新增 $nb 个，当前共 $cur 个"
  if [ "$(cfg report_sys 1)" = 1 ]; then
    up=$(cut -d. -f1 /proc/uptime); ud=$((up / 86400)); uh=$((up % 86400 / 3600)); um=$((up % 3600 / 60))
    [ $ud -gt 0 ] && ut="${ud}天${uh}小时" || ut="${uh}小时${um}分"
    mem=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%d%%", (t-a)*100/t}' /proc/meminfo)
    load=$(cut -d' ' -f1 /proc/loadavg)
    wan=$(ifstatus wan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
    body="$body
📟 运行 $ut · 内存 $mem · 负载 $load
🌍 公网 IP：${wan:-未获取}"
  fi
  send report "📊 $HOST 每日安全简报" "$body"
}

cron_set() {
  sed -i '/sshguard.sh report/d' /etc/crontabs/root 2>/dev/null
  if [ "$1" = on ] && [ "$(cfg report_enabled 1)" = 1 ]; then
    echo "$(cfg report_minute 0) $(cfg report_hour 9) * * * /usr/bin/sshguard.sh report >/dev/null 2>&1" >> /etc/crontabs/root
  fi
  /etc/init.d/cron restart >/dev/null 2>&1
}

cleanup() {
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}; [ "$pid" = $$ ] && continue
    case "$(tr '\0' ' ' 2>/dev/null < $p/cmdline)" in
      "/bin/sh /usr/bin/sshguard.sh ") kill "$pid" 2>/dev/null ;;
      "logread -f ") pp=$(awk '/^PPid/{print $2}' $p/status 2>/dev/null); [ "$pp" = 1 ] && { kill "$pid" 2>/dev/null; continue; }
        case "$(tr '\0' ' ' 2>/dev/null < /proc/$pp/cmdline)" in *sshguard.sh*|"") kill "$pid" 2>/dev/null ;; esac ;;
    esac
  done
}

case "$1" in
  test)    send test "🔔 $HOST 推送测试" "SSH 登录预警配置正常，时间 $(date '+%F %T')"; exit 0 ;;
  report)  report; exit 0 ;;
  cleanup) cleanup; exit 0 ;;
  cron)    cron_set "$2"; exit 0 ;;
  geo)     geo "$2"; exit 0 ;;
  fw)      # 防火墙重载 / 开机时恢复规则与封禁列表
           fw_ensure; [ -f "$P/ban.save" ] && sed 's/^add [^ ]* /add '$SET' /' "$P/ban.save" | ipset -! restore 2>/dev/null; exit 0 ;;
  ban)     BAN=1; do_ban "$2" && echo "已封禁 $2" || echo "无法封禁 $2（内网或白名单）"; exit 0 ;;
  unban)   if [ "$2" = all ]; then ipset -q flush $SET; else ipset -q del $SET "$2"; fi; ban_save; echo "已解封 $2"; exit 0 ;;
  bans)    ipset list $SET 2>/dev/null | sed -n '/^Members:/,$p' | sed -n 's/^\([0-9.]*\) timeout \([0-9]*\).*/\1 \2/p'; exit 0 ;;
esac

cleanup  # 只保留一个实例
[ "$BAN" = 1 ] && "$0" fw

fail() { # ip user type
  ip=$1; user=$2
  [ -n "$ip" ] || return
  is_lan "$ip" && return
  event "$3" "$ip" "$user"
  now=$(date +%s); f="$D/f_$(echo "$ip" | tr ':' '_')"
  echo "$now" >> "$f"
  awk -v n="$now" -v w="$WINDOW" '$1 > n - w' "$f" > "$f.t" && mv "$f.t" "$f"
  c=$(wc -l < "$f")
  [ "$c" -ge "$THRESHOLD" ] || return
  bt=""; do_ban "$ip" && bt=$(ban_text)
  [ "$NOTIFY_FAIL" = 1 ] || return
  last=$(cat "$D/a_$ip" 2>/dev/null); [ -n "$last" ] || last=0
  [ $((now - last)) -ge "$COOLDOWN" ] || return
  echo "$now" > "$D/a_$ip"
  notify fail "$FAIL_TITLE" "$FAIL_BODY" "$ip" "$user" "$c" "$bt"
}

ip_from() { echo "$1" | sed -n 's/.* from <\{0,1\}\[\{0,1\}\([0-9a-fA-F.:]*[0-9a-fA-F]\)\]\{0,1\}:[0-9]*>\{0,1\}.*$/\1/p'; }
user_from() { echo "$1" | sed -n "s/.* for '\([^']*\)'.*/\1/p"; }
lan_skip() { is_lan "$1" && [ "$NOTIFY_LAN_LOGIN" != 1 ]; }

/usr/bin/sshguard-luci-hook apply >/dev/null 2>&1

logread -f | while read -r line; do
  case "$line" in
    *" luci: accepted login for "*)
      user=$(echo "$line" | sed -n 's/.* login for \([^ ]*\) from .*/\1/p')
      ip=$(echo "$line" | sed -n 's/.* from \([0-9a-fA-F.:]*\)$/\1/p')
      now=$(date +%s); last=$(cat "$D/w_$ip" 2>/dev/null); [ -n "$last" ] || last=0
      [ $((now - last)) -ge 60 ] || continue
      echo "$now" > "$D/w_$ip"
      event webok "$ip" "$user"
      [ "$NOTIFY_WEB" = 1 ] || continue
      lan_skip "$ip" && continue
      notify web "$WEB_TITLE" "$WEB_BODY" "$ip" "$user" 1 ""
      continue ;;
    *" luci: failed login for "*)
      user=$(echo "$line" | sed -n 's/.* login for \([^ ]*\) from .*/\1/p')
      fail "$(echo "$line" | sed -n 's/.* from \([0-9a-fA-F.:]*\)$/\1/p')" "$user（网页）" webfail
      continue ;;
    *dropbear\[*) ;;
    *) continue ;;
  esac
  pid=$(echo "$line" | sed -n 's/.*dropbear\[\([0-9]*\)\].*/\1/p')
  case "$line" in
    *"Child connection from "*)
      echo "$line" | sed -n 's/.*Child connection from \[\{0,1\}\([0-9a-fA-F.:]*[0-9a-fA-F]\)\]\{0,1\}:[0-9]*$/\1/p' > "$D/p_$pid" ;;
    *"auth succeeded for "*)
      ip=$(ip_from "$line"); user=$(user_from "$line")
      event sshok "$ip" "$user"
      [ "$NOTIFY_OK" = 1 ] || continue
      lan_skip "$ip" && continue
      notify ssh "$OK_TITLE" "$OK_BODY" "$ip" "$user" 1 "" ;;
    *"Bad password attempt for "*)
      fail "$(ip_from "$line")" "$(user_from "$line")" sshfail ;;
    *"Login attempt for nonexistent user"*)
      fail "$(cat "$D/p_$pid" 2>/dev/null)" "不存在的用户" sshfail ;;
    *"Exit"*)
      rm -f "$D/p_$pid" ;;
  esac
done
