build: main.swift
	mkdir -p bin
	swiftc -O -o bin/mousezoomonmac main.swift

app: main.swift
	mkdir -p bin
	swiftc -O -o bin/mousezoomonmac main.swift
	mkdir -p "MouseZoomOnMac.app/Contents/MacOS"
	cp bin/mousezoomonmac "MouseZoomOnMac.app/Contents/MacOS/MouseZoomOnMac"
	cp Info.plist "MouseZoomOnMac.app/Contents/Info.plist"

clean:
	rm -rf bin "MouseZoomOnMac.app"

.PHONY: build app clean
all: app
