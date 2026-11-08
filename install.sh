#!/usr/bin/env bash
# Debian 13. Install: sudo bash install.sh [CDT GB already used this month]
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
[[ $# -le 1 ]] || { echo 'Usage: install.sh [CDT GB already used]' >&2; exit 1; }
used=${1-}
if [[ ! -f /var/lib/traffic-stop/state.json && -z $used ]]; then
    echo 'Pass the current month CDT usage in GB (0 if unused).' >&2
    exit 1
fi
[[ -z $used || $used =~ ^[0-9]+([.][0-9]+)?$ ]] || exit 1
command -v python3 >/dev/null
iface=$(ip -4 route show default | awk 'NR==1 {for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}')
test -n "$iface"
test -r "/sys/class/net/$iface/statistics/tx_bytes"

install -d -m 0700 /var/lib/traffic-stop
printf '%s\n' "$iface" > /etc/traffic-stop-interface
cat > /usr/local/sbin/traffic-stop.py <<'PY'
import json
import os
import subprocess
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
    subprocess.run(["systemctl", "poweroff"], check=True)
PY

if [[ ! -f /var/lib/traffic-stop/state.json ]]; then
    USED_GB="$used" python3 /usr/local/sbin/traffic-stop.py
fi

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

systemctl daemon-reload
systemctl enable --now traffic-stop.timer
echo 'Logs: sudo journalctl -u traffic-stop.service -n 10 --no-pager'
echo 'Enable shutdown: sudo touch /var/lib/traffic-stop/enabled'
echo 'Pause shutdown: sudo rm -f /var/lib/traffic-stop/enabled'
