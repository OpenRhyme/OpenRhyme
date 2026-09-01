.PHONY: build test format lint clean

SOURCES := Sources Tests Package.swift

build:
	swift build

test:
	swift test

format:
	swift format --in-place --recursive --parallel $(SOURCES)

lint:
	swift format lint --strict --recursive --parallel $(SOURCES)

clean:
	swift package clean
