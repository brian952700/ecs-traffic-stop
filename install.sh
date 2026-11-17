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
        if ! command -v python3 >/dev/null || ! command -v flock >/dev/null || [[ ! -x /etc/init.d/crond ]]; then
            run_quiet apk add --no-cache python3 busybox-openrc flock
        fi
        ;;
    debian) command -v systemctl >/dev/null || fail '需要 systemd。' ;;
    *) fail "不支持的系统：$ID" ;;
esac
ok "${PRETTY_NAME:-$ID}"

for dependency in python3 ip flock; do
    command -v "$dependency" >/dev/null || fail "缺少命令：$dependency"
done

install -d -m 0755 /usr/local/sbin
install -d -m 0700 /var/lib/traffic-stop
exec 9> /var/lib/traffic-stop/install.lock
flock -n 9 || fail '已有安装程序正在运行。'

used=${1-}
sample_args=(sample-only)
if [[ -e /var/lib/traffic-stop/state.json || -e /var/lib/traffic-stop/state.bak ]]; then
    if [[ $# == 1 ]]; then
        printf '  %s发现已有状态，沿用已保存的用量。手动校准请用 traffic-stop reconcile。%s\n' "$yellow" "$reset"
    fi
else
    if [[ $# == 0 && -t 0 && -t 1 ]]; then
        until [[ $used =~ ^[0-9]+([.][0-9]+)?$ ]]; do
            read -r -p '  CDT 本月已用多少 GB？尚未使用请填 0：' used || fail '未读取到用量。'
            if [[ ! $used =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                printf '  %s请输入非负数字，例如 0 或 12.5。%s\n' "$yellow" "$reset"
            fi
        done
    fi
    [[ $used =~ ^[0-9]+([.][0-9]+)?$ ]] || fail '请传入 CDT 本月已用 GB，例如 bash install.sh 12.5。'
    sample_args+=(--initial-gb "$used")
fi

mode=pinned
iface=${TRAFFIC_STOP_IFACE:-}
if [[ -z $iface ]]; then
    mode=auto
    if [[ -r /etc/traffic-stop-interface ]]; then
        { read -r iface || :; read -r saved_mode || :; } < /etc/traffic-stop-interface
        [[ $saved_mode != pinned ]] || mode=pinned
    else
        iface=$(ip -4 route show default | awk 'NR==1 {for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}')
    fi
fi
[[ -n $iface && $iface != */* && -r /sys/class/net/$iface/statistics/tx_bytes ]] ||
    fail '找不到可读取的出口网卡。可用 TRAFFIC_STOP_IFACE 指定网卡。'
ok "出口网卡：$iface"

step '[2/3] 配置出站流量统计'
stage_files=()
cleanup() {
    if (( ${#stage_files[@]} )); then rm -f -- "${stage_files[@]}"; fi
}
trap cleanup EXIT
stage() {
    staged=$(mktemp "$1.XXXXXX")
    stage_files+=("$staged")
}
stage /usr/local/sbin/.traffic-stop.py
python_stage=$staged
cat > "$python_stage" <<'PY'
#!/usr/bin/python3
import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path

DATA = Path("/var/lib/traffic-stop")
STATE = DATA / "state.json"
BACKUP = DATA / "state.bak"
ERROR = DATA / "last-error"
CONFIG = Path("/etc/traffic-stop-interface")
TZ = timezone(timedelta(hours=8))
GB = 1_000_000_000
LIMIT = 180 * GB


def read_state(path):
    state = json.loads(path.read_text())
    if (not isinstance(state, dict)
            or any(type(state.get(key)) is not int or state[key] < 0
                   for key in ("counter", "used"))
            or any(not isinstance(state.get(key), str) or not state[key]
                   for key in ("month", "iface", "boot_id"))
            or not re.fullmatch(r"\d{4}-(0[1-9]|1[0-2])", state["month"])):
        raise ValueError(f"状态格式无效：{path}")
    state.setdefault("sampled_at", path.stat().st_mtime)
    if type(state["sampled_at"]) not in (int, float):
        raise ValueError(f"采样时间无效：{path}")
    datetime.fromtimestamp(state["sampled_at"], TZ)
    warnings = state.setdefault("warnings", [])
    if not isinstance(warnings, list) or any(not isinstance(item, str) for item in warnings):
        raise ValueError(f"采样提示格式无效：{path}")
    return state


def write_atomic(path, content):
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                     prefix=f".{path.name}.", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
            stream.close()
            temporary.replace(path)
            fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        finally:
            temporary.unlink(missing_ok=True)


def parse_gb(value):
    if not re.fullmatch(r"[0-9]+(\.[0-9]+)?", value):
        raise ValueError("请输入非负数字，例如 0 或 12.5。")
    return int(Decimal(value) * GB)


def sample(args):
    config = CONFIG.read_text().splitlines()
    iface = config[0]
    counter = int(Path(f"/sys/class/net/{iface}/statistics/tx_bytes").read_text())
    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    now = datetime.now(TZ)
    month = now.strftime("%Y-%m")
    now_stamp = now.timestamp()
    warnings = []
    previous = None
    recovered = False
    if args.action == "reconcile":
        used = parse_gb(args.gb)
    elif args.initial_gb is not None and not STATE.exists() and not BACKUP.exists():
        used = parse_gb(args.initial_gb)
    else:
        try:
            previous = read_state(STATE)
        except (OSError, ValueError, OverflowError) as error:
            try:
                previous = read_state(BACKUP)
                if (previous["iface"] != iface or previous["boot_id"] != boot
                        or previous["month"] != month or previous["counter"] > counter
                        or previous["sampled_at"] > now_stamp):
                    raise ValueError("备份与当前采样不连续")
                recovered = True
            except (OSError, ValueError, OverflowError) as backup_error:
                raise ValueError(
                    f"无法恢复统计状态（{error}；{backup_error}）。"
                    "请核对 CDT 后运行 traffic-stop reconcile <本月已用GB>。"
                ) from backup_error

        if previous["sampled_at"] > now_stamp:
            raise ValueError("系统时间早于上一次采样，请先检查时钟。")
        if previous["month"] == month:
            warnings.extend(previous["warnings"])
            used = previous["used"]
        else:
            used = 0
            warnings.append("已跨月，跨月采样间隔的流量计入新月。")
        if previous["iface"] != iface:
            warnings.append("统计网卡已变更，切换期间的流量请用 CDT 核对。")
        elif previous["boot_id"] != boot or counter < previous["counter"]:
            used += counter
            warnings.append("检测到重启或计数器重置，可能漏记上次采样后的流量。")
        else:
            used += counter - previous["counter"]
        if recovered:
            warnings.append("已从备份恢复累计用量。")

    if len(config) > 1 and config[1] == "auto":
        routes = subprocess.check_output(["ip", "-4", "route", "show", "default"],
                                         text=True, timeout=3,
                                         env={**os.environ, "PATH": "/usr/sbin:/usr/bin:/sbin:/bin"})
        if set(re.findall(r"\bdev\s+(\S+)", routes)) != {iface}:
            warnings.append("默认 IPv4 路由与统计网卡不一致，请核对 CDT 用量。")

    state = dict(month=month, iface=iface, boot_id=boot, counter=counter, used=used,
                 sampled_at=now_stamp, warnings=list(dict.fromkeys(warnings)))
    if not recovered:
        same_counter = (previous is not None and previous["month"] == month
                        and previous["iface"] == iface and previous["boot_id"] == boot
                        and previous["counter"] <= counter)
        backup = previous if same_counter else state
        write_atomic(BACKUP, json.dumps(backup))
    write_atomic(STATE, json.dumps(state))
    ERROR.unlink(missing_ok=True)
    enabled = (DATA / "enabled").exists()
    print(f"{month} {iface}: {used / GB:.3f} GB; poweroff={enabled}"
          f" · {now.isoformat(timespec='seconds')}", flush=True)
    if args.action == "sample" and enabled and used >= LIMIT:
        command = ["/sbin/poweroff"] if args.alpine else ["systemctl", "--no-block", "poweroff"]
        subprocess.run(command, check=True, timeout=10)


def status():
    enabled = (DATA / "enabled").exists()
    print(f"自动关机：{'已开启' if enabled else '已关闭'} · 阈值 {LIMIT // GB} GB")
    failed = ERROR.exists()
    if failed:
        print(f"最近一次失败：{ERROR.read_text(encoding='utf-8').strip()}")
    state = read_state(STATE)
    now = datetime.now(TZ)
    when = datetime.fromtimestamp(state["sampled_at"], TZ)
    current = state["month"] == now.strftime("%Y-%m")
    label = "本月累计" if current else f"{state['month']} 累计（等待本月采样）"
    print(f"{label}：{state['used'] / GB:.3f} GB · {state['iface']}")
    print(f"最近成功采样：{when.isoformat(timespec='seconds')}")
    for warning in state["warnings"]:
        print(f"提示：{warning}")
    if not current or not 0 <= (now - when).total_seconds() <= 180:
        print("异常：采样已过期或系统时钟异常，请检查定时任务。", file=sys.stderr)
        return 1
    return int(failed)


def main():
    parser = argparse.ArgumentParser(description="查询、采样或校准出站流量")
    parser.add_argument("action", nargs="?", default="sample",
                        choices=("sample", "sample-only", "status", "reconcile"))
    parser.add_argument("gb", nargs="?")
    parser.add_argument("--alpine", action="store_true")
    parser.add_argument("--initial-gb")
    args = parser.parse_args()
    if (args.action == "reconcile") != (args.gb is not None):
        parser.error("用法：traffic-stop reconcile <本月已用GB>")
    if args.gb is not None:
        try:
            parse_gb(args.gb)
        except (ValueError, InvalidOperation, OverflowError) as error:
            parser.error(str(error))

    expected_errors = (OSError, ValueError, IndexError, OverflowError,
                       InvalidOperation, subprocess.SubprocessError)
    try:
        with (DATA / "sample.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if args.action == "status":
                return status()
            try:
                sample(args)
            except expected_errors as error:
                try:
                    write_atomic(ERROR, f"{datetime.now(TZ).isoformat(timespec='seconds')} {error}\n")
                except OSError as log_error:
                    print(f"无法保存异常记录：{log_error}", file=sys.stderr)
                raise
    except BlockingIOError:
        print("另一个采样正在运行，请稍后重试。", file=sys.stderr)
        return 1
    except expected_errors as error:
        print(f"统计异常：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
chmod 0755 "$python_stage"
run_quiet python3 -c 'import sys; compile(open(sys.argv[1], "rb").read(), sys.argv[1], "exec")' "$python_stage"

stage /etc/.traffic-stop-interface
config_stage=$staged
printf '%s\n%s\n' "$iface" "$mode" > "$config_stage"
chmod 0644 "$config_stage"
exec 8> /var/lib/traffic-stop/sample.lock
flock -w 15 8 || fail '无法锁定流量统计状态，请稍后重试。'
mv -f -- "$config_stage" /etc/traffic-stop-interface
mv -f -- "$python_stage" /usr/local/sbin/traffic-stop.py
ln -sfn /usr/local/sbin/traffic-stop.py /usr/local/sbin/traffic-stop
exec 8>&-
run_quiet /usr/bin/python3 /usr/local/sbin/traffic-stop.py "${sample_args[@]}"
ok '试采样成功'

step '[3/3] 启动每分钟定时检查'
if [[ $ID == debian ]]; then
    stage /etc/systemd/system/.traffic-stop.service
    service_stage=$staged
    cat > "$service_stage" <<'UNIT'
[Service]
Type=oneshot
TimeoutStartSec=30s
ExecStart=/usr/bin/python3 /usr/local/sbin/traffic-stop.py
UNIT
    stage /etc/systemd/system/.traffic-stop.timer
    timer_stage=$staged
    cat > "$timer_stage" <<'UNIT'
[Timer]
OnBootSec=1min
OnCalendar=*-*-* *:*:00
AccuracySec=1s

[Install]
WantedBy=timers.target
UNIT
    chmod 0644 "$service_stage" "$timer_stage"
    mv -f -- "$service_stage" /etc/systemd/system/traffic-stop.service
    mv -f -- "$timer_stage" /etc/systemd/system/traffic-stop.timer
    run_quiet systemctl daemon-reload
    run_quiet systemctl enable --now traffic-stop.timer 9>&-
    run_quiet systemctl is-active traffic-stop.timer
else
    [[ -x /sbin/poweroff ]] || fail '找不到 /sbin/poweroff。'
    run_quiet rc-update add crond default
    run_quiet rc-service crond start 9>&-
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
    installed_cron=$(crontab -l) || fail '无法回读 root 的 crontab。'
    matches=$(printf '%s\n' "$installed_cron" | grep -Fxc -- "$cron_job" || :)
    [[ $matches == 1 ]] || fail '定时任务回读失败，未找到唯一的流量统计任务。'
fi
ok '每分钟检查已启用'

printf '\n%s安装完成%s\n' "$green" "$reset"
/usr/local/sbin/traffic-stop status || printf '  请稍后运行 traffic-stop status 检查采样状态。\n'
printf '\n  查看用量  traffic-stop status\n'
printf '  开启关机  touch /var/lib/traffic-stop/enabled\n'
printf '  暂停关机  rm -f /var/lib/traffic-stop/enabled\n\n'
