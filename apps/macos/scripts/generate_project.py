#!/usr/bin/env python3
"""Создаёт Xcode-проект с локальным пакетом переводов. Нужен Xcode 26 со Swift 6.2 или новее."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
objects = {}

def identifier(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def add(object_name, isa, **values):
    key = identifier(object_name)
    objects[key] = dict(isa=isa, **values)
    return key

def configurations(name, settings):
    configs = []
    for mode in ("Debug", "Release"):
        flags = dict(settings)
        if name == "project":
            flags.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if mode == "Debug" else "-O",
                         DEBUG_INFORMATION_FORMAT="dwarf" if mode == "Debug" else "dwarf-with-dsym")
            if mode == "Debug":
                flags.update(SWIFT_ACTIVE_COMPILATION_CONDITIONS="$(inherited) DEBUG", ENABLE_TESTABILITY="YES", ONLY_ACTIVE_ARCH="YES")
        configs.append(add(f"{name}-{mode}", "XCBuildConfiguration", name=mode, buildSettings=flags))
    return add(f"{name}-configurations", "XCConfigurationList", buildConfigurations=configs,
               defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

project_configs = configurations("project", {
    "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "26.0", "SWIFT_VERSION": "6.0",
    "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
    "CODE_SIGN_IDENTITY": "-", "CODE_SIGN_STYLE": "Manual", "COMBINE_HIDPI_IMAGES": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17", "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
    "GCC_WARN_UNUSED_VARIABLE": "YES", "CLANG_WARN_UNREACHABLE_CODE": "YES",
    # Local builds use ad-hoc signing. The DMG packager can re-sign both bundles.
    "PROVISIONING_PROFILE_SUPPORTED": "NO",
    "PLANNER_APP_BUNDLE_IDENTIFIER": "local.planner.Planner",
    "PLANNER_APP_ENTITLEMENTS": "Planner/Planner.entitlements",
    "PLANNER_WIDGET_APP_GROUP": "group.local.planner.today",
})
localization_package = add("localization-package", "XCLocalSwiftPackageReference", relativePath="Packages/PlannerLocalization")
localization_product = add("localization-product", "XCSwiftPackageProductDependency", productName="PlannerLocalization", package=localization_package)
localization_build = add("localization-link", "PBXBuildFile", productRef=localization_product)
# AI Preview использует закреплённый MLX и собирается только для Apple silicon.
mlx_package = add("mlx-package", "XCRemoteSwiftPackageReference", repositoryURL="https://github.com/ml-explore/mlx-swift-lm.git", requirement={"kind": "exactVersion", "version": "2.31.3"})
mlx_products = [add("mlx-product-" + name, "XCSwiftPackageProductDependency", productName=name, package=mlx_package) for name in ("MLXLLM", "MLXLMCommon")]
mlx_builds = [add("mlx-link-" + name, "PBXBuildFile", productRef=product) for name, product in zip(("MLXLLM", "MLXLMCommon"), mlx_products)]
shared_widget_group = add("widget-shared-sources", "PBXFileSystemSynchronizedRootGroup",
                          path="TodayWidgetShared", sourceTree="<group>")
groups = [shared_widget_group]
products = []
targets = []
for name, product_type, extension in (
    ("Planner", "com.apple.product-type.application", "app"),
    ("PlannerTests", "com.apple.product-type.bundle.unit-test", "xctest"),
    ("PlannerUITests", "com.apple.product-type.bundle.ui-testing", "xctest"),
    ("TodayWidget", "com.apple.product-type.app-extension", "appex"),
):
    group = add(f"{name}-sources", "PBXFileSystemSynchronizedRootGroup", path=name, sourceTree="<group>")
    groups.append(group)
    product_name = "Takt" if name == "Planner" else name
    file_type = {"app": "wrapper.application", "appex": "wrapper.app-extension", "xctest": "wrapper.cfbundle"}
    product = add(f"{name}-product", "PBXFileReference", explicitFileType=file_type[extension],
                  includeInIndex=0, path=f"{product_name}.{extension}", sourceTree="BUILT_PRODUCTS_DIR")
    products.append(product)
    settings = {
        "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": f"local.planner.{name}",
        "GENERATE_INFOPLIST_FILE": "YES", "MARKETING_VERSION": "0.3.27", "CURRENT_PROJECT_VERSION": "111", "ARCHS": "arm64",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks", "@loader_path/../Frameworks"],
    }
    if name == "Planner":
        settings.update(PRODUCT_NAME=product_name, PRODUCT_MODULE_NAME=name,
                        PRODUCT_BUNDLE_IDENTIFIER="$(PLANNER_APP_BUNDLE_IDENTIFIER)",
                        SWIFT_ACTIVE_COMPILATION_CONDITIONS="$(inherited) $(PLANNER_EXTRA_SWIFT_FLAGS)",
                        CODE_SIGN_ENTITLEMENTS="$(PLANNER_APP_ENTITLEMENTS)", ENABLE_APP_SANDBOX="YES",
                        INFOPLIST_FILE="Configuration/Planner-Info.plist",
                        ENABLE_HARDENED_RUNTIME="YES", ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME="AccentColor",
                        ASSETCATALOG_COMPILER_APPICON_NAME="TasksIcon",
                        INFOPLIST_KEY_CFBundleDisplayName="Takt",
                        INFOPLIST_KEY_LSApplicationCategoryType="public.app-category.productivity",
                        INFOPLIST_KEY_NSMicrophoneUsageDescription="Takt использует микрофон, чтобы записать голос для расшифровки в заметке.",
                        INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription="Takt нужен доступ к календарям для просмотра событий и планирования времени.",
                        INFOPLIST_KEY_NSHumanReadableCopyright="", INFOPLIST_KEY_CFBundleDevelopmentRegion="ru")
    elif name == "TodayWidget":
        settings.update(PRODUCT_BUNDLE_IDENTIFIER="$(PLANNER_APP_BUNDLE_IDENTIFIER).TodayWidget",
                        INFOPLIST_FILE="Configuration/TodayWidget-Info.plist",
                        INFOPLIST_KEY_CFBundleDisplayName="Takt",
                        CODE_SIGN_ENTITLEMENTS="Configuration/TodayWidget.entitlements",
                        APPLICATION_EXTENSION_API_ONLY="YES", ENABLE_APP_SANDBOX="YES",
                        ENABLE_HARDENED_RUNTIME="YES", SKIP_INSTALL="YES")
    elif name == "PlannerTests":
        settings.update(TEST_HOST="$(BUILT_PRODUCTS_DIR)/Takt.app/Contents/MacOS/Takt", BUNDLE_LOADER="$(TEST_HOST)")
    else:
        settings.update(TEST_TARGET_NAME="Planner")
    phases = [add(f"{name}-{kind}", f"PBX{kind}BuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
              for kind in ("Sources", "Frameworks", "Resources")]
    if name == "Planner":
        objects[identifier(f"{name}-Frameworks")]["files"] = [localization_build] + mlx_builds
    dependencies = []
    dependency = {"Planner": "TodayWidget", "PlannerTests": "Planner", "PlannerUITests": "Planner"}.get(name)
    if dependency:
        target = identifier(f"{dependency}-target")
        proxy = add(f"{name}-proxy", "PBXContainerItemProxy", containerPortal=identifier("project"), proxyType=1,
                    remoteGlobalIDString=target, remoteInfo=dependency)
        dependencies.append(add(f"{name}-dependency", "PBXTargetDependency", target=target, targetProxy=proxy))
    if name == "Planner":
        widget = add("embed-widget-build", "PBXBuildFile", fileRef=identifier("TodayWidget-product"),
                     settings={"ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]})
        phases.append(add("embed-widget-phase", "PBXCopyFilesBuildPhase", name="Embed Widget Extension",
                          buildActionMask=2147483647, dstPath="", dstSubfolderSpec=13, files=[widget],
                          runOnlyForDeploymentPostprocessing=0))
    source_groups = [group, shared_widget_group] if name in ("Planner", "TodayWidget") else [group]
    targets.append(add(f"{name}-target", "PBXNativeTarget", buildConfigurationList=configurations(name, settings),
                       buildPhases=phases, buildRules=[], dependencies=dependencies, fileSystemSynchronizedGroups=source_groups,
                       packageProductDependencies=[localization_product] + mlx_products if name == "Planner" else [],
                       name=name, productName=product_name, productReference=product, productType=product_type))

products_group = add("products", "PBXGroup", children=products, name="Products", sourceTree="<group>")
main = add("main", "PBXGroup", children=groups + [products_group], sourceTree="<group>")
project = add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "2650",
              "TargetAttributes": {identifier("Planner-target"): {"CreatedOnToolsVersion": "26.5"},
                                   identifier("PlannerTests-target"): {"TestTargetID": identifier("Planner-target")},
                                   identifier("PlannerUITests-target"): {"TestTargetID": identifier("Planner-target")}}},
              buildConfigurationList=project_configs, compatibilityVersion="Xcode 16.0", developmentRegion="ru",
              knownRegions=["ru", "en", "Base"], mainGroup=main, productRefGroup=products_group,
              projectDirPath="", projectRoot="", targets=targets, preferredProjectObjectVersion=77, packageReferences=[localization_package, mlx_package])

def serialize(value, level=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (level + 1) + json.dumps(str(key), ensure_ascii=False) + " = " + serialize(item, level + 1) + ";\n" for key, item in value.items()) + "\t" * level + "}"
    if isinstance(value, list):
        return "(" + ", ".join(serialize(item, level) for item in value) + ")"
    return json.dumps(value, ensure_ascii=False)

directory = ROOT / "Planner.xcodeproj"
directory.mkdir(exist_ok=True)
(directory / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(dict(archiveVersion=1, classes={}, objectVersion=77, objects=objects, rootObject=project)) + "\n")
scheme_dir = directory / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)

def reference(name):
    filename = "Takt.app" if name == "Planner" else f"{name}.xctest"
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier(name + "-target")}" BuildableName="{filename}" BlueprintName="{name}" ReferencedContainer="container:Planner.xcodeproj"/>'

(scheme_dir / "Planner.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2650" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference("Planner")}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>
    <TestableReference skipped="NO" parallelizable="NO">{reference("PlannerTests")}</TestableReference>
    <TestableReference skipped="YES" parallelizable="NO">{reference("PlannerUITests")}</TestableReference>
  </Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">{reference("Planner")}</BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference("Planner")}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(directory)

# Отдельная opt-in схема проверяет настоящую модель только на вымышленных данных.
smoke_scheme = (scheme_dir / "Planner.xcscheme").read_text().replace('<Testables>', '<EnvironmentVariables><EnvironmentVariable key="PLANNER_AI_SMOKE" value="1" isEnabled="YES"/></EnvironmentVariables><Testables>')
(scheme_dir / "PlannerAIModelSmoke.xcscheme").write_text(smoke_scheme.replace('shouldUseLaunchSchemeArgsEnv="YES"', 'shouldUseLaunchSchemeArgsEnv="NO"', 1))

smoke4 = (scheme_dir / "PlannerAIModelSmoke.xcscheme").read_text().replace('</EnvironmentVariables>', '<EnvironmentVariable key="PLANNER_AI_VARIANT" value="4" isEnabled="YES"/></EnvironmentVariables>')
(scheme_dir / "PlannerAIModelSmoke4.xcscheme").write_text(smoke4)
