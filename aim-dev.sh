#!/bin/bash
# AIM 开发调试切换脚本 — 2026-08-27 by 离离
# 解决"手动 nohup 实例 vs systemd 服务抢 5000 端口"的崩溃循环问题
#
# 用法：
#   aim-dev.sh start   # 停掉 systemd 托管，手动启动实例（调试用，日志 /tmp/aim_server.log）
#   aim-dev.sh stop    # 杀掉手动实例，恢复 systemd 托管
#   aim-dev.sh status  # 查看当前谁在管 5000 端口

case "$1" in
  start)
    echo "[1/2] 停止 systemd 托管..."
    systemctl stop aim-server 2>/dev/null
    # 确保端口已释放
    PID=$(ss -tlnp 2>/dev/null | grep ':5000' | grep -oP 'pid=\K[0-9]+' | head -1)
    [ -n "$PID" ] && kill "$PID" 2>/dev/null && sleep 1
    echo "[2/2] 手动启动实例..."
    cd /root/aim/server && nohup node src/index.js > /tmp/aim_server.log 2>&1 &
    sleep 2
    ss -tlnp 2>/dev/null | grep ':5000'
    echo "手动实例已启动，日志: /tmp/aim_server.log"
    ;;
  stop)
    echo "[1/2] 杀掉手动实例..."
    PID=$(ss -tlnp 2>/dev/null | grep ':5000' | grep -oP 'pid=\K[0-9]+' | head -1)
    [ -n "$PID" ] && kill "$PID" 2>/dev/null && sleep 1
    echo "[2/2] 恢复 systemd 托管..."
    systemctl start aim-server
    sleep 2
    systemctl is-active aim-server
    ss -tlnp 2>/dev/null | grep ':5000'
    ;;
  status)
    PID=$(ss -tlnp 2>/dev/null | grep ':5000' | grep -oP 'pid=\K[0-9]+' | head -1)
    if [ -n "$PID" ]; then
      echo "5000 端口被 pid=$PID 占用:"
      ps -p "$PID" -o pid,ppid,lstart,cmd --no-headers
      echo "systemd 托管状态: $(systemctl is-active aim-server)"
    else
      echo "5000 端口无监听"
    fi
    ;;
  *)
    echo "用法: $0 {start|stop|status}"
    ;;
esac
