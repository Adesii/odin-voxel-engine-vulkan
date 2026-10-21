import utils.voxel_math;

static const uint MAX_LOD_LEVELS = 9u;

struct MeshSettings {
  // Camera-relative reversed-Z projection: apply to (worldPosition -
  // cameraPosition). Keeping the translation out of the matrix preserves vertex
  // precision far from the world origin.
  float4x4 viewProjRelative;
  float3 cameraPosition;
  float voxelSize;
  float nearVoxelDistance;
  uint meshBrickCount;
  uint meshDispatchX;
  uint chunkTableMask;
  uint materialCount;
  uint visualSeedLo;
  uint visualSeedHi;
  uint debugMode;
  uint heightfieldWorkgroupCount;
  uint levelCount;
  uint terrainMaterialOffset;
  uint terrainMaterialCount;
  float worldRadius;
  float maxDistance;
  float debugRingRadius;
  float heightfieldTransitionRatio;
  float4 lodDistances0;
  float4 lodDistances1;
  float4 lodDistances2;
  float4 virtualVoxelSizes0;
  float4 virtualVoxelSizes1;
  float4 virtualVoxelSizes2;
  float4 verticalSteps0;
  float4 verticalSteps1;
  float4 verticalSteps2;
  uint4 lodGridDiameters0;
  uint4 lodGridDiameters1;
  uint4 lodGridDiameters2;
  float2 outputSize;
  float voxelTransitionWidth;
  // Mesh vertices sit every `heightfieldCellStride` virtual cells; triangles
  // interpolate smoothly, so they need far fewer vertices than the raymarcher
  // needs cells.
  uint heightfieldCellStride;
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

struct TerrainLevel {
  float2 origin;
  float spacing;
  uint sampleCount;
  uint sampleOffset;
  float extent;
  float minHeight;
  float maxHeight;
};

struct TerrainSample {
  float height;
  float mountainInfluence;
  uint material;
  uint _padding;
};

struct MeshBrick {
  int3 voxelMin;
  uint _padding;
};

struct MeshStats {
  uint visibleBricks;
  uint culledBricks;
  uint meshWorkgroups;
  uint culledWorkgroups;
  uint generatedFaces;
  uint generatedPrimitives;
  uint heightfieldCells;
  uint heightfieldPrimitives;
};

struct MeshVertex {
  float4 position : SV_Position;
  float3 worldPosition : TEXCOORD0;
  nointerpolation uint material : TEXCOORD1;
  nointerpolation int3 voxel : TEXCOORD2;
  float3 normal : TEXCOORD3;
  nointerpolation uint representation : TEXCOORD4;
  nointerpolation uint lod : TEXCOORD5;
  nointerpolation int2 heightfieldCell : TEXCOORD6;
  nointerpolation float cellSize : TEXCOORD7;
  float sourceHeight : TEXCOORD8;
  float quantizedHeight : TEXCOORD9;
  float mountainInfluence : TEXCOORD10;
  float3 viewOffset : TEXCOORD11;
  // LOD0 patch whose voxels are resident: it fades out for them. Without
  // resident voxels (still streaming in) the heightfield stays fully visible.
  nointerpolation uint voxelBacked : TEXCOORD12;
};

uniform MeshSettings g_meshSettings;
uniform StructuredBuffer<VoxelChunk> g_voxelChunks;
uniform StructuredBuffer<VoxelBrick> g_voxelBricks;
uniform StructuredBuffer<uint> g_voxelMaterials;
uniform StructuredBuffer<VoxelChunkSlot> g_voxelChunkTable;
uniform StructuredBuffer<MaterialRenderInfo> g_materials;
uniform StructuredBuffer<MeshBrick> g_meshBricks;
uniform RWStructuredBuffer<MeshStats> g_meshStats;
uniform StructuredBuffer<TerrainLevel> g_terrainLevels;
uniform StructuredBuffer<TerrainSample> g_terrainSamples;

static const uint BRICK_EMPTY = 0u;
static const uint BRICK_SOLID = 1u;
static const int CHUNK_SIZE = 32;
static const int BRICK_SIZE = 8;
static const uint VOXELS_PER_BRICK = 512u;
static const uint VOXELS_PER_WORKGROUP = 10u;
static const uint WORKGROUPS_PER_BRICK = 52u;
static const uint MAX_OUTPUT_VERTICES = 240u;
static const uint MAX_OUTPUT_PRIMITIVES = 120u;
// Extra stipple coverage inside a crossfade so the two surfaces overlap rather
// than leave pinholes where their per-fragment distances differ slightly.
static const float TRANSITION_DITHER_OVERLAP = 0.15;
// A patch is a square of columns. Each column emits a top quad plus the side
// walls on its +x and +z edges, so a patch needs at most 3 quads per column:
// 16 * 3 * 4 = 192 vertices and 96 primitives, within the mesh output limits.
static const uint HEIGHTFIELD_PATCH_CELLS = 4u;
static const uint VOXEL_MATERIALS_PER_WORD = 4u;
static const uint MATERIAL_FLAG_RESOURCE = 1u;
static const uint REPRESENTATION_VOXEL = 0u;
static const uint REPRESENTATION_HEIGHTFIELD = 1u;
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

static const int3 NEIGHBOR_OFFSETS[6] = {
  int3(-1, 0, 0), int3(1, 0, 0),  int3(0, -1, 0),
  int3(0, 1, 0),  int3(0, 0, -1), int3(0, 0, 1),
};


static const uint4 FACE_CORNERS[6] = {
  uint4(0, 4, 6, 2), uint4(1, 3, 7, 5), uint4(0, 1, 5, 4),
  uint4(2, 6, 7, 3), uint4(0, 2, 3, 1), uint4(4, 5, 7, 6),
};

bool lookupChunk(int3 coord, out VoxelChunk chunk) {
  chunk = (VoxelChunk)0;
  if (g_meshSettings.chunkTableMask == 0)
    return false;
  uint slot = hashVoxel(coord) & g_meshSettings.chunkTableMask;
  for (uint probe = 0; probe < 32; probe++) {
    VoxelChunkSlot candidate = g_voxelChunkTable[slot];
    if (candidate.chunkIndexPlusOne == 0)
      return false;
    if (all(candidate.coord == coord)) {
      chunk = g_voxelChunks[candidate.chunkIndexPlusOne - 1];
      return true;
    }
    slot = (slot + 1) & g_meshSettings.chunkTableMask;
  }
  return false;
}

bool sampleVoxel(int3 voxel, out uint material) {
  material = 0;
  int3 chunkCoord = floorDiv3(voxel, CHUNK_SIZE);
  VoxelChunk chunk;
  if (!lookupChunk(chunkCoord, chunk))
    return false;
  int3 local = voxel - chunkCoord * CHUNK_SIZE;
  int3 brickCoord = local / BRICK_SIZE;
  uint brickIndex = uint(brickCoord.z * 16 + brickCoord.y * 4 + brickCoord.x);
  VoxelBrick brick = g_voxelBricks[chunk.brickOffset + brickIndex];
  if (brick.kind == BRICK_EMPTY)
    return false;
  if (brick.kind == BRICK_SOLID) {
    material = brick.material;
    return material != 0;
  }
  int3 cell = local - brickCoord * BRICK_SIZE;
  uint cellIndex = uint(cell.z * 64 + cell.y * 8 + cell.x);
  uint packedMaterial = g_voxelMaterials[brick.voxelOffset +
                                         cellIndex / VOXEL_MATERIALS_PER_WORD];
  material =
      (packedMaterial >> ((cellIndex % VOXEL_MATERIALS_PER_WORD) * 8u)) & 0xFFu;
  return material != 0;
}

float lodValue(float4 values0, float4 values1, float4 values2, uint lod) {
  if (lod < 4u)
    return values0[lod];
  if (lod < 8u)
    return values1[lod - 4u];
  return values2[lod - 8u];
}

uint lodGridDiameter(uint lod) {
  if (lod < 4u)
    return g_meshSettings.lodGridDiameters0[lod];
  if (lod < 8u)
    return g_meshSettings.lodGridDiameters1[lod - 4u];
  return g_meshSettings.lodGridDiameters2[lod - 8u];
}

float verticalStepForLod(uint lod) {
  return max(lodValue(g_meshSettings.verticalSteps0,
                      g_meshSettings.verticalSteps1,
                      g_meshSettings.verticalSteps2, lod),
             0.001);
}

TerrainSample loadTerrainSample(TerrainLevel level, int2 sampleCoord) {
  return g_terrainSamples[level.sampleOffset +
                          uint(sampleCoord.y) * level.sampleCount +
                          uint(sampleCoord.x)];
}

float meshCellSize(uint lod) {
  return lodValue(g_meshSettings.virtualVoxelSizes0,
                  g_meshSettings.virtualVoxelSizes1,
                  g_meshSettings.virtualVoxelSizes2, lod) *
         float(max(g_meshSettings.heightfieldCellStride, 1u));
}

// Samples the terrain at a mesh grid vertex. `slope` is the analytic gradient
// of the interpolated height (dh/dx, dh/dz), used for shading.
bool sampleTerrainSurface(int2 cell, uint lod, out TerrainSample terrain,
                          out float quantizedHeight, out float2 slope) {
  terrain = (TerrainSample)0;
  quantizedHeight = 0.0;
  slope = 0.0;
  TerrainLevel level = g_terrainLevels[lod];
  float cellSize = meshCellSize(lod);
  float2 cellCenter = float2(cell) * cellSize;
  float2 samplePosition = (cellCenter - level.origin) / level.spacing;
  float maximumSample = float(level.sampleCount - 1u);
  if (any(samplePosition < 0.0) || any(samplePosition > maximumSample))
    return false;

  int2 sample0 = int2(floor(samplePosition));
  int2 maximumCoord = int2(int(level.sampleCount) - 1);
  int2 sample1 = min(sample0 + int2(1), maximumCoord);
  float2 blend = frac(samplePosition);
  TerrainSample sample00 = loadTerrainSample(level, sample0);
  TerrainSample sample10 =
      loadTerrainSample(level, int2(sample1.x, sample0.y));
  TerrainSample sample01 =
      loadTerrainSample(level, int2(sample0.x, sample1.y));
  TerrainSample sample11 = loadTerrainSample(level, sample1);
  terrain.height =
      lerp(lerp(sample00.height, sample10.height, blend.x),
           lerp(sample01.height, sample11.height, blend.x), blend.y);
  terrain.mountainInfluence =
      lerp(lerp(sample00.mountainInfluence, sample10.mountainInfluence, blend.x),
           lerp(sample01.mountainInfluence, sample11.mountainInfluence, blend.x),
           blend.y);
  slope = float2((sample10.height - sample00.height) * (1.0 - blend.y) +
                     (sample11.height - sample01.height) * blend.y,
                 (sample01.height - sample00.height) * (1.0 - blend.x) +
                     (sample11.height - sample10.height) * blend.x) /
          level.spacing;
  int2 nearestSample =
      min(int2(floor(samplePosition + 0.5)), maximumCoord);
  terrain.material = loadTerrainSample(level, nearestSample).material;
  // Round to the nearest step: flooring would sink every coarse LOD by half a
  // step on average and leave a visible ledge at each LOD boundary.
  float verticalStep = verticalStepForLod(lod);
  quantizedHeight = floor(terrain.height / verticalStep + 0.5) * verticalStep;
  return true;
}

bool sampleTerrainColumn(int2 cell, uint lod, out TerrainSample terrain,
                         out float quantizedHeight) {
  float2 slope;
  return sampleTerrainSurface(cell, lod, terrain, quantizedHeight, slope);
}

float lodEndDistance(uint lod) {
  return lodValue(g_meshSettings.lodDistances0, g_meshSettings.lodDistances1,
                  g_meshSettings.lodDistances2, lod);
}

bool heightfieldPatchForWorkgroup(uint workgroupIndex, out uint lod,
                                  out int2 patchStart) {
  lod = 0u;
  patchStart = 0;
  for (uint candidateLod = 0u;
       candidateLod < MAX_LOD_LEVELS &&
       candidateLod < g_meshSettings.levelCount;
       candidateLod++) {
    uint diameter = lodGridDiameter(candidateLod);
    uint levelWorkgroups = diameter * diameter;
    if (workgroupIndex >= levelWorkgroups) {
      workgroupIndex -= levelWorkgroups;
      continue;
    }
    lod = candidateLod;
    float cellSize = meshCellSize(lod);
    int2 cameraCell =
        int2(floor(g_meshSettings.cameraPosition.xz / cellSize + 0.5));
    int radius = int(diameter / 2u);
    int2 patchOffset =
        int2(int(workgroupIndex % diameter), int(workgroupIndex / diameter)) -
        radius;
    patchStart =
        cameraCell + patchOffset * int(HEIGHTFIELD_PATCH_CELLS) -
        int2(int(HEIGHTFIELD_PATCH_CELLS / 2u));
    return true;
  }
  return false;
}

// Half width of the crossfade centred on a LOD's outer boundary. It scales with
// the boundary distance so the fade spans a similar number of pixels at every
// LOD, however coarse its cells are.
float lodTransitionHalfWidth(uint lod) {
  return lodEndDistance(lod) * g_meshSettings.heightfieldTransitionRatio;
}

float nearestVoxelFadeStart() {
  return max(g_meshSettings.nearVoxelDistance -
                 g_meshSettings.voxelTransitionWidth,
             0.0);
}

// Nearest horizontal distance at which a LOD can contribute any coverage.
float lodInnerReach(uint lod) {
  if (lod == 0u)
    return g_meshSettings.debugMode == DEBUG_HEIGHTFIELD_ONLY
               ? 0.0
               : nearestVoxelFadeStart();
  return max(lodEndDistance(lod - 1u) - lodTransitionHalfWidth(lod - 1u), 0.0);
}

// Furthest horizontal distance at which a LOD can contribute any coverage.
float lodOuterReach(uint lod) {
  if (lod + 1u >= g_meshSettings.levelCount)
    return lodEndDistance(lod);
  return lodEndDistance(lod) + lodTransitionHalfWidth(lod);
}

float fadeBetween(float lower, float upper, float value) {
  if (upper <= lower)
    return value >= upper ? 1.0 : 0.0;
  float t = saturate((value - lower) / (upper - lower));
  return t * t * (3.0 - 2.0 * t);
}

// 0 in the voxel region, 1 once only the heightfield remains.
float voxelToHeightfieldBlend(float horizontalDistance) {
  return fadeBetween(nearestVoxelFadeStart(),
                     g_meshSettings.nearVoxelDistance, horizontalDistance);
}

// Interleaved gradient noise: stable, resolution independent screen dither.
float transitionNoise(float2 pixel) {
  return frac(52.9829189 * frac(dot(pixel, float2(0.06711056, 0.00583715))));
}

// A surface fading out keeps the low noise values, one fading in keeps the
// high ones, so the two interleave per pixel instead of z-fighting.
bool fadeOutKeeps(float visibility, float noise) {
  return noise < visibility * (1.0 + TRANSITION_DITHER_OVERLAP);
}

bool fadeInKeeps(float visibility, float noise) {
  return noise >= 1.0 - visibility * (1.0 + TRANSITION_DITHER_OVERLAP);
}

bool voxelFragmentVisible(float horizontalDistance, float noise) {
  if (g_meshSettings.debugMode == DEBUG_VOXEL_ONLY)
    return true;
  return fadeOutKeeps(1.0 - voxelToHeightfieldBlend(horizontalDistance), noise);
}

bool heightfieldFragmentVisible(uint lod, float horizontalDistance,
                                float noise, bool voxelBacked) {
  float fadeIn = 1.0;
  if (lod == 0u) {
    if (voxelBacked && g_meshSettings.debugMode != DEBUG_HEIGHTFIELD_ONLY)
      fadeIn = voxelToHeightfieldBlend(horizontalDistance);
  } else {
    float boundary = lodEndDistance(lod - 1u);
    float halfWidth = lodTransitionHalfWidth(lod - 1u);
    fadeIn = fadeBetween(boundary - halfWidth, boundary + halfWidth,
                         horizontalDistance);
  }
  float fadeOut = 1.0;
  if (lod + 1u < g_meshSettings.levelCount) {
    float boundary = lodEndDistance(lod);
    float halfWidth = lodTransitionHalfWidth(lod);
    fadeOut = 1.0 - fadeBetween(boundary - halfWidth, boundary + halfWidth,
                                horizontalDistance);
  }
  if (fadeIn <= 0.0 || fadeOut <= 0.0)
    return false;
  return fadeInKeeps(fadeIn, noise) && fadeOutKeeps(fadeOut, noise);
}

// Conservative frustum test for a camera-relative axis-aligned box.
bool boxOutsideFrustum(float3 boxMinimum, float3 boxMaximum) {
  float4x4 m = g_meshSettings.viewProjRelative;
  float4 planes[5] = {
    m[3] + m[0], m[3] - m[0], m[3] + m[1], m[3] - m[1], m[3] - m[2],
  };
  for (uint index = 0u; index < 5u; index++) {
    float3 normal = planes[index].xyz;
    float3 farthestAlongNormal =
        float3(normal.x > 0.0 ? boxMaximum.x : boxMinimum.x,
               normal.y > 0.0 ? boxMaximum.y : boxMinimum.y,
               normal.z > 0.0 ? boxMaximum.z : boxMinimum.z);
    if (dot(normal, farthestAlongNormal) + planes[index].w < 0.0)
      return true;
  }
  return false;
}

bool heightfieldPatchInFrustum(uint lod, int2 patchStart, float cellSize) {
  TerrainLevel level = g_terrainLevels[lod];
  float step = verticalStepForLod(lod);
  // Columns extend half a cell past their centres; pad by a whole cell.
  float2 patchMinimum = float2(patchStart - int2(1)) * cellSize;
  float2 patchMaximum =
      float2(patchStart + int2(int(HEIGHTFIELD_PATCH_CELLS) + 1)) * cellSize;
  float3 offsetMinimum =
      float3(patchMinimum.x, level.minHeight - step, patchMinimum.y) -
      g_meshSettings.cameraPosition;
  float3 offsetMaximum =
      float3(patchMaximum.x, level.maxHeight + step, patchMaximum.y) -
      g_meshSettings.cameraPosition;
  return !boxOutsideFrustum(offsetMinimum, offsetMaximum);
}

// True when the voxel chunks under a LOD0 patch's corners are resident, so the
// voxel meshes cover it. While chunks are still streaming in (fast movement) the
// patch must keep drawing instead of leaving a hole.
bool voxelColumnResident(float2 xz, float height) {
  int3 voxel = int3(floor(float3(xz.x, height - 0.5, xz.y) /
                          g_meshSettings.voxelSize));
  VoxelChunk chunk;
  return lookupChunk(floorDiv3(voxel, CHUNK_SIZE), chunk);
}

bool patchVoxelBacked(int2 patchStart, float cellSize) {
  float2 center = (float2(patchStart) + float(HEIGHTFIELD_PATCH_CELLS) * 0.5) *
                  cellSize;
  if (distance(center, g_meshSettings.cameraPosition.xz) >
      g_meshSettings.nearVoxelDistance + 16.0)
    return false;
  for (uint corner = 0u; corner < 4u; corner++) {
    int2 cell = patchStart + int2(int(corner & 1u), int(corner >> 1u)) *
                                 int(HEIGHTFIELD_PATCH_CELLS);
    TerrainSample terrain;
    float quantizedHeight;
    if (!sampleTerrainColumn(cell, 0u, terrain, quantizedHeight) ||
        !voxelColumnResident(float2(cell) * cellSize, terrain.height))
      return false;
  }
  return true;
}

bool heightfieldPatchVisible(uint lod, int2 patchStart, float cellSize,
                             bool voxelBacked) {
  if (g_meshSettings.debugMode == DEBUG_VOXEL_ONLY)
    return false;
  float2 patchMinimum = float2(patchStart) * cellSize;
  float2 patchMaximum =
      float2(
          patchStart + int2(int(HEIGHTFIELD_PATCH_CELLS))) *
      cellSize;
  float2 closestToCamera =
      clamp(g_meshSettings.cameraPosition.xz, patchMinimum, patchMaximum);
  float closestDistance =
      distance(closestToCamera, g_meshSettings.cameraPosition.xz);
  float2 furthestOffset =
      max(abs(patchMinimum - g_meshSettings.cameraPosition.xz),
          abs(patchMaximum - g_meshSettings.cameraPosition.xz));
  float furthestDistance = length(furthestOffset);
  // Unbacked LOD0 patches are never culled from the inside: they stand in for
  // voxels that have not been generated yet.
  bool coveredFromInside = lod != 0u || voxelBacked;
  if (closestDistance > lodOuterReach(lod) + cellSize ||
      (coveredFromInside && furthestDistance < lodInnerReach(lod) - cellSize))
    return false;
  float2 closestToWorld =
      clamp(float2(0.0), patchMinimum, patchMaximum);
  return length(closestToWorld) <= g_meshSettings.worldRadius;
}

MeshVertex makeMeshVertex(float3 worldPosition, uint material, int3 voxel,
                          float3 normal, uint representation, uint lod,
                          int2 heightfieldCell, float cellSize,
                          float sourceHeight, float quantizedHeight,
                          float mountainInfluence) {
  MeshVertex output;
  float3 viewOffset = worldPosition - g_meshSettings.cameraPosition;
  output.position =
      mul(g_meshSettings.viewProjRelative, float4(viewOffset, 1.0));
  output.position.y = -output.position.y;
  output.worldPosition = worldPosition;
  output.viewOffset = viewOffset;
  output.voxelBacked = 1u;
  output.material = material;
  output.voxel = voxel;
  output.normal = normal;
  output.representation = representation;
  output.lod = lod;
  output.heightfieldCell = heightfieldCell;
  output.cellSize = cellSize;
  output.sourceHeight = sourceHeight;
  output.quantizedHeight = quantizedHeight;
  output.mountainInfluence = mountainInfluence;
  return output;
}

groupshared uint g_faceCount;

// One flat face of a virtual voxel column. Columns match the raymarcher: a flat
// top at the quantized height and vertical walls wherever a neighbour is lower.
struct ColumnQuad {
  bool valid;
  float3 corner[4];
  float3 normal;
  int2 cell;
  uint material;
  float sourceHeight;
  float quantizedHeight;
  float mountainInfluence;
  uint slot;
};

ColumnQuad emptyColumnQuad() {
  ColumnQuad quad = (ColumnQuad)0;
  quad.valid = false;
  return quad;
}

ColumnQuad makeColumnQuad(int2 cell, TerrainSample terrain, float height,
                          float3 normal) {
  ColumnQuad quad = emptyColumnQuad();
  quad.valid = true;
  quad.normal = normal;
  quad.cell = cell;
  quad.material = terrain.material;
  quad.sourceHeight = terrain.height;
  quad.quantizedHeight = height;
  quad.mountainInfluence = terrain.mountainInfluence;
  return quad;
}

// Emits the top of `cell` and the walls on its +x / +z edges. Each wall is owned
// by the column that stands higher, so shared edges are drawn exactly once.
void buildColumnQuads(int2 cell, uint lod, float cellSize,
                      inout ColumnQuad quads[3]) {
  TerrainSample terrain;
  float height;
  if (!sampleTerrainColumn(cell, lod, terrain, height))
    return;
  float halfSize = cellSize * 0.5;
  float2 center = float2(cell) * cellSize;
  float2 low = center - halfSize;
  float2 high = center + halfSize;

  quads[0] = makeColumnQuad(cell, terrain, height, float3(0, 1, 0));
  quads[0].corner[0] = float3(low.x, height, low.y);
  quads[0].corner[1] = float3(high.x, height, low.y);
  quads[0].corner[2] = float3(high.x, height, high.y);
  quads[0].corner[3] = float3(low.x, height, high.y);

  for (uint axis = 0u; axis < 2u; axis++) {
    int2 neighborCell = cell + (axis == 0u ? int2(1, 0) : int2(0, 1));
    TerrainSample neighbor;
    float neighborHeight;
    if (!sampleTerrainColumn(neighborCell, lod, neighbor, neighborHeight) ||
        abs(height - neighborHeight) < 1e-4)
      continue;
    bool ownHigher = height > neighborHeight;
    float lowerY = min(height, neighborHeight);
    float upperY = max(height, neighborHeight);
    float sign = ownHigher ? 1.0 : -1.0;
    ColumnQuad wall = ownHigher
                          ? makeColumnQuad(cell, terrain, height,
                                           axis == 0u ? float3(sign, 0, 0)
                                                      : float3(0, 0, sign))
                          : makeColumnQuad(neighborCell, neighbor,
                                           neighborHeight,
                                           axis == 0u ? float3(sign, 0, 0)
                                                      : float3(0, 0, sign));
    if (axis == 0u) {
      wall.corner[0] = float3(high.x, lowerY, low.y);
      wall.corner[1] = float3(high.x, lowerY, high.y);
      wall.corner[2] = float3(high.x, upperY, high.y);
      wall.corner[3] = float3(high.x, upperY, low.y);
    } else {
      wall.corner[0] = float3(low.x, lowerY, high.y);
      wall.corner[1] = float3(high.x, lowerY, high.y);
      wall.corner[2] = float3(high.x, upperY, high.y);
      wall.corner[3] = float3(low.x, upperY, high.y);
    }
    quads[1u + axis] = wall;
  }
}

[shader("mesh")]
[numthreads(32, 1, 1)]
[outputtopology("triangle")]
void mesh_main(uint3 groupID: SV_GroupID, uint threadID: SV_GroupThreadID,
               out vertices MeshVertex vertices[MAX_OUTPUT_VERTICES],
               out indices uint3 triangles[MAX_OUTPUT_PRIMITIVES]) {
  if (threadID == 0)
    g_faceCount = 0;
  GroupMemoryBarrierWithGroupSync();

  uint flatGroup = groupID.x + groupID.y * g_meshSettings.meshDispatchX;
  uint voxelWorkgroups =
      g_meshSettings.meshBrickCount * WORKGROUPS_PER_BRICK;
  uint totalWorkgroups =
      voxelWorkgroups + g_meshSettings.heightfieldWorkgroupCount;
  if (flatGroup >= totalWorkgroups) {
    SetMeshOutputCounts(0, 0);
    return;
  }

  if (flatGroup >= voxelWorkgroups) {
    uint lod;
    int2 patchStart;
    if (!heightfieldPatchForWorkgroup(flatGroup - voxelWorkgroups, lod,
                                      patchStart)) {
      SetMeshOutputCounts(0, 0);
      return;
    }
    float cellSize = meshCellSize(lod);
    if (!heightfieldPatchInFrustum(lod, patchStart, cellSize)) {
      SetMeshOutputCounts(0, 0);
      return;
    }
    bool voxelBacked = lod == 0u && patchVoxelBacked(patchStart, cellSize);
    if (!heightfieldPatchVisible(lod, patchStart, cellSize, voxelBacked)) {
      SetMeshOutputCounts(0, 0);
      return;
    }
    ColumnQuad quads[3];
    for (uint quadIndex = 0u; quadIndex < 3u; quadIndex++)
      quads[quadIndex] = emptyColumnQuad();
    if (threadID < HEIGHTFIELD_PATCH_CELLS * HEIGHTFIELD_PATCH_CELLS) {
      int2 cell = patchStart + int2(int(threadID % HEIGHTFIELD_PATCH_CELLS),
                                    int(threadID / HEIGHTFIELD_PATCH_CELLS));
      buildColumnQuads(cell, lod, cellSize, quads);
    }
    uint quadCount = 0u;
    for (uint quadIndex = 0u; quadIndex < 3u; quadIndex++) {
      if (quads[quadIndex].valid)
        InterlockedAdd(g_faceCount, 1u, quads[quadIndex].slot);
    }
    GroupMemoryBarrierWithGroupSync();
    SetMeshOutputCounts(g_faceCount * 4u, g_faceCount * 2u);
    for (uint quadIndex = 0u; quadIndex < 3u; quadIndex++) {
      ColumnQuad quad = quads[quadIndex];
      if (!quad.valid)
        continue;
      uint vertexBase = quad.slot * 4u;
      uint terrainMaterial =
          g_meshSettings.terrainMaterialOffset +
          min(quad.material, max(g_meshSettings.terrainMaterialCount, 1u) - 1u);
      for (uint corner = 0u; corner < 4u; corner++) {
        vertices[vertexBase + corner] = makeMeshVertex(
            quad.corner[corner], terrainMaterial,
            int3(quad.cell.x, int(lod), quad.cell.y), quad.normal,
            REPRESENTATION_HEIGHTFIELD, lod, quad.cell, cellSize,
            quad.sourceHeight, quad.quantizedHeight, quad.mountainInfluence);
        vertices[vertexBase + corner].voxelBacked = voxelBacked ? 1u : 0u;
      }
      triangles[quad.slot * 2u] =
          uint3(vertexBase, vertexBase + 1u, vertexBase + 2u);
      triangles[quad.slot * 2u + 1u] =
          uint3(vertexBase, vertexBase + 2u, vertexBase + 3u);
    }
    if (threadID == 0u) {
      InterlockedAdd(g_meshStats[0].heightfieldCells,
                     HEIGHTFIELD_PATCH_CELLS * HEIGHTFIELD_PATCH_CELLS);
      InterlockedAdd(g_meshStats[0].heightfieldPrimitives, g_faceCount * 2u);
    }
    return;
  }

  uint meshBrickIndex = flatGroup / WORKGROUPS_PER_BRICK;
  uint batchIndex = flatGroup % WORKGROUPS_PER_BRICK;
  MeshBrick meshBrick = g_meshBricks[meshBrickIndex];
  float3 brickMinimum = float3(meshBrick.voxelMin) * g_meshSettings.voxelSize;
  float3 brickMaximum = brickMinimum + BRICK_SIZE * g_meshSettings.voxelSize;
  float2 closest =
      clamp(g_meshSettings.cameraPosition.xz, brickMinimum.xz, brickMaximum.xz);
  bool brickCulled = distance(closest, g_meshSettings.cameraPosition.xz) >
                         g_meshSettings.nearVoxelDistance ||
                     g_meshSettings.debugMode == DEBUG_HEIGHTFIELD_ONLY ||
                     boxOutsideFrustum(brickMinimum - g_meshSettings.cameraPosition,
                                       brickMaximum - g_meshSettings.cameraPosition);
  if (brickCulled) {
    if (threadID == 0) {
      InterlockedAdd(g_meshStats[0].culledWorkgroups, 1u);
      if (batchIndex == 0)
        InterlockedAdd(g_meshStats[0].culledBricks, 1u);
    }
    SetMeshOutputCounts(0, 0);
    return;
  }
  if (threadID == 0) {
    InterlockedAdd(g_meshStats[0].meshWorkgroups, 1u);
    if (batchIndex == 0)
      InterlockedAdd(g_meshStats[0].visibleBricks, 1u);
  }

  int3 voxel = 0;
  uint material = 0;
  bool exposed[6];
  uint faceSlot[6];
  for (uint direction = 0; direction < 6; direction++) {
    exposed[direction] = false;
    faceSlot[direction] = 0;
  }

  uint voxelIndex = batchIndex * VOXELS_PER_WORKGROUP + threadID;
  if (threadID < VOXELS_PER_WORKGROUP && voxelIndex < VOXELS_PER_BRICK) {
    int3 local = int3(int(voxelIndex % 8u), int((voxelIndex / 8u) % 8u),
                      int(voxelIndex / 64u));
    voxel = meshBrick.voxelMin + local;
    if (sampleVoxel(voxel, material)) {
      for (uint direction = 0; direction < 6; direction++) {
        uint neighborMaterial;
        if (!sampleVoxel(voxel + NEIGHBOR_OFFSETS[direction],
                         neighborMaterial)) {
          exposed[direction] = true;
          InterlockedAdd(g_faceCount, 1u, faceSlot[direction]);
        }
      }
    }
  }

  GroupMemoryBarrierWithGroupSync();
  SetMeshOutputCounts(g_faceCount * 4u, g_faceCount * 2u);

  for (uint direction = 0; direction < 6; direction++) {
    if (!exposed[direction])
      continue;
    uint vertexBase = faceSlot[direction] * 4u;
    uint primitiveBase = faceSlot[direction] * 2u;
    for (uint faceCorner = 0; faceCorner < 4; faceCorner++) {
      uint corner = FACE_CORNERS[direction][faceCorner];
      float3 offset = float3(float(corner & 1u), float((corner >> 1u) & 1u),
                             float((corner >> 2u) & 1u));
      float3 worldPosition =
          (float3(voxel) + offset) * g_meshSettings.voxelSize;
      vertices[vertexBase + faceCorner] =
          makeMeshVertex(worldPosition, material, voxel,
                         float3(NEIGHBOR_OFFSETS[direction]),
                         REPRESENTATION_VOXEL, 0u, int2(0), 0.0, 0.0, 0.0,
                         0.0);
    }
    triangles[primitiveBase] =
        uint3(vertexBase, vertexBase + 1u, vertexBase + 2u);
    triangles[primitiveBase + 1u] =
        uint3(vertexBase, vertexBase + 2u, vertexBase + 3u);
  }
  if (threadID == 0) {
    InterlockedAdd(g_meshStats[0].generatedFaces, g_faceCount);
    InterlockedAdd(g_meshStats[0].generatedPrimitives, g_faceCount * 2u);
  }
}

float3 unpackColor(uint packed) {
  return float3(float(packed & 0xFFu), float((packed >> 8u) & 0xFFu),
                float((packed >> 16u) & 0xFFu)) /
         255.0;
}

float stableVariation(int3 voxel, uint material, float strength) {
  uint seed = g_meshSettings.visualSeedLo ^
              (g_meshSettings.visualSeedHi * 0x9E3779B9u) ^
              material * 0x85EBCA6Bu;
  float coarse =
      float(hashVoxel(floorDiv3(voxel, 8)) ^ seed) / 4294967295.0;
  float fine =
      float(hashVoxel(voxel) ^ hashUint(seed)) / 4294967295.0;
  return 1.0 + (coarse - 0.5) * strength * 0.9 +
         (fine - 0.5) * strength * 0.45;
}

float heightfieldVariation(MeshVertex input, float strength) {
  uint terrainMaterial = input.material - g_meshSettings.terrainMaterialOffset;
  uint seed = g_meshSettings.visualSeedLo ^
              (g_meshSettings.visualSeedHi * 0x9E3779B9u) ^
              terrainMaterial * 0x85EBCA6Bu;
  int3 cellKey =
      int3(input.heightfieldCell.x, int(input.lod), input.heightfieldCell.y);
  float geological =
      float(hashVoxel(floorDiv3(cellKey, 8)) ^ seed) / 4294967295.0;
  float cell =
      float(hashVoxel(cellKey) ^ hashUint(seed)) / 4294967295.0;
  return 1.0 + (geological - 0.5) * strength * 0.72 +
         (cell - 0.5) * strength * 0.28;
}

float3 lodDebugColor(uint lod) {
  if (lod == 0u)
    return float3(0.12, 0.9, 0.25);
  if (lod == 1u)
    return float3(0.95, 0.75, 0.08);
  if (lod == 2u)
    return float3(0.18, 0.45, 1.0);
  if (lod == 3u)
    return float3(0.92, 0.18, 0.72);
  if (lod == 4u)
    return float3(0.05, 0.88, 0.82);
  if (lod == 5u)
    return float3(1.0, 0.38, 0.08);
  if (lod == 6u)
    return float3(0.52, 0.24, 0.94);
  if (lod == 7u)
    return float3(0.72, 0.92, 0.12);
  return float3(0.08, 0.58, 0.95);
}

float3 heightfieldColor(MeshVertex input, MaterialRenderInfo info) {
  float3 base = unpackColor(info.baseColor);
  float3 surface =
      base * heightfieldVariation(input, info.variationStrength);
  if (g_meshSettings.debugMode == DEBUG_LOD)
    return lodDebugColor(input.lod);
  if (g_meshSettings.debugMode == DEBUG_MATERIAL)
    return base;
  if (g_meshSettings.debugMode == DEBUG_MOUNTAIN_INFLUENCE)
    return input.mountainInfluence.xxx;
  float2 local =
      frac((input.worldPosition.xz + input.cellSize * 0.5) / input.cellSize);
  float2 edgeDistance = min(local, 1.0 - local);
  float cellEdge =
      1.0 - smoothstep(0.025, 0.045, min(edgeDistance.x, edgeDistance.y));
  if (g_meshSettings.debugMode == DEBUG_HEIGHTFIELD_GRID)
    return lerp(surface * 0.35, float3(0.04, 0.95, 0.95), cellEdge);
  if (g_meshSettings.debugMode == DEBUG_VIRTUAL_VOXEL_CELLS)
    return lerp(surface * 0.28 + lodDebugColor(input.lod) * 0.18,
                float3(0.02, 1.0, 0.95), cellEdge);
  if (g_meshSettings.debugMode == DEBUG_VIRTUAL_VOXEL_FACES) {
    if (input.normal.y > 0.5)
      return float3(0.15, 0.95, 0.22);
    if (abs(input.normal.x) > 0.5)
      return input.normal.x > 0.0 ? float3(1.0, 0.18, 0.08)
                                  : float3(0.62, 0.04, 0.02);
    return input.normal.z > 0.0 ? float3(0.08, 0.42, 1.0)
                                : float3(0.03, 0.12, 0.58);
  }
  if (g_meshSettings.debugMode == DEBUG_LOD_TRANSITIONS) {
    float horizontalDistance =
        length(input.worldPosition.xz - g_meshSettings.cameraPosition.xz);
    bool inTransition =
        abs(horizontalDistance - g_meshSettings.nearVoxelDistance) <
        g_meshSettings.voxelTransitionWidth;
    for (uint lod = 0u; lod < g_meshSettings.levelCount; lod++) {
      inTransition =
          inTransition ||
          abs(horizontalDistance - lodEndDistance(lod)) <
              lodTransitionHalfWidth(lod);
    }
    return inTransition ? float3(1.0, 0.04, 0.75) : surface * 0.25;
  }
  if (g_meshSettings.debugMode == DEBUG_HEIGHT_QUANTIZATION) {
    float verticalStep = verticalStepForLod(input.lod);
    float loss = saturate(abs(input.sourceHeight - input.quantizedHeight) /
                          (verticalStep * 0.5));
    return lerp(float3(0.08, 0.18, 0.95), float3(1.0, 0.12, 0.02), loss);
  }
  if (g_meshSettings.debugMode == DEBUG_DDA_TRAVERSAL)
    return surface * 0.25;
  if (g_meshSettings.debugMode == DEBUG_WORLD_RING) {
    float ringDistance =
        abs(length(input.worldPosition.xz) - g_meshSettings.debugRingRadius);
    return ringDistance < 80.0 ? float3(1.0, 0.05, 0.05) : surface * 0.35;
  }
  if (g_meshSettings.debugMode == DEBUG_RESIDENCY)
    return surface * 0.18;
  if (g_meshSettings.debugMode == DEBUG_REPRESENTATION)
    return float3(0.95, 0.58, 0.08);
  if (g_meshSettings.debugMode >= DEBUG_MODIFICATIONS &&
      g_meshSettings.debugMode <= DEBUG_ORE)
    return surface * 0.12;
  return surface;
}

float3 voxelColor(MeshVertex input, MaterialRenderInfo info) {
  float3 color =
      unpackColor(info.baseColor) *
      stableVariation(input.voxel, input.material, info.variationStrength);
  if (g_meshSettings.debugMode == DEBUG_MATERIAL)
    return unpackColor(info.baseColor);
  if (g_meshSettings.debugMode == DEBUG_BRICK_CLASSIFICATION)
    return color;
  if (g_meshSettings.debugMode == DEBUG_ORE)
    return (info.flags & MATERIAL_FLAG_RESOURCE) != 0
               ? float3(1.0, 0.8, 0.05)
               : color * 0.12;
  if (g_meshSettings.debugMode == DEBUG_REPRESENTATION)
    return float3(0.1, 0.9, 0.9);
  return color;
}

[shader("fragment")]
float4 fragment_main(MeshVertex input) : SV_Target {
  // Distance from the camera, from the precise camera-relative offset.
  float horizontalDistance = length(input.viewOffset.xz);
  float noise = transitionNoise(input.position.xy);
  if (input.representation == REPRESENTATION_HEIGHTFIELD) {
    if (length(input.worldPosition.xz) > g_meshSettings.worldRadius)
      discard;
    if (!heightfieldFragmentVisible(input.lod, horizontalDistance, noise,
                                    input.voxelBacked != 0u))
      discard;
  } else if (!voxelFragmentVisible(horizontalDistance, noise)) {
    discard;
  }

  uint materialLimit =
      input.representation == REPRESENTATION_HEIGHTFIELD
          ? g_meshSettings.terrainMaterialOffset +
                g_meshSettings.terrainMaterialCount
          : g_meshSettings.materialCount;
  uint materialIndex = min(input.material, max(materialLimit, 1u) - 1u);
  MaterialRenderInfo info = g_materials[materialIndex];
  float3 color =
      input.representation == REPRESENTATION_HEIGHTFIELD
          ? heightfieldColor(input, info)
          : voxelColor(input, info);
  if (g_meshSettings.debugMode == DEBUG_NORMAL) {
    float3 sunDirection = normalize(float3(0.45, 0.82, 0.35));
    float diffuse =
        0.28 + 0.72 * saturate(dot(normalize(input.normal), sunDirection));
    float distanceFog =
        saturate(distance(input.worldPosition, g_meshSettings.cameraPosition) /
                 g_meshSettings.maxDistance);
    float3 viewDirection =
        normalize(input.worldPosition - g_meshSettings.cameraPosition);
    float3 sky =
        lerp(float3(0.13, 0.18, 0.24), float3(0.36, 0.48, 0.60),
             saturate(viewDirection.y * 0.5 + 0.5));
    color *= diffuse;
    color = lerp(color, sky, distanceFog * distanceFog * 0.72);
  }
  float2 crosshair =
      abs(input.position.xy - g_meshSettings.outputSize * 0.5);
  if ((crosshair.x < 1.0 && crosshair.y < 6.0) ||
      (crosshair.y < 1.0 && crosshair.x < 6.0))
    color = lerp(color, float3(0.95, 0.95, 0.95), 0.85);
  return float4(color, 1.0);
}
