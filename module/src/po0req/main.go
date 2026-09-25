// po0req —— po0fw 模块用的极简 HTTP(S) 请求工具（纯 Go 标准库，静态编译）。
//
//   - -iface 用 SO_BINDTODEVICE 把 socket 绑到物理网卡。root 进程在 Android 上会命中
//     netd 的「oif + uidrange 0-0」路由规则，从而绕过代理 / VPN，服务端看到的就是
//     本机真实出口 IP。DNS（仅当 URL 是域名时）也经同一网卡直连查询，避开 fake-ip。
//   - URL 建议经环境变量 PO0REQ_URL 传入，不出现在 /proc/<pid>/cmdline；输出里的
//     token 片段（URL 中 ≥12 字符的路径段 / 查询值）一律打码。
//   - 证书默认按 Android 系统 CA 校验（Conscrypt APEX 优先，其次 /system），
//     也支持 -insecure 与 -pin（sha256//BASE64，与 curl --pinnedpubkey 同格式）。
//
// 输出（stdout，每行 key=value）：code ms local remote tls [location] body | err
// 退出码：0=2xx 1=参数错误 2=网络错误 3=TLS 错误 4=HTTP 4xx 5=其他 HTTP 状态
// -cert 模式：只做 TLS 握手，打印证书链、SAN、有效期、公钥 PIN 与系统 CA 校验结果。
package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

var version = "dev"

const (
	exitOK   = 0
	exitArg  = 1
	exitNet  = 2
	exitTLS  = 3
	exit4xx  = 4
	exitHTTP = 5
)

const defaultCADirs = "/apex/com.android.conscrypt/cacerts:/system/etc/security/cacerts"

var errPin = errors.New("public key pin mismatch")

type options struct {
	url      *url.URL
	method   string
	iface    string
	timeout  time.Duration
	insecure bool
	pins     []string
	dns      []string
	network  string // tcp / tcp4 / tcp6
	caDirs   []string
	caFile   string
	ua       string
	max      int
}

func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }

func run(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("po0req", flag.ContinueOnError)
	fs.SetOutput(stderr)
	rawURL := fs.String("url", "", "request URL (default: $PO0REQ_URL)")
	method := fs.String("method", "POST", "HTTP method")
	iface := fs.String("iface", "", "bind sockets to this interface (SO_BINDTODEVICE, needs root)")
	timeout := fs.Duration("timeout", 10*time.Second, "overall timeout")
	insecure := fs.Bool("insecure", false, "skip certificate chain and hostname verification")
	pin := fs.String("pin", "", "public key pin(s): sha256//BASE64[;sha256//BASE64...]")
	dns := fs.String("dns", "223.5.5.5,119.29.29.29", "DNS servers used when the host is not an IP literal")
	only4 := fs.Bool("4", false, "IPv4 only")
	only6 := fs.Bool("6", false, "IPv6 only")
	caDir := fs.String("cadir", defaultCADirs, "CA directories, ':'-separated; the first non-empty one is used")
	caFile := fs.String("cafile", "", "additional CA bundle (PEM)")
	ua := fs.String("ua", "po0fw/"+version, "User-Agent")
	maxBody := fs.Int("max", 300, "max characters of the response body to print")
	certMode := fs.Bool("cert", false, "only do a TLS handshake and print the certificate chain and pins")
	showVer := fs.Bool("version", false, "print version and exit")
	if err := fs.Parse(args); err != nil {
		return exitArg
	}
	if *showVer {
		fmt.Fprintf(stdout, "po0req %s (%s %s/%s)\n", version, runtime.Version(), runtime.GOOS, runtime.GOARCH)
		return exitOK
	}

	raw := *rawURL
	if raw == "" {
		raw = os.Getenv("PO0REQ_URL")
	}
	u, err := url.Parse(strings.TrimSpace(raw))
	out := &kvWriter{w: stdout, m: newMasker(u)}
	if err != nil || u == nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		out.kv("code", "0")
		out.kv("err", "invalid url")
		return exitArg
	}

	o := &options{
		url:      u,
		method:   strings.ToUpper(strings.TrimSpace(*method)),
		iface:    strings.TrimSpace(*iface),
		timeout:  *timeout,
		insecure: *insecure,
		pins:     parsePins(*pin),
		dns:      parseDNS(*dns),
		network:  "tcp",
		caDirs:   filepath.SplitList(*caDir),
		caFile:   *caFile,
		ua:       *ua,
		max:      *maxBody,
	}
	if o.method == "" {
		o.method = "POST"
	}
	if *only4 {
		o.network = "tcp4"
	} else if *only6 {
		o.network = "tcp6"
	}
	if o.timeout <= 0 {
		o.timeout = 10 * time.Second
	}
	if *certMode {
		return certInfo(o, stdout)
	}
	return doRequest(o, out)
}

