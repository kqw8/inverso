#!/usr/bin/env bash
# Open the installed binary and the macOS permission pane. macOS grants access
# only after the user approves it; never edit/reset TCC or replace the binary here.
set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo '用法：bash scripts/authorize-inverso.command' >&2
  exit 2
fi

INVERSO_INSTALLED_BINARY='/usr/local/bin/inverso'
if [ ! -x "$INVERSO_INSTALLED_BINARY" ]; then
  echo "找不到已安装的程序：$INVERSO_INSTALLED_BINARY" >&2
  exit 1
fi

INVERSO_LAST_STATUS=''
daemon_is_enabled() {
  INVERSO_LAST_STATUS="$("$INVERSO_INSTALLED_BINARY" status 2>&1)" || true
  /usr/bin/grep -Eq 'Scroll event tap:[[:space:]]+enabled[[:space:]]*$' <<< "$INVERSO_LAST_STATUS"
}

report_ready() {
  printf '%s\n' "$INVERSO_LAST_STATUS"
  echo '已确认后台滚轮监听启用，无需重复授权。'
}

# Terminal/Codex may have a different responsible-process permission context.
# A working daemon is stronger evidence than this CLI invocation's trust bit.
if daemon_is_enabled; then
  report_ready
  exit 0
fi

cat <<'INSTRUCTIONS'
即将打开两个窗口：
  • Finder：已选中真正运行的 inverso 文件。
  • 系统设置：隐私与安全性 → 设备控制和数据访问。
    （旧版 macOS 将这个授权页面称为“辅助功能”。）

请把 Finder 里选中的 inverso 拖进设置右侧的应用列表，然后打开它的开关。
如果不能拖放：点击列表下方“+”，按 ⇧⌘G，输入 /usr/local/bin/inverso，添加并开启。
如果已有 inverso 但授权一直不生效，只删除它的旧条目，再拖入当前文件重新开启。
最后的授权开关必须由你确认。保持此窗口运行，脚本会检查后台服务是否生效。
INSTRUCTIONS

/usr/bin/open -R "$INVERSO_INSTALLED_BINARY"
/usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'

if ! "$INVERSO_INSTALLED_BINARY" permission; then
  if daemon_is_enabled; then
    report_ready
    exit 0
  fi
  echo '授权尚未完成。完成设置中的确认后，可以重新运行本助手。' >&2
  exit 1
fi

# Trust in this CLI invocation alone is insufficient: independently check the
# running daemon's modifying scroll tap. Allow its five-second health check to run.
for INVERSO_ATTEMPT in 1 2 3 4 5 6; do
  if daemon_is_enabled; then
    report_ready
    exit 0
  fi
  /bin/sleep 2
done

printf '%s\n' "$INVERSO_LAST_STATUS"
echo '尚未确认后台监听启用；把上面的状态发给我继续排查。' >&2
exit 1
