import utils.camera;
import utils.ray;

struct TerrainSettings {
  float worldRadius;
  float maxDistance;
  float modificationVoxelSize;
  uint levelCount;
  uint overrideTableMask;
  uint debugMode;
  float debugRingRadius;
  float _padding0;
  float4 lodDistances;
  float3 overrideBoundsMin;
  float _padding1;
  float3 overrideBoundsMax;
  float _padding2;
};

struct TerrainLevel {
  float2 origin;
  float spacing;
  uint sampleCount;
  uint sampleOffset;
  float extent;
  uint lod;
  uint _padding;
};

struct TerrainSample {
  float height;
  float mountainInfluence;
  uint material;
  uint packedColor;
};

struct SparseVoxel {
  int3 voxel;
  uint state;
  uint material;
  uint3 _padding;
};

uniform CameraUniforms g_camera;
uniform TerrainSettings g_settings;
uniform StructuredBuffer<TerrainLevel> g_levels;
uniform StructuredBuffer<TerrainSample> g_samples;
uniform StructuredBuffer<SparseVoxel> g_overrides;
uniform RWTexture2D<float4> g_outputFramebuffer;

Ray generateCameraRay(uint2 pixelCoord, float2 screenSize) {
  float2 ndc = ((float2(pixelCoord) + 0.5) / screenSize) * 2.0 - 1.0;
  ndc.y = -ndc.y;
  float4 worldTarget = mul(g_camera.invViewProj, float4(ndc.x, ndc.y, -1.0, 1.0));
  worldTarget /= worldTarget.w;
  Ray ray;
  ray.origin = g_camera.position;
  ray.direction = normalize(worldTarget.xyz - ray.origin);
  return ray;
}

uint desiredLod(float distanceFromCamera) {
  if (distanceFromCamera < g_settings.lodDistances.x) return 0;
  if (distanceFromCamera < g_settings.lodDistances.y) return 1;
  return 2;
}

bool sampleTerrain(float2 worldPosition, float distanceFromCamera, out TerrainSample result, out uint selectedLod) {
  result = (TerrainSample)0;
  selectedLod = 0;
  uint firstLod = min(desiredLod(distanceFromCamera), g_settings.levelCount - 1);
  for (uint lod = firstLod; lod < g_settings.levelCount; lod++) {
    TerrainLevel level = g_levels[lod];
    float2 local = (worldPosition - level.origin) / level.spacing;
    if (any(local < 0.0) || any(local > float(level.sampleCount - 1))) continue;
    uint2 baseCoord = uint2(floor(local));
    uint2 nextCoord = min(baseCoord + 1, level.sampleCount - 1);
    float2 amount = frac(local);
    uint row = level.sampleCount;
    TerrainSample s00 = g_samples[level.sampleOffset + baseCoord.y * row + baseCoord.x];
    TerrainSample s10 = g_samples[level.sampleOffset + baseCoord.y * row + nextCoord.x];
    TerrainSample s01 = g_samples[level.sampleOffset + nextCoord.y * row + baseCoord.x];
    TerrainSample s11 = g_samples[level.sampleOffset + nextCoord.y * row + nextCoord.x];
    result.height = lerp(lerp(s00.height, s10.height, amount.x), lerp(s01.height, s11.height, amount.x), amount.y);
    result.mountainInfluence = lerp(
      lerp(s00.mountainInfluence, s10.mountainInfluence, amount.x),
      lerp(s01.mountainInfluence, s11.mountainInfluence, amount.x),
      amount.y);
    uint2 materialCoord = uint2(amount.x < 0.5 ? baseCoord.x : nextCoord.x, amount.y < 0.5 ? baseCoord.y : nextCoord.y);
    TerrainSample materialSample = g_samples[level.sampleOffset + materialCoord.y * row + materialCoord.x];
    result.material = materialSample.material;
    result.packedColor = materialSample.packedColor;
    selectedLod = lod;
    return true;
  }
  return false;
}

uint hashVoxel(int3 voxel) {
  return (uint(voxel.x) * 73856093u) ^ (uint(voxel.y) * 19349663u) ^ (uint(voxel.z) * 83492791u);
}

