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
  float voxelSize;
  float voxelRenderRadius;
  float voxelTransitionWidth;
  float chunkWorldSize;
  uint chunkTableMask;
  uint chunkCount;
  uint materialCount;
  uint visualSeedLo;
  uint visualSeedHi;
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

struct VoxelChunk {
  int3 coord;
  uint brickOffset;
};

struct VoxelBrick {
  uint kind;
  uint material;
  uint voxelOffset;
  uint _padding;
};

struct VoxelChunkSlot {
  int3 coord;
  uint chunkIndexPlusOne;
};

struct MaterialRenderInfo {
  uint baseColor;
  float variationStrength;
  uint flags;
  uint _padding;
};

struct VoxelHit {
  bool hit;
  float distance;
  float3 position;
  float3 normal;
  int3 voxel;
  uint material;
  uint brickKind;
};

struct HeightfieldHit {
  bool hit;
  float distance;
  float3 position;
  TerrainSample terrain;
  uint lod;
};

uniform CameraUniforms g_camera;
uniform TerrainSettings g_settings;
uniform StructuredBuffer<TerrainLevel> g_levels;
uniform StructuredBuffer<TerrainSample> g_samples;
uniform StructuredBuffer<SparseVoxel> g_overrides;
uniform StructuredBuffer<VoxelChunk> g_voxelChunks;
uniform StructuredBuffer<VoxelBrick> g_voxelBricks;
uniform StructuredBuffer<uint> g_voxelMaterials;
uniform StructuredBuffer<VoxelChunkSlot> g_voxelChunkTable;
uniform StructuredBuffer<MaterialRenderInfo> g_materials;
uniform RWTexture2D<float4> g_outputFramebuffer;

static const uint MATERIAL_FLAG_RESOURCE = 1u;
static const uint BRICK_EMPTY = 0u;
static const uint BRICK_SOLID = 1u;
static const uint BRICK_MIXED = 2u;
static const int CHUNK_SIZE = 32;
static const int BRICK_SIZE = 8;
static const int BRICKS_PER_AXIS = 4;

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

uint hashUint(uint value) {
  value ^= value >> 16;
  value *= 0x7FEB352Du;
  value ^= value >> 15;
  value *= 0x846CA68Bu;
  value ^= value >> 16;
  return value;
}

uint hashVoxel(int3 voxel) {
  return hashUint(uint(voxel.x) * 73856093u ^ uint(voxel.y) * 19349663u ^ uint(voxel.z) * 83492791u);
}

// Explicit floor is required here: signed integer division truncated negative world coordinates on the GPU.
int floorDiv(int value, int divisor) {
  return int(floor(float(value) / float(divisor)));
}

int3 floorDiv3(int3 value, int divisor) {
  return int3(floorDiv(value.x, divisor), floorDiv(value.y, divisor), floorDiv(value.z, divisor));
}

bool lookupChunk(int3 coord, out VoxelChunk chunk) {
  chunk = (VoxelChunk)0;
  if (g_settings.chunkCount == 0 || g_settings.chunkTableMask == 0) return false;
  uint slot = hashVoxel(coord) & g_settings.chunkTableMask;
  for (uint probe = 0; probe < 32; probe++) {
    VoxelChunkSlot candidate = g_voxelChunkTable[slot];
    if (candidate.chunkIndexPlusOne == 0) return false;
    if (all(candidate.coord == coord)) {
      chunk = g_voxelChunks[candidate.chunkIndexPlusOne - 1];
      return true;
    }
    slot = (slot + 1) & g_settings.chunkTableMask;
  }
  return false;
}