// ---------------------------------------------------------------- 网络

// bindControl 返回把 socket 绑到指定网卡的 Control 函数。
func bindControl(iface string) func(network, address string, c syscall.RawConn) error {
	if iface == "" {
		return nil
	}
	return func(network, address string, c syscall.RawConn) error {
		var serr error
		if err := c.Control(func(fd uintptr) {
			serr = syscall.SetsockoptString(int(fd), syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, iface)
		}); err != nil {
			return err
		}
		if serr != nil {
			return fmt.Errorf("bind to %s: %w", iface, serr)
		}
		return nil
	}
}

// newResolver：只在 URL 是域名时用到。DNS 查询同样绑定网卡直连指定服务器，
// 不读 /etc/resolv.conf（Android 上没有），也不会拿到代理的 fake-ip。
func newResolver(servers []string, ctrl func(string, string, syscall.RawConn) error) *net.Resolver {
	if len(servers) == 0 {
		return nil
	}
	var n uint32
	return &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			i := atomic.AddUint32(&n, 1) - 1
			d := net.Dialer{Timeout: 3 * time.Second, Control: ctrl}
			return d.DialContext(ctx, network, servers[int(i)%len(servers)])
		},
	}
}

type connInfo struct {
	mu            sync.Mutex
	local, remote string
}

func (c *connInfo) set(conn net.Conn) {
	c.mu.Lock()
	c.local, c.remote = conn.LocalAddr().String(), conn.RemoteAddr().String()
	c.mu.Unlock()
}

func (c *connInfo) get() (string, string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.local, c.remote
}

func dialer(o *options) *net.Dialer {
	ctrl := bindControl(o.iface)
	return &net.Dialer{Timeout: o.timeout, Control: ctrl, Resolver: newResolver(o.dns, ctrl), KeepAlive: -1}
}

// ---------------------------------------------------------------- TLS

func loadRoots(dirs []string, file string) (*x509.CertPool, int) {
	pool := x509.NewCertPool()
	n := 0
	for _, d := range dirs {
		if d == "" {
			continue
		}
		ents, err := os.ReadDir(d)
		if err != nil {
			continue
		}
		for _, e := range ents {
			if e.IsDir() {
				continue
			}
			// Android 的 cacerts 文件是「PEM + 文本说明」，AppendCertsFromPEM 会跳过文本。
			if b, err := os.ReadFile(filepath.Join(d, e.Name())); err == nil && pool.AppendCertsFromPEM(b) {
				n++
			}
		}
		if n > 0 {
			break // Conscrypt APEX（可更新）优先，有了就不再读 /system 的旧副本
		}
	}
	if file != "" {
		if b, err := os.ReadFile(file); err == nil && pool.AppendCertsFromPEM(b) {
			n++
		}
	}
	if n == 0 {
		if sys, err := x509.SystemCertPool(); err == nil {
			return sys, -1
		}
	}
	return pool, n
}

func spkiPin(c *x509.Certificate) string {
	sum := sha256.Sum256(c.RawSubjectPublicKeyInfo)
	return "sha256//" + base64.StdEncoding.EncodeToString(sum[:])
}

func parsePins(s string) []string {
	var pins []string
	for _, p := range strings.FieldsFunc(s, func(r rune) bool { return r == ';' || r == ',' || r == ' ' }) {
		if !strings.HasPrefix(p, "sha256//") {
			p = "sha256//" + p
		}
		pins = append(pins, p)
	}
	return pins
}

func tlsConfig(o *options) (*tls.Config, string) {
	pool, n := loadRoots(o.caDirs, o.caFile)
	tc := &tls.Config{
		RootCAs:    pool,
		MinVersion: tls.VersionTLS12,
		// 不带后量子混合密钥交换，ClientHello 小，兼容老旧服务端 / 中间设备
		CurvePreferences: []tls.CurveID{tls.X25519, tls.CurveP256, tls.CurveP384},
	}
	mode := "verify"
	if n >= 0 {
		mode += "(ca=" + strconv.Itoa(n) + ")"
	}
	if o.insecure {
		tc.InsecureSkipVerify = true
		mode = "insecure"
	}
	if len(o.pins) > 0 {
		pins := o.pins
		tc.VerifyConnection = func(cs tls.ConnectionState) error {
			if len(cs.PeerCertificates) == 0 {
				return errPin
			}
			got := spkiPin(cs.PeerCertificates[0])
			for _, p := range pins {
				if p == got {
					return nil
				}
			}
			return fmt.Errorf("%w (server key %s)", errPin, got)
		}
		mode += "+pin"
	}
	return tc, mode
}

