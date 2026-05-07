.PHONY: build release install test clean

build:
	cargo build

release:
	cargo build --release

install: release
	cargo install --path .
	@echo "nostromo installed to $$(which nostromo)"

test:
	cargo test

clean:
	cargo clean
