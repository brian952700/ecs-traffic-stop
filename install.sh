#!/usr/bin/env bash
# Debian 13 / Alpine 3.23.8+. Install as root: bash install.sh [CDT GB already used this month]
set -euo pipefail
blue= green= yellow= red= reset=
if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
    blue=$'\033[34m' green=$'\033[32m' yellow=$'\033[33m'
    red=$'\033[31m' reset=$'\033[0m'
fi
fail() {
    printf '%s错误：%s%s\n' "$red" "$1" "$reset" >&2
    exit 1
}
step() { printf '\n%s%s%s\n' "$blue" "$1" "$reset"; }
ok() { printf '  %s[OK]%s %s\n' "$green" "$reset" "$1"; }
run_quiet() {
    local output
    if ! output=$("$@" 2>&1); then
        printf '%s\n' "$output" >&2
        fail "命令执行失败：$*"
    fi
    if [[ ${VERBOSE:-0} == 1 && -n $output ]]; then
        printf '%s\n' "$output"
    fi
}

printf '\n%sECS 流量守护%s\n' "$blue" "$reset"
printf '%s\n' '----------------------------------------'
step '[1/3] 检查运行环境'
[[ $EUID == 0 ]] || fail '请在 root 终端运行安装脚本。'
[[ $# -le 1 ]] || fail '用法：bash install.sh [CDT 本月已用 GB]'
source /etc/os-release
case "$ID" in
    alpine)
        IFS=. read -r major minor patch <<< "$VERSION_ID"
        [[ ${major:-} =~ ^[0-9]+$ && ${minor:-} =~ ^[0-9]+$ && ${patch:-} =~ ^[0-9]+$ ]] ||
            fail "无法识别 Alpine 版本：$VERSION_ID"
        (( major > 3 || (major == 3 && (minor > 23 || (minor == 23 && patch >= 8))) )) ||
            fail '需要 Alpine 3.23.8 或更新版本。'
        command -v rc-service >/dev/null && command -v rc-update >/dev/null ||
            fail '需要运行 OpenRC 的 Alpine 主机。'
        if ! command -v python3 >/dev/null || [[ ! -x /etc/init.d/crond ]]; then
            run_quiet apk add --no-cache python3 busybox-openrc
        fi
        ;;
    debian) command -v systemctl >/dev/null || fail '需要 systemd。' ;;
    *) fail "不支持的系统：$ID" ;;
esac
ok "${PRETTY_NAME:-$ID}"

for dependency in python3 ip; do
    command -v "$dependency" >/dev/null || fail "缺少命令：$dependency"
done

