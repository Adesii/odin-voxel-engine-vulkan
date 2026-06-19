

struct Voxel {
  uint color; // Packed RGBA8 (4 bytes per voxel instead of 16-byte float4)
};

// This represents your dense, flat array
struct VoxelVolume {
  uint3 origin;
  uint3 size;  // Grid dimensions (e.g., 64, 64, 64)
  Voxel *data; // Flat 1D array inside the struct!
};
