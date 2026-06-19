

struct Voxel {
  uint color; // Packed RGBA8 (4 bytes per voxel instead of 16-byte float4)
};

// This represents your dense, flat array
struct VoxelVolume {
  uint origin_x;
  uint origin_y;
  uint origin_z;
  uint size_x;
  uint size_y;
  uint size_z;
  Voxel *data; // Flat 1D array inside the struct!
};
