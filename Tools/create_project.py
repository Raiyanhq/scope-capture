#!/usr/bin/env python3
"""Generate a standalone Xcode project. No dependencies and no signing identity changes."""
from pathlib import Path
import hashlib
import json
import xml.sax.saxutils as xml

ROOT = Path(__file__).resolve().parents[1]
objects = {}

def identifier(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def add(object_key, **values):
    key = identifier(object_key)
    objects[key] = values
    return key

def render(value, level=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t"*(level+1) + json.dumps(k) + " = " + render(v, level+1) + ";\n" for k,v in value.items()) + "\t"*level + "}"
    if isinstance(value, list):
        return "(" + ", ".join(render(item, level) for item in value) + ")"
    return json.dumps(value) if isinstance(value, str) else str(value)

source_refs, source_builds = [], []
for path in sorted(ROOT.glob("Sources/**/*.swift")):
    relative = str(path.relative_to(ROOT))
    ref = add(relative, isa="PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="<group>")
    source_refs.append(ref)
    source_builds.append(add(relative+".build", isa="PBXBuildFile", fileRef=ref))
resources = []
for relative, kind in [("Configuration/PrivacyInfo.xcprivacy", "text.xml"), ("Assets.xcassets", "folder.assetcatalog")]:
    ref = add(relative, isa="PBXFileReference", lastKnownFileType=kind, path=relative, sourceTree="<group>")
    source_refs.append(ref)
    resources.append(add(relative+".build", isa="PBXBuildFile", fileRef=ref))
info = add("info", isa="PBXFileReference", lastKnownFileType="text.plist.xml", path="Configuration/Info.plist", sourceTree="<group>")
source_refs.append(info)
product = add("product", isa="PBXFileReference", explicitFileType="wrapper.application", path="SCOPE Capture.app", sourceTree="BUILT_PRODUCTS_DIR")
products = add("products", isa="PBXGroup", children=[product], name="Products", sourceTree="<group>")
main = add("main", isa="PBXGroup", children=source_refs+[products], sourceTree="<group>")
sources = add("sources", isa="PBXSourcesBuildPhase", buildActionMask=2147483647, files=source_builds, runOnlyForDeploymentPostprocessing=0)
frameworks = add("frameworks", isa="PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
resource_phase = add("resources", isa="PBXResourcesBuildPhase", buildActionMask=2147483647, files=resources, runOnlyForDeploymentPostprocessing=0)
project_configs, target_configs = [], []
for configuration in ["Debug", "Release"]:
    project_configs.append(add("project"+configuration, isa="XCBuildConfiguration", name=configuration,
        buildSettings={"SDKROOT":"iphoneos", "IPHONEOS_DEPLOYMENT_TARGET":"17.0", "CLANG_ENABLE_MODULES":"YES"}))
    settings = {
        "PRODUCT_NAME":"SCOPE Capture", "PRODUCT_BUNDLE_IDENTIFIER":"org.example.scope.capture",
        "INFOPLIST_FILE":"Configuration/Info.plist", "GENERATE_INFOPLIST_FILE":"NO",
        "MARKETING_VERSION":"1.2", "CURRENT_PROJECT_VERSION":"4", "SWIFT_VERSION":"5.0",
        "SWIFT_STRICT_CONCURRENCY":"complete",
        "TARGETED_DEVICE_FAMILY":"1", "SUPPORTED_PLATFORMS":"iphoneos iphonesimulator",
        "SUPPORTS_MACCATALYST":"NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD":"NO",
        "ASSETCATALOG_COMPILER_APPICON_NAME":"AppIcon", "CODE_SIGN_STYLE":"Automatic",
        "ENABLE_USER_SCRIPT_SANDBOXING":"YES", "LD_RUNPATH_SEARCH_PATHS":"$(inherited) @executable_path/Frameworks",
        "SWIFT_OPTIMIZATION_LEVEL":"-Onone" if configuration == "Debug" else "-O",
        "DEBUG_INFORMATION_FORMAT":"dwarf" if configuration == "Debug" else "dwarf-with-dsym",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS":"DEBUG" if configuration == "Debug" else "",
        "ENABLE_TESTABILITY":"YES" if configuration == "Debug" else "NO"
    }
    target_configs.append(add("target"+configuration, isa="XCBuildConfiguration", name=configuration, buildSettings=settings))
pconfigs = add("projectconfigs", isa="XCConfigurationList", buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
tconfigs = add("targetconfigs", isa="XCConfigurationList", buildConfigurations=target_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
target = add("target", isa="PBXNativeTarget", buildConfigurationList=tconfigs, buildPhases=[sources, frameworks, resource_phase],
    buildRules=[], dependencies=[], name="SCOPE Capture", productName="SCOPE Capture", productReference=product,
    productType="com.apple.product-type.application")
project = add("project", isa="PBXProject", attributes={"LastUpgradeCheck":"2600", "BuildIndependentTargetsInParallel":"YES"},
    buildConfigurationList=pconfigs, compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0,
    knownRegions=["en", "Base"], mainGroup=main, productRefGroup=products, projectDirPath="", projectRoot="", targets=[target])
folder = ROOT / "SCOPECapture.xcodeproj"
folder.mkdir(exist_ok=True)
(folder/"project.pbxproj").write_text("// !$*UTF8*$!\n" + render({"archiveVersion":1,"classes":{},"objectVersion":56,"objects":objects,"rootObject":project}) + "\n")
scheme_folder = folder / "xcshareddata/xcschemes"
scheme_folder.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="SCOPE Capture.app" BlueprintName="SCOPE Capture" ReferencedContainer="container:SCOPECapture.xcodeproj"/>'
(scheme_folder/"SCOPE Capture.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(folder)
