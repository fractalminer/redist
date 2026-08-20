compiler = /usr/bin/g++

compile = $(HOME)/dev/redist/src/builder.sh $(compiler)
link = $(compiler)

.PHONY: clean all run

all: build/binary

run: build/binary
	./build/binary

build:
	mkdir -p build

build/%.o: %.cpp Makefile | build
	$(compile) -O3 -MMD -MF build/$*.d -MT $@ -Wall -Werror -c $< -o $@

build/binary: build/main.o build/a.o build/b.o build/c.o Makefile
	$(link) build/main.o build/a.o build/b.o build/c.o -o $@

clean:
	rm -rf build

-include build/*.d