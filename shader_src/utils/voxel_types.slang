

struct Voxel {
  uint color; // Packed RGBA8 (4 bytes per voxel instead of 16-byte float4)
};

// This represents your dense, flat array
struct VoxelVolume {
  float3 origin; // Changed to float3 to support fractional world positions
  uint size_x;
  uint size_y;
  uint size_z;
  float3x3 invRotation; // Inverse (Transpose) of your Odin 3x3 rotation matrix
  float3x3 rotation;    // Original rotation matrix
  Voxel *data;
};
