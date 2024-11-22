# This file can be pointed to with a `MOZ_BUILD_HOOK` path to avoid optimizing WebGPU-specific code
# in Firefox.
#
# See these Firefox docs. for reference:
# <https://firefox-source-docs.mozilla.org/setup/configuring_build_options.html#changing-build-options-per-directory-the-moz-build-hook>

nonopt = (
    "dom/webgpu/",
    "gfx/wgpu_bindings",
    "third_party/rust/naga",
    "third_party/rust/wgpu-core",
    "third_party/rust/wgpu-hal",
    "third_party/rust/wgpu-types",
)

if RELATIVEDIR.startswith(nonopt):
    COMPILE_FLAGS["OPTIMIZE"] = []
