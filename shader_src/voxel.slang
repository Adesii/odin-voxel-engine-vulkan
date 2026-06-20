import utils.camera;
import utils.ray;
import utils.voxel_types;

uniform CameraUniforms g_camera;
uniform StructuredBuffer<VoxelVolume> g_volume;

uniform RWTexture2D<float4> g_outputFramebuffer;

// voxel.slang

Ray generate_camera_ray(uint2 pixelCoord, float2 screenSize) {
  float2 ndc = ((float2(pixelCoord) + 0.5) / screenSize) * 2.0 - 1.0;
  ndc.y = -ndc.y; // Standard Vulkan/Graphics Y orientation

  // Standard near plane depth format
  float4 clipTarget = float4(ndc.x, ndc.y, -1.0, 1.0);

  float4 worldTarget = mul(g_camera.invViewProj, clipTarget);
  worldTarget /= worldTarget.w; // Classic perspective division step

  Ray ray;
  ray.origin = g_camera.position;
  ray.direction = normalize(worldTarget.xyz - ray.origin);

  return ray;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID: SV_DispatchThreadID) {
  uint2 pixelCoord = dispatchThreadID.xy;

  // 1. MUST use unsigned integers for GetDimensions!
  uint width, height;
  g_outputFramebuffer.GetDimensions(width, height);

  // Guard against overflow or window resizing threads
  if (pixelCoord.x >= width || pixelCoord.y >= height)
    return;

  // 2. Safely cast to floats for the ray generation math
  float2 screenSize = float2((float)width, (float)height);

  // 1. Generate the ray
  Ray ray = generate_camera_ray(pixelCoord, screenSize);
  float4 finalColor = float4(0.2, 0.4, 0.6, 1.0); // Default sky bluebackground

  float depth = 1e9; // Start with a very large depth value
  bool hasPrimaryHit = false;
  float3 primaryColor = float3(0, 0, 0);
  float3 primaryHitWorld = float3(0, 0, 0);

  for (int i = 0; i < g_volume.getCount(); i++) {
    VoxelVolume volume = g_volume[i];

    Ray localRay;
    localRay.direction.x = dot(volume.invRotation[0], ray.direction);
    localRay.direction.y = dot(volume.invRotation[1], ray.direction);
    localRay.direction.z = dot(volume.invRotation[2], ray.direction);

    float3 translatedOrigin = ray.origin - volume.origin;
    localRay.origin.x = dot(volume.invRotation[0], translatedOrigin);
    localRay.origin.y = dot(volume.invRotation[1], translatedOrigin);
    localRay.origin.z = dot(volume.invRotation[2], translatedOrigin);

    HitInfo hit;
    if (TraceVoxelVolumeLocal(localRay, volume, depth, hit)) {
      float3 hitWorld = volume.origin + mul(volume.rotation, hit.position);
      float worldDepth = distance(hitWorld, ray.origin);

      if (worldDepth < depth) {
        depth = worldDepth;
        hasPrimaryHit = true;
        primaryColor = hit.color.rgb;
        primaryHitWorld = hitWorld;
      }
    }
  }

  if (hasPrimaryHit) {
    Ray shadowRay;
    shadowRay.origin = primaryHitWorld + float3(0, 1, 0) * 0.01;
    shadowRay.direction = float3(0.5, 1, 0.5);

    bool inShadow = false;
    for (int i = 0; i < g_volume.getCount(); i++) {
      HitInfo shadowHit;
      if (TraceVoxelVolume(shadowRay, g_volume[i], 100000.0, shadowHit)) {
        inShadow = true;
        break;
      }
    }

    float depth_shadow = 1.0 / (1.0 + (depth * 0.002));
    float shadowFactor = inShadow ? 0.35 : 1.0;
    finalColor = float4(primaryColor * depth_shadow * shadowFactor, 1.0);
  }

  g_outputFramebuffer[pixelCoord] = finalColor;
}
