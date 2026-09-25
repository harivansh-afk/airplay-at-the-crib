// airplay-beacon announces an existing Roku over Bluetooth; media stays direct.
package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"encoding/xml"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/godbus/dbus/v5"
	"github.com/godbus/dbus/v5/prop"
	"howett.net/plist"
)

const (
	adPath           = dbus.ObjectPath("/sh/harivan/airplay_beacon")
	adInterface      = "org.bluez.LEAdvertisement1"
	managerInterface = "org.bluez.LEAdvertisingManager1"
	maxBody          = 65536
)

type options struct {
	address, serial, mac, iface, adapter, networks, stateFile string
	port                                                      int
	interval, retry, scanInterval                             time.Duration
	check                                                     bool
}

type receiver struct{ Address, Name string }
type cache struct{ Address, Serial string }

func payload(address string, port int) []byte {
	ip := netip.MustParseAddr(address).As4()
	data := append([]byte{0x09, 0x08, 0x13, 0x30}, ip[:]...)
	return binary.BigEndian.AppendUint16(data, uint16(port))
}

func validAddress(address string) bool {
	ip, err := netip.ParseAddr(address)
	return err == nil && ip.Is4() && ip.IsPrivate()
}

func newClient() *http.Client {
	return &http.Client{
		Timeout:       2 * time.Second,
		Transport:     &http.Transport{DialContext: (&net.Dialer{Timeout: time.Second}).DialContext, MaxIdleConns: 2, IdleConnTimeout: 90 * time.Second},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

func get(ctx context.Context, client *http.Client, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	response, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maxBody+1))
	if len(body) > maxBody {
		return nil, errors.New("receiver response too large")
	}
	return body, err
}

func identity(ctx context.Context, client *http.Client, address, serial string) error {
	if !validAddress(address) {
		return errors.New("not a private IPv4 address")
	}
	body, err := get(ctx, client, "http://"+address+":8060/query/device-info")
	if err != nil {
		return err
	}
	var info struct {
		Serial  string `xml:"serial-number"`
		AirPlay string `xml:"supports-airplay"`
	}
	if err := xml.Unmarshal(body, &info); err != nil {
		return err
	}
	if info.Serial != serial {
		return errors.New("receiver serial mismatch")
	}
	if info.AirPlay != "true" {
		return errors.New("receiver lacks AirPlay support")
	}
	return nil
}

func probe(ctx context.Context, client *http.Client, address string, opts options) (receiver, error) {
	if err := identity(ctx, client, address, opts.serial); err != nil {
		return receiver{}, err
	}
	body, err := get(ctx, client, fmt.Sprintf("http://%s:%d/info?txtAirPlay&txtRAOP", address, opts.port))
	if err != nil {
		return receiver{}, err
	}
	var info struct {
		Name    string `plist:"name"`
		AirPlay []byte `plist:"txtAirPlay"`
		RAOP    []byte `plist:"txtRAOP"`
	}
	if _, err := plist.Unmarshal(body, &info); err != nil {
		return receiver{}, err
	}
	if len(info.AirPlay) == 0 || len(info.RAOP) == 0 || info.Name == "" {
		return receiver{}, errors.New("incomplete AirPlay discovery information")
	}
	return receiver{Address: address, Name: info.Name}, nil
}

func neighbors(contents, mac, iface string) []string {
	var addresses []string
	if mac == "" || iface == "" {
		return addresses
	}
	for line := range strings.SplitSeq(contents, "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 6 && strings.EqualFold(fields[3], mac) && fields[5] == iface && validAddress(fields[0]) {
			addresses = append(addresses, fields[0])
		}
	}
	return addresses
}

func scanAddresses(networks string) ([]string, error) {
	var addresses []string
	seen := map[string]bool{}
	for _, value := range strings.Split(networks, ",") {
		if value = strings.TrimSpace(value); value == "" {
			continue
		}
		prefix, err := netip.ParsePrefix(value)
		if err != nil || !prefix.Addr().Is4() || !prefix.Addr().IsPrivate() || prefix.Bits() < 24 {
			return nil, errors.New("discovery networks must be private IPv4 /24 or smaller")
		}
		prefix = prefix.Masked()
		for ip := prefix.Addr(); prefix.Contains(ip); ip = ip.Next() {
			if prefix.Bits() <= 30 && (ip == prefix.Addr() || !prefix.Contains(ip.Next())) {
				continue
			}
			if !seen[ip.String()] {
				seen[ip.String()] = true
				addresses = append(addresses, ip.String())
			}
			if len(addresses) > 1024 {
				return nil, errors.New("discovery scope exceeds 1024 addresses")
			}
		}
	}
	return addresses, nil
}

