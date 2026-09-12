# /// script
# requires-python = ">=3.12"
# ///
"""Generate Canoe.xcodeproj/project.pbxproj (plist format, objectVersion 77).

The project is a single macOS app target. Source files live under ``Canoe/``
and are discovered automatically, so adding/removing files only requires
re-running this script (``just generate``). Third-party Swift packages are
declared in ``PACKAGES`` below and wired as package product dependencies.

Run:  uv run Tools/generate_xcodeproj.py
"""

from __future__ import annotations

import hashlib
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE_ROOT = ROOT / "Sources" / "Canoe"
PROJECT_DIR = ROOT / "Canoe.xcodeproj"

PRODUCT_NAME = "Canoe"
BUNDLE_ID = "app.canoe"
DEPLOYMENT_TARGET = "26.0"
SWIFT_VERSION = "6.3"
INFOPLIST_FILE = "Resources/Canoe-Info.plist"
ASSETCATALOG = "Assets.xcassets"
APPICON_NAME = "Canoe"

# Third-party Swift packages (Xcode resolves them on first build - network
# required). Each entry links its products into the app target.
PACKAGES: list[dict] = [
    {
        "identity": "swift-tree-sitter",
        "url": "https://github.com/tree-sitter/swift-tree-sitter",
        "minimumVersion": "0.25.0",
        "products": ["SwiftTreeSitter"],
    },
    {
        "identity": "tree-sitter-json",
        "url": "https://github.com/tree-sitter/tree-sitter-json",
        "minimumVersion": "0.24.8",
        "products": ["TreeSitterJSON"],
    },
]


def uuid(key: str) -> str:
    """Deterministic 24-hex-char object ID so reruns produce stable diffs."""
    return hashlib.sha1(("canoe\x00" + key).encode()).hexdigest()[:24].upper()


# ---------------------------------------------------------------------------
# Build settings (mirrors the layout used by the reference project: compiler
# warnings + toolchain versions at project level, target-specific settings at
# target level).
# ---------------------------------------------------------------------------

PROJECT_DEBUG: dict = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION": "YES_AGGRESSIVE",
    "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
    "CLANG_CXX_LIBRARY": "libc++",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_ENABLE_OBJC_WEAK": "YES",
    "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
    "CLANG_WARN_BOOL_CONVERSION": "YES",
    "CLANG_WARN_COMMA": "YES",
    "CLANG_WARN_CONSTANT_CONVERSION": "YES",
    "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS": "YES",
    "CLANG_WARN_DIRECT_OBJC_ISA_USAGE": "YES_ERROR",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
    "CLANG_WARN_EMPTY_BODY": "YES",
    "CLANG_WARN_ENUM_CONVERSION": "YES",
    "CLANG_WARN_INFINITE_RECURSION": "YES",
    "CLANG_WARN_INT_CONVERSION": "YES",
    "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "YES",
    "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF": "YES",
    "CLANG_WARN_OBJC_LITERAL_CONVERSION": "YES",
    "CLANG_WARN_OBJC_ROOT_CLASS": "YES_ERROR",
    "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
    "CLANG_WARN_RANGE_LOOP_ANALYSIS": "YES",
    "CLANG_WARN_STRICT_PROTOTYPES": "YES",
    "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
    "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
    "CLANG_WARN_UNREACHABLE_CODE": "YES",
    "CLANG_WARN__DUPLICATE_METHOD_MATCH": "YES",
    "COPY_PHASE_STRIP": "NO",
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_TESTABILITY": "YES",
    "EXCLUDED_ARCHS": "x86_64",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_DYNAMIC_NO_PIC": "NO",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ["$(inherited)", "DEBUG=1"],
    "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
    "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
    "GCC_WARN_UNDECLARED_SELECTOR": "YES",
    "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
    "GCC_WARN_UNUSED_FUNCTION": "YES",
    "GCC_WARN_UNUSED_VARIABLE": "YES",
    "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "MTL_FAST_MATH": "YES",
    "ONLY_ACTIVE_ARCH": "YES",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SDKROOT": "macosx",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    "SWIFT_VERSION": SWIFT_VERSION,
}

