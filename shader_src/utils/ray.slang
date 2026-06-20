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
  public int3 voxelCoord;
  public uint packedColor;
};

void reset_hit_info(float maxDistance, out HitInfo hit) {
  hit.position = float3(0, 0, 0);
  hit.color = float4(0, 0, 0, 0);
  hit.depth = maxDistance;
  hit.voxelCoord = int3(-1, -1, -1);
  hit.packedColor = 0;
}

public bool IntersectRayAABB(Ray ray, float3 boundsMin, float3 boundsMax,
                             out float tEnter, out float tExit) {
  tEnter = 0.0;
  tExit = 1e30;

  for (int axis = 0; axis < 3; axis++) {
    float dir = ray.direction[axis];
    float origin = ray.origin[axis];

    if (abs(dir) < 1e-6) {
      if (origin < boundsMin[axis] || origin > boundsMax[axis]) {
        return false;
      }
      continue;
    }

    float invDir = 1.0 / dir;
    float t1 = (boundsMin[axis] - origin) * invDir;
    float t2 = (boundsMax[axis] - origin) * invDir;

    float tNear = min(t1, t2);
    float tFar = max(t1, t2);

    tEnter = max(tEnter, tNear);
    tExit = min(tExit, tFar);

    if (tEnter > tExit) {
      return false;
    }
  }

  return tExit >= 0.0;
}

public Ray to_local_ray(Ray worldRay, VoxelVolume volume) {
  Ray localRay;
  float3 translatedOrigin = worldRay.origin - volume.origin;

  localRay.origin = float3(dot(volume.invRotation[0], translatedOrigin),
                           dot(volume.invRotation[1], translatedOrigin),
                           dot(volume.invRotation[2], translatedOrigin));

  localRay.direction = float3(dot(volume.invRotation[0], worldRay.direction),
                              dot(volume.invRotation[1], worldRay.direction),
                              dot(volume.invRotation[2], worldRay.direction));

  return localRay;
}

public bool TraceVoxelVolumeLocal(Ray localRay, VoxelVolume volume,
                                  float maxDistance, out HitInfo hit) {
  reset_hit_info(maxDistance, hit);

  float3 volumeSize = float3(volume.size_x, volume.size_y, volume.size_z);
  float tEnter, tExit;
  if (!IntersectRayAABB(localRay, float3(0, 0, 0), volumeSize, tEnter, tExit)) {
    return false;
  }

  float tLimit = min(tExit, maxDistance);
  float t = max(tEnter, 0.0);
  float3 rayDir = localRay.direction;
  float3 invDir = 1.0 / rayDir;
  float3 tDelta = abs(invDir);

  float3 startPos = localRay.origin + rayDir * t;
  int3 voxel = int3(floor(startPos + (rayDir * 0.0001)));
  int3 step = int3(rayDir.x > 0 ? 1 : (rayDir.x < 0 ? -1 : 0),
                   rayDir.y > 0 ? 1 : (rayDir.y < 0 ? -1 : 0),
                   rayDir.z > 0 ? 1 : (rayDir.z < 0 ? -1 : 0));

  float3 nextBoundary = float3(float(voxel.x + (step.x > 0 ? 1 : 0)),
                               float(voxel.y + (step.y > 0 ? 1 : 0)),
                               float(voxel.z + (step.z > 0 ? 1 : 0)));

  float3 tMax;
  tMax.x =
      (step.x != 0) ? (nextBoundary.x - localRay.origin.x) * invDir.x : 1e30;
  tMax.y =
      (step.y != 0) ? (nextBoundary.y - localRay.origin.y) * invDir.y : 1e30;
  tMax.z =
      (step.z != 0) ? (nextBoundary.z - localRay.origin.z) * invDir.z : 1e30;

  uint maxVoxels = volume.size_x * volume.size_y * volume.size_z;

  for (int i = 0; i < 100000 && t <= tLimit; i++) {
    if (voxel.x < 0 || voxel.y < 0 || voxel.z < 0 ||
        voxel.x >= (int)volume.size_x || voxel.y >= (int)volume.size_y ||
        voxel.z >= (int)volume.size_z) {
      break;
    }

    uint3 voxelCoord = uint3(voxel);
    uint flatIndex = voxelCoord.x + (voxelCoord.y * volume.size_x) +
                     (voxelCoord.z * volume.size_x * volume.size_y);

    if (flatIndex >= maxVoxels) {
      break;
    }

    uint packed = volume.data[flatIndex].color;
    if (packed != 0) {
      hit.position = localRay.origin + rayDir * t;
      hit.depth = t;
      hit.voxelCoord = voxel;
      hit.packedColor = packed;

      float r = (float)((packed >> 24) & 0xFF) / 255.0;
      float g = (float)((packed >> 16) & 0xFF) / 255.0;
      float b = (float)((packed >> 8) & 0xFF) / 255.0;
      hit.color = float4(r, g, b, 1.0);
      return true;
    }

    if (tMax.x < tMax.y) {
      if (tMax.x < tMax.z) {
        t = tMax.x;
        tMax.x += tDelta.x;
        voxel.x += step.x;
      } else {
        t = tMax.z;
        tMax.z += tDelta.z;
        voxel.z += step.z;
      }
    } else {
      if (tMax.y < tMax.z) {
        t = tMax.y;
        tMax.y += tDelta.y;
        voxel.y += step.y;
      } else {
        t = tMax.z;
        tMax.z += tDelta.z;
        voxel.z += step.z;
      }
    }
  }

  return false;
}

public bool TraceVoxelVolume(Ray worldRay, VoxelVolume volume,
                             float maxDistance, out HitInfo hit) {
  Ray localRay = to_local_ray(worldRay, volume);
  HitInfo localHit;

  if (!TraceVoxelVolumeLocal(localRay, volume, maxDistance, localHit)) {
    reset_hit_info(maxDistance, hit);
    return false;
  }

  hit = localHit;
  hit.position = volume.origin + mul(volume.rotation, localHit.position);
  hit.depth = distance(hit.position, worldRay.origin);
  return true;
}

public HitInfo DDATrace(Ray ray, VoxelVolume volume, float lastDepth) {
  HitInfo hit;
  if (TraceVoxelVolume(ray, volume, lastDepth, hit)) {
    return hit;
  }

  reset_hit_info(lastDepth, hit);
  return hit;
}