// ---------------------------------------------------------------- 请求

func doRequest(o *options, out *kvWriter) int {
	ctx, cancel := context.WithTimeout(context.Background(), o.timeout)
	defer cancel()

	info := &connInfo{}
	d := dialer(o)
	tc, mode := tlsConfig(o)
	tr := &http.Transport{
		Proxy: nil, // 永远直连，忽略任何代理环境变量
		DialContext: func(ctx context.Context, _, addr string) (net.Conn, error) {
			c, err := d.DialContext(ctx, o.network, addr)
			if err == nil {
				info.set(c)
			}
			return c, err
		},
		TLSClientConfig:        tc,
		TLSHandshakeTimeout:    o.timeout,
		ResponseHeaderTimeout:  o.timeout,
		DisableKeepAlives:      true,
		MaxResponseHeaderBytes: 64 << 10,
	}
	defer tr.CloseIdleConnections()
	client := &http.Client{
		Transport:     tr,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}

	req, err := http.NewRequestWithContext(ctx, o.method, o.url.String(), nil)
	if err != nil {
		out.kv("code", "0")
		out.kv("err", errText(err))
		return exitArg
	}
	req.Header.Set("User-Agent", o.ua)
	req.Header.Set("Accept", "*/*")

	start := time.Now()
	resp, err := client.Do(req)
	ms := time.Since(start).Milliseconds()
	local, remote := info.get()
	if o.url.Scheme != "https" {
		mode = "none"
	}
	if err != nil {
		out.kv("code", "0")
		out.kv("ms", strconv.FormatInt(ms, 10))
		out.kv("local", local)
		out.kv("remote", remote)
		out.kv("tls", mode)
		out.kv("err", errText(err))
		return classify(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))

	out.kv("code", strconv.Itoa(resp.StatusCode))
	out.kv("ms", strconv.FormatInt(time.Since(start).Milliseconds(), 10))
	out.kv("local", local)
	out.kv("remote", remote)
	out.kv("tls", mode)
	if loc := resp.Header.Get("Location"); loc != "" {
		out.kv("location", loc)
	}
	out.kvMax("body", string(body), o.max)

	switch c := resp.StatusCode; {
	case c >= 200 && c < 300:
		return exitOK
	case c >= 400 && c < 500:
		return exit4xx
	default:
		return exitHTTP
	}
}

func classify(err error) int {
	var (
		cve *tls.CertificateVerificationError
		ua  x509.UnknownAuthorityError
		hn  x509.HostnameError
		ci  x509.CertificateInvalidError
		rh  tls.RecordHeaderError
		ae  tls.AlertError
	)
	if errors.Is(err, errPin) || errors.As(err, &cve) || errors.As(err, &ua) || errors.As(err, &hn) ||
		errors.As(err, &ci) || errors.As(err, &rh) || errors.As(err, &ae) {
		return exitTLS
	}
	return exitNet
}

