import utils.camera;
import utils.ray;
import utils.voxel_types;

uniform CameraUniforms g_camera;
uniform VoxelVolume g_volume;

uniform RWTexture2D<float4> g_outputFramebuffer;

// Generates a clean 3D perspective ray from a pixel coordinate
// Ray generate_camera_ray(uint2 pixelCoord, float2 screenSize) {
//   // 1. Convert pixel coordinate to Normalized Device Coordinates (-1 to 1)
//   float2 ndc = (float2(pixelCoord) / screenSize) * 2.0 - 1.0;
//   ndc.y = -ndc.y; // Flip Y for Vulkan screen coordinate space
//
//   // 2. Un-project the NDC screen point into 3D space near and far planes
//   // We use a clip-space point on the near plane (z = 0.0)
//   float4 clipTarget = float4(ndc.x, ndc.y, 0.0, 1.0);
//
//   // Multiply by the inverse view-projection matrix
//   float4 worldTarget = mul(g_camera.invViewProj, clipTarget);
//   worldTarget /=
//       worldTarget.w; // Perspective divide to get true 3D world coordinate
//
//   Ray ray;
//   ray.origin = g_camera.position;
//
//   // The direction is simply the vector from the camera eye to our
//   un-projected
//   // world point
//   ray.direction = normalize(worldTarget.xyz - ray.origin);
//
//   return ray;
// }

// voxel.slang

Ray generate_camera_ray(uint2 pixelCoord, float2 screenSize) {
  float2 ndc = ((float2(pixelCoord) + 0.5) / screenSize) * 2.0 - 1.0;
  ndc.y = -ndc.y; // Match Vulkan Y axis configuration

  // Un-project a clip space coordinate on the near plane.
  float4 clipTarget = float4(ndc.x, ndc.y, -1.0, 1.0);

  // Multiply target by your layout-aligned inverse view-proj matrix
  float4 worldTarget = mul(g_camera.invViewProj, clipTarget);
  worldTarget /=
      worldTarget.w; // Perspective divide to translate to 3D world space

  Ray ray;
  ray.origin = g_camera.position;
  ray.direction = normalize(worldTarget.xyz - ray.origin);

  return ray;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID: SV_DispatchThreadID) {
  uint2 pixelCoord = dispatchThreadID.xy;

  // 1. MUST use unsigned integers for GetDimensions!
  uint width, height;
  g_outputFramebuffer.GetDimensions(width, height);

  // Guard against overflow or window resizing threads
  if (pixelCoord.x >= width || pixelCoord.y >= height)
    return;

  // 2. Safely cast to floats for the ray generation math
  float2 screenSize = float2((float)width, (float)height);

  // 1. Generate the ray
  Ray ray = generate_camera_ray(pixelCoord, screenSize);

  // Output the ray direction directly as RGB colors!
  // g_outputFramebuffer[pixelCoord] = float4(abs(ray.direction), 1.0);
  // return; // Short-circuit the rest of the raymarcher loop
  // 2. Raymarching parameters
  float3 size = float3(g_volume.size);
  float t = 0.0;
  float max_dist = 200.0; // How far the camera can see
  float step_size =
      0.05; // Smaller = sharper voxels, larger = faster performance

  float4 finalColor = float4(0.2, 0.4, 0.6, 1.0); // Default sky bluebackground

  while (t < max_dist) {
    float3 position = ray.origin + ray.direction * t;

    // Check if the ray position has entered our 3D grid boundary
    if (position.x >= 0 && position.x < size.x && position.y >= 0 &&
        position.y < size.y && position.z >= 0 && position.z < size.z) {

      // Convert float 3D coordinate to exact integer voxel coordinate
      uint3 voxelCoord = uint3(position);

      // Translate 3D coordinates to your flat dense 1D array index!
      uint flatIndex = voxelCoord.x + (voxelCoord.y * (uint)size.x) +
                       (voxelCoord.z * (uint)size.x * (uint)size.y);

      uint packed_color = g_volume.data[flatIndex].color;

      // If the voxel color is not transparent, we hit a voxel!
      if (packed_color != 0) {
        // Unpack RGBA8 color from the u32
        float r = (float)((packed_color >> 24) & 0xFF) / 255.0;
        float g = (float)((packed_color >> 16) & 0xFF) / 255.0;
        float b = (float)((packed_color >> 8) & 0xFF) / 255.0;

        // Add a tiny bit of distance shading so it looks beautifully 3D
        float depth_shadow = 1.0 / (1.0 + (t * t * 0.005));
        finalColor = float4(float3(r, g, b) * depth_shadow, 1.0);
        break;
      }
    }
    t += step_size;
  }

  // 3. Output the pixel straight to the screen image container
  g_outputFramebuffer[pixelCoord] = finalColor;
}
