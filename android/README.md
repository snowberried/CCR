# CCR Android S24 Exact-Frame Spike

This is an independent diagnostic Android project. It does not move or share the desktop runtime and is not a medical device or an official diagnostic program.

## Build contract

- JDK 17
- Gradle Wrapper 9.5.0
- Android Gradle Plugin 9.3.0
- minSdk 34, compileSdk/targetSdk 37
- application ID `com.snowberried.ctcinereviewer.internal`
- versionName `0.1.0`, versionCode `1`

The project requires Android SDK Platform 37.0, Build Tools 36.0.0 and platform-tools. Set `ANDROID_HOME` or create an untracked `local.properties`.

```powershell
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
.\gradlew.bat --version
.\gradlew.bat lintInternalDebug testInternalDebugUnitTest assembleInternalDebug
.\scripts\verify-apk-privacy.ps1
```

## Signing

`internalDebug` uses the standard local debug key. Release signing values may be supplied in an ignored `signing.properties` copied from `signing.properties.example`, or through:

- `CCR_ANDROID_KEYSTORE_PATH`
- `CCR_ANDROID_KEYSTORE_PASSWORD`
- `CCR_ANDROID_KEY_ALIAS`
- `CCR_ANDROID_KEY_PASSWORD`

No keystore is committed. Gate 0-3 CI uploads only the internal debug APK as a workflow artifact and never creates a GitHub Release.

## Privacy and scope

The manifest declares no INTERNET or broad storage permission. Source video access will use SAF read-only descriptors. Project storage, DICOM/PACS, AI, cloud, server communication, remote analytics, annotations and comparison view are excluded from this spike.
