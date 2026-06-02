.PHONY: debug release test clean

debug:
	zig build

release:
	zig build -Doptimize=ReleaseSafe

test:
	zig build test

clean:
	rm -rf zig-out .zig-cache
