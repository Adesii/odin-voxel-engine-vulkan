all: build-debug run-debug


build:
  mkdir -p bin
  odin build src -out:bin/voxel

build-shaders-debug:
  odin run src/utils -debug -- FORCE_RECOMPILE

build-shaders:
  odin run src/utils -debug # This builds the reflection data for shaders

build-debug:
  mkdir -p bin
  odin build src -out:bin/voxel -debug

run:
  bin/voxel

run-debug:
  bin/voxel -debug
