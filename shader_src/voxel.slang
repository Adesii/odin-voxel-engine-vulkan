import utils.camera;
import utils.ray;
import utils.voxel_types;

uniform CameraUniforms g_camera;
uniform StructuredBuffer<VoxelVolume> g_volume;

uniform RWTexture2D<float4> g_outputFramebuffer;

// voxel.slang

Ray generate_camera_ray(uint2 pixelCoord, float2 screenSize) {
  float2 ndc = ((float2(pixelCoord) + 0.5) / screenSize) * 2.0 - 1.0;
  ndc.y = -ndc.y; // Standard Vulkan/Graphics Y orientation

  // Standard near plane depth format
  float4 clipTarget = float4(ndc.x, ndc.y, -1.0, 1.0);

  float4 worldTarget = mul(g_camera.invViewProj, clipTarget);
  worldTarget /= worldTarget.w; // Classic perspective division step

  Ray ray;
  ray.origin = g_camera.position;
  ray.direction = normalize(worldTarget.xyz - ray.origin);

  return ray;
}

float get_start_distance(Ray localRay, float3 volumeSize) {
  float tMin = 0.0;
  float tMax = 1e9;
  float3 volumeOrigin = float3(0, 0, 0); // Ray is already localized

  for (int i = 0; i < 3; i++) {
    if (abs(localRay.direction[i]) < 1e-6) {
      if (localRay.origin[i] <= 0.0 || localRay.origin[i] >= volumeSize[i]) {
        return -1.0;
      }
    } else {
      float ood = 1.0 / localRay.direction[i];
      float t1 = (0.0 - localRay.origin[i]) * ood;
      float t2 = (volumeSize[i] - localRay.origin[i]) * ood;

      float tNear = min(t1, t2);
      float tFar = max(t1, t2);

      tMin = max(tMin, tNear);
      tMax = min(tMax, tFar);

      if (tMin > tMax)
        return -1.0;
    }
  }

  if (tMax < 0.0)
    return -1.0;
  return tMin;
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
  float4 finalColor = float4(0.2, 0.4, 0.6, 1.0); // Default sky bluebackground

  float depth = 1e9; // Start with a very large depth value
  for (int i = 0; i < g_volume.getCount(); i++) {
    VoxelVolume volume = g_volume[i];

    float3 size = float3(volume.size_x, volume.size_y, volume.size_z);

    Ray localRay;
    localRay.direction.x = dot(volume.invRotation[0], ray.direction);
    localRay.direction.y = dot(volume.invRotation[1], ray.direction);
    localRay.direction.z = dot(volume.invRotation[2], ray.direction);
    // localRay.direction = (localRay.direction);

    float3 translatedOrigin = ray.origin - volume.origin;
    localRay.origin.x = dot(volume.invRotation[0], translatedOrigin);
    localRay.origin.y = dot(volume.invRotation[1], translatedOrigin);
    localRay.origin.z = dot(volume.invRotation[2], translatedOrigin);

    // 2. Perform intersection test using the local space ray definitions
    float starting_distance = get_start_distance(localRay, size);
    if (starting_distance < -0.5)
      continue;

    // HitInfo hit = DDATrace(localRay, volume, depth);
    // if (hit.color.a > 0.0) {
    //   float worldDepth = distance(hit.position, ray.origin);
    //   if (worldDepth < depth) {
    //     depth = worldDepth;
    //     finalColor = hit.color;
    //   }
    // }

    float t = starting_distance;
    // float max_dist = t + 500000.0;
    float3 ray_dir = localRay.direction; // Use local ray details now!
    float3 inv_dir = 1.0 / ray_dir;
    float3 tDelta = abs(inv_dir);

    float3 start_pos = localRay.origin + t * ray_dir;
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

    // Run your DDA loop...
    for (int j = 0; j < 100000; j++) {
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

            float3 hitLocal = voxel;
            float3 hitWorld = volume.origin + mul(volume.rotation, hitLocal);

            float worldDepth = distance(hitWorld, ray.origin);
            float depth_shadow = 1.0 / (1.0 + (worldDepth * 0.005));

            if (worldDepth < depth) {
              depth = worldDepth;
              finalColor = float4(float3(r, g, b) * depth_shadow, 1.0);
            }
            break;
          }
        } else {
          // This path can safely break out or be removed now
          break;
        }
      } else {
        // Ray stepped cleanly out of the voxel grid bounding region
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
  g_outputFramebuffer[pixelCoord] = finalColor;
}