bool sampleVoxel(int3 voxel, out uint material, out uint brickKind, out bool resident) {
  material = 0;
  brickKind = BRICK_EMPTY;
  int3 chunkCoord = floorDiv3(voxel, CHUNK_SIZE);
  VoxelChunk chunk;
  resident = lookupChunk(chunkCoord, chunk);
  if (!resident) return false;
  int3 local = voxel - chunkCoord * CHUNK_SIZE;
  int3 brickCoord = local / BRICK_SIZE;
  uint brickIndex = uint(brickCoord.z * BRICKS_PER_AXIS * BRICKS_PER_AXIS + brickCoord.y * BRICKS_PER_AXIS + brickCoord.x);
  VoxelBrick brick = g_voxelBricks[chunk.brickOffset + brickIndex];
  brickKind = brick.kind;
  if (brick.kind == BRICK_EMPTY) return false;
  if (brick.kind == BRICK_SOLID) {
    material = brick.material;
    return material != 0;
  }
  int3 cell = local % BRICK_SIZE;
  uint cellIndex = uint(cell.z * BRICK_SIZE * BRICK_SIZE + cell.y * BRICK_SIZE + cell.x);
  material = g_voxelMaterials[brick.voxelOffset + cellIndex];
  return material != 0;
}

VoxelHit traceVoxels(Ray ray) {
  VoxelHit result = (VoxelHit)0;
  float voxelSize = g_settings.voxelSize;
  int3 voxel = int3(floor(ray.origin / voxelSize));
  int3 step = int3(
    ray.direction.x < 0.0 ? -1 : 1,
    ray.direction.y < 0.0 ? -1 : 1,
    ray.direction.z < 0.0 ? -1 : 1);
  float3 nextBoundary = (float3(voxel) + float3(step.x > 0 ? 1 : 0, step.y > 0 ? 1 : 0, step.z > 0 ? 1 : 0)) * voxelSize;
  float3 delta = float3(
    abs(ray.direction.x) < 1e-7 ? 1e30 : abs(voxelSize / ray.direction.x),
    abs(ray.direction.y) < 1e-7 ? 1e30 : abs(voxelSize / ray.direction.y),
    abs(ray.direction.z) < 1e-7 ? 1e30 : abs(voxelSize / ray.direction.z));
  float3 maximum = float3(
    abs(ray.direction.x) < 1e-7 ? 1e30 : max((nextBoundary.x - ray.origin.x) / ray.direction.x, 0.0),
    abs(ray.direction.y) < 1e-7 ? 1e30 : max((nextBoundary.y - ray.origin.y) / ray.direction.y, 0.0),
    abs(ray.direction.z) < 1e-7 ? 1e30 : max((nextBoundary.z - ray.origin.z) / ray.direction.z, 0.0));
  float distanceAlongRay = 0.0;
  float3 enteredNormal = 0;

  for (uint stepIndex = 0; stepIndex < 512 && distanceAlongRay <= g_settings.voxelRenderRadius; stepIndex++) {
    uint material;
    uint brickKind;
    bool resident;
    if (sampleVoxel(voxel, material, brickKind, resident)) {
      result.hit = true;
      result.distance = distanceAlongRay;
      result.position = ray.origin + ray.direction * distanceAlongRay;
      result.normal = enteredNormal;
      result.voxel = voxel;
      result.material = material;
      result.brickKind = brickKind;
      return result;
    }
    if (maximum.x <= maximum.y && maximum.x <= maximum.z) {
      distanceAlongRay = maximum.x;
      maximum.x += delta.x;
      voxel.x += step.x;
      enteredNormal = float3(-step.x, 0, 0);
    } else if (maximum.y <= maximum.z) {
      distanceAlongRay = maximum.y;
      maximum.y += delta.y;
      voxel.y += step.y;
      enteredNormal = float3(0, -step.y, 0);
    } else {
      distanceAlongRay = maximum.z;
      maximum.z += delta.z;
      voxel.z += step.z;
      enteredNormal = float3(0, 0, -step.z);
    }
  }
  return result;
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
    result.mountainInfluence = lerp(lerp(s00.mountainInfluence, s10.mountainInfluence, amount.x), lerp(s01.mountainInfluence, s11.mountainInfluence, amount.x), amount.y);
    uint2 materialCoord = uint2(amount.x < 0.5 ? baseCoord.x : nextCoord.x, amount.y < 0.5 ? baseCoord.y : nextCoord.y);
    TerrainSample materialSample = g_samples[level.sampleOffset + materialCoord.y * row + materialCoord.x];
    result.material = materialSample.material;
    result.packedColor = materialSample.packedColor;
    selectedLod = lod;
    return true;
  }
  return false;
}

