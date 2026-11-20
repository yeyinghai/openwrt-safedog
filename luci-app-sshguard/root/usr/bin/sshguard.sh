#!/bin/sh
# luci-app-sshguard: dropbear 暴力破解 / 登录成功 Bark 预警
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
NOTIFY_LAN_LOGIN=$(cfg notify_lan_login 1)
FAIL_TITLE=$(cfg fail_title '⚠️ {host} SSH 暴力破解')
FAIL_BODY=$(cfg fail_body '{ip} 在 {minutes} 分钟内失败 {count} 次，最近尝试用户：{user}')
OK_TITLE=$(cfg ok_title '🔐 {host} SSH 登录成功')
OK_BODY=$(cfg ok_body '用户 {user} 从 {ip} 登录，时间 {time}')
NOTIFY_WEB=$(cfg notify_web_success 1)
WEB_TITLE=$(cfg web_title '🌐 {host} 网页后台登录成功')
WEB_BODY=$(cfg web_body '用户 {user} 从 {ip} 登录 LuCI，时间 {time}')
AUTO_DIRECT=$(cfg auto_direct 1)
DIRECT_ADDR=$(cfg direct_addr "")
WINDOW=$((WINDOW_MIN * 60)); COOLDOWN=$((COOLDOWN_MIN * 60))

D=/tmp/sshguard; mkdir -p "$D"
LOG=$D/history.log
HOST=$(uci -q get system.@system[0].hostname); [ -n "$HOST" ] || HOST=OpenWrt

esc_sed() { printf '%s' "$1" | sed 's/[\\&|]/\\&/g'; }
esc_json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
render() { # 模板 ip user count
  printf '%s' "$1" | sed "s|{host}|$(esc_sed "$HOST")|g; s|{ip}|$(esc_sed "$2")|g; s|{user}|$(esc_sed "$3")|g; s|{count}|$(esc_sed "$4")|g; s|{minutes}|$WINDOW_MIN|g; s|{time}|$(date '+%F %T')|g"
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

push() { # 类型 标题 内容 [sync]
  [ -n "$BARK_URL" ] || { [ "$4" = sync ] && echo "❌ 未填写 Bark 地址"; return 1; }
  t=$(esc_json "$2"); b=$(esc_json "$3")
  extra=""; [ -n "$SOUND" ] && extra=",\"sound\":\"$(esc_json "$SOUND")\""
  data="{\"title\":\"$t\",\"body\":\"$b\",\"group\":\"$(esc_json "$GROUP")\",\"level\":\"$LEVEL\"$extra}"
  co=$(connect_opt)
  if [ "$4" = sync ]; then
    r=$(curl -sS -m 10 $co -X POST "$BARK_URL" -H 'Content-Type: application/json; charset=utf-8' -d "$data" 2>&1)
    case "$r" in *'"code":200'*) st=ok; echo "✅ 发送成功${co:+（经内网 $(echo "${co#* }" | cut -d: -f3-)）}" ;; *) st=fail; echo "❌ 发送失败：$r" ;; esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$1" "$st" "$2" "$3" >> "$LOG"
  else
    ( r=$(curl -sS -m 10 $co -X POST "$BARK_URL" -H 'Content-Type: application/json; charset=utf-8' -d "$data" 2>&1)
      case "$r" in *'"code":200'*) st=ok ;; *) st=fail ;; esac
      printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$1" "$st" "$2" "$3" >> "$LOG" ) &
  fi
  [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 200 ] && { tail -n 200 "$LOG" > "$LOG.t" && mv "$LOG.t" "$LOG"; }
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

if [ "$1" = test ]; then
  push test "🔔 $HOST 推送测试" "SSH 登录预警配置正常，时间 $(date '+%F %T')" sync
  exit 0
fi

[ "$1" = cleanup ] && { cleanup; exit 0; }
cleanup  # 只保留一个实例

fail() { # ip user
  ip=$1; user=$2
  [ "$NOTIFY_FAIL" = 1 ] || return
  [ -n "$ip" ] || return
  case "$ip" in "$LAN_PREFIX"*|127.*) return ;; esac
  now=$(date +%s); f="$D/f_$ip"
  echo "$now" >> "$f"
  awk -v n="$now" -v w="$WINDOW" '$1 > n - w' "$f" > "$f.t" && mv "$f.t" "$f"
  c=$(wc -l < "$f")
  [ "$c" -ge "$THRESHOLD" ] || return
  last=$(cat "$D/a_$ip" 2>/dev/null); [ -n "$last" ] || last=0
  [ $((now - last)) -ge "$COOLDOWN" ] || return
  echo "$now" > "$D/a_$ip"
  push fail "$(render "$FAIL_TITLE" "$ip" "$user" "$c")" "$(render "$FAIL_BODY" "$ip" "$user" "$c")"
}