// Scans happen only while the known receiver is unavailable, at most once per
// scan interval. Each endpoint must match the paired serial before use.
func scan(ctx context.Context, client *http.Client, addresses []string, opts options) (receiver, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	jobs := make(chan string)
	found := make(chan receiver, 1)
	var workers sync.WaitGroup
	for range 8 {
		workers.Go(func() {
			for address := range jobs {
				if ctx.Err() != nil {
					return
				}
				result, err := probe(ctx, client, address, opts)
				if err == nil {
					select {
					case found <- result:
						cancel()
					default:
					}
					return
				}
			}
		})
	}
feed:
	for _, address := range addresses {
		select {
		case jobs <- address:
		case <-ctx.Done():
			break feed
		}
	}
	close(jobs)
	workers.Wait()
	select {
	case result := <-found:
		return result, nil
	default:
		return receiver{}, errors.New("paired Roku unavailable")
	}
}

func saveCache(path string, value cache) error {
	if path == "" {
		return nil
	}
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".address-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if _, err = file.Write(data); err != nil {
		file.Close()
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), path)
}

type advertisement struct {
	wanted   atomic.Bool
	released chan struct{}
}

func (ad *advertisement) Release() *dbus.Error {
	if ad.wanted.Load() {
		select {
		case ad.released <- struct{}{}:
		default:
		}
	}
	return nil
}

type objectMap map[dbus.ObjectPath]map[string]map[string]dbus.Variant

func adapterReady(objects objectMap, path dbus.ObjectPath) bool {
	interfaces := objects[path]
	_, advertising := interfaces[managerInterface]
	powered, _ := interfaces["org.bluez.Adapter1"]["Powered"].Value().(bool)
	return advertising && powered
}

func waitAdapter(ctx context.Context, conn *dbus.Conn, path dbus.ObjectPath) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	for {
		var objects objectMap
		err := conn.Object("org.bluez", "/").CallWithContext(ctx, "org.freedesktop.DBus.ObjectManager.GetManagedObjects", 0).Store(&objects)
		if err == nil && adapterReady(objects, path) {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("Bluetooth adapter not ready: %w", ctx.Err())
		case <-time.After(250 * time.Millisecond):
		}
	}
}

func run(ctx context.Context, opts options) error {
	client := newClient()
	defer client.CloseIdleConnections()
	return runWithClient(ctx, opts, client)
}