bool lookupOverride(float3 worldPosition, out SparseVoxel result) {
  result = (SparseVoxel)0;
  if (g_settings.overrideTableMask == 0 ||
      any(worldPosition < g_settings.overrideBoundsMin) ||
      any(worldPosition > g_settings.overrideBoundsMax)) {
    return false;
  }
  int3 voxel = int3(floor(worldPosition / g_settings.modificationVoxelSize));
  uint slot = hashVoxel(voxel) & g_settings.overrideTableMask;
  for (uint probe = 0; probe < 32; probe++) {
    SparseVoxel candidate = g_overrides[slot];
    if (candidate.state == 0) return false;
    if (all(candidate.voxel == voxel)) {
      result = candidate;
      return true;
    }
    slot = (slot + 1) & g_settings.overrideTableMask;
  }
  return false;
}

bool pointIsSolid(float3 position, float distanceFromCamera, out TerrainSample terrain, out uint lod, out SparseVoxel overrideVoxel, out bool overridden) {
  terrain = (TerrainSample)0;
  lod = 0;
  overrideVoxel = (SparseVoxel)0;
  overridden = false;
  overridden = lookupOverride(position, overrideVoxel);
  if (overridden) {
    if (overrideVoxel.state == 1) return false;
    if (overrideVoxel.state == 2) {
      terrain = (TerrainSample)0;
      lod = desiredLod(distanceFromCamera);
      return true;
    }
  }
  if (length(position.xz) > g_settings.worldRadius) return false;
  if (!sampleTerrain(position.xz, distanceFromCamera, terrain, lod)) return false;
  return position.y <= terrain.height;
}

float3 unpackTerrainColor(uint packedColor) {
  return float3(
    float(packedColor & 0xFFu),
    float((packedColor >> 8) & 0xFFu),
    float((packedColor >> 16) & 0xFFu)) / 255.0;
}

float3 terrainSurfaceColor(float2 worldPosition, float distanceFromCamera) {
  uint firstLod = min(desiredLod(distanceFromCamera), g_settings.levelCount - 1);
  for (uint lod = firstLod; lod < g_settings.levelCount; lod++) {
    TerrainLevel level = g_levels[lod];
    float2 local = (worldPosition - level.origin) / level.spacing;
    if (any(local < 0.0) || any(local > float(level.sampleCount - 1))) continue;
    uint2 baseCoord = uint2(floor(local));
    uint2 nextCoord = min(baseCoord + 1, level.sampleCount - 1);
    float2 amount = frac(local);
    uint row = level.sampleCount;
    float3 c00 = unpackTerrainColor(g_samples[level.sampleOffset + baseCoord.y * row + baseCoord.x].packedColor);
    float3 c10 = unpackTerrainColor(g_samples[level.sampleOffset + baseCoord.y * row + nextCoord.x].packedColor);
    float3 c01 = unpackTerrainColor(g_samples[level.sampleOffset + nextCoord.y * row + baseCoord.x].packedColor);
    float3 c11 = unpackTerrainColor(g_samples[level.sampleOffset + nextCoord.y * row + nextCoord.x].packedColor);
    return lerp(lerp(c00, c10, amount.x), lerp(c01, c11, amount.x), amount.y);
  }
  return float3(0.6, 0.2, 0.6);
}

float3 debugColor(float3 hitPosition, float distanceFromCamera, TerrainSample terrain, uint lod, bool overridden, SparseVoxel overrideVoxel) {
  float3 surfaceColor = overridden ? float3(0.62, 0.48, 0.24) : terrainSurfaceColor(hitPosition.xz, distanceFromCamera);
  if (g_settings.debugMode == 1) {
    if (lod == 0) return float3(0.12, 0.9, 0.25);
    if (lod == 1) return float3(0.95, 0.75, 0.08);
    return float3(0.18, 0.45, 1.0);
  }
  if (g_settings.debugMode == 2) return surfaceColor;
  if (g_settings.debugMode == 3) return terrain.mountainInfluence.xxx;
  if (g_settings.debugMode == 4) {
    TerrainLevel level = g_levels[lod];
    float tileSize = level.spacing * 16.0;
    float2 grid = abs(frac((hitPosition.xz - level.origin) / tileSize + 0.5) - 0.5);
    return min(grid.x, grid.y) < 0.025 ? float3(0.04, 0.95, 0.95) : surfaceColor * 0.35;
  }
  if (g_settings.debugMode == 5) {
    float ringDistance = abs(length(hitPosition.xz) - g_settings.debugRingRadius);
    return ringDistance < 80.0 ? float3(1.0, 0.05, 0.05) : surfaceColor * 0.35;
  }
  if (g_settings.debugMode == 6) {
    if (overridden) return overrideVoxel.state == 2 ? float3(1.0, 0.05, 0.8) : float3(0.05, 0.9, 1.0);
    return surfaceColor * 0.22;
  }
  return surfaceColor;
}

