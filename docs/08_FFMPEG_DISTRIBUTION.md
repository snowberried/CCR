# FFmpeg Distribution

## 선택 결과

- 제공처: BtbN/FFmpeg-Builds
- release tag: `autobuild-2026-06-30-13-34`
- asset: `ffmpeg-n8.1.2-21-gce3c09c101-win64-lgpl-shared-8.1.zip`
- upstream asset: https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-06-30-13-34/ffmpeg-n8.1.2-21-gce3c09c101-win64-lgpl-shared-8.1.zip
- archive size: 70,103,338 bytes
- SHA-256: `27bcaf58b5140171dfe838a0b365d12c60607d71fc168424456410bad6a834da`
- FFmpeg version: `n8.1.2-21-gce3c09c101-20260630`
- build date identifier: `20260630`
- target: Windows x64
- linkage: shared
- license: LGPLv3
- 최소 Windows 기준: Windows 10 22H2 이상

BtbN은 일일 빌드를 최근 14개만 보관하지만 월말 빌드는 2년 보관한다고 명시한다. 따라서 floating `latest`가 아니라 월말 고정 release tag를 선택했다.

공식 참고:

- FFmpeg Windows 다운로드 제공처 안내: https://ffmpeg.org/download.html
- BtbN 빌드 종류와 보관 정책: https://github.com/BtbN/FFmpeg-Builds
- 선택한 BtbN release: https://github.com/BtbN/FFmpeg-Builds/releases/tag/autobuild-2026-06-30-13-34
- FFmpeg 라이선스 안내: https://ffmpeg.org/legal.html

## 선택 이유

- `lgpl-shared`는 BtbN이 GPL 전용 dependency를 제외한 shared variant로 정의한다.
- 실제 `ffmpeg -buildconf`에 `--enable-shared`, `--disable-static`, `--enable-version3`가 있고 `--enable-gpl`, `--enable-nonfree`는 없다.
- `libx264`, `libx265`, `libxvid` 등 GPL 관련 encoder dependency가 비활성화돼 있다.
- 실제 decoder 목록에서 H.264와 HEVC/H.265 디코더 존재를 확인했다. 현재 probe 및 향후 기본 MP4 디코딩에 GPL 전용 기능은 필요하지 않다.
- shared DLL 구성이 FFmpeg 공식 LGPL compliance checklist의 동적 연결 권고와 향후 라이브러리 연동 가능성에 맞는다.

## 로컬 취득과 검증

프로젝트 실행 중 자동 다운로드하지 않는다. 개발자가 다음 명령을 명시적으로 실행한다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-ffmpeg.ps1
```

스크립트는 다음 순서로 동작한다.

1. 고정 release URL의 정확한 asset만 다운로드한다.
2. archive SHA-256을 고정값과 비교한다.
3. checksum이 다르면 압축을 풀거나 실행하지 않는다.
4. `tools/ffmpeg/bin/`에 `ffmpeg.exe`, `ffprobe.exe`와 shared DLL을 배치한다.
5. archive의 `LICENSE.txt`를 `tools/ffmpeg/licenses/`에 보존한다.
6. 실제 `-version`과 `-buildconf`를 실행해 로컬 metadata 문서를 생성한다.

`tools/ffmpeg/`와 다운로드 archive는 Git에서 제외한다. 저장소에는 고정 취득 스크립트와 이 문서만 보관한다.

## 로컬 런타임 파일

- `ffmpeg.exe`
- `ffprobe.exe`
- `avcodec-62.dll`
- `avdevice-62.dll`
- `avfilter-11.dll`
- `avformat-62.dll`
- `avutil-60.dll`
- `swresample-6.dll`
- `swscale-9.dll`

`ffplay.exe`는 현재 앱에 필요하지 않아 배치하지 않는다.

## 라이선스와 패키징 주의

archive의 `LICENSE.txt`는 GNU LGPL version 3 전문이다. 선택 build에는 `--enable-version3`가 포함된다.

현재 로컬 기술 스파이크와 향후 제품 배포는 구분한다. 제품 패키징 전에는 다음을 추가로 확정해야 한다.

- FFmpeg 사용 사실과 LGPLv3 고지 위치
- 선택 binary와 정확히 대응하는 FFmpeg source commit `ce3c09c101` 제공 방식
- BtbN build script와 build configuration 보존 방식
- archive에 포함된 외부 라이브러리별 license/notice와 대응 source 제공 의무
- FFmpeg DLL 교체를 방해하지 않는 패키징 방식
- EULA와 reverse engineering 제한 문구 검토

FFmpeg 공식 legal checklist는 소스 제공, build configuration, About/EULA 고지 등을 권고한다. 이 문서는 법률 자문이 아니며 외부 배포 전에 별도 라이선스 검토가 필요하다.

## 재현 정보

- FFmpeg source identifier: `n8.1.2-21-gce3c09c101`
- FFmpeg source repository: https://git.ffmpeg.org/ffmpeg.git
- BtbN build repository: https://github.com/BtbN/FFmpeg-Builds
- full build configuration: 로컬 `tools/ffmpeg/BUILDINFO.md`에서 자동 생성
- archive checksum record: 로컬 `tools/ffmpeg/SHA256SUMS.txt`에서 자동 생성