func runWithClient(ctx context.Context, opts options, client *http.Client) error {
	addresses, err := scanAddresses(opts.networks)
	if err != nil {
		return err
	}
	if opts.check {
		result, err := probe(ctx, client, opts.address, opts)
		if err == nil {
			log.Printf("verified %q at %s:%d; manufacturer payload %x", result.Name, result.Address, opts.port, payload(result.Address, opts.port))
		}
		return err
	}
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return err
	}
	defer conn.Close()
	adapterPath := dbus.ObjectPath("/org/bluez/" + opts.adapter)
	if err := waitAdapter(ctx, conn, adapterPath); err != nil {
		return err
	}
	changes := make(chan *dbus.Signal, 4)
	conn.Signal(changes)
	if err := conn.AddMatchSignal(dbus.WithMatchInterface("org.freedesktop.DBus"), dbus.WithMatchMember("NameOwnerChanged"), dbus.WithMatchArg(0, "org.bluez")); err != nil {
		return err
	}
	ad := &advertisement{released: make(chan struct{}, 1)}
	if err := conn.Export(ad, adPath, adInterface); err != nil {
		return err
	}
	manager := conn.Object("org.bluez", adapterPath)
	registered := ""
	unregister := func() error {
		if registered == "" {
			return nil
		}
		ad.wanted.Store(false)
		cleanup, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		err := manager.CallWithContext(cleanup, managerInterface+".UnregisterAdvertisement", 0, adPath).Err
		registered = ""
		return err
	}
	defer unregister()
	current := opts.address
	if data, err := os.ReadFile(opts.stateFile); err == nil {
		var saved cache
		if json.Unmarshal(data, &saved) == nil && saved.Serial == opts.serial && validAddress(saved.Address) {
			current = saved.Address
		}
	}
	var nextScan time.Time
	offline := false
	for {
		candidates := []string{current, opts.address}
		if arp, err := os.ReadFile("/proc/net/arp"); err == nil {
			candidates = append(candidates, neighbors(string(arp), opts.mac, opts.iface)...)
		}
		seen := map[string]bool{}
		var result receiver
		var probeErr error
		for _, address := range candidates {
			if seen[address] {
				continue
			}
			seen[address] = true
			result, probeErr = probe(ctx, client, address, opts)
			if probeErr == nil {
				break
			}
		}
		if ctx.Err() != nil {
			return nil
		}
		if probeErr != nil && registered != "" {
			if err := unregister(); err != nil {
				return err
			}
			log.Print("TV unavailable; advertisement withdrawn")
		}
		if probeErr != nil && len(addresses) > 0 && !time.Now().Before(nextScan) {
			nextScan = time.Now().Add(opts.scanInterval)
			result, probeErr = scan(ctx, client, addresses, opts)
		}
		if ctx.Err() != nil {
			return nil
		}
		delay := opts.retry
		if probeErr == nil {
			if registered != result.Address {
				if err := unregister(); err != nil {
					return err
				}
				properties := prop.Map{adInterface: {
					"Type":             &prop.Prop{Value: "broadcast", Emit: prop.EmitFalse},
					"ManufacturerData": &prop.Prop{Value: map[uint16]dbus.Variant{0x004c: dbus.MakeVariant(payload(result.Address, opts.port))}, Emit: prop.EmitFalse},
				}}
				if _, err := prop.Export(conn, adPath, properties); err != nil {
					return err
				}
				ad.wanted.Store(true)
				// Also attempt cleanup if cancellation races BlueZ's reply.
				registered = result.Address
				callCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
				err := manager.CallWithContext(callCtx, managerInterface+".RegisterAdvertisement", 0, adPath, map[string]dbus.Variant{}).Err
				cancel()
				if err != nil {
					return err
				}
				log.Printf("advertising %q at %s:%d", result.Name, result.Address, opts.port)
				if err := saveCache(opts.stateFile, cache{Address: result.Address, Serial: opts.serial}); err != nil {
					log.Printf("address cache: %v", err)
				}
			}
			current, delay, offline = result.Address, opts.interval, false
		} else if !offline {
			log.Printf("waiting for paired Roku: %v", probeErr)
			offline = true
		}
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil
		case <-conn.Context().Done():
			timer.Stop()
			return errors.New("system D-Bus disconnected")
		case <-changes:
			timer.Stop()
			return errors.New("Bluetooth daemon changed; reconnecting")
		case <-ad.released:
			timer.Stop()
			return errors.New("Bluetooth released advertisement; reconnecting")
		case <-timer.C:
		}
	}
}

func main() {
	var opts options
	flag.StringVar(&opts.address, "address", "", "Roku private IPv4 address hint")
	flag.StringVar(&opts.serial, "serial", "", "paired Roku serial number")
	flag.StringVar(&opts.mac, "mac", "", "Roku Wi-Fi MAC for neighbor-cache recovery")
	flag.StringVar(&opts.iface, "interface", "", "LAN interface for neighbor-cache recovery")
	flag.StringVar(&opts.adapter, "adapter", "hci0", "BlueZ adapter")
	flag.StringVar(&opts.networks, "discovery-networks", "", "comma-separated private /24-or-smaller fallback networks")
	flag.StringVar(&opts.stateFile, "state-file", "", "persistent address-cache file")
	flag.IntVar(&opts.port, "port", 7000, "Roku AirPlay port")
	flag.DurationVar(&opts.interval, "interval", time.Minute, "healthy receiver check interval")
	flag.DurationVar(&opts.retry, "retry", 15*time.Second, "unavailable receiver retry interval")
	flag.DurationVar(&opts.scanInterval, "scan-interval", 5*time.Minute, "minimum interval between fallback scans")
	flag.BoolVar(&opts.check, "check", false, "verify TV without advertising")
	flag.Parse()
	if !validAddress(opts.address) || opts.serial == "" || opts.port < 1 || opts.port > 65535 || opts.interval < time.Second || opts.retry < time.Second || opts.scanInterval < time.Minute || strings.ContainsAny(opts.adapter, "/.") {
		log.Fatal("invalid receiver or timing configuration")
	}
	if opts.mac != "" {
		if _, err := net.ParseMAC(opts.mac); err != nil {
			log.Fatal(err)
		}
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, opts); err != nil && ctx.Err() == nil {
		log.Fatal(err)
	}
}
