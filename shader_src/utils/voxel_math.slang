module Math;

public uint hashUint(uint value) {
  value ^= value >> 16;
  value *= 0x7FEB352Du;
  value ^= value >> 15;
  value *= 0x846CA68Bu;
  value ^= value >> 16;
  return value;
}

public uint hashVoxel(int3 voxel) {
  return hashUint(uint(voxel.x) * 73856093u ^ uint(voxel.y) * 19349663u ^
                  uint(voxel.z) * 83492791u);
}

// Explicit floor is required here: signed integer division truncated negative
// world coordinates on the GPU.
public int floorDiv(int value, int divisor) {
  return int(floor(float(value) / float(divisor)));
}

public int3 floorDiv3(int3 value, int divisor) {
  return int3(floorDiv(value.x, divisor), floorDiv(value.y, divisor),
              floorDiv(value.z, divisor));
}