HeightfieldHit traceHeightfield(Ray ray, float startDistance) {
  HeightfieldHit result = (HeightfieldHit)0;
  float distanceAlongRay = max(startDistance, g_settings.modificationVoxelSize * 0.5);
  float previousDistance = distanceAlongRay;
  for (uint stepIndex = 0; stepIndex < 640 && distanceAlongRay < g_settings.maxDistance; stepIndex++) {
    float3 position = ray.origin + ray.direction * distanceAlongRay;
    TerrainSample terrain;
    uint lod;
    if (length(position.xz) <= g_settings.worldRadius && sampleTerrain(position.xz, distanceAlongRay, terrain, lod) && position.y <= terrain.height) {
      float low = previousDistance;
      float high = distanceAlongRay;
      for (uint refine = 0; refine < 7; refine++) {
        float middle = (low + high) * 0.5;
        float3 middlePosition = ray.origin + ray.direction * middle;
        TerrainSample middleTerrain;
        uint middleLod;
        if (sampleTerrain(middlePosition.xz, middle, middleTerrain, middleLod) && middlePosition.y <= middleTerrain.height) {
          high = middle;
          terrain = middleTerrain;
          lod = middleLod;
        } else {
          low = middle;
        }
      }
      result.hit = true;
      result.distance = high;
      result.position = ray.origin + ray.direction * high;
      result.terrain = terrain;
      result.lod = lod;
      return result;
    }
    uint marchLod = min(desiredLod(distanceAlongRay), g_settings.levelCount - 1);
    float maxStep = g_levels[marchLod].spacing * 0.5;
    previousDistance = distanceAlongRay;
    distanceAlongRay += max(g_settings.modificationVoxelSize * 0.45, min(maxStep, max(distanceAlongRay * 0.02, 0.2)));
  }
  return result;
}

