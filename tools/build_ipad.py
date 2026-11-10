#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Generate/build a local iPad app from shared source and caller-selected data.

Original resources are copied only below ignored build/. No original executable
is executed. A simulator build is not a signed physical-device installation.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def uid(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()


def quoted(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def generate(data: Path, output: Path) -> Path:
    data = data.resolve(); output = output.resolve()
    assets = output / "GameData"
    if (not output.is_relative_to(ROOT / "build") or output.is_relative_to(data)
            or (data.is_relative_to(output) and data != assets)):
        raise ValueError("iPad output must be below this repository's ignored build/, separate from input data")
    for name in ("resources.json", "campaign.json", "combat.json", "people.json"):
        if not (data / name).is_file():
            raise ValueError(f"Prepared caller-selected GameData is missing {name}")
    output.mkdir(parents=True, exist_ok=True)
    if data != assets:
        shutil.copytree(data, assets, dirs_exist_ok=True)
    shared = json.loads((ROOT / "iOS/SharedSources.json").read_text())
    files = [ROOT / item for item in shared] + sorted((ROOT / "iOS").glob("IPad*.swift"))
    if len(set(files)) != len(files) or any(not f.is_file() or not f.resolve().is_relative_to(ROOT) for f in files):
        raise ValueError("iPad source manifest contains a missing, repeated or external file")
    if any(f.name == "main.swift" or f.name.endswith("Tests.swift") for f in files):
        raise ValueError("Desktop entry points and test code must not ship in the iPad target")
    info = {
        "CFBundleDisplayName": "영걸전", "CFBundleName": "Yeonggeoljeon",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.5.0", "CFBundleVersion": "5",
        "LSRequiresIPhoneOS": True, "UIDeviceFamily": [2], "UILaunchScreen": {},
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight", "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown"],
        "UIFileSharingEnabled": True, "LSSupportsOpeningDocumentsInPlace": True,
        "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
    }
    (output / "Info.plist").write_bytes(plistlib.dumps(info))
    objects: list[str] = []
    def obj(key: str, fields: str) -> str:
        identifier = uid(key);objects.append(f"{identifier} = {{ {fields} }};");return identifier
    refs = []; source_builds = []
    for path in files:
        ref = obj("file:"+str(path), f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(str(path))}; sourceTree = \"<absolute>\";")
        refs.append(ref)
        source_builds.append(obj("compile:"+str(path),f"isa = PBXBuildFile; fileRef = {ref};"))
    resource = obj("resource", "isa = PBXFileReference; lastKnownFileType = folder; path = GameData; sourceTree = \"<group>\";")
    resource_build = obj("resource-build",f"isa = PBXBuildFile; fileRef = {resource};")
    product = obj("product", "isa = PBXFileReference; explicitFileType = wrapper.application; path = Yeonggeoljeon.app; sourceTree = BUILT_PRODUCTS_DIR;")
    products = obj("products",f"isa = PBXGroup; children = ({product},); name = Products; sourceTree = \"<group>\";")
    main_group = obj("group",f"isa = PBXGroup; children = ({','.join(refs+[resource,products])},); sourceTree = \"<group>\";")
    sources = obj("sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(source_builds)},); runOnlyForDeploymentPostprocessing = 0;")
    resources = obj("resources",f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({resource_build},); runOnlyForDeploymentPostprocessing = 0;")
    frameworks = obj("frameworks","isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
    settings = 'SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 16.0; SWIFT_VERSION = 5.0; CLANG_ENABLE_MODULES = YES;'
    app_settings = settings+' PRODUCT_NAME = Yeonggeoljeon; PRODUCT_BUNDLE_IDENTIFIER = org.yeonggeoljeon.engine.ipad; INFOPLIST_FILE = Info.plist; TARGETED_DEVICE_FAMILY = 2; CODE_SIGN_STYLE = Automatic; SUPPORTS_MACCATALYST = NO; SWIFT_EMIT_LOC_STRINGS = NO;'
    def configs(kind: str, value: str) -> str:
        ids = []
        for name in ["Debug", "Release"]:
            extra = ' SWIFT_OPTIMIZATION_LEVEL = "-Onone"; DEBUG_INFORMATION_FORMAT = dwarf;' if name == "Debug" else ' SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";'
            ids.append(obj(kind+name,f"isa = XCBuildConfiguration; buildSettings = {{ {value+extra} }}; name = {name};"))
        return obj(kind+"configs",f"isa = XCConfigurationList; buildConfigurations = ({','.join(ids)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
    target_cfg = configs("target",app_settings);project_cfg = configs("project",settings)
    target = obj("target",f'isa = PBXNativeTarget; buildConfigurationList = {target_cfg}; buildPhases = ({sources},{frameworks},{resources},); buildRules = (); dependencies = (); name = Yeonggeoljeon; productName = Yeonggeoljeon; productReference = {product}; productType = "com.apple.product-type.application";')
    project = obj("project",f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2700; }}; buildConfigurationList = {project_cfg}; compatibilityVersion = "Xcode 14.0"; developmentRegion = ko; knownRegions = (ko,en,Base,); mainGroup = {main_group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},);')
    project_dir = output / "Yeonggeoljeon iPad.xcodeproj";project_dir.mkdir(exist_ok=True)
    (project_dir / "project.pbxproj").write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {project}; }}\n')
    evidence = {"sourceFiles": {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
                "inputData":str(data), "dataFiles": {str(p.relative_to(assets)):hashlib.sha256(p.read_bytes()).hexdigest() for p in assets.rglob("*") if p.is_file()}}
    (output / "ipad-build-inputs.json").write_text(json.dumps(evidence,ensure_ascii=False,indent=2))
    return project_dir


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data",type=Path,required=True)
    parser.add_argument("--output",type=Path,default=ROOT/"build/ipad")
    parser.add_argument("--sdk",choices=["iphoneos","iphonesimulator"],default="iphoneos")
    parser.add_argument("--configuration",choices=["Debug","Release"],default="Debug")
    parser.add_argument("--generate-only",action="store_true")
    parser.add_argument("--team",help="Explicit developer team to sign a physical-device build")
    parser.add_argument("--device",help="Connected iPad identifier; include this device in automatic provisioning")
    args = parser.parse_args();project = generate(args.data,args.output)
    print(project,flush=True)
    if args.generate_only:return
    if args.device and (args.sdk != "iphoneos" or not args.team):
        parser.error("--device requires --sdk iphoneos and an explicit --team")
    destination = "id="+args.device if args.device else "generic/platform="+("iOS Simulator" if args.sdk == "iphonesimulator" else "iOS")
    command = ["xcodebuild","-project",str(project),"-scheme","Yeonggeoljeon","-configuration",args.configuration,
               "-sdk",args.sdk,"-destination",destination,
               "-derivedDataPath",str(args.output.resolve()/"DerivedData"),"build"]
    if args.team:command += ["DEVELOPMENT_TEAM="+args.team,"-allowProvisioningUpdates"]
    else:command += ["CODE_SIGNING_ALLOWED=NO"]
    if args.device:command += ["-allowProvisioningDeviceRegistration"]
    subprocess.run(command,check=True,cwd=ROOT)


if __name__ == "__main__":main()