ip_from() { echo "$1" | sed -n 's/.* from <\{0,1\}\[\{0,1\}\([0-9a-fA-F.:]*[0-9a-fA-F]\)\]\{0,1\}:[0-9]*>\{0,1\}.*$/\1/p'; }
user_from() { echo "$1" | sed -n "s/.* for '\([^']*\)'.*/\1/p"; }

/usr/bin/sshguard-luci-hook apply >/dev/null 2>&1

logread -f | while read -r line; do
  case "$line" in
    *" luci: accepted login for "*)
      [ "$NOTIFY_WEB" = 1 ] || continue
      user=$(echo "$line" | sed -n 's/.* login for \([^ ]*\) from .*/\1/p')
      ip=$(echo "$line" | sed -n 's/.* from \([0-9a-fA-F.:]*\)$/\1/p')
      case "$ip" in "$LAN_PREFIX"*) [ "$NOTIFY_LAN_LOGIN" = 1 ] || continue ;; esac
      now=$(date +%s); last=$(cat "$D/w_$ip" 2>/dev/null); [ -n "$last" ] || last=0
      [ $((now - last)) -ge 60 ] || continue
      echo "$now" > "$D/w_$ip"
      push web "$(render "$WEB_TITLE" "$ip" "$user" 1)" "$(render "$WEB_BODY" "$ip" "$user" 1)"
      continue ;;
    *" luci: failed login for "*)
      user=$(echo "$line" | sed -n 's/.* login for \([^ ]*\) from .*/\1/p')
      fail "$(echo "$line" | sed -n 's/.* from \([0-9a-fA-F.:]*\)$/\1/p')" "$user（网页）"
      continue ;;
    *dropbear\[*) ;;
    *) continue ;;
  esac
  pid=$(echo "$line" | sed -n 's/.*dropbear\[\([0-9]*\)\].*/\1/p')
  case "$line" in
    *"Child connection from "*)
      echo "$line" | sed -n 's/.*Child connection from \[\{0,1\}\([0-9a-fA-F.:]*[0-9a-fA-F]\)\]\{0,1\}:[0-9]*$/\1/p' > "$D/p_$pid" ;;
    *"auth succeeded for "*)
      [ "$NOTIFY_OK" = 1 ] || continue
      ip=$(ip_from "$line"); user=$(user_from "$line")
      case "$ip" in "$LAN_PREFIX"*) [ "$NOTIFY_LAN_LOGIN" = 1 ] || continue ;; esac
      push ssh "$(render "$OK_TITLE" "$ip" "$user" 1)" "$(render "$OK_BODY" "$ip" "$user" 1)" ;;
    *"Bad password attempt for "*)
      fail "$(ip_from "$line")" "$(user_from "$line")" ;;
    *"Login attempt for nonexistent user"*)
      fail "$(cat "$D/p_$pid" 2>/dev/null)" "不存在的用户" ;;
    *"Exit"*)
      rm -f "$D/p_$pid" ;;
  esac
done
