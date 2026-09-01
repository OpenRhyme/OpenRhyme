.PHONY: build test run format lint clean

SOURCES := Sources Tests Package.swift

build:
	swift build

test:
	swift test

run:
	swift build && .build/debug/openrhyme daemon --verbose

format:
	swift format --in-place --recursive --parallel $(SOURCES)

lint:
	swift format lint --strict --recursive --parallel $(SOURCES)

clean:
	swift package clean
