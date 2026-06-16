all: build run


build:
  mkdir -p bin
  odin build src -out:bin/voxel

build-debug:
  mkdir -p bin
  odin build src -out:bin/voxel -debug

run:
  bin/voxel