// errText 去掉 *url.Error 外壳（里面带完整 URL，也就是 token）。
func errText(err error) string {
	var ue *url.Error
	if errors.As(err, &ue) {
		err = ue.Err
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	return err.Error()
}

// ---------------------------------------------------------------- -cert

func certInfo(o *options, w io.Writer) int {
	host := o.url.Hostname()
	port := o.url.Port()
	if port == "" {
		port = "443"
	}
	m := newMasker(o.url)
	ctx, cancel := context.WithTimeout(context.Background(), o.timeout)
	defer cancel()

	raw, err := dialer(o).DialContext(ctx, o.network, net.JoinHostPort(host, port))
	if err != nil {
		fmt.Fprintf(w, "连接失败：%s\n", m.apply(err.Error()))
		return exitNet
	}
	defer raw.Close()
	tc := &tls.Config{InsecureSkipVerify: true, CurvePreferences: []tls.CurveID{tls.X25519, tls.CurveP256, tls.CurveP384}}
	if net.ParseIP(host) == nil {
		tc.ServerName = host
	}
	conn := tls.Client(raw, tc)
	if err := conn.HandshakeContext(ctx); err != nil {
		fmt.Fprintf(w, "TLS 握手失败：%s\n", m.apply(err.Error()))
		return exitTLS
	}
	cs := conn.ConnectionState()
	fmt.Fprintf(w, "连接：%s → %s（%s）\n", raw.LocalAddr(), raw.RemoteAddr(), tls.VersionName(cs.Version))
	for i, c := range cs.PeerCertificates {
		fmt.Fprintf(w, "[%d] 主体：%s\n", i, c.Subject)
		fmt.Fprintf(w, "    签发：%s\n", c.Issuer)
		fmt.Fprintf(w, "    有效期：%s ~ %s\n", c.NotBefore.Format("2006-01-02"), c.NotAfter.Format("2006-01-02"))
		var sans []string
		sans = append(sans, c.DNSNames...)
		for _, ip := range c.IPAddresses {
			sans = append(sans, "IP:"+ip.String())
		}
		if len(sans) > 0 {
			fmt.Fprintf(w, "    SAN：%s\n", strings.Join(sans, ", "))
		}
		fmt.Fprintf(w, "    PIN：%s\n", spkiPin(c))
	}
	if len(cs.PeerCertificates) == 0 {
		return exitTLS
	}
	pool, n := loadRoots(o.caDirs, o.caFile)
	inter := x509.NewCertPool()
	for _, c := range cs.PeerCertificates[1:] {
		inter.AddCert(c)
	}
	_, verr := cs.PeerCertificates[0].Verify(x509.VerifyOptions{Roots: pool, Intermediates: inter, DNSName: host})
	if verr == nil {
		fmt.Fprintf(w, "系统 CA 校验（%d 个根证书）：通过 ✅\n", n)
		return exitOK
	}
	fmt.Fprintf(w, "系统 CA 校验（%d 个根证书）：失败 ❌ %s\n", n, m.apply(verr.Error()))
	fmt.Fprintf(w, "若确认是服务端自签证书：config.conf 里设 INSECURE=1，并把上面 [0] 的 PIN 填进 PIN=\n")
	return exitTLS
}

// ---------------------------------------------------------------- 输出与打码

type masker struct{ secrets []string }

func newMasker(u *url.URL) *masker {
	m := &masker{}
	if u == nil {
		return m
	}
	add := func(s string) {
		if len(s) >= 12 {
			m.secrets = append(m.secrets, s)
		}
	}
	for _, s := range strings.Split(u.EscapedPath(), "/") {
		add(s)
	}
	for _, s := range strings.Split(u.Path, "/") {
		add(s)
	}
	for _, vs := range u.Query() {
		for _, v := range vs {
			add(v)
		}
	}
	if u.User != nil {
		if p, ok := u.User.Password(); ok {
			add(p)
		}
	}
	return m
}

func maskToken(s string) string {
	r := []rune(s)
	if len(r) <= 10 {
		return "***"
	}
	return string(r[:6]) + "…" + string(r[len(r)-3:])
}

func (m *masker) apply(s string) string {
	for _, sec := range m.secrets {
		s = strings.ReplaceAll(s, sec, maskToken(sec))
	}
	return s
}

type kvWriter struct {
	w io.Writer
	m *masker
}

func (k *kvWriter) kv(key, v string) { k.kvMax(key, v, 0) }

func (k *kvWriter) kvMax(key, v string, max int) {
	fmt.Fprintf(k.w, "%s=%s\n", key, oneLine(k.m.apply(v), max))
}

// oneLine：折叠空白、去控制字符、按字符数截断，保证一行。
func oneLine(s string, max int) string {
	s = strings.ToValidUTF8(s, "?")
	var b strings.Builder
	n, space := 0, false
	for _, r := range s {
		switch {
		case r == '\n' || r == '\r' || r == '\t' || r == ' ':
			space = b.Len() > 0
			continue
		case r < 0x20 || r == 0x7f:
			continue
		}
		if space {
			b.WriteByte(' ')
			n++
			space = false
		}
		if max > 0 && n >= max {
			b.WriteString("…")
			break
		}
		b.WriteRune(r)
		n++
	}
	return b.String()
}

func parseDNS(s string) []string {
	var out []string
	for _, f := range strings.FieldsFunc(s, func(r rune) bool { return r == ',' || r == ' ' || r == ';' }) {
		if ip := net.ParseIP(strings.Trim(f, "[]")); ip != nil {
			out = append(out, net.JoinHostPort(ip.String(), "53"))
		} else if _, _, err := net.SplitHostPort(f); err == nil {
			out = append(out, f)
		}
	}
	return out
}
