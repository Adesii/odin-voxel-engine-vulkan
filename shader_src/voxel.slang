import utils.camera;
import utils.ray;
import utils.voxel_types;

uniform CameraUniforms g_camera;
uniform StructuredBuffer<VoxelVolume> g_volume;

uniform RWTexture2D<float4> g_outputFramebuffer;

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

float get_start_distance(Ray ray, float3 volumeOrigin, float3 volumeSize) {
  float tMin = 0.0; // Do not start behind the camera
  float tMax = 1e9; // Upper bound for intersection
  float3 volumeMax = volumeOrigin + volumeSize;

  for (int i = 0; i < 3; i++) {
    if (abs(ray.direction[i]) < 1e-6) {
      // Ray is parallel to slab. Miss if origin is outside.
      if (ray.origin[i] < volumeOrigin[i] || ray.origin[i] > volumeMax[i]) {
        return -1.0;
      }
    } else {
      float ood = 1.0 / ray.direction[i];
      float t1 = (volumeOrigin[i] - ray.origin[i]) * ood;
      float t2 = (volumeMax[i] - ray.origin[i]) * ood;

      // Setup near and far intersections for this axis
      float tNear = min(t1, t2);
      float tFar = max(t1, t2);

      tMin = max(tMin, tNear);
      tMax = min(tMax, tFar);

      // Early exit if ray misses the box
      if (tMin > tMax) {
        return -1.0;
      }
    }
  }

  // If the box is entirely behind the ray
  if (tMax < 0.0) {
    return -1.0;
  }

  // Returns 0.0 if inside, or the exact entry distance if outside
  return tMin;
}

VoxelVolume get_volume() {
  // For this demo, we just have one volume at index 0. You can expand this
  // to support multiple volumes with different origins and sizes!
  return g_volume[0];
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
  // VoxelVolume volume = get_volume();
  // if (dispatchThreadID.x == 0 &&
  //     dispatchThreadID.y == 0) // Print volume info for the first thread only
  // printf("Volume info: origin=(%u, %u, %u), size=(%u, %u, %u)\n",
  //        volume.origin_x, volume.origin_y, volume.origin_z, volume.size_x,
  //        volume.size_y, volume.size_z);
  // printf("camera info: position=(%f, %f, %f), matrix=(%f, %f, %f, %f)\n",
  //        g_camera.position.x, g_camera.position.y, g_camera.position.z,
  //        g_camera.invViewProj._11, g_camera.invViewProj._12,
  //        g_camera.invViewProj._13, g_camera.invViewProj._14);
  // return;
  float4 finalColor = float4(0.2, 0.4, 0.6, 1.0); // Default sky bluebackground
  float depth = 1e9; // Start with a very large depth value
  for (int i = 0; i < g_volume.getCount(); i++) {
    VoxelVolume volume = g_volume[i];

    float3 size = float3(volume.size_x, volume.size_y, volume.size_z);
    float3 origin = float3(volume.origin_x, volume.origin_y, volume.origin_z);
    float starting_distance = get_start_distance(ray, origin, size);
    if (starting_distance < 0.0)
      continue;

    float t = starting_distance;
    float max_dist = t + 500000.0;
    float3 ray_dir = ray.direction;
    float3 inv_dir = 1.0 / ray_dir;
    float3 tDelta = abs(inv_dir);

    float3 start_pos = ray.origin + t * ray_dir - origin;
    int3 voxel = int3(floor(start_pos + (ray_dir * 0.0001)));

    float3 tMax;
    tMax.x = (ray_dir.x != 0)
                 ? (float(voxel.x + (ray_dir.x > 0 ? 1 : 0)) - start_pos.x) *
                       inv_dir.x
                 : 1e30;
    tMax.y = (ray_dir.y != 0)
                 ? (float(voxel.y + (ray_dir.y > 0 ? 1 : 0)) - start_pos.y) *
                       inv_dir.y
                 : 1e30;
    tMax.z = (ray_dir.z != 0)
                 ? (float(voxel.z + (ray_dir.z > 0 ? 1 : 0)) - start_pos.z) *
                       inv_dir.z
                 : 1e30;

    for (int i = 0; i < 1000000 && t < max_dist; i++) {
      if (voxel.x >= 0 && voxel.x < (int)size.x && voxel.y >= 0 &&
          voxel.y < (int)size.y && voxel.z >= 0 && voxel.z < (int)size.z) {
        uint3 voxelCoord = uint3(voxel);
        uint flatIndex = voxelCoord.x + (voxelCoord.y * volume.size_x) +
                         (voxelCoord.z * volume.size_x * volume.size_y);
        uint maxVoxels = volume.size_x * volume.size_y * volume.size_z;

        if (flatIndex < maxVoxels) {
          uint packed_color = volume.data[flatIndex].color;
          if (packed_color != 0) {
            float r = (float)((packed_color >> 24) & 0xFF) / 255.0;
            float g = (float)((packed_color >> 16) & 0xFF) / 255.0;
            float b = (float)((packed_color >> 8) & 0xFF) / 255.0;
            float3 global_voxel_pos = origin + float3(voxel);
            float distance_to_voxel = length(global_voxel_pos - ray.origin);
            float depth_shadow = 1.0 / (1.0 + (distance_to_voxel * 0.0005));
            if (depth > distance_to_voxel) {
              depth = distance_to_voxel;
              finalColor = float4(float3(r, g, b) * depth_shadow, 1.0);
            }
            break;
          }
        } else {
          finalColor = float4(1.0, 0.0, 1.0, 1.0);
          break;
        }
      } else {
        break;
      }

      if (tMax.x < tMax.y) {
        if (tMax.x < tMax.z) {
          t += tMax.x;
          tMax.x += tDelta.x;
          voxel.x += (ray_dir.x > 0 ? 1 : -1);
        } else {
          t += tMax.z;
          tMax.z += tDelta.z;
          voxel.z += (ray_dir.z > 0 ? 1 : -1);
        }
      } else {
        if (tMax.y < tMax.z) {
          t += tMax.y;
          tMax.y += tDelta.y;
          voxel.y += (ray_dir.y > 0 ? 1 : -1);
        } else {
          t += tMax.z;
          tMax.z += tDelta.z;
          voxel.z += (ray_dir.z > 0 ? 1 : -1);
        }
      }
    }
  }
  // if (dispatchThreadID.x == 0 &&
  //     dispatchThreadID.y == 0) // Print volume info for the first thread only
  //   printf("Final color: (%f, %f, %f)\n", finalColor.r, finalColor.g,
  //          finalColor.b);

  // 3. Output the pixel straight to the screen image container
  g_outputFramebuffer[pixelCoord] = finalColor;
}