float3 terrainNormal(float3 position, float distanceFromCamera, uint lod) {
  TerrainLevel level = g_levels[lod];
  float spacing = max(level.spacing, 1.0);
  TerrainSample left, right, back, front;
  uint ignored;
  bool leftOk = sampleTerrain(position.xz - float2(spacing, 0), distanceFromCamera, left, ignored);
  bool rightOk = sampleTerrain(position.xz + float2(spacing, 0), distanceFromCamera, right, ignored);
  bool backOk = sampleTerrain(position.xz - float2(0, spacing), distanceFromCamera, back, ignored);
  bool frontOk = sampleTerrain(position.xz + float2(0, spacing), distanceFromCamera, front, ignored);
  if (!(leftOk && rightOk && backOk && frontOk)) return float3(0, 1, 0);
  return normalize(float3(left.height - right.height, spacing * 2.0, back.height - front.height));
}

[shader("compute")]
[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID: SV_DispatchThreadID) {
  uint width, height;
  g_outputFramebuffer.GetDimensions(width, height);
  uint2 pixelCoord = dispatchThreadID.xy;
  if (pixelCoord.x >= width || pixelCoord.y >= height) return;

  Ray ray = generateCameraRay(pixelCoord, float2(width, height));
  float3 sky = lerp(float3(0.13, 0.18, 0.24), float3(0.36, 0.48, 0.60), saturate(ray.direction.y * 0.5 + 0.5));
  float3 finalColor = sky;
  float distanceAlongRay = g_settings.modificationVoxelSize * 0.5;
  float previousDistance = 0.0;
  float3 hitPosition = 0;
  TerrainSample hitTerrain = (TerrainSample)0;
  SparseVoxel hitOverride = (SparseVoxel)0;
  uint hitLod = 0;
  bool hitWasOverride = false;
  bool hit = false;

  for (uint stepIndex = 0; stepIndex < 640 && distanceAlongRay < g_settings.maxDistance; stepIndex++) {
    float3 position = ray.origin + ray.direction * distanceAlongRay;
    TerrainSample terrain;
    SparseVoxel overrideVoxel;
    uint lod;
    bool overridden;
    if (pointIsSolid(position, distanceAlongRay, terrain, lod, overrideVoxel, overridden)) {
      float low = previousDistance;
      float high = distanceAlongRay;
      for (uint refine = 0; refine < 7; refine++) {
        float middle = (low + high) * 0.5;
        TerrainSample middleTerrain;
        SparseVoxel middleOverride;
        uint middleLod;
        bool middleOverridden;
        if (pointIsSolid(ray.origin + ray.direction * middle, middle, middleTerrain, middleLod, middleOverride, middleOverridden)) {
          high = middle;
          terrain = middleTerrain;
          overrideVoxel = middleOverride;
          lod = middleLod;
          overridden = middleOverridden;
        } else {
          low = middle;
        }
      }
      distanceAlongRay = high;
      hitPosition = ray.origin + ray.direction * high;
      hitTerrain = terrain;
      hitOverride = overrideVoxel;
      hitLod = lod;
      hitWasOverride = overridden;
      hit = true;
      break;
    }
    uint marchLod = min(desiredLod(distanceAlongRay), g_settings.levelCount - 1);
    float maxStep = g_levels[marchLod].spacing * 0.5;
    previousDistance = distanceAlongRay;
    distanceAlongRay += max(g_settings.modificationVoxelSize * 0.45, min(maxStep, distanceAlongRay * 0.02));
  }

  if (hit) {
    float3 color = debugColor(hitPosition, distanceAlongRay, hitTerrain, hitLod, hitWasOverride, hitOverride);
    if (g_settings.debugMode == 0) {
      float3 normal = hitWasOverride ? float3(0, 1, 0) : terrainNormal(hitPosition, distanceAlongRay, hitLod);
      float3 sunDirection = normalize(float3(0.45, 0.82, 0.35));
      float diffuse = 0.28 + 0.72 * saturate(dot(normal, sunDirection));
      float distanceFog = saturate(distanceAlongRay / g_settings.maxDistance);
      color *= diffuse;
      color = lerp(color, sky, distanceFog * distanceFog * 0.72);
    }
    finalColor = color;
  }

  g_outputFramebuffer[pixelCoord] = float4(finalColor, 1.0);
}
