[[vk::binding(2, 0)]]
cbuffer Globals {
  float4x4 transform;
};

[[vk::binding(0, 0)]]
SamplerState samp;

[[vk::binding(1, 0)]]
Texture2D<float> text;

struct VSOut {
  float4 position : SV_Position;
  float2 texCoord : TEXCOORD0;
  nointerpolation uint color : COLOR0;
};

[shader("vertex")]
VSOut vs_main(float2 pos : POSITION, float2 texCoord : TEXCOORD0, uint color : COLOR0) {
  VSOut output;
  output.position = mul(transform, float4(pos, 0.0, 1.0));
  output.texCoord = texCoord;
  output.color = color;
  return output;
}

[shader("fragment")]
float4 fs_main(VSOut input) : SV_Target {
  float a = text.Sample(samp, input.texCoord).r * float((input.color >> 24) & 0xffu) / 255.0;
  float b = float((input.color >> 16) & 0xffu) / 255.0;
  float g = float((input.color >> 8) & 0xffu) / 255.0;
  float r = float(input.color & 0xffu) / 255.0;
  return float4(r, g, b, a);
}