used=${1-}
state_file=/var/lib/traffic-stop/state.json
if [[ ! -f $state_file && $# == 0 && -t 0 && -t 1 ]]; then
    until [[ $used =~ ^[0-9]+([.][0-9]+)?$ ]]; do
        read -r -p '  CDT 本月已用多少 GB？尚未使用请填 0：' used || fail '未读取到用量。'
        if [[ ! $used =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            printf '  %s请输入非负数字，例如 0 或 12.5。%s\n' "$yellow" "$reset"
        fi
    done
fi
if [[ $# == 1 || ! -f $state_file ]]; then
    [[ $used =~ ^[0-9]+([.][0-9]+)?$ ]] || fail '请传入 CDT 本月已用 GB，例如 bash install.sh 12.5。'
fi
iface=$(ip -4 route show default | awk 'NR==1 {for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}')
[[ -n $iface && -r /sys/class/net/$iface/statistics/tx_bytes ]] || fail '找不到可读取的默认 IPv4 出口网卡。'
ok "出口网卡：$iface"

step '[2/3] 配置出站流量统计'

install -d -m 0755 /usr/local/sbin
install -d -m 0700 /var/lib/traffic-stop
printf '%s\n' "$iface" > /etc/traffic-stop-interface
cat > /usr/local/sbin/traffic-stop.py <<'PY'
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

directory = Path("/var/lib/traffic-stop")
state_file = directory / "state.json"
iface = Path("/etc/traffic-stop-interface").read_text().strip()
counter = int(Path(f"/sys/class/net/{iface}/statistics/tx_bytes").read_text())
boot_id = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
month = datetime.now(timezone(timedelta(hours=8))).strftime("%Y-%m")
if state_file.exists():
    previous = json.loads(state_file.read_text())
    same_counter = (previous["boot_id"] == boot_id
                    and previous["iface"] == iface
                    and counter >= previous["counter"])
    delta = counter - previous["counter"] if same_counter else counter
    used = (previous["used"] if previous["month"] == month else 0) + delta
else:
    used = int(Decimal(os.environ["USED_GB"]) * 1_000_000_000)

temporary = state_file.with_suffix(".tmp")
temporary.write_text(json.dumps(dict(month=month, iface=iface, boot_id=boot_id,
                                    counter=counter, used=used)))
temporary.replace(state_file)
enabled = (directory / "enabled").exists()
print(f"{month} {iface}: {used / 1_000_000_000:.3f} GB; poweroff={enabled}", flush=True)
if enabled and used >= 180_000_000_000:
    command = ["/sbin/poweroff"] if "--alpine" in sys.argv[1:] else ["systemctl", "poweroff"]
    subprocess.run(command, check=True)
PY

if [[ ! -f /var/lib/traffic-stop/state.json ]]; then
    USED_GB="$used" run_quiet python3 /usr/local/sbin/traffic-stop.py
fi

if [[ $ID == debian ]]; then
cat > /etc/systemd/system/traffic-stop.service <<'UNIT'
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/sbin/traffic-stop.py
UNIT
cat > /etc/systemd/system/traffic-stop.timer <<'UNIT'
[Timer]
OnBootSec=1min
OnCalendar=*-*-* *:*:00
AccuracySec=1s

[Install]
WantedBy=timers.target
UNIT

    log_command='journalctl -u traffic-stop.service -n 10 --no-pager'
else
    log_command='cat /var/lib/traffic-stop/last-run.log'
fi
ok '统计脚本已配置'

step '[3/3] 启动每分钟定时检查'
if [[ $ID == debian ]]; then
    run_quiet systemctl daemon-reload
    run_quiet systemctl enable --now traffic-stop.timer
    run_quiet systemctl is-active traffic-stop.timer
else
    [[ -x /sbin/poweroff ]] || fail '找不到 /sbin/poweroff。'
    run_quiet rc-update add crond default
    run_quiet rc-service crond start
    run_quiet rc-service crond status
    cron_job='* * * * * /usr/bin/python3 /usr/local/sbin/traffic-stop.py --alpine > /var/lib/traffic-stop/last-run.log 2>&1 # ecs-traffic-stop'
    if ! cron_entries=$(LC_ALL=C crontab -l 2>&1); then
        case "$cron_entries" in
            *'No such file or directory'*|*'no crontab for root'*) cron_entries= ;;
            *) fail "$cron_entries" ;;
        esac
    fi
    if ! { printf '%s\n' "$cron_entries" | awk '!/ # ecs-traffic-stop$/'; printf '%s\n' "$cron_job"; } | crontab -; then
        fail '无法更新 root 的 crontab。'
    fi
fi
ok '每分钟检查已启用'

usage=$(python3 - "$state_file" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text())
month = datetime.now(timezone(timedelta(hours=8))).strftime("%Y-%m")
if state["month"] == month:
    print(f'{state["used"] / 1_000_000_000:.3f} GB')
else:
    print("等待本月首次采样")
PY
)
printf '\n%s安装完成%s\n' "$green" "$reset"
printf '  本月累计用量  %s\n  关机阈值      180 GB\n' "$usage"
if [[ -f /var/lib/traffic-stop/enabled ]]; then
    printf '  自动关机      %s已开启 · 达到阈值会关机%s\n' "$yellow" "$reset"
else
    printf '  自动关机      %s已关闭 · 当前只统计%s\n' "$yellow" "$reset"
fi
printf '\n  查看用量  %s\n' "$log_command"
printf '  开启关机  touch /var/lib/traffic-stop/enabled\n'
printf '  暂停关机  rm -f /var/lib/traffic-stop/enabled\n\n'
