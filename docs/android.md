# 안드로이드 태블릿 실행

2026-11-13. iPad 앱과 같은 엔진 소스(`iOS/SharedSources.json`의 공용 소스와 `iOS/IPadGameStore.swift`)를 Swift의 안드로이드 SDK로 빌드하고, 화면·터치·소리는 Java 앱이 맡는다. 맥 화면을 전송하지 않는다. 원본 DOS 실행 파일은 실행하지 않는다.

## 구성

- `android/swift/AndroidShim.swift`: 안드로이드에 없는 CoreGraphics 일부(이미지·비트맵 컨텍스트), PNG 읽기, SHA-256, Darwin 파일 호출을 대신한다. 안드로이드에서만 컴파일한다.
- `android/swift/AndroidBridge.swift`: 앱이 부르는 C 함수. 상태를 JSON으로, 그림을 RGBA 바이트로 내보내고 터치를 엔진 호출로 바꾼다.
- `android/swift/AndroidBattleRenderer.swift`: 전장 지도를 한 장의 그림(칸당 32픽셀)으로 그린다.
- `android/jni/yg_jni.c`: Java와 위 C 함수 사이의 JNI 층.
- `android/app/`: Java 앱(화면·대화 카드·메뉴·확대 전투·하단 명령 막대·소리). iPad 앱의 구성과 같다.
- 공용 소스의 `#if os(Android)` 분기: 오디오(샘플을 앱이 당겨 간다), 가져오기 정리, OPL2 계산식 단순화(맥에서도 같은 값).

## 만드는 방법

도구는 모두 무시되는 `build/android/` 아래에 풀어 두며 전역 설치는 하지 않는다. 필요한 것:

1. swift.org의 Swift 6.3 툴체인 pkg를 `pkgutil --expand-full`로 `build/android/toolchain`에 푼다(설치하지 않음).
2. Swift 6.3 안드로이드 SDK 번들을 `build/android/sdk`에 풀고 `swift sdk install --swift-sdks-path build/android/sdks`로 등록한 뒤, `ANDROID_NDK_HOME`을 NDK 27.3으로 하여 번들의 `scripts/setup-android-sdk.sh`를 실행한다.
3. Android SDK 플랫폼 35와 빌드 도구 35, NDK 27.3(`sdkmanager`), JDK 17 이상.

```sh
python3 tools/build_android.py --data build/ipad/GameData --install "$ADB_SERIAL"
```

`GameData`는 caller가 고른 원본에서 자체 도구로 뽑은 폴더다. APK에 들어가며 첫 실행 때 앱 저장 공간으로 풀린다. 앱은 `build/android/Yeonggeoljeon.apk`이고 디버그 키로 서명한다.

## 검증 구분

- Lenovo TB373FU(Android 16, arm64)에서 새 게임 시작·대사 건너뛰기·궁전 장면 표시·불러오기 화면을 확인했다.
- 전투·확대 전투·소리·저장은 이 기기에서 아직 확인하지 않았다. 일기토 연출은 iPad와 같이 없다.
- Java 화면은 안드로이드에서 처음 쓴 것이라 iPad 화면과 모양이 다를 수 있다.