PROJECT_RELEASE: dict = {
    **{k: v for k, v in PROJECT_DEBUG.items() if k not in {
        "DEBUG_INFORMATION_FORMAT",
        "ENABLE_TESTABILITY",
        "GCC_DYNAMIC_NO_PIC",
        "GCC_OPTIMIZATION_LEVEL",
        "GCC_PREPROCESSOR_DEFINITIONS",
        "ONLY_ACTIVE_ARCH",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS",
        "SWIFT_OPTIMIZATION_LEVEL",
        "MTL_ENABLE_DEBUG_INFO",
    }},
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_TESTABILITY": "NO",
    "GCC_DYNAMIC_NO_PIC": "YES",
    "GCC_OPTIMIZATION_LEVEL": "s",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "SWIFT_OPTIMIZATION_LEVEL": "-O",
}

TARGET_COMMON: dict = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": APPICON_NAME,
    "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS": "YES",
    "COMBINE_HIDPI_IMAGES": "YES",
    "INFOPLIST_FILE": INFOPLIST_FILE,
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SDKROOT": "macosx",
}

# Signing identity/team/style are intentionally absent here - they come
# solely from xcodebuild command-line overrides (see Justfile `build`,
# driven by CODE_SIGN_STYLE / CODE_SIGN_IDENTITY / DEVELOPMENT_TEAM env).
TARGET_DEBUG: dict = {**TARGET_COMMON}
TARGET_RELEASE: dict = {**TARGET_COMMON, "ARCHS": "arm64"}


# ---------------------------------------------------------------------------
# Project model
# ---------------------------------------------------------------------------

objects: dict[str, dict] = {}


def add(obj_id: str, obj: dict) -> str:
    obj = {"isa": obj.pop("isa")} | obj
    objects[obj_id] = obj
    return obj_id


def build_settings(settings: dict) -> dict:
    return {"buildSettings": settings}


def scan_swift_files(base: Path) -> list[Path]:
    return sorted(p for p in base.rglob("*.swift"))


def rel_parts(path: Path) -> list[str]:
    return path.relative_to(SOURCE_ROOT).parts

def build_group_tree() -> tuple[str, list[str], list[str]]:
    """Build nested PBXGroup tree mirroring the Canoe/ directory.

    Returns (canoe_group_id, source_build_file_ids, resource_build_file_ids).
    """
    swift_files = scan_swift_files(SOURCE_ROOT)

    # Group files by their directory relative to Canoe/.
    tree: dict[tuple[str, ...], list[Path]] = {}
    for f in swift_files:
        parts = rel_parts(f)
        dir_key = parts[:-1]
        tree.setdefault(dir_key, []).append(f)

    all_dirs = sorted({k for k in tree} | {k[:-1] for k in tree if k}, key=lambda d: (len(d), d))

    # Create a group for each directory.
    dir_to_group: dict[tuple[str, ...], str] = {}
    for d in all_dirs:
        name = "/".join(d) if d else "(root)"
        dir_to_group[d] = uuid("group:" + name)

    root_group_id = dir_to_group[()]

    # Populate each group's children.
    for d in all_dirs:
        children: list[str] = []
        # Subdirectories whose parent is this one.
        for other in all_dirs:
            if len(other) == len(d) + 1 and other[: len(d)] == d:
                children.append(dir_to_group[other])
        # Files in this directory.
        for f in tree.get(d, []):
            parts = rel_parts(f)
            rel_path = "/".join(parts)  # relative to SOURCE_ROOT, e.g. App/AppDelegate.swift
            file_ref_id = uuid("fileref:" + rel_path)
            add(file_ref_id, {
                "isa": "PBXFileReference",
                "lastKnownFileType": "sourcecode.swift",
                "path": parts[-1],
                "sourceTree": "<group>",
            })
            children.append(file_ref_id)
        group_obj: dict = {"isa": "PBXGroup", "children": children, "sourceTree": "<group>"}
        if d:
            group_obj["path"] = d[-1]
        else:
            group_obj["path"] = "Sources/Canoe"
        add(dir_to_group[d], group_obj)

    # Build source build files + collect their IDs.
    source_build_ids: list[str] = []
    for f in swift_files:
        parts = rel_parts(f)
        rel_path = "/".join(parts)
        file_ref_id = uuid("fileref:" + rel_path)
        build_id = uuid("buildfile:" + rel_path)
        add(build_id, {"isa": "PBXBuildFile", "fileRef": file_ref_id})
        source_build_ids.append(build_id)

    # Assets resource.
    assets_ref_id = uuid("fileref:Assets.xcassets")
    add(assets_ref_id, {
        "isa": "PBXFileReference",
        "lastKnownFileType": "folder.assetcatalog",
        "path": ASSETCATALOG,
        "sourceTree": "<group>",
    })
    assets_build_id = uuid("buildfile:Assets.xcassets")
    add(assets_build_id, {"isa": "PBXBuildFile", "fileRef": assets_ref_id})

    return root_group_id, source_build_ids, [assets_build_id]


