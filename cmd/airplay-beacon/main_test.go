package main

import (
	"context"
	"encoding/hex"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
	"howett.net/plist"
)

type transportFunc func(*http.Request) (*http.Response, error)

func (fn transportFunc) RoundTrip(req *http.Request) (*http.Response, error) { return fn(req) }
func response(body string) *http.Response {
	return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}
}

func TestPayloadMatchesWorkingBeacon(t *testing.T) {
	if got := hex.EncodeToString(payload("10.41.1.210", 7000)); got != "090813300a2901d21b58" {
		t.Fatal(got)
	}
}

func TestReceiverIdentityAndBootstrap(t *testing.T) {
	data, _ := plist.Marshal(map[string]any{"name": "Living room", "txtAirPlay": []byte{1, 2}, "txtRAOP": []byte{3}}, plist.BinaryFormat)
	var infoCalls int
	client := &http.Client{Transport: transportFunc(func(req *http.Request) (*http.Response, error) {
		if req.URL.Path == "/query/device-info" {
			return response("<device-info><serial-number>paired</serial-number><supports-airplay>true</supports-airplay></device-info>"), nil
		}
		infoCalls++
		if req.URL.RawQuery != "txtAirPlay&txtRAOP" {
			t.Fatal(req.URL)
		}
		return response(string(data)), nil
	})}
	if _, err := probe(context.Background(), client, "10.41.1.210", options{serial: "other", port: 7000}); err == nil || infoCalls != 0 {
		t.Fatal("unpaired receiver reached AirPlay bootstrap")
	}
	result, err := probe(context.Background(), client, "10.41.1.210", options{serial: "paired", port: 7000})
	if err != nil || result.Name != "Living room" || infoCalls != 1 {
		t.Fatalf("%+v %v", result, err)
	}
}

func TestRejectsOversizedAndIncompleteResponses(t *testing.T) {
	client := &http.Client{Transport: transportFunc(func(*http.Request) (*http.Response, error) { return response(strings.Repeat("x", maxBody+1)), nil })}
	if _, err := get(context.Background(), client, "http://10.41.1.210/"); err == nil {
		t.Fatal("oversized body accepted")
	}
	data, _ := plist.Marshal(map[string]any{"name": "TV", "txtAirPlay": []byte{1}}, plist.BinaryFormat)
	client.Transport = transportFunc(func(req *http.Request) (*http.Response, error) {
		if req.URL.Path == "/query/device-info" {
			return response("<device-info><serial-number>paired</serial-number><supports-airplay>true</supports-airplay></device-info>"), nil
		}
		return response(string(data)), nil
	})
	if _, err := probe(context.Background(), client, "10.41.1.210", options{serial: "paired", port: 7000}); err == nil {
		t.Fatal("missing RAOP data accepted")
	}
}

func TestPrivateAddressAndDiscoveryBounds(t *testing.T) {
	for _, value := range []string{"127.0.0.1", "8.8.8.8", "169.254.1.1", "::1", "10.0.0.1/path"} {
		if validAddress(value) {
			t.Fatal(value)
		}
	}
	for _, scope := range []string{"10.41.0.0/16", "8.8.8.0/24", "invalid", "fd00::/64"} {
		if _, err := scanAddresses(scope); err == nil {
			t.Fatal(scope)
		}
	}
	addresses, err := scanAddresses("10.41.1.0/24,10.41.1.0/24,10.41.2.0/24")
	if err != nil || len(addresses) != 508 || addresses[0] != "10.41.1.1" || addresses[507] != "10.41.2.254" {
		t.Fatalf("count=%d err=%v", len(addresses), err)
	}
}

func TestNeighborRecoveryRestrictsMACAndInterface(t *testing.T) {
	arp := "10.41.2.8 0x1 0x2 aa:bb:cc:dd:ee:ff * wlan0\n10.41.2.9 0x1 0x2 aa:bb:cc:dd:ee:ff * eth0\n10.41.2.10 0x1 0x2 00:11:22:33:44:55 * wlan0\n"
	got := neighbors(arp, "AA:BB:CC:DD:EE:FF", "wlan0")
	if len(got) != 1 || got[0] != "10.41.2.8" {
		t.Fatal(got)
	}
}

func TestAdapterStartupRace(t *testing.T) {
	path := dbus.ObjectPath("/org/bluez/hci0")
	if adapterReady(objectMap{}, path) {
		t.Fatal("missing adapter ready")
	}
	objects := objectMap{path: {managerInterface: {}, "org.bluez.Adapter1": {"Powered": dbus.MakeVariant(false)}}}
	if adapterReady(objects, path) {
		t.Fatal("unpowered adapter ready")
	}
	objects[path]["org.bluez.Adapter1"]["Powered"] = dbus.MakeVariant(true)
	if !adapterReady(objects, path) {
		t.Fatal("powered adapter not ready")
	}
}

func TestFallbackScanIsBoundedAndCancellable(t *testing.T) {
	var active, peak atomic.Int32
	client := &http.Client{Transport: transportFunc(func(req *http.Request) (*http.Response, error) {
		n := active.Add(1)
		defer active.Add(-1)
		for p := peak.Load(); n > p; p = peak.Load() {
			if peak.CompareAndSwap(p, n) {
				break
			}
		}
		<-req.Context().Done()
		return nil, req.Context().Err()
	})}
	addresses, _ := scanAddresses("10.41.1.0/24")
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	start := time.Now()
	if _, err := scan(ctx, client, addresses, options{serial: "paired", port: 7000}); err == nil {
		t.Fatal("cancelled scan succeeded")
	}
	if peak.Load() > 8 || active.Load() != 0 || time.Since(start) > time.Second {
		t.Fatalf("workers=%d remaining=%d", peak.Load(), active.Load())
	}
}

func TestCacheAtomicReplacement(t *testing.T) {
	path := filepath.Join(t.TempDir(), "address.json")
	for _, addr := range []string{"10.41.1.210", "10.41.2.210"} {
		if err := saveCache(path, cache{Address: addr, Serial: "paired"}); err != nil {
			t.Fatal(err)
		}
	}
	data, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(data), "10.41.2.210") {
		t.Fatalf("%s %v", data, err)
	}
	entries, _ := os.ReadDir(filepath.Dir(path))
	if len(entries) != 1 {
		t.Fatal("temporary cache files leaked")
	}
}

func TestExpectedReleaseDoesNotTriggerRestart(t *testing.T) {
	ad := &advertisement{released: make(chan struct{}, 1)}
	ad.Release()
	select {
	case <-ad.released:
		t.Fatal("intentional unregister treated as failure")
	default:
	}
	ad.wanted.Store(true)
	ad.Release()
	select {
	case <-ad.released:
	default:
		t.Fatal("unexpected release ignored")
	}
}
