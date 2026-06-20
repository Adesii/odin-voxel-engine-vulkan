module Ray;
import voxel_types;

public struct Ray {
  public float3 origin;
  public float3 direction;
}

public struct HitInfo {
  public float3 position;
  public float4 color;
  public float depth;
};

public HitInfo DDATrace(Ray ray, VoxelVolume volume, float lastDepth) {
  float3 ray_dir = normalize(ray.direction);
  float3 inv_dir = 1.0 / ray_dir;
  float3 tDelta = abs(inv_dir);
  float3 tMin = (volume.origin - ray.origin) * inv_dir;
  float3 tMax =
      (volume.origin + float3(volume.size_x, volume.size_y, volume.size_z) -
       ray.origin) *
      inv_dir;

  float3 t1 = min(tMin, tMax);
  float3 t2 = max(tMin, tMax);

  float tNear = max(max(t1.x, t1.y), t1.z);
  float tFar = min(min(t2.x, t2.y), t2.z);

  if (tNear > tFar || tFar < 0.0) {
    HitInfo noHit;
    noHit.color = float4(0, 0, 0, 0);
    return noHit; // No intersection
  }

  float t = max(tNear, 0.0);
  float3 voxel =
      floor((ray.origin + ray_dir * t - volume.origin) / float3(1.0, 1.0, 1.0));

  float depth = lastDepth;
  float4 finalColor = float4(0, 0, 0, 0);

  while (t < tFar) {
    if (voxel.x >= 0 && voxel.x < volume.size_x && voxel.y >= 0 &&
        voxel.y < volume.size_y && voxel.z >= 0 && voxel.z < volume.size_z) {

      uint voxelCoordX = uint(voxel.x);
      uint voxelCoordY = uint(voxel.y);
      uint voxelCoordZ = uint(voxel.z);

      uint flatIndex = voxelCoordX + (voxelCoordY * volume.size_x) +
                       (voxelCoordZ * volume.size_x * volume.size_y);
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

          if (worldDepth < depth) {
            depth = worldDepth;
            finalColor = float4(float3(r, g, b), 1.0);
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
  HitInfo hitInfo;
  hitInfo.position = ray.origin + ray_dir * depth;
  hitInfo.color = finalColor;
  hitInfo.depth = depth;
  return hitInfo;
}

public bool TraceVoxelVolume(Ray ray, VoxelVolume volume, float maxDistance,
                             out HitInfo hit) {
  hit.depth = maxDistance;
  hit.color = float4(0, 0, 0, 0);
  hit.position = float3(0, 0, 0);

  float t = 0.0;

  float3 rayDir = ray.direction;

  float3 invDir = 1.0 / rayDir;
  float3 tDelta = abs(invDir);

  // Starting position in world space
  float3 pos = ray.origin + rayDir * t;

  // Transform into voxel-local space (if needed)
  float3 localPos = mul(volume.invRotation, (pos - volume.origin));

  int3 voxel = int3(floor(localPos));

  // Initial tMax setup
  float3 tMax;

  tMax.x =
      (rayDir.x != 0)
          ? ((float(voxel.x + (rayDir.x > 0 ? 1 : 0)) - localPos.x) * invDir.x)
          : 1e30;

  tMax.y =
      (rayDir.y != 0)
          ? ((float(voxel.y + (rayDir.y > 0 ? 1 : 0)) - localPos.y) * invDir.y)
          : 1e30;

  tMax.z =
      (rayDir.z != 0)
          ? ((float(voxel.z + (rayDir.z > 0 ? 1 : 0)) - localPos.z) * invDir.z)
          : 1e30;

  // DDA loop
  for (int i = 0; i < 100000; i++) {
    // Bounds check
    if (voxel.x < 0 || voxel.y < 0 || voxel.z < 0 ||
        voxel.x >= (int)volume.size_x || voxel.y >= (int)volume.size_y ||
        voxel.z >= (int)volume.size_z) {
      return false;
    }

    uint flatIndex = voxel.x + voxel.y * volume.size_x +
                     voxel.z * volume.size_x * volume.size_y;

    uint maxVoxels = volume.size_x * volume.size_y * volume.size_z;

    if (flatIndex >= maxVoxels)
      return false;

    uint packed = volume.data[flatIndex].color;

    // HIT
    if (packed != 0) {
      float r = ((packed >> 24) & 0xFF) / 255.0;
      float g = ((packed >> 16) & 0xFF) / 255.0;
      float b = ((packed >> 8) & 0xFF) / 255.0;

      float3 hitLocal = float3(voxel);
      float3 hitWorld = volume.origin + mul(volume.rotation, hitLocal);

      float dist = distance(hitWorld, ray.origin);

      hit.position = hitWorld;
      hit.depth = dist;
      hit.color = float4(r, g, b, 1.0);

      return true;
    }

    // Step DDA
    if (tMax.x < tMax.y) {
      if (tMax.x < tMax.z) {
        t += tMax.x;
        tMax.x += tDelta.x;
        voxel.x += (rayDir.x > 0 ? 1 : -1);
      } else {
        t += tMax.z;
        tMax.z += tDelta.z;
        voxel.z += (rayDir.z > 0 ? 1 : -1);
      }
    } else {
      if (tMax.y < tMax.z) {
        t += tMax.y;
        tMax.y += tDelta.y;
        voxel.y += (rayDir.y > 0 ? 1 : -1);
      } else {
        t += tMax.z;
        tMax.z += tDelta.z;
        voxel.z += (rayDir.z > 0 ? 1 : -1);
      }
    }

    if (t > maxDistance)
      break;
  }

  return false;
}
