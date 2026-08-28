import utils.voxel_math;

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
  uint2 _padding;
};

struct MeshVertex {
  float4 position : SV_Position;
  float3 worldPosition : TEXCOORD0;
  nointerpolation uint material : TEXCOORD1;
  nointerpolation int3 voxel : TEXCOORD2;
  nointerpolation float3 normal : TEXCOORD3;
};

uniform MeshSettings g_meshSettings;
uniform StructuredBuffer<VoxelChunk> g_voxelChunks;
uniform StructuredBuffer<VoxelBrick> g_voxelBricks;
uniform StructuredBuffer<uint> g_voxelMaterials;
uniform StructuredBuffer<VoxelChunkSlot> g_voxelChunkTable;
uniform StructuredBuffer<MaterialRenderInfo> g_materials;
uniform StructuredBuffer<MeshBrick> g_meshBricks;
uniform RWTexture2D<float> g_heightfieldDepth;
uniform RWStructuredBuffer<MeshStats> g_meshStats;

static const uint BRICK_EMPTY = 0u;
static const uint BRICK_SOLID = 1u;
static const int CHUNK_SIZE = 32;
static const int BRICK_SIZE = 8;
static const uint VOXELS_PER_BRICK = 512u;
static const uint VOXELS_PER_WORKGROUP = 10u;
static const uint WORKGROUPS_PER_BRICK = 52u;
static const uint MAX_OUTPUT_VERTICES = 240u;
static const uint MAX_OUTPUT_PRIMITIVES = 120u;
static const uint VOXEL_MATERIALS_PER_WORD = 4u;
static const uint DEBUG_NORMAL = 0u;
static const uint DEBUG_MATERIAL = 2u;
static const uint DEBUG_HEIGHTFIELD_ONLY = 45u;

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
  uint totalWorkgroups = g_meshSettings.meshBrickCount * WORKGROUPS_PER_BRICK;
  if (flatGroup >= totalWorkgroups) {
    SetMeshOutputCounts(0, 0);
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
      MeshVertex output;
      output.position = mul(g_meshSettings.viewProj, float4(worldPosition, 1));
      output.position.y = -output.position.y;
      output.position.z = (output.position.z + output.position.w) * 0.5;
      output.worldPosition = worldPosition;
      output.material = material;
      output.voxel = voxel;
      output.normal = float3(NEIGHBOR_OFFSETS[direction]);
      vertices[vertexBase + faceCorner] = output;
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
  float coarse = float(hashVoxel(floorDiv3(voxel, 8)) ^ seed) / 4294967295.0;
  float fine = float(hashVoxel(voxel) ^ hashUint(seed)) / 4294967295.0;
  return 1.0 + (coarse - 0.5) * strength * 0.9 + (fine - 0.5) * strength * 0.45;
}

[shader("fragment")]
float4 fragment_main(MeshVertex input) : SV_Target {
  uint width, height;
  g_heightfieldDepth.GetDimensions(width, height);
  uint2 pixel = min(uint2(input.position.xy), uint2(width - 1, height - 1));
  float voxelDistance =
      distance(input.worldPosition, g_meshSettings.cameraPosition);
  float heightfieldDistance = g_heightfieldDepth[pixel];
  if (heightfieldDistance + g_meshSettings.voxelSize * 2.0 < voxelDistance)
    discard;

  uint materialIndex =
      min(input.material, max(g_meshSettings.materialCount, 1u) - 1u);
  MaterialRenderInfo info = g_materials[materialIndex];
  float3 color =
      unpackColor(info.baseColor) *
      stableVariation(input.voxel, input.material, info.variationStrength);
  if (g_meshSettings.debugMode == DEBUG_MATERIAL)
    color = unpackColor(info.baseColor);
  float3 normal = input.normal;
  float3 sunDirection = normalize(float3(0.45, 0.82, 0.35));
  float diffuse = 0.28 + 0.72 * saturate(dot(normal, sunDirection));
  color *= diffuse;
  float2 crosshair = abs(input.position.xy - float2(width, height) * 0.5);
  if ((crosshair.x < 1.0 && crosshair.y < 6.0) ||
      (crosshair.y < 1.0 && crosshair.x < 6.0))
    color = lerp(color, float3(0.95, 0.95, 0.95), 0.85);
  return float4(color, 1.0);
}
