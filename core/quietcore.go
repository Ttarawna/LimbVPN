// Package quietcore: тонкая обёртка вокруг Mihomo для Android.
// Собирается через gomobile в quietcore.aar. Лежит внутри клонированного репозитория
// Mihomo (см. .github/workflows/android.yml), поэтому использует его go.mod.
package quietcore

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sync"
	"syscall"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"gopkg.in/yaml.v3"
)

// Protector реализуется на стороне Kotlin и вызывает VpnService.protect(fd).
// Защищённые сокеты идут мимо туннеля: так трафик к серверу mieru не зацикливается.
type Protector interface {
	Protect(fd int) bool
}

var (
	mu      sync.Mutex
	running bool
	logFile *os.File

	secretRe = regexp.MustCompile(`(?m)^(\s*(?:-\s*)?(?:username|password|server):).*$`)
)

// redirectLogs направляет stdout и stderr процесса в файл, чтобы журнал ядра
// можно было показать в приложении.
func redirectLogs(path string) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return
	}
	_ = syscall.Dup3(int(f.Fd()), 1, 0)
	_ = syscall.Dup3(int(f.Fd()), 2, 0)
	if logFile != nil {
		_ = logFile.Close()
	}
	logFile = f
}

// Version возвращает версию встроенного ядра Mihomo.
func Version() string { return constant.Version }

// Start запускает ядро. tunFd — дескриптор туннеля от VpnService.
func Start(homeDir string, config string, tunFd int, p Protector) error {
	mu.Lock()
	defer mu.Unlock()
	if running {
		return errors.New("ядро уже запущено")
	}

	redirectLogs(filepath.Join(homeDir, "core.log"))

	// Ядро получает копию дескриптора: оригиналом владеет Kotlin и закроет его сам.
	fd, err := syscall.Dup(tunFd)
	if err != nil {
		return fmt.Errorf("dup tun fd: %w", err)
	}

	cfg, err := patchConfig(config, fd)
	if err != nil {
		_ = syscall.Close(fd)
		return fmt.Errorf("конфиг: %w", err)
	}

	fmt.Println("=== quietcore: версия Mihomo", constant.Version, "===")
	fmt.Println("=== итоговый конфиг (логин, пароль и сервер скрыты) ===")
	fmt.Println(secretRe.ReplaceAllString(string(cfg), `$1 "***"`))
	fmt.Println("=== запуск ===")

	if p != nil {
		dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
			var protectErr error
			if err := conn.Control(func(f uintptr) {
				if !p.Protect(int(f)) {
					protectErr = errors.New("не удалось защитить сокет")
				}
			}); err != nil {
				return err
			}
			return protectErr
		}
	}

	constant.SetHomeDir(homeDir)
	if err := hub.Parse(cfg); err != nil {
		_ = syscall.Close(fd)
		return fmt.Errorf("запуск Mihomo: %w", err)
	}
	running = true
	fmt.Println("=== quietcore: ядро запущено ===")
	return nil
}

// Stop останавливает ядро.
func Stop() {
	mu.Lock()
	defer mu.Unlock()
	if !running {
		return
	}
	executor.Shutdown()
	running = false
}

// patchConfig подгоняет общий конфиг под Android: маршруты задаёт система (VpnService),
// а туннель приходит готовым дескриптором.
func patchConfig(raw string, fd int) ([]byte, error) {
	var m map[string]any
	if err := yaml.Unmarshal([]byte(raw), &m); err != nil {
		return nil, err
	}
	if m == nil {
		return nil, errors.New("пустой конфиг")
	}
	tun, _ := m["tun"].(map[string]any)
	if tun == nil {
		tun = map[string]any{}
	}
	for _, k := range []string{
		"auto-route", "auto-detect-interface", "strict-route",
		"route-exclude-address", "route-address", "interface-name",
	} {
		delete(tun, k)
	}
	tun["enable"] = true
	tun["stack"] = "gvisor"
	tun["file-descriptor"] = fd
	tun["inet4-address"] = []string{"172.19.0.1/30"}
	if v6, _ := m["ipv6"].(bool); v6 {
		tun["inet6-address"] = []string{"fdfe:dcba:9876::1/126"}
	}
	tun["dns-hijack"] = []string{"any:53"}
	m["tun"] = tun
	return yaml.Marshal(m)
}