def build_packages() -> tuple[list[str], list[str], list[str]]:
    """Emit package reference/product objects for ``PACKAGES``.

    Returns (remote_ref_ids, product_dep_ids, build_file_ids).
    """
    ref_ids: list[str] = []
    dep_ids: list[str] = []
    build_ids: list[str] = []
    for package in PACKAGES:
        identity = package["identity"]
        ref_id = uuid("pkgref:" + identity)
        add(ref_id, {
            "isa": "XCRemoteSwiftPackageReference",
            "repositoryURL": package["url"],
            "requirement": {
                "kind": "upToNextMajorVersion",
                "minimumVersion": package["minimumVersion"],
            },
        })
        ref_ids.append(ref_id)
        for product in package["products"]:
            dep_id = uuid("pkgdep:" + identity + ":" + product)
            add(dep_id, {
                "isa": "XCSwiftPackageProductDependency",
                "package": ref_id,
                "productName": product,
            })
            dep_ids.append(dep_id)
            build_id = uuid("pkgbuild:" + identity + ":" + product)
            add(build_id, {"isa": "PBXBuildFile", "productRef": dep_id})
            build_ids.append(build_id)
    return ref_ids, dep_ids, build_ids


def main() -> None:
    canoe_group_id, source_build_ids, resource_build_ids = build_group_tree()
    package_ref_ids, package_dep_ids, package_build_ids = build_packages()

    # --- Build phases ----------------------------------------------------
    sources_phase_id = uuid("phase:sources")
    add(sources_phase_id, {
        "isa": "PBXSourcesBuildPhase",
        "buildActionMask": "2147483647",
        "files": source_build_ids,
        "runOnlyForDeploymentPostprocessing": "0",
    })

    frameworks_phase_id = uuid("phase:frameworks")
    add(frameworks_phase_id, {
        "isa": "PBXFrameworksBuildPhase",
        "buildActionMask": "2147483647",
        "files": package_build_ids,
        "runOnlyForDeploymentPostprocessing": "0",
    })

    resources_phase_id = uuid("phase:resources")
    add(resources_phase_id, {
        "isa": "PBXResourcesBuildPhase",
        "buildActionMask": "2147483647",
        "files": resource_build_ids,
        "runOnlyForDeploymentPostprocessing": "0",
    })

    # --- Product reference ----------------------------------------------
    product_ref_id = uuid("product:Canoe.app")
    add(product_ref_id, {
        "isa": "PBXFileReference",
        "explicitFileType": "wrapper.application",
        "includeInIndex": "0",
        "path": PRODUCT_NAME + ".app",
        "sourceTree": "BUILT_PRODUCTS_DIR",
    })

    # --- Products group --------------------------------------------------
    products_group_id = uuid("group:Products")
    add(products_group_id, {
        "isa": "PBXGroup",
        "children": [product_ref_id],
        "name": "Products",
        "sourceTree": "<group>",
    })

    # --- Main group ------------------------------------------------------
    assets_ref_id = uuid("fileref:Assets.xcassets")
    main_group_id = uuid("group:main")
    add(main_group_id, {
        "isa": "PBXGroup",
        "children": [canoe_group_id, products_group_id, assets_ref_id],
        "sourceTree": "<group>",
    })

    # --- Configurations --------------------------------------------------
    project_debug_id = uuid("cfg:project-debug")
    project_release_id = uuid("cfg:project-release")
    add(project_debug_id, {"isa": "XCBuildConfiguration", "name": "Debug", **build_settings(PROJECT_DEBUG)})
    add(project_release_id, {"isa": "XCBuildConfiguration", "name": "Release", **build_settings(PROJECT_RELEASE)})

    project_config_list_id = uuid("cfglist:project")
    add(project_config_list_id, {
        "isa": "XCConfigurationList",
        "buildConfigurations": [project_debug_id, project_release_id],
        "defaultConfigurationIsVisible": "0",
        "defaultConfigurationName": "Debug",
    })

    target_debug_id = uuid("cfg:target-debug")
    target_release_id = uuid("cfg:target-release")
    add(target_debug_id, {"isa": "XCBuildConfiguration", "name": "Debug", **build_settings(TARGET_DEBUG)})
    add(target_release_id, {"isa": "XCBuildConfiguration", "name": "Release", **build_settings(TARGET_RELEASE)})

    target_config_list_id = uuid("cfglist:target")
    add(target_config_list_id, {
        "isa": "XCConfigurationList",
        "buildConfigurations": [target_debug_id, target_release_id],
        "defaultConfigurationIsVisible": "0",
        "defaultConfigurationName": "Debug",
    })

    # --- Target ----------------------------------------------------------
    target_id = uuid("target:Canoe")
    add(target_id, {
        "isa": "PBXNativeTarget",
        "buildConfigurationList": target_config_list_id,
        "buildPhases": [sources_phase_id, frameworks_phase_id, resources_phase_id],
        "buildRules": [],
        "dependencies": [],
        "name": PRODUCT_NAME,
        "packageProductDependencies": package_dep_ids,
        "productName": PRODUCT_NAME,
        "productReference": product_ref_id,
        "productType": "com.apple.product-type.application",
    })

    # --- Project ---------------------------------------------------------
    project_id = uuid("project:root")
    add(project_id, {
        "isa": "PBXProject",
        "attributes": {"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1430"},
        "buildConfigurationList": project_config_list_id,
        "developmentRegion": "en",
        "hasScannedForEncodings": "0",
        "knownRegions": ["Base", "en"],
        "mainGroup": main_group_id,
        "packageReferences": package_ref_ids,
        "productRefGroup": products_group_id,
        "projectDirPath": "",
        "projectRoot": "",
        "targets": [target_id],
    })

    # --- Write -----------------------------------------------------------
    PROJECT_DIR.mkdir(exist_ok=True)
    out_path = PROJECT_DIR / "project.pbxproj"
    document = {
        "archiveVersion": "1",
        "classes": {},
        "objectVersion": "77",
        "objects": objects,
        "rootObject": project_id,
    }
    with out_path.open("wb") as f:
        plistlib.dump(document, f, sort_keys=False, fmt=plistlib.FMT_XML)

    print(f"Generated {out_path.relative_to(ROOT)}")
    print(f"  {len(source_build_ids)} source files, {len(objects)} objects")


if __name__ == "__main__":
    main()
