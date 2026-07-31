# Frame Accuracy Fixtures

비식별 합성 RGB 패턴만 포함한다. 실제 사용자 영상과 파일명은 포함하지 않는다. MP4는 고정 파일이며 CI에서 재인코딩하지 않는다.

`duplicate-pts.mp4`는 고정 RTX 4080 SUPER NVENC B-frame 경로로 만든 8프레임 합성 벡터다. 서로 다른 embedded frame ID를 유지하면서 실제 MP4 sample의 PTS가 중복된다.

고정 FFmpeg와 같은 NVENC host에서 이 벡터만 재생성하려면 저장소 루트에서 `node android/tools/generate-frame-accuracy-fixtures.mjs --duplicate-pts-only`를 실행한다. 이 옵션은 기존 픽스처를 삭제하거나 재인코딩하지 않는다.
