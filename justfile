all: build-debug run-debug


build:
  mkdir -p bin
  odin build src -out:bin/voxel

build-shaders:
  odin run src/utils # This builds the reflection data for shaders

build-debug:
  mkdir -p bin
  odin build src -out:bin/voxel -debug

run:
  bin/voxel

run-debug:
  export VK_LAYER_PRINTF_TO_STDOUT=0
  bin/voxel
