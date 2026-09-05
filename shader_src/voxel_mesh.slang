import utils.voxel_math;

static const uint MAX_LOD_LEVELS = 9u;

struct MeshSettings {
  float4x4 viewProj;
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
  float heightfieldTransitionWidth;
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
  uint _padding;
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
  uint lod;
  uint _padding;
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
static const uint HEIGHTFIELD_PATCH_CELLS = 7u;
static const uint HEIGHTFIELD_PATCH_VERTICES = 8u;
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

TerrainSample loadTerrainSample(TerrainLevel level, int2 sampleCoord) {
  return g_terrainSamples[level.sampleOffset +
                          uint(sampleCoord.y) * level.sampleCount +
                          uint(sampleCoord.x)];
}

bool sampleTerrainColumn(int2 cell, uint lod, out TerrainSample terrain,
                         out float quantizedHeight) {
  terrain = (TerrainSample)0;
  quantizedHeight = 0.0;
  TerrainLevel level = g_terrainLevels[lod];
  float cellSize =
      lodValue(g_meshSettings.virtualVoxelSizes0,
               g_meshSettings.virtualVoxelSizes1,
               g_meshSettings.virtualVoxelSizes2, lod);
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
  int2 nearestSample =
      min(int2(floor(samplePosition + 0.5)), maximumCoord);
  terrain.material = loadTerrainSample(level, nearestSample).material;
  float verticalStep =
      max(lodValue(g_meshSettings.verticalSteps0,
                   g_meshSettings.verticalSteps1,
                   g_meshSettings.verticalSteps2, lod),
          0.001);
  quantizedHeight = floor(terrain.height / verticalStep) * verticalStep;
  return true;
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
    float cellSize =
        lodValue(g_meshSettings.virtualVoxelSizes0,
                 g_meshSettings.virtualVoxelSizes1,
                 g_meshSettings.virtualVoxelSizes2, lod);
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

bool heightfieldPatchVisible(uint lod, int2 patchStart, float cellSize) {
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
  float innerDistance =
      lod == 0u
          ? (g_meshSettings.debugMode == DEBUG_HEIGHTFIELD_ONLY
                 ? 0.0
                 : g_meshSettings.nearVoxelDistance)
          : lodEndDistance(lod - 1u);
  float innerOverlap =
      max(lod == 0u ? g_meshSettings.voxelTransitionWidth
                    : g_meshSettings.heightfieldTransitionWidth,
          cellSize);
  float outerOverlap =
      max(g_meshSettings.heightfieldTransitionWidth, cellSize);
  if (closestDistance > lodEndDistance(lod) + outerOverlap ||
      furthestDistance < max(innerDistance - innerOverlap, 0.0))
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
  output.position =
      mul(g_meshSettings.viewProj, float4(worldPosition, 1.0));
  output.position.y = -output.position.y;
  output.position.z = (output.position.z + output.position.w) * 0.5;
  output.worldPosition = worldPosition;
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
    float cellSize =
        lodValue(g_meshSettings.virtualVoxelSizes0,
                 g_meshSettings.virtualVoxelSizes1,
                 g_meshSettings.virtualVoxelSizes2, lod);
    if (!heightfieldPatchVisible(lod, patchStart, cellSize)) {
      SetMeshOutputCounts(0, 0);
      return;
    }
    SetMeshOutputCounts(
        HEIGHTFIELD_PATCH_VERTICES * HEIGHTFIELD_PATCH_VERTICES,
        HEIGHTFIELD_PATCH_CELLS * HEIGHTFIELD_PATCH_CELLS * 2u);

    for (uint vertexSlot = threadID;
         vertexSlot <
         HEIGHTFIELD_PATCH_VERTICES * HEIGHTFIELD_PATCH_VERTICES;
         vertexSlot += 32u) {
      int2 cell =
          patchStart +
          int2(int(vertexSlot % HEIGHTFIELD_PATCH_VERTICES),
               int(vertexSlot / HEIGHTFIELD_PATCH_VERTICES));
      TerrainSample terrain;
      float quantizedHeight;
      sampleTerrainColumn(cell, lod, terrain, quantizedHeight);
      TerrainSample neighborTerrain;
      float leftHeight;
      float rightHeight;
      float backHeight;
      float frontHeight;
      sampleTerrainColumn(cell + int2(-1, 0), lod, neighborTerrain,
                          leftHeight);
      sampleTerrainColumn(cell + int2(1, 0), lod, neighborTerrain,
                          rightHeight);
      sampleTerrainColumn(cell + int2(0, -1), lod, neighborTerrain,
                          backHeight);
      sampleTerrainColumn(cell + int2(0, 1), lod, neighborTerrain,
                          frontHeight);
      float3 normal =
          normalize(float3(leftHeight - rightHeight, cellSize * 2.0,
                           backHeight - frontHeight));
      uint terrainMaterial =
          g_meshSettings.terrainMaterialOffset +
          min(terrain.material,
              max(g_meshSettings.terrainMaterialCount, 1u) - 1u);
      float3 worldPosition =
          float3(float(cell.x) * cellSize, quantizedHeight,
                 float(cell.y) * cellSize);
      vertices[vertexSlot] =
          makeMeshVertex(worldPosition, terrainMaterial,
                         int3(cell.x, int(lod), cell.y), normal,
                         REPRESENTATION_HEIGHTFIELD, lod, cell, cellSize,
                         terrain.height, quantizedHeight,
                         terrain.mountainInfluence);
    }
    for (uint patchCell = threadID;
         patchCell < HEIGHTFIELD_PATCH_CELLS * HEIGHTFIELD_PATCH_CELLS;
         patchCell += 32u) {
      uint x = patchCell % HEIGHTFIELD_PATCH_CELLS;
      uint z = patchCell / HEIGHTFIELD_PATCH_CELLS;
      uint vertexBase = z * HEIGHTFIELD_PATCH_VERTICES + x;
      uint primitiveBase = patchCell * 2u;
      triangles[primitiveBase] =
          uint3(vertexBase, vertexBase + 1u,
                vertexBase + HEIGHTFIELD_PATCH_VERTICES + 1u);
      triangles[primitiveBase + 1u] =
          uint3(vertexBase,
                vertexBase + HEIGHTFIELD_PATCH_VERTICES + 1u,
                vertexBase + HEIGHTFIELD_PATCH_VERTICES);
    }
    if (threadID == 0u) {
      InterlockedAdd(
          g_meshStats[0].heightfieldCells,
          HEIGHTFIELD_PATCH_CELLS * HEIGHTFIELD_PATCH_CELLS);
      InterlockedAdd(
          g_meshStats[0].heightfieldPrimitives,
          HEIGHTFIELD_PATCH_CELLS * HEIGHTFIELD_PATCH_CELLS * 2u);
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
                     g_meshSettings.debugMode == DEBUG_HEIGHTFIELD_ONLY;
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
              g_meshSettings.heightfieldTransitionWidth;
    }
    return inTransition ? float3(1.0, 0.04, 0.75) : surface * 0.25;
  }
  if (g_meshSettings.debugMode == DEBUG_HEIGHT_QUANTIZATION) {
    float verticalStep =
        max(lodValue(g_meshSettings.verticalSteps0,
                     g_meshSettings.verticalSteps1,
                     g_meshSettings.verticalSteps2, input.lod),
            0.001);
    float loss =
        saturate((input.sourceHeight - input.quantizedHeight) / verticalStep);
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
  if (input.representation == REPRESENTATION_HEIGHTFIELD) {
    if (length(input.worldPosition.xz) > g_meshSettings.worldRadius)
      discard;
    float horizontalDistance =
        length(input.worldPosition.xz - g_meshSettings.cameraPosition.xz);
    float innerTransitionWidth =
        input.lod == 0u ? g_meshSettings.voxelTransitionWidth
                        : g_meshSettings.heightfieldTransitionWidth;
    float innerDistance =
        input.lod == 0u
            ? (g_meshSettings.debugMode == DEBUG_HEIGHTFIELD_ONLY
                   ? 0.0
                   : g_meshSettings.nearVoxelDistance)
            : lodEndDistance(input.lod - 1u);
    if (horizontalDistance <
            max(innerDistance - innerTransitionWidth, 0.0) ||
        horizontalDistance >
            lodEndDistance(input.lod) +
                g_meshSettings.heightfieldTransitionWidth)
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
