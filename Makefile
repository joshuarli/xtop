.PHONY: debug release test clean fmt run

debug:
	rm -f ./zig-out/bin/xtop
	zig build

run:
	zig build run

release:
	zig build -Doptimize=ReleaseSafe

test:
	zig build test

fmt:
	zig fmt src/*.zig build.zig

fmt-check:
	zig fmt --check src/*.zig build.zig

clean:
	rm -rf zig-out .zig-cache
