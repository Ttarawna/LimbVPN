"""Android запрещает обычным приложениям некоторые вещи, на которые рассчитана
библиотека sing-tun (её использует Mihomo):
  1. netlink-сокеты (монитор сети), поэтому монитор подменяется пустышкой;
  2. чтение /data/system/packages.xml (список приложений), поэтому ошибка чтения
     игнорируется и список остаётся пустым (правила по приложениям нам не нужны).
Скрипт копирует sing-tun, правит копию и подключает её через go.mod replace.
Запускается из папки mihomo."""
import os
import pathlib
import shutil
import stat
import subprocess
import sys

MOD = "github.com/metacubex/sing-tun"

STUB = '''

// ---- Limb VPN: на Android монитор сети отключён (netlink там запрещён) ----
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

# --- 2. Список приложений: ошибку чтения игнорируем ---
pk = dst / "packages_android.go"
if pk.exists():
    ptext = pk.read_text()
    needle = 'return E.Cause(err, "read packages list")'
    if needle not in ptext:
        sys.exit("В packages_android.go не найдено ожидаемое место. Код библиотеки изменился.")
    for imp in ('"bytes"', '"encoding/xml"'):
        if imp not in ptext:
            sys.exit("В packages_android.go нет импорта " + imp)
    ptext = ptext.replace(
        needle,
        'm.logger.Warn(E.Cause(err, "read packages list (ignored)"))\n'
        '\t\t_ = m.decodePackages(xml.NewDecoder(bytes.NewReader([]byte("<packages></packages>"))))\n'
        '\t\treturn nil',
        1,
    )
    pk.write_text(ptext)
    print("packages_android.go исправлен")
else:
    print("packages_android.go не найден, пропускаем")

subprocess.check_call(["go", "mod", "edit", "-replace", "%s=%s" % (MOD, dst)])
print("sing-tun подменён:", target.name, "->", dst)
