package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
	"howett.net/plist"
)

type fakeBlueZ struct {
	conn   *dbus.Conn
	events chan string
}

func (bluez *fakeBlueZ) GetManagedObjects() (objectMap, *dbus.Error) {
	return objectMap{"/org/bluez/hci0": {
		managerInterface:     {},
		"org.bluez.Adapter1": {"Powered": dbus.MakeVariant(true)},
	}}, nil
}

func (bluez *fakeBlueZ) RegisterAdvertisement(sender dbus.Sender, path dbus.ObjectPath, _ map[string]dbus.Variant) *dbus.Error {
	var properties map[string]dbus.Variant
	if err := bluez.conn.Object(string(sender), path).Call("org.freedesktop.DBus.Properties.GetAll", 0, adInterface).Store(&properties); err != nil {
		return dbus.MakeFailedError(err)
	}
	manufacturers, ok := properties["ManufacturerData"].Value().(map[uint16]dbus.Variant)
	if !ok {
		return dbus.MakeFailedError(fmt.Errorf("incorrect manufacturer type: %T", properties["ManufacturerData"].Value()))
	}
	data, ok := manufacturers[0x004c].Value().([]byte)
	if !ok || !bytes.Equal(data, []byte{9, 8, 19, 48, 10, 41, 1, 210, 27, 88}) || properties["Type"].Value() != "broadcast" {
		return dbus.MakeFailedError(fmt.Errorf("incorrect advertisement payload"))
	}
	// BlueZ probes this optional property. Its absence must be a normal error,
	// not a crash or a change to the payload that worked with the real Roku.
	if err := bluez.conn.Object(string(sender), path).Call("org.freedesktop.DBus.Properties.Get", 0, adInterface, "TxPower").Err; err == nil {
		return dbus.MakeFailedError(fmt.Errorf("unexpected TxPower override"))
	}
	bluez.events <- "registered"
	return nil
}

func (bluez *fakeBlueZ) UnregisterAdvertisement(_ dbus.ObjectPath) *dbus.Error {
	bluez.events <- "withdrawn"
	return nil
}

func TestDBusHealthRecoveryAndCleanup(t *testing.T) {
	if os.Getenv("AIRPLAY_TEST_PRIVATE_BUS") != "1" {
		t.Skip("requires an isolated test bus")
	}
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.RequestName("org.bluez", dbus.NameFlagDoNotQueue); err != nil {
		t.Fatal(err)
	}
	bluez := &fakeBlueZ{conn: conn, events: make(chan string, 8)}
	if err := conn.Export(bluez, "/", "org.freedesktop.DBus.ObjectManager"); err != nil {
		t.Fatal(err)
	}
	if err := conn.Export(bluez, "/org/bluez/hci0", managerInterface); err != nil {
		t.Fatal(err)
	}
	data, _ := plist.Marshal(map[string]any{"name": "Living room", "txtAirPlay": []byte{1}, "txtRAOP": []byte{2}}, plist.BinaryFormat)
	var online atomic.Bool
	online.Store(true)
	client := &http.Client{Transport: transportFunc(func(req *http.Request) (*http.Response, error) {
		if !online.Load() {
			return &http.Response{StatusCode: 503, Body: http.NoBody}, nil
		}
		if req.URL.Path == "/query/device-info" {
			return response("<device-info><serial-number>paired</serial-number><supports-airplay>true</supports-airplay></device-info>"), nil
		}
		return response(string(data)), nil
	})}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- runWithClient(ctx, options{address: "10.41.1.210", serial: "paired", port: 7000, adapter: "hci0", interval: 5 * time.Millisecond, retry: 5 * time.Millisecond}, client)
	}()
	expect := func(want string) {
		t.Helper()
		select {
		case got := <-bluez.events:
			if got != want {
				t.Fatalf("got %s want %s", got, want)
			}
		case err := <-done:
			t.Fatalf("daemon exited: %v", err)
		case <-ctx.Done():
			t.Fatal("timed out waiting for", want)
		}
	}
	expect("registered")
	online.Store(false)
	expect("withdrawn")
	online.Store(true)
	expect("registered")
	cancel()
	select {
	case got := <-bluez.events:
		if got != "withdrawn" {
			t.Fatal(got)
		}
	case <-time.After(time.Second):
		t.Fatal("shutdown did not unregister")
	}
	if err := <-done; err != nil && !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}
