module Camera;

public struct CameraUniforms {
  public column_major float4x4 viewProj;
  public column_major float4x4 invViewProj; // Match your new Odin field
  public float3 position;
};

