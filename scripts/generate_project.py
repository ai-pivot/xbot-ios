#!/usr/bin/env python3
"""Generate the dependency-free Xcode project using only Python's standard library."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent.parent
objects = {}
def uid(label): return hashlib.sha1(label.encode()).hexdigest()[:24].upper()
def add(label, text):
    key = uid(label); objects[key] = text; return key
def ref(label): return uid(label)
def quoted(value): return json.dumps(str(value))
def array(values): return "(" + ", ".join(values) + ",)" if values else "()"

app_sources = sorted((ROOT / "Sources").rglob("*.swift"))
test_sources = sorted((ROOT / "XbotUITests").rglob("*.swift"))
source_ids, test_ids, children = [], [], []
for path in app_sources + test_sources:
    relative = str(path.relative_to(ROOT))
    file_id = add("file:" + relative, f'{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(relative)}; sourceTree = SOURCE_ROOT; }}')
    build_id = add("build:" + relative, f'{{isa = PBXBuildFile; fileRef = {file_id}; }}')
    children.append(file_id)
    (source_ids if path in app_sources else test_ids).append(build_id)
asset = add("assets", '{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Sources/XbotApp/Assets.xcassets; sourceTree = SOURCE_ROOT; }')
asset_build = add("asset-build", f'{{isa = PBXBuildFile; fileRef = {asset}; }}')
mermaid = add("mermaid-resources", '{isa = PBXFileReference; lastKnownFileType = folder; path = Sources/XbotApp/Resources/Mermaid; sourceTree = SOURCE_ROOT; }')
mermaid_build = add("mermaid-build", f'{{isa = PBXBuildFile; fileRef = {mermaid}; }}')
privacy = add("privacy", '{isa = PBXFileReference; lastKnownFileType = text.xml; path = Sources/XbotApp/PrivacyInfo.xcprivacy; sourceTree = SOURCE_ROOT; }')
privacy_build = add("privacy-build", f'{{isa = PBXBuildFile; fileRef = {privacy}; }}')
app_product = add("app-product", '{isa = PBXFileReference; explicitFileType = wrapper.application; path = Xbot.app; sourceTree = BUILT_PRODUCTS_DIR; }')
test_product = add("test-product", '{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = XbotUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }')
products = add("products", f'{{isa = PBXGroup; children = {array([app_product, test_product])}; name = Products; sourceTree = "<group>"; }}')
main_group = add("main-group", f'{{isa = PBXGroup; children = {array(children + [asset, mermaid, privacy, products])}; sourceTree = "<group>"; }}')
app_phase = add("app-sources", f'{{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {array(source_ids)}; runOnlyForDeploymentPostprocessing = 0; }}')
test_phase = add("test-sources", f'{{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {array(test_ids)}; runOnlyForDeploymentPostprocessing = 0; }}')
resources = add("resources", f'{{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {array([asset_build, mermaid_build, privacy_build])}; runOnlyForDeploymentPostprocessing = 0; }}')
proxy = add("proxy", f'{{isa = PBXContainerItemProxy; containerPortal = {ref("project")}; proxyType = 1; remoteGlobalIDString = {ref("app")}; remoteInfo = Xbot; }}')
dependency = add("dependency", f'{{isa = PBXTargetDependency; target = {ref("app")}; targetProxy = {proxy}; }}')

common = {"IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SWIFT_VERSION": "6.0", "SDKROOT": "iphoneos", "CLANG_ENABLE_MODULES": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES"}
def configs(label, extra):
    ids = []
    for mode in ["Debug", "Release"]:
        settings = common | extra | {"SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O", "DEBUG_INFORMATION_FORMAT": "dwarf" if mode == "Debug" else "dwarf-with-dsym"}
        if mode == "Debug": settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
        text = " ".join(f'{key} = {quoted(value)};' for key, value in settings.items())
        ids.append(add(label + mode, f'{{isa = XCBuildConfiguration; buildSettings = {{{text}}}; name = {mode}; }}'))
    return add(label + "-configs", f'{{isa = XCConfigurationList; buildConfigurations = {array(ids)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }}')

project_configs = configs("project", {})
app_configs = configs("app", {"XBOT_PUSH_ENABLED": "NO", "PRODUCT_BUNDLE_IDENTIFIER": "dev.xbot.ios", "PRODUCT_NAME": "$(TARGET_NAME)", "INFOPLIST_FILE": "Sources/XbotApp/Info.plist", "TARGETED_DEVICE_FAMILY": "1,2", "CODE_SIGN_STYLE": "Automatic", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor", "MARKETING_VERSION": "1.0.0", "CURRENT_PROJECT_VERSION": "1", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks", "ENABLE_PREVIEWS": "YES"})
test_configs = configs("tests", {"PRODUCT_BUNDLE_IDENTIFIER": "dev.xbot.ios.uitests", "PRODUCT_NAME": "$(TARGET_NAME)", "GENERATE_INFOPLIST_FILE": "YES", "TEST_TARGET_NAME": "Xbot", "TARGETED_DEVICE_FAMILY": "1,2", "CODE_SIGN_STYLE": "Automatic"})
add("app", f'{{isa = PBXNativeTarget; buildConfigurationList = {app_configs}; buildPhases = {array([app_phase, resources])}; buildRules = (); dependencies = (); name = Xbot; productName = Xbot; productReference = {app_product}; productType = "com.apple.product-type.application"; }}')
add("tests", f'{{isa = PBXNativeTarget; buildConfigurationList = {test_configs}; buildPhases = {array([test_phase])}; buildRules = (); dependencies = {array([dependency])}; name = XbotUITests; productName = XbotUITests; productReference = {test_product}; productType = "com.apple.product-type.bundle.ui-testing"; }}')
add("project", f'{{isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; TargetAttributes = {{{ref("tests")} = {{TestTargetID = {ref("app")}; }}; }}; }}; buildConfigurationList = {project_configs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh-Hans; hasScannedForEncodings = 0; knownRegions = (en, "zh-Hans", Base); mainGroup = {main_group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = {array([ref("app"), ref("tests")])}; }}')
project = ROOT / "Xbot.xcodeproj"
project.mkdir(exist_ok=True)
(project / "project.pbxproj").write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(f'{key} = {value};' for key, value in objects.items()) + f'\n}}; rootObject = {ref("project")}; }}\n')
scheme_dir = project / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
def buildable(target, name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref(target)}" BuildableName="{name}" BlueprintName="{"Xbot" if target == "app" else "XbotUITests"}" ReferencedContainer="container:Xbot.xcodeproj"/>'
(scheme_dir / "Xbot.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable("app", "Xbot.app")}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{buildable("tests", "XbotUITests.xctest")}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable("app", "Xbot.app")}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable("app", "Xbot.app")}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print("Generated Xbot.xcodeproj")
