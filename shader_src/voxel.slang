import utils.camera;
import utils.ray;
import utils.voxel_types;

uniform CameraUniforms g_camera;
uniform VoxelVolume g_volume;

[shader("compute")]
[numthreads(8, 8, 1)]
void cs_main(uint3 dispatchThreadID: SV_DispatchThreadID) {
  uint2 screenCoord = dispatchThreadID.xy;

  // 1. Fetch grid bounds
  uint3 size = g_volume.size;
  uint3 coord = dispatchThreadID; // Use this to test sample a voxel

  // Safety bounds check for the voxel grid
  if (coord.x < size.x && coord.y < size.y && coord.z < size.z) {
    // 2. Calculate the flat 1D index
    uint flatIndex = coord.x + (coord.y * size.x) + (coord.z * size.x * size.y);

    Voxel v = g_volume.data[flatIndex];

    // Let's unpack the color to print it (assuming it's a packed color)
    // printf("Voxel color integer: %u\n", v.color);
  }

  // 3. For the Fly-cam later:
  // You will use screenCoord, generate a ray from g_camera,
  // march through g_volume.data, and write the color to g_outputFramebuffer
}
