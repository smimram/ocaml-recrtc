# Only needed when the address to advertise is not one this machine can see,
# such as the public side of a port forwarding.
IP ?=

all: build

build:
	@dune build

test:
	@dune test

serve: build
	@dune exec src/recrtc.exe -- $(if $(IP),--ip $(IP)) $(ARGS)

clean:
	@dune clean

.PHONY: all build test serve clean
