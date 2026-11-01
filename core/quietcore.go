// Package quietcore: тонкая обёртка вокруг Mihomo для Android.
// Собирается через gomobile в quietcore.aar. Лежит внутри клонированного репозитория
// Mihomo (см. .github/workflows/android.yml), поэтому использует его go.mod.
package quietcore

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"gopkg.in/yaml.v3"
)

// Protector реализуется на стороне Kotlin и вызывает VpnService.protect(fd).
// Получает КОПИЮ дескриптора и обязан её закрыть.
// Защищённые сокеты идут мимо туннеля: так трафик к серверу mieru не зацикливается.
type Protector interface {
	Protect(fd int) bool
}

var (
	mu      sync.Mutex
	running bool
	logFile *os.File
	prot    Protector

	secretRe = regexp.MustCompile(`(?m)^(\s*(?:-\s*)?(?:username|password|server):).*$`)
	ruleRe   = regexp.MustCompile(`(?m)^(\s*-\s*(?:IP-CIDR6?|DOMAIN),)[^,\n]*(,DIRECT.*)$`)
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

// protectFd отправляет на защиту копию сокета: Kotlin закрывает её сам,
// а оригинал остаётся у ядра.
func protectFd(p Protector, f uintptr) bool {
	nfd, err := syscall.Dup(int(f))
	if err != nil {
		return false
	}
	return p.Protect(nfd)
}

// Version возвращает версию встроенного ядра Mihomo.
func Version() string { return constant.Version }

// Start запускает ядро. tunFd — дескриптор туннеля от VpnService.
func Start(homeDir string, config string, tunFd int, p Protector, debug bool) error {
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

	cfg, err := patchConfig(config, fd, debug)
	if err != nil {
		_ = syscall.Close(fd)
		return fmt.Errorf("конфиг: %w", err)
	}

	fmt.Println("=== quietcore: версия Mihomo", constant.Version, "===")
	fmt.Println("=== итоговый конфиг (логин, пароль и сервер скрыты) ===")
	shown := secretRe.ReplaceAllString(string(cfg), `$1 "***"`)
	shown = ruleRe.ReplaceAllString(shown, `${1}***${2}`)
	fmt.Println(shown)
	fmt.Println("=== запуск ===")

	prot = p
	if p != nil {
		dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
			var protectErr error
			if err := conn.Control(func(f uintptr) {
				if !protectFd(p, f) {
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

	// Mihomo не возвращает ошибку, если туннель не поднялся, а только пишет её в журнал.
	// Поэтому через полторы секунды проверяем журнал сами.
	time.Sleep(1500 * time.Millisecond)
	if line := findTunError(filepath.Join(homeDir, "core.log")); line != "" {
		executor.Shutdown()
		return errors.New(line)
	}

	running = true
	fmt.Println("=== quietcore: ядро запущено ===")
	if debug {
		go selfTest(cfg)
		go tunProbeLoop()
	}
	return nil
}

// selfTest проверяет работу цепочки без участия пользователя: один запрос идёт через
// сервер mieru, другой напрямую. Запросы идут через локальный прокси самого ядра.
func selfTest(cfg []byte) {
	time.Sleep(2 * time.Second)
	dnsTest()
	probeServer(cfg)
	proxy, _ := url.Parse("http://127.0.0.1:7890")
	client := &http.Client{
		Timeout:       20 * time.Second,
		Transport:     &http.Transport{Proxy: http.ProxyURL(proxy)},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	tests := []struct{ name, target string }{
		{"через VPN (gstatic.com)", "https://www.gstatic.com/generate_204"},
		{"напрямую (ya.ru)", "https://ya.ru"},
	}
	for _, tc := range tests {
		started := time.Now()
		resp, err := client.Get(tc.target)
		if err != nil {
			fmt.Println("=== самопроверка:", tc.name, "ОШИБКА:", err, "===")
			continue
		}
		_ = resp.Body.Close()
		fmt.Println("=== самопроверка:", tc.name, "ответ", resp.StatusCode, "за", time.Since(started).Round(time.Millisecond), "===")
	}
}

func findTunError(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.Contains(line, "Start TUN listening error") {
			if i := strings.Index(line, "msg="); i >= 0 {
				return strings.Trim(line[i+4:], `"`)
			}
			return line
		}
	}
	return ""
}

// Stop останавливает ядро.
func Stop() {
	mu.Lock()
	defer mu.Unlock()
	defer func() { _ = recover() }()
	if !running {
		return
	}
	executor.Shutdown()
	running = false
}

// patchConfig подгоняет общий конфиг под Android: маршруты задаёт система (VpnService),
// а туннель приходит готовым дескриптором.
func patchConfig(raw string, fd int, debug bool) ([]byte, error) {
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
	for _, k := range []string{"route-exclude-address", "route-address", "interface-name"} {
		delete(tun, k)
	}
	// Маршруты задаёт Android (VpnService). Эти параметры в Mihomo по умолчанию
	// ВКЛЮЧЕНЫ, поэтому их нужно выключить явно.
	tun["auto-route"] = false
	tun["auto-detect-interface"] = false
	tun["strict-route"] = false
	tun["enable"] = true
	tun["stack"] = "gvisor"
	tun["file-descriptor"] = fd
	tun["inet4-address"] = []string{"172.19.0.1/30"}
	if v6, _ := m["ipv6"].(bool); v6 {
		tun["inet6-address"] = []string{"fdfe:dcba:9876::1/126"}
	}
	tun["dns-hijack"] = []string{"any:53"}
	tun["mtu"] = 9000
	m["tun"] = tun
	// Локальный DNS ядра нужен для самопроверки (напрямую его опрашивает только мы).
	// Локальный порт DNS открываем только в режиме диагностики: его могут обнаружить.
	if dns, ok := m["dns"].(map[string]any); ok && debug {
		dns["listen"] = "127.0.0.1:1053"
	}
	return yaml.Marshal(m)
}

// dnsTest спрашивает DNS самого ядра: российский домен должен получить настоящий IP,
// зарубежный фиктивный из диапазона 198.18.x.x.
func dnsTest() {
	r := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "udp", "127.0.0.1:1053")
		},
	}
	for _, name := range []string{"dzen.ru", "example.com"} {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		started := time.Now()
		addrs, err := r.LookupHost(ctx, name)
		cancel()
		if err != nil {
			fmt.Println("=== самопроверка DNS:", name, "ОШИБКА:", err, "===")
			continue
		}
		fmt.Println("=== самопроверка DNS:", name, "->", addrs, "за", time.Since(started).Round(time.Millisecond), "===")
	}
}

// probeServer пробует открыть TCP-соединение с каждым портом сервера mieru.
// Адрес сервера в журнал не выводится, только номера портов и результат.
func probeServer(cfg []byte) {
	var m map[string]any
	if yaml.Unmarshal(cfg, &m) != nil {
		return
	}
	list, _ := m["proxies"].([]any)
	seen := map[string]bool{}
	for _, item := range list {
		px, _ := item.(map[string]any)
		if px == nil || fmt.Sprint(px["transport"]) != "TCP" {
			continue
		}
		host := fmt.Sprint(px["server"])
		var ports []int
		if v, ok := px["port"]; ok {
			var n int
			_, _ = fmt.Sscan(fmt.Sprint(v), &n)
			ports = append(ports, n)
		}
		if v, ok := px["port-range"]; ok {
			var a, b int
			if _, err := fmt.Sscanf(fmt.Sprint(v), "%d-%d", &a, &b); err == nil {
				for n := a; n <= b && n-a < 20; n++ {
					ports = append(ports, n)
				}
			}
		}
		for _, port := range ports {
			key := net.JoinHostPort(host, fmt.Sprint(port))
			if port <= 0 || seen[key] {
				continue
			}
			seen[key] = true
			d := net.Dialer{
				Timeout: 4 * time.Second,
				Control: func(network, address string, c syscall.RawConn) error {
					if prot == nil {
						return nil
					}
					return c.Control(func(fd uintptr) { protectFd(prot, fd) })
				},
			}
			started := time.Now()
			conn, err := d.Dial("tcp", key)
			if err != nil {
				reason := "порт закрыт или отклонил соединение"
				if ne, ok := err.(net.Error); ok && ne.Timeout() {
					reason = "таймаут (порт заблокирован или сервер не отвечает)"
				}
				fmt.Println("=== проверка порта", port, ": ОШИБКА,", reason, "===")
				continue
			}
			_ = conn.Close()
			fmt.Println("=== проверка порта", port, ": доступен за", time.Since(started).Round(time.Millisecond), "===")
		}
	}
}

// tunProbeLoop раз в 5 секунд шлёт обычные (не защищённые) пакеты. Они идут через
// туннель так же, как пакеты любого приложения, и показывают, живёт ли путь пакетов.
func tunProbeLoop() {
	time.Sleep(3 * time.Second)
	for i := 1; i <= 12; i++ {
		fmt.Println("=== тест туннеля", i, ":", probeTunDNS(), "|", probeTunTCP(), "===")
		time.Sleep(5 * time.Second)
	}
}

func probeTunDNS() string {
	conn, err := net.DialTimeout("udp", "172.19.0.2:53", 2*time.Second)
	if err != nil {
		return "DNS: ошибка соединения"
	}
	defer conn.Close()
	query := []byte{
		0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0,
		7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0,
		0, 1, 0, 1,
	}
	started := time.Now()
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Write(query); err != nil {
		return "DNS: ошибка отправки"
	}
	buf := make([]byte, 512)
	n, err := conn.Read(buf)
	if err != nil {
		return "DNS: нет ответа за 2с"
	}
	return fmt.Sprintf("DNS: ответ %d байт за %v", n, time.Since(started).Round(time.Millisecond))
}

func probeTunTCP() string {
	started := time.Now()
	conn, err := net.DialTimeout("tcp", "1.1.1.1:443", 4*time.Second)
	if err != nil {
		return "TCP: нет соединения за 4с"
	}
	_ = conn.Close()
	return fmt.Sprintf("TCP: соединение за %v", time.Since(started).Round(time.Millisecond))
}
