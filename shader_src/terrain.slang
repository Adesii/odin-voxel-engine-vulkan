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
  uint terrainMaterialOffset;
  uint terrainMaterialCount;
  uint visualSeedLo;
  uint visualSeedHi;
  float4 lodDistances;
  float4 virtualVoxelSizes;
  float4 verticalSteps;
  float3 overrideBoundsMin;
  uint statsSampleStride;
  float3 overrideBoundsMax;
  float heightfieldTransitionWidth;
  uint terrainBackend;
  uint3 _padding;
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
  uint _padding;
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
  uint cellVisits;
};

struct HeightfieldHit {
  bool hit;
  float distance;
  float3 position;
  float3 normal;
  TerrainSample terrain;
  uint lod;
  int2 cell;
  float cellSize;
  float quantizedHeight;
  uint traversedCells;
  uint4 lodCellVisits;
};

struct TerrainTraversalStats {
  uint sampledRays;
  uint heightfieldCellVisits;
  uint maxHeightfieldCellVisits;
  uint heightfieldHits;
  uint heightfieldHitDistanceMeters;
  uint lod0Hits;
  uint lod1Hits;
  uint lod2Hits;
  uint lod0CellVisits;
  uint lod1CellVisits;
  uint lod2CellVisits;
  uint lod0TraversedRays;
  uint lod1TraversedRays;
  uint lod2TraversedRays;
  uint voxelOnlyHits;
  uint heightfieldOnlyHits;
  uint blendedHits;
  uint missedRays;
  uint voxelCellVisits;
  uint maxVoxelCellVisits;
  uint2 _padding;
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
uniform RWStructuredBuffer<TerrainTraversalStats> g_traversalStats;
uniform RWTexture2D<float> g_outputLinearDepth;

static const uint MATERIAL_FLAG_RESOURCE = 1u;
static const uint BRICK_EMPTY = 0u;
static const uint BRICK_SOLID = 1u;
static const uint BRICK_MIXED = 2u;
static const int CHUNK_SIZE = 32;
static const int BRICK_SIZE = 8;
static const uint VOXEL_MATERIALS_PER_WORD = 4u;
static const uint TERRAIN_BACKEND_RAYMARCH = 0u;
static const uint DEBUG_NORMAL = 0u;
static const uint DEBUG_LOD = 1u;
static const uint DEBUG_MATERIAL = 2u;
static const uint DEBUG_MOUNTAIN_INFLUENCE = 3u;
static const uint DEBUG_HEIGHTFIELD_GRID = 4u;
static const uint DEBUG_VIRTUAL_VOXEL_CELLS = 5u;
static const uint DEBUG_VIRTUAL_VOXEL_FACES = 6u;
static const uint DEBUG_LOD_TRANSITIONS = 7u;
static const uint DEBUG_HEIGHT_QUANTIZATION = 8u;
static const uint DEBUG_DDA_TRAVERSAL = 9u;
static const uint DEBUG_WORLD_RING = 10u;
static const uint DEBUG_MODIFICATIONS = 11u;
static const uint DEBUG_VOXEL_GRID = 12u;
static const uint DEBUG_CHUNK_BOUNDS = 13u;
static const uint DEBUG_BRICK_BOUNDS = 14u;
static const uint DEBUG_BRICK_CLASSIFICATION = 15u;
static const uint DEBUG_ORE = 16u;
static const uint DEBUG_RESIDENCY = 17u;
static const uint DEBUG_REPRESENTATION = 18u;
static const uint DEBUG_HEIGHTFIELD_ONLY = 19u;
static const uint DEBUG_VOXEL_ONLY = 20u;
static const int BRICKS_PER_AXIS = 4;

Ray generateCameraRay(uint2 pixelCoord, float2 screenSize) {
  float2 ndc = ((float2(pixelCoord) + 0.5) / screenSize) * 2.0 - 1.0;
  ndc.y = -ndc.y;
  float4 worldTarget =
      mul(g_camera.invViewProj, float4(ndc.x, ndc.y, -1.0, 1.0));
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
  return hashUint(uint(voxel.x) * 73856093u ^ uint(voxel.y) * 19349663u ^
                  uint(voxel.z) * 83492791u);
}

// Explicit floor is required here: signed integer division truncated negative
// world coordinates on the GPU.
int floorDiv(int value, int divisor) {
  return int(floor(float(value) / float(divisor)));
}

int3 floorDiv3(int3 value, int divisor) {
  return int3(floorDiv(value.x, divisor), floorDiv(value.y, divisor),
              floorDiv(value.z, divisor));
}

bool lookupChunk(int3 coord, out VoxelChunk chunk) {
  chunk = (VoxelChunk)0;
  if (g_settings.chunkCount == 0 || g_settings.chunkTableMask == 0)
    return false;
  uint slot = hashVoxel(coord) & g_settings.chunkTableMask;
  for (uint probe = 0; probe < 32; probe++) {
    VoxelChunkSlot candidate = g_voxelChunkTable[slot];
    if (candidate.chunkIndexPlusOne == 0)
      return false;
    if (all(candidate.coord == coord)) {
      chunk = g_voxelChunks[candidate.chunkIndexPlusOne - 1];
      return true;
    }
    slot = (slot + 1) & g_settings.chunkTableMask;
  }
  return false;
}

bool sampleVoxel(int3 voxel, out uint material, out uint brickKind,
                 out bool resident) {
  material = 0;
  brickKind = BRICK_EMPTY;
  int3 chunkCoord = floorDiv3(voxel, CHUNK_SIZE);
  VoxelChunk chunk;
  resident = lookupChunk(chunkCoord, chunk);
  if (!resident)
    return false;
  int3 local = voxel - chunkCoord * CHUNK_SIZE;
  int3 brickCoord = local / BRICK_SIZE;
  uint brickIndex = uint(brickCoord.z * BRICKS_PER_AXIS * BRICKS_PER_AXIS +
                         brickCoord.y * BRICKS_PER_AXIS + brickCoord.x);
  VoxelBrick brick = g_voxelBricks[chunk.brickOffset + brickIndex];
  brickKind = brick.kind;
  if (brick.kind == BRICK_EMPTY)
    return false;
  if (brick.kind == BRICK_SOLID) {
    material = brick.material;
    return material != 0;
  }
  int3 cell = local % BRICK_SIZE;
  uint cellIndex =
      uint(cell.z * BRICK_SIZE * BRICK_SIZE + cell.y * BRICK_SIZE + cell.x);
  uint packedMaterial =
      g_voxelMaterials[brick.voxelOffset + cellIndex / VOXEL_MATERIALS_PER_WORD];
  material =
      (packedMaterial >> ((cellIndex % VOXEL_MATERIALS_PER_WORD) * 8u)) & 0xFFu;
  return material != 0;
}

VoxelHit traceVoxels(Ray ray) {
  VoxelHit result = (VoxelHit)0;
  float voxelSize = g_settings.voxelSize;
  int3 voxel = int3(floor(ray.origin / voxelSize));
  int3 step =
      int3(ray.direction.x < 0.0 ? -1 : 1, ray.direction.y < 0.0 ? -1 : 1,
           ray.direction.z < 0.0 ? -1 : 1);
  float3 nextBoundary =
      (float3(voxel) +
       float3(step.x > 0 ? 1 : 0, step.y > 0 ? 1 : 0, step.z > 0 ? 1 : 0)) *
      voxelSize;
  float3 delta = float3(
      abs(ray.direction.x) < 1e-7 ? 1e30 : abs(voxelSize / ray.direction.x),
      abs(ray.direction.y) < 1e-7 ? 1e30 : abs(voxelSize / ray.direction.y),
      abs(ray.direction.z) < 1e-7 ? 1e30 : abs(voxelSize / ray.direction.z));
  float3 maximum =
      float3(abs(ray.direction.x) < 1e-7
                 ? 1e30
                 : max((nextBoundary.x - ray.origin.x) / ray.direction.x, 0.0),
             abs(ray.direction.y) < 1e-7
                 ? 1e30
                 : max((nextBoundary.y - ray.origin.y) / ray.direction.y, 0.0),
             abs(ray.direction.z) < 1e-7
                 ? 1e30
                 : max((nextBoundary.z - ray.origin.z) / ray.direction.z, 0.0));
  float distanceAlongRay = 0.0;
  float3 enteredNormal = 0;

  for (uint stepIndex = 0;
       stepIndex < 512 && distanceAlongRay <= g_settings.voxelRenderRadius;
       stepIndex++) {
    result.cellVisits++;
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

float lodValue(float4 values, uint lod) {
  if (lod == 0)
    return values.x;
  if (lod == 1)
    return values.y;
  if (lod == 2)
    return values.z;
  return values.w;
}

bool sampleTerrainColumn(int2 cell, uint lod, out TerrainSample terrain,
                         out float quantizedHeight) {
  terrain = (TerrainSample)0;
  quantizedHeight = 0.0;
  TerrainLevel level = g_levels[lod];
  float cellSize = lodValue(g_settings.virtualVoxelSizes, lod);
  float2 cellCenter = float2(cell) * cellSize;
  int2 sampleCoord =
      int2(floor((cellCenter - level.origin) / level.spacing + 0.5));
  if (any(sampleCoord < 0) || any(sampleCoord >= int(level.sampleCount)))
    return false;
  terrain =
      g_samples[level.sampleOffset + uint(sampleCoord.y) * level.sampleCount +
                uint(sampleCoord.x)];
  float verticalStep = max(lodValue(g_settings.verticalSteps, lod), 0.001);
  quantizedHeight = floor(terrain.height / verticalStep) * verticalStep;
  return true;
}

bool intersectColumn(Ray ray, float3 boundsMin, float3 boundsMax,
                     float segmentStart, float segmentEnd,
                     out float hitDistance, out float3 hitNormal) {
  float3 safeDirection = float3(
      abs(ray.direction.x) < 1e-7 ? (ray.direction.x < 0.0 ? -1e-7 : 1e-7)
                                  : ray.direction.x,
      abs(ray.direction.y) < 1e-7 ? (ray.direction.y < 0.0 ? -1e-7 : 1e-7)
                                  : ray.direction.y,
      abs(ray.direction.z) < 1e-7 ? (ray.direction.z < 0.0 ? -1e-7 : 1e-7)
                                  : ray.direction.z);
  float3 first = (boundsMin - ray.origin) / safeDirection;
  float3 second = (boundsMax - ray.origin) / safeDirection;
  float3 nearTimes = min(first, second);
  float3 farTimes = max(first, second);
  float nearDistance = max(nearTimes.x, max(nearTimes.y, nearTimes.z));
  float farDistance = min(farTimes.x, min(farTimes.y, farTimes.z));
  hitDistance = max(nearDistance, segmentStart);
  hitNormal = 0.0;
  if (nearDistance > farDistance || farDistance < segmentStart ||
      hitDistance > segmentEnd)
    return false;

  if (nearTimes.y >= nearTimes.x && nearTimes.y >= nearTimes.z) {
    hitNormal = float3(0, ray.direction.y > 0.0 ? -1.0 : 1.0, 0);
  } else if (nearTimes.x >= nearTimes.z) {
    hitNormal = float3(ray.direction.x > 0.0 ? -1.0 : 1.0, 0, 0);
  } else {
    hitNormal = float3(0, 0, ray.direction.z > 0.0 ? -1.0 : 1.0);
  }
  return true;
}

bool traceHeightfieldLod(Ray ray, uint lod, float segmentStart,
                         float segmentEnd, out HeightfieldHit hit,
                         out uint cellVisits) {
  hit = (HeightfieldHit)0;
  cellVisits = 0;
  if (segmentEnd <= segmentStart)
    return false;

  float cellSize = lodValue(g_settings.virtualVoxelSizes, lod);
  float2 horizontalDirection = ray.direction.xz;
  float2 startPosition =
      ray.origin.xz + horizontalDirection * (segmentStart + 1e-4);
  int2 cell = int2(floor(startPosition / cellSize + 0.5));
  int2 step = int2(horizontalDirection.x < 0.0 ? -1 : 1,
                   horizontalDirection.y < 0.0 ? -1 : 1);
  float2 nextBoundary = (float2(cell) + float2(step) * 0.5) * cellSize;
  float2 maximum =
      float2(abs(horizontalDirection.x) < 1e-7
                 ? 1e30
                 : max((nextBoundary.x - ray.origin.x) / horizontalDirection.x,
                       segmentStart),
             abs(horizontalDirection.y) < 1e-7
                 ? 1e30
                 : max((nextBoundary.y - ray.origin.z) / horizontalDirection.y,
                       segmentStart));
  float2 delta = float2(abs(horizontalDirection.x) < 1e-7
                            ? 1e30
                            : abs(cellSize / horizontalDirection.x),
                        abs(horizontalDirection.y) < 1e-7
                            ? 1e30
                            : abs(cellSize / horizontalDirection.y));
  float currentDistance = segmentStart;

  for (uint stepIndex = 0; stepIndex < 1024 && currentDistance <= segmentEnd;
       stepIndex++) {
    cellVisits++;
    TerrainSample terrain;
    float quantizedHeight;
    if (sampleTerrainColumn(cell, lod, terrain, quantizedHeight)) {
      float halfSize = cellSize * 0.5;
      float2 center = float2(cell) * cellSize;
      float hitDistance;
      float3 hitNormal;
      if (intersectColumn(
              ray,
              float3(center.x - halfSize, -g_settings.maxDistance,
                     center.y - halfSize),
              float3(center.x + halfSize, quantizedHeight, center.y + halfSize),
              currentDistance, segmentEnd, hitDistance, hitNormal)) {
        float3 hitPosition = ray.origin + ray.direction * hitDistance;
        if (length(hitPosition.xz) <= g_settings.worldRadius) {
          hit.hit = true;
          hit.distance = hitDistance;
          hit.position = hitPosition;
          hit.normal = hitNormal;
          hit.terrain = terrain;
          hit.lod = lod;
          hit.cell = cell;
          hit.cellSize = cellSize;
          hit.quantizedHeight = quantizedHeight;
          return true;
        }
      }
    }

    float nextDistance = min(maximum.x, maximum.y);
    if (nextDistance > segmentEnd)
      break;
    currentDistance = nextDistance;
    if (maximum.x < maximum.y) {
      cell.x += step.x;
      maximum.x += delta.x;
    } else if (maximum.y < maximum.x) {
      cell.y += step.y;
      maximum.y += delta.y;
    } else {
      cell += step;
      maximum += delta;
    }
  }
  return false;
}

HeightfieldHit traceHeightfield(Ray ray, float startDistance) {
  HeightfieldHit result = (HeightfieldHit)0;
  float segmentStart =
      max(startDistance, g_settings.modificationVoxelSize * 0.5);
  for (uint lod = 0; lod < 3 && lod < g_settings.levelCount; lod++) {
    float segmentEnd =
        min(lodValue(g_settings.lodDistances, lod), g_settings.maxDistance);
    uint visits;
    HeightfieldHit lodHit;
    bool hit =
        traceHeightfieldLod(ray, lod, segmentStart, segmentEnd, lodHit, visits);
    result.traversedCells += visits;
    if (lod == 0)
      result.lodCellVisits.x += visits;
    else if (lod == 1)
      result.lodCellVisits.y += visits;
    else
      result.lodCellVisits.z += visits;
    if (hit) {
      lodHit.traversedCells = result.traversedCells;
      lodHit.lodCellVisits = result.lodCellVisits;
      return lodHit;
    }
    segmentStart = segmentEnd;
    if (segmentStart >= g_settings.maxDistance)
      break;
  }
  return result;
}

bool lookupOverride(int3 voxel, out SparseVoxel result) {
  result = (SparseVoxel)0;
  if (g_settings.overrideTableMask == 0)
    return false;
  float3 worldPosition =
      (float3(voxel) + 0.5) * g_settings.modificationVoxelSize;
  if (any(worldPosition < g_settings.overrideBoundsMin) ||
      any(worldPosition > g_settings.overrideBoundsMax))
    return false;
  uint slot = hashVoxel(voxel) & g_settings.overrideTableMask;
  for (uint probe = 0; probe < 32; probe++) {
    SparseVoxel candidate = g_overrides[slot];
    if (candidate.state == 0)
      return false;
    if (all(candidate.voxel == voxel)) {
      result = candidate;
      return true;
    }
    slot = (slot + 1) & g_settings.overrideTableMask;
  }
  return false;
}

float3 unpackColor(uint packedColor) {
  return float3(float(packedColor & 0xFFu), float((packedColor >> 8) & 0xFFu),
                float((packedColor >> 16) & 0xFFu)) /
         255.0;
}

float virtualCellVariation(HeightfieldHit hit, float strength) {
  int3 cellKey = int3(hit.cell.x, int(hit.lod), hit.cell.y);
  uint seed = g_settings.visualSeedLo ^
              (g_settings.visualSeedHi * 0x9E3779B9u) ^
              hit.terrain.material * 0x85EBCA6Bu;
  float geological =
      float(hashVoxel(floorDiv3(cellKey, 8)) ^ seed) / 4294967295.0;
  float cell = float(hashVoxel(cellKey) ^ hashUint(seed)) / 4294967295.0;
  return 1.0 + (geological - 0.5) * strength * 0.72 +
         (cell - 0.5) * strength * 0.28;
}

float virtualColumnEdge(HeightfieldHit hit, float width) {
  return 0.0f;
  float halfSize = hit.cellSize * 0.5;
  float verticalStep = max(lodValue(g_settings.verticalSteps, hit.lod), 0.001);
  float xEdge = min(frac((hit.position.x + halfSize) / hit.cellSize),
                    1.0 - frac((hit.position.x + halfSize) / hit.cellSize));
  float zEdge = min(frac((hit.position.z + halfSize) / hit.cellSize),
                    1.0 - frac((hit.position.z + halfSize) / hit.cellSize));
  float yEdge = min(frac(hit.position.y / verticalStep),
                    1.0 - frac(hit.position.y / verticalStep));
  float tangentEdge =
      abs(hit.normal.x) > 0.5
          ? min(yEdge, zEdge)
          : (abs(hit.normal.y) > 0.5 ? min(xEdge, zEdge) : min(xEdge, yEdge));
  return 1.0 - smoothstep(width, width * 1.8, tangentEdge);
}

float stableVariation(int3 voxel, uint material, float strength) {
  uint seed = g_settings.visualSeedLo ^
              (g_settings.visualSeedHi * 0x9E3779B9u) ^ material * 0x85EBCA6Bu;
  float coarse = float(hashVoxel(floorDiv3(voxel, 8)) ^ seed) / 4294967295.0;
  float fine = float(hashVoxel(voxel) ^ hashUint(seed)) / 4294967295.0;
  return 1.0 + (coarse - 0.5) * strength * 0.9 + (fine - 0.5) * strength * 0.45;
}

float gridEdge(float3 position, float3 normal, float size, float width) {
  float3 local = frac(position / size);
  float3 edge = min(local, 1.0 - local);
  float tangentEdge =
      abs(normal.x) > 0.5
          ? min(edge.y, edge.z)
          : (abs(normal.y) > 0.5 ? min(edge.x, edge.z) : min(edge.x, edge.y));
  return 1.0 - smoothstep(width, width * 1.8, tangentEdge);
}

float3 voxelColor(VoxelHit hit) {
  uint materialIndex = min(hit.material, max(g_settings.materialCount, 1u) - 1);
  MaterialRenderInfo info = g_materials[materialIndex];
  float3 color =
      unpackColor(info.baseColor) *
      stableVariation(hit.voxel, hit.material, info.variationStrength);
  // float voxelEdge = gridEdge(hit.position, hit.normal, g_settings.voxelSize,
  // 0.035);
  float voxelEdge = 0.0f;
  color *= lerp(1.0, 0.48, voxelEdge);
  if (g_settings.debugMode == DEBUG_MATERIAL)
    return unpackColor(info.baseColor);
  if (g_settings.debugMode == DEBUG_MODIFICATIONS) {
    SparseVoxel modified;
    return lookupOverride(hit.voxel, modified) ? float3(1.0, 0.05, 0.85)
                                               : color * 0.18;
  }
  if (g_settings.debugMode == DEBUG_VOXEL_GRID)
    return lerp(color * 0.28, float3(0.05, 0.95, 1.0), voxelEdge);
  if (g_settings.debugMode == DEBUG_CHUNK_BOUNDS) {
    int3 chunk = floorDiv3(hit.voxel, CHUNK_SIZE);
    uint chunkHash = hashVoxel(chunk);
    float3 chunkColor =
        float3(float((chunkHash >> 0) & 0xFFu), float((chunkHash >> 8) & 0xFFu),
               float((chunkHash >> 16) & 0xFFu)) /
        255.0;
    chunkColor = 0.18 + chunkColor * 0.72;
    // float edge = gridEdge(hit.position, hit.normal, g_settings.voxelSize *
    // CHUNK_SIZE, 0.018);
    float edge = 0.0f;
    return lerp(chunkColor, float3(1.0, 0.05, 0.02), edge);
  }
  if (g_settings.debugMode == DEBUG_BRICK_BOUNDS) {
    // float edge = gridEdge(hit.position, hit.normal, g_settings.voxelSize *
    // BRICK_SIZE, 0.028);
    float edge = 0.0f;
    return lerp(color * 0.25, float3(0.1, 1.0, 0.3), edge);
  }
  if (g_settings.debugMode == DEBUG_BRICK_CLASSIFICATION) {
    if (hit.brickKind == BRICK_SOLID)
      return float3(0.1, 0.35, 1.0);
    if (hit.brickKind == BRICK_MIXED)
      return float3(1.0, 0.25, 0.05);
    return float3(0.05, 0.05, 0.05);
  }
  if (g_settings.debugMode == DEBUG_ORE)
    return (info.flags & MATERIAL_FLAG_RESOURCE) != 0 ? float3(1.0, 0.8, 0.05)
                                                      : color * 0.12;
  if (g_settings.debugMode == DEBUG_RESIDENCY)
    return color;
  if (g_settings.debugMode == DEBUG_REPRESENTATION)
    return float3(0.1, 0.9, 0.9);
  return color;
}

float3 heightfieldColor(HeightfieldHit hit) {
  uint terrainIndex =
      g_settings.terrainMaterialOffset +
      min(hit.terrain.material, max(g_settings.terrainMaterialCount, 1u) - 1);
  MaterialRenderInfo info = g_materials[terrainIndex];
  float3 base = unpackColor(info.baseColor);
  float3 surface = base * virtualCellVariation(hit, info.variationStrength);
  float cellEdge = virtualColumnEdge(hit, 0.035);
  surface *= lerp(1.0, 0.62, cellEdge);

  if (g_settings.debugMode == DEBUG_LOD) {
    if (hit.lod == 0)
      return float3(0.12, 0.9, 0.25);
    if (hit.lod == 1)
      return float3(0.95, 0.75, 0.08);
    return float3(0.18, 0.45, 1.0);
  }
  if (g_settings.debugMode == DEBUG_MATERIAL)
    return base;
  if (g_settings.debugMode == DEBUG_MOUNTAIN_INFLUENCE)
    return hit.terrain.mountainInfluence.xxx;
  if (g_settings.debugMode == DEBUG_HEIGHTFIELD_GRID) {
    float tileSize = hit.cellSize * 16.0;
    float2 tileLocal = frac((hit.position.xz + hit.cellSize * 0.5) / tileSize);
    float2 tileEdge = min(tileLocal, 1.0 - tileLocal);
    return min(tileEdge.x, tileEdge.y) < 0.025 ? float3(0.04, 0.95, 0.95)
                                               : surface * 0.35;
  }
  if (g_settings.debugMode == DEBUG_VIRTUAL_VOXEL_CELLS) {
    float3 lodTint = hit.lod == 0 ? float3(0.12, 0.9, 0.25)
                                  : (hit.lod == 1 ? float3(0.95, 0.75, 0.08)
                                                  : float3(0.18, 0.45, 1.0));
    return lerp(surface * 0.28 + lodTint * 0.18, float3(0.02, 1.0, 0.95),
                cellEdge);
  }
  if (g_settings.debugMode == DEBUG_VIRTUAL_VOXEL_FACES) {
    if (hit.normal.y > 0.5)
      return float3(0.15, 0.95, 0.22);
    if (abs(hit.normal.x) > 0.5)
      return hit.normal.x > 0.0 ? float3(1.0, 0.18, 0.08)
                                : float3(0.62, 0.04, 0.02);
    return hit.normal.z > 0.0 ? float3(0.08, 0.42, 1.0)
                              : float3(0.03, 0.12, 0.58);
  }
  if (g_settings.debugMode == DEBUG_LOD_TRANSITIONS) {
    float horizontalDistance = length(hit.position.xz - g_camera.position.xz);
    float transitionDistance =
        min(abs(horizontalDistance - g_settings.voxelRenderRadius),
            min(abs(hit.distance - g_settings.lodDistances.x),
                abs(hit.distance - g_settings.lodDistances.y)));
    return transitionDistance < g_settings.heightfieldTransitionWidth
               ? float3(1.0, 0.04, 0.75)
               : surface * 0.25;
  }
  if (g_settings.debugMode == DEBUG_HEIGHT_QUANTIZATION) {
    float verticalStep =
        max(lodValue(g_settings.verticalSteps, hit.lod), 0.001);
    float loss =
        saturate((hit.terrain.height - hit.quantizedHeight) / verticalStep);
    return lerp(float3(0.08, 0.18, 0.95), float3(1.0, 0.12, 0.02), loss);
  }
  if (g_settings.debugMode == DEBUG_DDA_TRAVERSAL) {
    float cost = saturate(float(hit.traversedCells) / 384.0);
    return lerp(float3(0.04, 0.5, 0.12), float3(1.0, 0.03, 0.01), cost);
  }
  if (g_settings.debugMode == DEBUG_WORLD_RING) {
    float ringDistance =
        abs(length(hit.position.xz) - g_settings.debugRingRadius);
    return ringDistance < 80.0 ? float3(1.0, 0.05, 0.05) : surface * 0.35;
  }
  if (g_settings.debugMode == DEBUG_RESIDENCY)
    return surface * 0.18;
  if (g_settings.debugMode == DEBUG_REPRESENTATION)
    return float3(0.95, 0.58, 0.08);
  if (g_settings.debugMode >= DEBUG_MODIFICATIONS &&
      g_settings.debugMode <= DEBUG_ORE)
    return surface * 0.12;
  return surface;
}

void recordTraversalStats(uint2 pixelCoord, VoxelHit voxelHit,
                          HeightfieldHit terrainHit) {
  uint stride = g_settings.statsSampleStride;
  if (stride == 0 || pixelCoord.x % stride != 0 || pixelCoord.y % stride != 0)
    return;

  InterlockedAdd(g_traversalStats[0].sampledRays, 1u);
  InterlockedAdd(g_traversalStats[0].voxelCellVisits, voxelHit.cellVisits);
  InterlockedMax(g_traversalStats[0].maxVoxelCellVisits, voxelHit.cellVisits);
  InterlockedAdd(g_traversalStats[0].heightfieldCellVisits,
                 terrainHit.traversedCells);
  InterlockedMax(g_traversalStats[0].maxHeightfieldCellVisits,
                 terrainHit.traversedCells);
  InterlockedAdd(g_traversalStats[0].lod0CellVisits,
                 terrainHit.lodCellVisits.x);
  InterlockedAdd(g_traversalStats[0].lod1CellVisits,
                 terrainHit.lodCellVisits.y);
  InterlockedAdd(g_traversalStats[0].lod2CellVisits,
                 terrainHit.lodCellVisits.z);
  if (terrainHit.lodCellVisits.x > 0)
    InterlockedAdd(g_traversalStats[0].lod0TraversedRays, 1u);
  if (terrainHit.lodCellVisits.y > 0)
    InterlockedAdd(g_traversalStats[0].lod1TraversedRays, 1u);
  if (terrainHit.lodCellVisits.z > 0)
    InterlockedAdd(g_traversalStats[0].lod2TraversedRays, 1u);
  if (terrainHit.hit) {
    InterlockedAdd(g_traversalStats[0].heightfieldHits, 1u);
    InterlockedAdd(g_traversalStats[0].heightfieldHitDistanceMeters,
                   uint(terrainHit.distance + 0.5));
    if (terrainHit.lod == 0)
      InterlockedAdd(g_traversalStats[0].lod0Hits, 1u);
    else if (terrainHit.lod == 1)
      InterlockedAdd(g_traversalStats[0].lod1Hits, 1u);
    else
      InterlockedAdd(g_traversalStats[0].lod2Hits, 1u);
  }
  if (voxelHit.hit && terrainHit.hit)
    InterlockedAdd(g_traversalStats[0].blendedHits, 1u);
  else if (voxelHit.hit)
    InterlockedAdd(g_traversalStats[0].voxelOnlyHits, 1u);
  else if (terrainHit.hit)
    InterlockedAdd(g_traversalStats[0].heightfieldOnlyHits, 1u);
  else
    InterlockedAdd(g_traversalStats[0].missedRays, 1u);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID: SV_DispatchThreadID) {
  uint width, height;
  g_outputFramebuffer.GetDimensions(width, height);
  uint2 pixelCoord = dispatchThreadID.xy;
  if (pixelCoord.x >= width || pixelCoord.y >= height)
    return;

  Ray ray = generateCameraRay(pixelCoord, float2(width, height));
  float3 sky = lerp(float3(0.13, 0.18, 0.24), float3(0.36, 0.48, 0.60),
                    saturate(ray.direction.y * 0.5 + 0.5));
  VoxelHit voxelHit = (VoxelHit)0;
  if (g_settings.terrainBackend == TERRAIN_BACKEND_RAYMARCH)
    voxelHit = traceVoxels(ray);
  HeightfieldHit terrainHit = traceHeightfield(ray, 0.0);
  float representationBlend = 0.0;
  if (voxelHit.hit && terrainHit.hit) {
    // These are separate ray traces into potentially different geometry. Blend
    // only coincident terrain surfaces; otherwise the nearest ray intersection
    // owns pixel.
    float transitionStart = max(
        g_settings.voxelRenderRadius - g_settings.voxelTransitionWidth, 0.0);
    float horizontalDistance =
        length(voxelHit.position.xz - g_camera.position.xz);
    representationBlend = saturate((horizontalDistance - transitionStart) /
                                   max(g_settings.voxelTransitionWidth, 0.001));
  }
  recordTraversalStats(pixelCoord, voxelHit, terrainHit);

  if (g_settings.debugMode == DEBUG_HEIGHTFIELD_ONLY)
    voxelHit.hit = false;
  if (g_settings.debugMode == DEBUG_VOXEL_ONLY)
    terrainHit.hit = false;
  bool hit = voxelHit.hit || terrainHit.hit;
  float distanceAlongRay =
      voxelHit.hit ? voxelHit.distance : terrainHit.distance;
  float3 color = sky;
  float3 normal = float3(0, 1, 0);
  if (hit) {
    if (voxelHit.hit && terrainHit.hit) {
      color = lerp(voxelColor(voxelHit), heightfieldColor(terrainHit),
                   representationBlend);
      float3 voxelNormal =
          length(voxelHit.normal) > 0.0 ? voxelHit.normal : float3(0, 1, 0);
      normal = representationBlend < 0.5 ? voxelNormal : terrainHit.normal;
      distanceAlongRay =
          lerp(voxelHit.distance, terrainHit.distance, representationBlend);
    } else if (voxelHit.hit) {
      color = voxelColor(voxelHit);
      normal = voxelHit.normal;
    } else if (terrainHit.hit) {
      color = heightfieldColor(terrainHit);
      normal = terrainHit.normal;
      distanceAlongRay = terrainHit.distance;
    } else {
      color = float3(0.1, 0.8, 0.8);
      normal = terrainHit.normal;
    }
    if (g_settings.debugMode == DEBUG_NORMAL) {
      float3 sunDirection = normalize(float3(0.45, 0.82, 0.35));
      float diffuse = 0.28 + 0.72 * saturate(dot(normal, sunDirection));
      float distanceFog = saturate(distanceAlongRay / g_settings.maxDistance);
      color *= diffuse;
      color = lerp(color, sky, distanceFog * distanceFog * 0.72);
    }
  }

  float2 crosshair = abs(float2(pixelCoord) - float2(width, height) * 0.5);
  if ((crosshair.x < 1.0 && crosshair.y < 6.0) ||
      (crosshair.y < 1.0 && crosshair.x < 6.0)) {
    color = lerp(color, float3(0.95, 0.95, 0.95), 0.85);
  }
  g_outputFramebuffer[pixelCoord] = float4(color, 1.0);
  g_outputLinearDepth[pixelCoord] =
      hit ? distanceAlongRay : g_settings.maxDistance;
}
