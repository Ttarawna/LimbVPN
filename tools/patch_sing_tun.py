"""Android запрещает обычным приложениям netlink-сокеты, поэтому монитор сети из
библиотеки sing-tun (её использует Mihomo) падает при запуске туннеля.
Скрипт копирует sing-tun, подменяет монитор на пустышку для Android
и подключает копию через go.mod replace.
Запускается из папки mihomo."""
import os
import pathlib
import shutil
import stat
import subprocess
import sys

MOD = "github.com/metacubex/sing-tun"

STUB = '''

// ---- Quiet VPN: на Android монитор сети отключён (netlink там запрещён) ----
func NewNetworkUpdateMonitor(logger logger.Logger) (NetworkUpdateMonitor, error) {
	if runtime.GOOS == "android" {
		return &noopNetworkUpdateMonitor{}, nil
	}
	return newNetworkUpdateMonitorLinux(logger)
}

type noopNetworkUpdateMonitor struct{}

func (*noopNetworkUpdateMonitor) Start() error { return nil }

func (*noopNetworkUpdateMonitor) Close() error { return nil }

func (*noopNetworkUpdateMonitor) RegisterCallback(callback NetworkUpdateCallback) *list.Element[NetworkUpdateCallback] {
	return nil
}

func (*noopNetworkUpdateMonitor) UnregisterCallback(element *list.Element[NetworkUpdateCallback]) {}
'''

subprocess.check_call(["go", "mod", "download", MOD])
src = subprocess.check_output(["go", "list", "-m", "-f", "{{.Dir}}", MOD], text=True).strip()
if not src:
    sys.exit("Не найден модуль " + MOD)

dst = pathlib.Path(os.getcwd()).parent / "sing-tun-patched"
if dst.exists():
    shutil.rmtree(dst)
shutil.copytree(src, dst)
for p in [dst, *dst.rglob("*")]:
    try:
        extra = stat.S_IWUSR | (stat.S_IXUSR if p.is_dir() else 0)
        p.chmod(p.stat().st_mode | extra)
    except OSError:
        pass

target = None
for f in sorted(dst.glob("*.go")):
    if "linux" in f.name and "func NewNetworkUpdateMonitor(" in f.read_text():
        target = f
        break
if target is None:
    sys.exit("В sing-tun не найден NewNetworkUpdateMonitor для linux. Код библиотеки изменился.")

text = target.read_text()
for needle in ('/x/list"', '/logger"', '"runtime"'):
    if needle not in text:
        sys.exit("В %s нет ожидаемого импорта %s" % (target.name, needle))

text = text.replace("func NewNetworkUpdateMonitor(", "func newNetworkUpdateMonitorLinux(", 1) + STUB
target.write_text(text)

subprocess.check_call(["go", "mod", "edit", "-replace", "%s=%s" % (MOD, dst)])
print("sing-tun подменён:", target.name, "->", dst)
