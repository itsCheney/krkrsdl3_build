set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_OSX_DEPLOYMENT_TARGET 13.0)
# Mikage only links the Release framework. Avoid building an unused Debug
# variant of each dependency in the iOS CI path.
set(VCPKG_BUILD_TYPE release)
