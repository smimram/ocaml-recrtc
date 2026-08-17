all: build

build:
	@dune build

serve:
	@dune exec src/recrtc.exe
