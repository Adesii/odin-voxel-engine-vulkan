# Repository invariants

- Run build, shader, test, and executable commands from the repository root; runtime asset and save paths are root-relative.
- `shader_src/` is the shader source of truth. Never hand-edit reflected Odin files under `src/shaders/` or generated shader artifacts under `shaders/`; run `just build-shaders` or the forced `just build-shaders-debug` workflow.
- Any shader interface change must regenerate reflection and Odin bindings. CPU/Slang buffer layouts, descriptor bindings, entry points, and their compile-time size checks must agree.
- Terrain backend selection is render policy, not world configuration. Raymarch and mesh must consume the same live heightfield cache, resident voxel world, sparse edits, materials, seed, camera, and common terrain settings.
- Switching backend must not regenerate, reload, fork, or mutate world state. World type/seed generation and representation configuration remain backend-independent.
- Common terrain configuration retains equivalent meaning across both backends. If a shared distance, transition, LOD, material, or debug contract changes, update and verify every backend path that promises that contract.
- The camera projection far plane must cover the configured terrain far distance; otherwise rasterized mesh LODs are clipped even while raymarch LODs still render.
- Keep heightfield capacity/count, cache spacing, render LOD data, shader-side representation, GPU uploads, validation, statistics, and package tests synchronized; never add a separate hard-coded LOD convention.
- World generation and persistence policy belongs in the game package; reusable cache/voxel/edit storage belongs in engine terrain packages; render packages only consume and upload that data.