bool lookupOverride(int3 voxel, out SparseVoxel result) {
  result = (SparseVoxel)0;
  if (g_settings.overrideTableMask == 0) return false;
  float3 worldPosition = (float3(voxel) + 0.5) * g_settings.modificationVoxelSize;
  if (any(worldPosition < g_settings.overrideBoundsMin) || any(worldPosition > g_settings.overrideBoundsMax)) return false;
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

float3 unpackColor(uint packedColor) {
  return float3(float(packedColor & 0xFFu), float((packedColor >> 8) & 0xFFu), float((packedColor >> 16) & 0xFFu)) / 255.0;
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
    float3 c00 = unpackColor(g_samples[level.sampleOffset + baseCoord.y * row + baseCoord.x].packedColor);
    float3 c10 = unpackColor(g_samples[level.sampleOffset + baseCoord.y * row + nextCoord.x].packedColor);
    float3 c01 = unpackColor(g_samples[level.sampleOffset + nextCoord.y * row + baseCoord.x].packedColor);
    float3 c11 = unpackColor(g_samples[level.sampleOffset + nextCoord.y * row + nextCoord.x].packedColor);
    return lerp(lerp(c00, c10, amount.x), lerp(c01, c11, amount.x), amount.y);
  }
  return float3(0.6, 0.2, 0.6);
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

float stableVariation(int3 voxel, uint material, float strength) {
  uint seed = g_settings.visualSeedLo ^ (g_settings.visualSeedHi * 0x9E3779B9u) ^ material * 0x85EBCA6Bu;
  float coarse = float(hashVoxel(floorDiv3(voxel, 8)) ^ seed) / 4294967295.0;
  float fine = float(hashVoxel(voxel) ^ hashUint(seed)) / 4294967295.0;
  return 1.0 + (coarse - 0.5) * strength * 0.9 + (fine - 0.5) * strength * 0.45;
}

float gridEdge(float3 position, float3 normal, float size, float width) {
  float3 local = frac(position / size);
  float3 edge = min(local, 1.0 - local);
  float tangentEdge = abs(normal.x) > 0.5 ? min(edge.y, edge.z) : (abs(normal.y) > 0.5 ? min(edge.x, edge.z) : min(edge.x, edge.y));
  return 1.0 - smoothstep(width, width * 1.8, tangentEdge);
}

float3 voxelColor(VoxelHit hit) {
  uint materialIndex = min(hit.material, max(g_settings.materialCount, 1u) - 1);
  MaterialRenderInfo info = g_materials[materialIndex];
  float3 color = unpackColor(info.baseColor) * stableVariation(hit.voxel, hit.material, info.variationStrength);
  float voxelEdge = gridEdge(hit.position, hit.normal, g_settings.voxelSize, 0.035);
  color *= lerp(1.0, 0.48, voxelEdge);
  if (g_settings.debugMode == 2) return unpackColor(info.baseColor);
  if (g_settings.debugMode == 6) {
    SparseVoxel modified;
    return lookupOverride(hit.voxel, modified) ? float3(1.0, 0.05, 0.85) : color * 0.18;
  }
  if (g_settings.debugMode == 7) return lerp(color * 0.28, float3(0.05, 0.95, 1.0), voxelEdge);
  if (g_settings.debugMode == 8) {
    int3 chunk = floorDiv3(hit.voxel, CHUNK_SIZE);
    uint chunkHash = hashVoxel(chunk);
    float3 chunkColor = float3(
      float((chunkHash >> 0) & 0xFFu),
      float((chunkHash >> 8) & 0xFFu),
      float((chunkHash >> 16) & 0xFFu)
    ) / 255.0;
    chunkColor = 0.18 + chunkColor * 0.72;
    float edge = gridEdge(hit.position, hit.normal, g_settings.voxelSize * CHUNK_SIZE, 0.018);
    return lerp(chunkColor, float3(1.0, 0.05, 0.02), edge);
  }
  if (g_settings.debugMode == 9) {
    float edge = gridEdge(hit.position, hit.normal, g_settings.voxelSize * BRICK_SIZE, 0.028);
    return lerp(color * 0.25, float3(0.1, 1.0, 0.3), edge);
  }
  if (g_settings.debugMode == 10) {
    if (hit.brickKind == BRICK_SOLID) return float3(0.1, 0.35, 1.0);
    if (hit.brickKind == BRICK_MIXED) return float3(1.0, 0.25, 0.05);
    return float3(0.05, 0.05, 0.05);
  }
  if (g_settings.debugMode == 11) return (info.flags & MATERIAL_FLAG_RESOURCE) != 0 ? float3(1.0, 0.8, 0.05) : color * 0.12;
  if (g_settings.debugMode == 12) return color;
  if (g_settings.debugMode == 13) return float3(0.1, 0.9, 0.9);
  return color;
}

float3 heightfieldColor(HeightfieldHit hit) {
  float3 surface = terrainSurfaceColor(hit.position.xz, hit.distance);
  if (g_settings.debugMode == 1) {
    if (hit.lod == 0) return float3(0.12, 0.9, 0.25);
    if (hit.lod == 1) return float3(0.95, 0.75, 0.08);
    return float3(0.18, 0.45, 1.0);
  }
  if (g_settings.debugMode == 2) return surface;
  if (g_settings.debugMode == 3) return hit.terrain.mountainInfluence.xxx;
  if (g_settings.debugMode == 4) {
    TerrainLevel level = g_levels[hit.lod];
    float tileSize = level.spacing * 16.0;
    float2 grid = abs(frac((hit.position.xz - level.origin) / tileSize + 0.5) - 0.5);
    return min(grid.x, grid.y) < 0.025 ? float3(0.04, 0.95, 0.95) : surface * 0.35;
  }
  if (g_settings.debugMode == 5) {
    float ringDistance = abs(length(hit.position.xz) - g_settings.debugRingRadius);
    return ringDistance < 80.0 ? float3(1.0, 0.05, 0.05) : surface * 0.35;
  }
  if (g_settings.debugMode == 12) return surface * 0.18;
  if (g_settings.debugMode == 13) return float3(0.95, 0.58, 0.08);
  if (g_settings.debugMode >= 6 && g_settings.debugMode <= 11) return surface * 0.12;
  return surface;
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
  VoxelHit voxelHit = traceVoxels(ray);
  float transitionStart = max(g_settings.voxelRenderRadius - g_settings.voxelTransitionWidth, 0.0);
  HeightfieldHit terrainHit = traceHeightfield(ray, 0.0);
  if (g_settings.debugMode == 14) voxelHit.hit = false;
  if (g_settings.debugMode == 15) terrainHit.hit = false;
  float representationBlend = 0.0;
  bool terrainResident = false;
  if (terrainHit.hit) {
    uint terrainMaterial, terrainBrickKind;
    int3 terrainVoxel = int3(floor(terrainHit.position / g_settings.voxelSize));
    sampleVoxel(terrainVoxel, terrainMaterial, terrainBrickKind, terrainResident);
  }
  if (voxelHit.hit && terrainHit.hit) {
    if (!terrainResident) {
      voxelHit.hit = false;
    } else {
      float horizontalDistance = length(terrainHit.position.xz - g_camera.position.xz);
      representationBlend = saturate((horizontalDistance - transitionStart) / max(g_settings.voxelTransitionWidth, 0.001));
    }
  }

  bool hit = voxelHit.hit || terrainHit.hit;
  float distanceAlongRay = voxelHit.hit ? voxelHit.distance : terrainHit.distance;
  float3 color = sky;
  float3 normal = float3(0, 1, 0);
  if (hit) {
    if (voxelHit.hit && terrainHit.hit) {
      color = lerp(voxelColor(voxelHit), heightfieldColor(terrainHit), representationBlend);
      float3 voxelNormal = length(voxelHit.normal) > 0.0 ? voxelHit.normal : float3(0, 1, 0);
      float3 heightfieldNormal = terrainNormal(terrainHit.position, terrainHit.distance, terrainHit.lod);
      normal = normalize(lerp(voxelNormal, heightfieldNormal, representationBlend));
      distanceAlongRay = lerp(voxelHit.distance, terrainHit.distance, representationBlend);
    } else if (voxelHit.hit) {
      color = voxelColor(voxelHit);
      normal = voxelHit.normal;
    } else {
      color = heightfieldColor(terrainHit);
      normal = terrainNormal(terrainHit.position, terrainHit.distance, terrainHit.lod);
      distanceAlongRay = terrainHit.distance;
    }
    if (g_settings.debugMode == 0) {
      float3 sunDirection = normalize(float3(0.45, 0.82, 0.35));
      float diffuse = 0.28 + 0.72 * saturate(dot(normal, sunDirection));
      float distanceFog = saturate(distanceAlongRay / g_settings.maxDistance);
      color *= diffuse;
      color = lerp(color, sky, distanceFog * distanceFog * 0.72);
    }
  }

  float2 crosshair = abs(float2(pixelCoord) - float2(width, height) * 0.5);
  if ((crosshair.x < 1.0 && crosshair.y < 6.0) || (crosshair.y < 1.0 && crosshair.x < 6.0)) {
    color = lerp(color, float3(0.95, 0.95, 0.95), 0.85);
  }
  g_outputFramebuffer[pixelCoord] = float4(color, 1.0);
}
