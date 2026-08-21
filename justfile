all: build-debug run-debug


build:
  mkdir -p bin
  odin build src -out:bin/voxel

build-shaders-debug:
  odin run src/engine/tools/shader -debug -- FORCE_RECOMPILE

build-shaders:
  odin run src/engine/tools/shader -debug # This builds the reflection data for shaders

build-debug:
  mkdir -p bin
  odin build src -out:bin/voxel -debug

run:
  bin/voxel

run-debug:
  bin/voxel -debug

run-debug-profiling:
  odin build src -out:bin/voxel -debug -define:TRACY_ENABLE=true
  bin/voxel -debug

run-release:
  odin build src -out:bin/voxel -o:speed
  bin/voxel
run-release-fresh:
  rm saves/delta_core_mvp.world
  odin build src -out:bin/voxel -o:speed
  bin/voxel
