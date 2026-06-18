
// hello.slang

struct VertexOutput {
  float4 position : SV_Position;
  float2 uv : TEXCOORD0;
};

uniform Sampler2D g_texture;

[shader("vertex")]
VertexOutput vs_main(uint vertexID: SV_VertexID) {
  VertexOutput output;

  // Define 4 structural coordinates mapping out a perfect 2D square
  // to fill Normalized Device Coordinates (NDC) completely
  float2 gridPositions[4] = {
    float2(-1.0, -1.0), // 0: Top-Left
    float2(1.0, -1.0),  // 1: Top-Right
    float2(-1.0, 1.0),  // 2: Bottom-Left
    float2(1.0, 1.0)    // 3: Bottom-Right
  };

  // Explicitly align the normalized UV texture sampling coordinates (0 to 1)
  float2 gridUVs[4] = {
    float2(0.0, 0.0), // 0: Top-Left
    float2(1.0, 0.0), // 1: Top-Right
    float2(0.0, 1.0), // 2: Bottom-Left
    float2(1.0, 1.0)  // 3: Bottom-Right
  };

  // Map your 3 incoming vertex IDs sequentially to rasterize the quad
  // using a hardware triangle strip approach:
  // If your pipeline topology is set to TRIANGLE_LIST, we use a 6-index mapping
  // scheme. If your pipeline uses TRIANGLE_STRIP, change vertex draw bounds
  // to 4.

  // Fallback standard for a standard TRIANGLE_LIST (6 vertices total drawn):
  uint indexOrder[6] = { 0, 1, 2, 2, 1, 3 };
  uint targetIndex = indexOrder[vertexID];

  output.position = float4(gridPositions[targetIndex], 0.0, 1.0);
  output.uv = gridUVs[targetIndex];

  return output;
}

[shader("fragment")]
float4 fs_main(VertexOutput input) : SV_Target {
  // Perfect 0.0 -> 1.0 sampling coverage across your compute surface bounds!
  float4 sampledColor = g_texture.SampleLevel(input.uv, 0);

  return sampledColor;
}
