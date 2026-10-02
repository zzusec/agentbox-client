#!/usr/bin/env bash
# 把已经传到生产机并解包好的发布包装上去：install → activate → 发布后验证。
#
#   deploy/prod-release.sh v0.1.7-custom21 [生产机上的解包目录]
#
# 省略第二个参数时在生产机 /root/pkg*/ 下按版本名自动找解包目录（build-release.py
# 的产物解包后目录名就是 agentbox_<版本>_<平台>）。参数从 deploy/production.env 读，
# 该文件已 gitignore；PROD_PKG_GLOB 可改搜索位置。
#
# 这个脚本只做 install/activate/验证，不构建也不传包：构建用
# `python3 scripts/build-release.py --version <版本> --output DIR`，再把
# agentbox_<版本>_$PROD_ARCH.tar.gz scp 到生产机并 tar xzf 解包。
# activate 会重启服务，HTTP/WebSocket 连接会断一下，不是滚动发布。
set -euo pipefail

ver=${1:-}
pkg=${2:-}
if [ -z "$ver" ]; then
	echo "用法: $(basename "$0") <版本> [生产机上的解包目录]" >&2
	exit 2
fi

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
env_file=$root/deploy/production.env
[ -f "$env_file" ] || { echo "缺少 $env_file（见 deploy/production.env.example）" >&2; exit 2; }
# shellcheck disable=SC1090
set -a; . "$env_file"; set +a
: "${PROD_SSH:?production.env 里缺 PROD_SSH}"
app=${PROD_APP:-/opt/agentbox}
# production.env 里的路径带 $HOME，展开后再用。
key=$(eval printf %s "${PROD_SSH_KEY:-$HOME/.ssh/agentbox_deploy}")
glob=${PROD_PKG_GLOB:-/root/pkg*}

sshq() { ssh -o BatchMode=yes -i "$key" "$PROD_SSH" "$@"; }

if [ -z "$pkg" ]; then
	# 解包目录可能有多个（重传过），取最新的那个。
	pkg=$(sshq "ls -1dt $glob/agentbox_${ver}_* 2>/dev/null | head -1")
	[ -n "$pkg" ] || { echo "生产机 $glob 下没找到 agentbox_${ver}_* 的解包目录，请显式给第二个参数" >&2; exit 1; }
	echo "== 解包目录: $pkg"
fi
sshq "test -x $pkg/agentbox && test -f $pkg/deploy/release.py" ||
	{ echo "$pkg 看起来不是解包后的发布目录（缺 agentbox 或 deploy/release.py）" >&2; exit 1; }

echo "== install $ver"
sshq "python3 $pkg/deploy/release.py install --package $pkg"

echo "== activate $ver（会备份、停机、切换、重启服务）"
sshq "python3 $app/current/deploy/release.py activate --version $ver"

echo "== 发布后验证"
sshq "readlink -f $app/current; systemctl is-active agentbox"
# PROD_LISTEN 可能是 0.0.0.0:8180，本机验证统一打 127.0.0.1。
port=${PROD_LISTEN##*:}
sshq "curl -sS -o /dev/null -w 'local HTTP %{http_code}\n' --max-time 10 http://127.0.0.1:${port:-8180}/"
sshq 'journalctl -u agentbox --since "5 minutes ago" --no-pager -n 30'
if [ -n "${PROD_URL:-}" ]; then
	# 跟随重定向：未登录访问根路径会 307 到 /management.html，只看首个状态码会误判成失败。
	curl -sS -o /dev/null -L -w "public HTTP %{http_code} %{url_effective}\n" --connect-timeout 10 --max-time 25 "$PROD_URL"
fi
echo "== 完成：systemd active + 内外网最终 200 + 日志无启动失败才算通过"
