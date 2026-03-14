
// hello.slang

// Vertex Shader Output Structure
struct VertexOutput {
  float4 position : SV_Position;
  float4 color : COLOR0;
};

// Vertex Shader Entry Point
[shader("vertex")]
VertexOutput vs_main(uint vertexID: SV_VertexID) {
  float2 positions[] = { float2(+0.0, -0.5), float2(+0.5, +0.5),
                         float2(-0.5, +0.5) };
  float4 colors[] = { float4(1, 0, 0, 1), float4(0, 1, 0, 1),
                      float4(0, 0, 1, 1) };

  VertexOutput output;
  output.position = float4(positions[vertexID], 0.0, 1.0);
  output.color = colors[vertexID];
  return output;
}

// Fragment Shader Entry Point
[shader("fragment")]
float4 fs_main(VertexOutput input) : SV_Target { return input.color; }

