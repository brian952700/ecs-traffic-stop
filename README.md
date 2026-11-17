# ecs-traffic-stop

每分钟统计默认出口网卡的出站流量，按 UTC+8 自然月累计。开启自动关机后，累计达到 180 GB 时执行系统关机。

## 一键下载安装

在服务器的 root 终端运行对应命令。命令固定到已发布的脚本版本。

### Alpine Linux 3.23.8 及以上（OpenRC）

```sh
apk add bash curl && curl -fsSL 'https://raw.githubusercontent.com/brian952700/ecs-traffic-stop/c31c370ee2b4ab15ebf87becf18c7bb6a1b6d24d/install.sh' -o install.sh && bash install.sh
```

### Debian 13（systemd）

```sh
curl -fsSL 'https://raw.githubusercontent.com/brian952700/ecs-traffic-stop/c31c370ee2b4ab15ebf87becf18c7bb6a1b6d24d/install.sh' -o install.sh && bash install.sh
```

Debian 若缺少 curl，先运行 `apt-get update && apt-get install -y curl`。

首次安装时，按提示输入 CDT 本月已用量（GB）。例如已用 5 GB 就输入 `5`，也可以运行 `bash install.sh 5`。首次安装默认只统计。

重复运行安装命令即可升级。升级会沿用已有累计用量及自动关机设置。

## 查看用量

运行 `traffic-stop status` 查看本月累计用量、最近成功采样时间、异常和关机状态。连续超过三分钟没有成功采样时，查询会提示异常。

如果状态无法恢复，或需要重新对齐账单，先在 CDT 控制台确认本月累计用量，再运行 `traffic-stop reconcile 5`（把 `5` 换成实际的 GB 数）。这个命令会覆盖本月统计基准。

需要指定网卡时，在下载脚本后运行 `TRAFFIC_STOP_IFACE=eth0 bash install.sh`，并把 `eth0` 换成实际网卡名。

- Alpine 运行 `cat /var/lib/traffic-stop/last-run.log`。
- Debian 运行 `journalctl -u traffic-stop.service -n 10 --no-pager`。

网卡统计可能包含内网出站流量，计费用量以阿里云 CDT 为准。

## 自动关机

运行 `touch /var/lib/traffic-stop/enabled` 开启自动关机。

运行 `rm -f /var/lib/traffic-stop/enabled` 暂停自动关机并继续统计。
