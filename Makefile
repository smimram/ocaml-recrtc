IP ?= 127.0.0.1

all: build

build:
	@dune build

test:
	@dune test

serve: build
	@dune exec src/recrtc.exe -- --ip $(IP) $(ARGS)

clean:
	@dune clean

.PHONY: all build test serve clean
