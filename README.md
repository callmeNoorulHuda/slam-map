# iPhone SLAM Mapper

A minimal Flutter + native ARKit app that runs Apple's built-in visual-inertial
SLAM, streams live pose + point-count to the UI, and exports the accumulated
3D point cloud as a `.ply` file you can open in MeshLab / CloudCompare.

No LiDAR is required — this uses ARKit's `rawFeaturePoints` (sparse point
cloud), which works on any ARKit-capable iPhone, including the iPhone 11.

## 1. Create the Flutter project locally (on Windows)

```
flutter create iphone_slam
cd iphone_slam
```

Then drop these files from this bundle into place, overwriting the
generated defaults:

- `pubspec.yaml` → project root
- `lib/main.dart` → `lib/main.dart`
- `ios/Runner/ARSlamManager.swift` → `ios/Runner/ARSlamManager.swift` (new file)
- `ios/Runner/AppDelegate.swift` → `ios/Runner/AppDelegate.swift` (overwrite)

Run `flutter pub get` to fetch `share_plus`.

## 2. Add the camera permission

Open `ios/Runner/Info.plist` and add:

```xml
<key>NSCameraUsageDescription</key>
<string>Camera access is required to run ARKit SLAM tracking.</string>
```

## 3. iOS project settings

Since you don't have a Mac, do these edits directly in the text files
(no Xcode UI needed):

- `ios/Podfile` (if present): set `platform :ios, '13.0'` — ARKit world
  tracking needs iOS 13+.
- In `ios/Runner.xcodeproj/project.pbxproj`, deployment target should also
  read `13.0` (Flutter usually sets this already; only touch it if a build
  error complains about ARKit APIs).

## 4. Build in the cloud with Codemagic

Add a `codemagic.yaml` at the project root:

```yaml
workflows:
  ios-unsigned:
    name: iOS Unsigned Build
    max_build_duration: 30
    environment:
      flutter: stable
      xcode: latest
    scripts:
      - name: Get Flutter packages
        script: flutter pub get
      - name: Build unsigned iOS app
        script: flutter build ios --release --no-codesign
      - name: Package as .ipa (unsigned)
        script: |
          mkdir -p build/ios/iphoneos/Payload
          cp -r build/ios/iphoneos/Runner.app build/ios/iphoneos/Payload/
          cd build/ios/iphoneos && zip -r iphone_slam_unsigned.ipa Payload
    artifacts:
      - build/ios/iphoneos/iphone_slam_unsigned.ipa
```

Push to GitHub, connect the repo in Codemagic, run the `ios-unsigned`
workflow, and download the resulting `.ipa` — this avoids needing a paid
Apple Developer account for Codemagic's own signing step.

## 5. Sideload onto your iPhone 11

1. Install Sideloadly on your Windows PC.
2. Connect the iPhone via USB, open Sideloadly, drag in the `.ipa`.
3. Sign in with your (free) Apple ID when prompted — Sideloadly handles
   signing on-device.
4. Trust the developer certificate on the phone: **Settings → General →
   VPN & Device Management**.
5. Re-sideload every 7 days (free Apple ID signing expiry).

## How the map export works

- While scanning, `ARSlamManager` accumulates every unique ARKit feature
  point (deduplicated by point identifier) plus the full camera trajectory.
- Tapping **Export & Share Map** writes all accumulated points to a `.ply`
  file in the app's Documents folder and opens the iOS share sheet.
- Open the `.ply` in MeshLab or CloudCompare on your laptop to view the
  point cloud.

## Tips for better maps

- Move the phone slowly; fast motion degrades VIO tracking.
- Well-lit, texture-rich surfaces (avoid blank walls) give far more feature
  points.
- If `trackingState` shows `limited-*`, slow down or improve lighting
  before continuing the scan.
