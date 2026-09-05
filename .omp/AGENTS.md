# Repository onboarding

## Quick start

Run commands from the repository root; shader, asset, and save paths are relative to it.

Required developer tools are Odin, `just`, `slangc`, and a Vulkan-capable system. The mesh terrain path additionally requires `VK_EXT_mesh_shader` and the device limits checked at startup.

```sh
just build-debug       # compile bin/voxel with Odin debug checks
just run-debug         # run an already-built debug binary
just all               # build-debug, then run-debug
just build             # compile bin/voxel
just run               # run an already-built binary
just run-release       # optimized build, then run
```

`just run-release-fresh` deletes the main saved world before building and running; use it only when a fresh generated world is intended.

Select terrain and benchmark-world variants on the executable:

```sh
bin/voxel --terrain=raymarch --world=delta_core
bin/voxel --terrain=mesh --world=flat
```

The accepted world values are `delta_core`, `flat`, `noise`, and `stress`. Raymarch is the default terrain backend. Mesh selection fails clearly when the required Vulkan mesh-shader capability or limits are unavailable. In the running app, F5 switches terrain backend without recreating the world and F6 recompiles/reloads shaders.

## Tests

There is no aggregate `just` test recipe. Tests live beside their Odin packages and are run per package:

```sh
odin test src/game/delta_core
odin test src/engine/terrain/heightfield
odin test src/engine/terrain/voxel
odin test src/engine/render/terrain
```

Add a package command when another directory gains `@(test)` procedures. Keep tests package-local unless behavior genuinely crosses the game/world boundary.

## Shader workflow

Author shaders under `shader_src/`; shared Slang helpers are under `shader_src/utils/`. Runtime artifacts are loaded from `shaders/`, while reflected Odin layouts and binding constants are generated under `src/shaders/`.

```sh
just build-shaders          # incremental Slang compile plus reflection/binding generation
just build-shaders-debug    # force every shader to recompile, then regenerate bindings
```

The shader tool invokes `slangc`, writes SPIR-V and reflection JSON, then derives the Odin binding packages from that reflection. Use the forced command after changing shader interfaces or whenever timestamps/artifacts may be stale. Do not hand-edit generated files in `src/shaders/`; change the Slang source and regenerate. SPIR-V files are ignored by Git, while reflection and generated-source changes should be reviewed with the source change.

The app also compiles shaders on startup and watches the presentation and terrain shader sources during a run. The `just` recipes remain the canonical way to deliberately regenerate all reflected bindings before an Odin build.

## Module map

- `src/main.odin` — minimal executable entry; hands control to the game package.
- `src/game/delta_core/` — application lifecycle, input/UI, world planning and generation, persistence, material policy, and the composition root that connects world data to rendering.
- `src/engine/terrain/heightfield/` — multi-resolution sampled terrain cache and its LOD levels. Inner levels follow the camera while the outer level remains world-centered for full coverage. The package owns cache storage/streaming, not procedural game-world policy.
- `src/engine/terrain/voxel/` — near-field resident chunk/brick data, streaming, material queries, and CPU raycasts.
- `src/engine/terrain/sparse/` — persistent sparse voxel overrides used for mining/building edits.
- `src/engine/render/terrain/` — terrain renderer facade, GPU uploads, raymarch compute pipeline, mesh pipeline, backend dispatch, and render statistics.
- `src/engine/render/vulkan/` — Vulkan device, swapchain, resources, synchronization, frame submission, and capability discovery.
- `src/engine/render/shader_assets/` — canonical runtime paths for shader source and compiled assets.
- `src/engine/tools/shader/` — Slang compilation, reflection-to-Odin generation, and file watching.
- `src/engine/view/` and `src/engine/ui/` — camera state and UI overlay.
- `shader_src/` — hand-authored Slang; `shaders/` and `src/shaders/` are outputs of the shader workflow.
- `saves/` — runtime world persistence; not source data.

## Terrain and world boundaries

The game package owns the natural terrain definition, seed/world plan, materials, persistence, and configuration. It exposes sampling adapters to the engine. World streaming maintains two derived representations from the same terrain source:

1. the heightfield cache supplies broad, multi-resolution terrain coverage, with camera-following inner levels and fixed world-centered outer coverage;
2. the resident voxel world supplies detailed chunks around the camera and applies the sparse edit set.

The renderer receives those same live objects, material tables, camera, and terrain configuration in one frame input. Rendering must consume them; it must not become a second source of world generation or persistence policy.

`world_config.odin` is the composition boundary for world settings, render settings, and representation/cache settings. Keep their validation aligned when changing distances, LOD counts, cache spacing, voxel scale, or residency. The natural terrain sampler is the source for both heightfield samples and voxel columns, so changes there intentionally affect both representations.

The default terrain stack uses nine factor-of-two levels. Heightfield spacing, virtual cell size, and vertical quantization progress through `1, 2, 4, 8, 16, 32, 64, 128, 256`; LOD band ends are derived from screen coverage. Camera-following inner levels preserve local detail, while one fixed world-centered outer level provides final far-distance coverage without forcing an enormous near cache.

## Raymarch and mesh responsibilities

Both choices are views of one world, not separate world modes:

- **Raymarch:** `shader_src/terrain.slang` traces resident voxels in the near field and the configured heightfield LODs beyond/through the representation transition, then writes the composed color and linear depth.
- **Mesh shader:** the terrain compute pass only clears sky color and linear depth. `shader_src/voxel_mesh.slang` emits both exposed faces from resident voxel chunk/brick data and tessellated heightfield LOD patches whose vertices use the shared quantized level/sample data. Hardware depth testing composes that geometry into one terrain result.

The Odin terrain renderer owns common uploads for heightfield levels/samples, resident voxel data, sparse overrides, and materials. The mesh renderer reuses those common heightfield and voxel buffers and adds candidate-brick, mesh-pipeline, depth, and mesh-stat resources. Startup flags choose the initial backend; runtime switching changes only renderer policy and preserves the live world/cache/edit state.

Unlike compute raymarching, rasterized mesh terrain is clipped by the camera projection. The game therefore updates the camera with the configured terrain far distance as its projection far plane; keeping the camera helper's shorter default would silently remove the outer mesh LODs.

When changing shared terrain behavior, check both backend paths. A setting represented as common terrain configuration must keep the same meaning in each backend even when implementation differs. Backend-specific GPU capability checks and statistics may remain backend-specific.

## Working conventions

- Prefer changing ownership at its boundary: game terrain policy in `src/game/delta_core`, reusable representation logic in `src/engine/terrain`, and GPU presentation in `src/engine/render/terrain` plus `shader_src`.
- Treat CPU structs mirrored into Slang as an ABI. Regenerate bindings after shader layout/binding/entry-point changes and keep the compile-time size checks valid.
- Stream/cache updates follow camera movement; do not make renderer selection regenerate the world or fork its data.
- Preserve deterministic world generation and persistence compatibility deliberately. Tests that create saves use dedicated temporary names; do not point them at the normal runtime save.
- Keep LOD arrays, active level counts, shader representations, uploads, validation, statistics, and tests in sync. Do not assume a fixed count in a new call site when a shared capacity/count already defines it.
