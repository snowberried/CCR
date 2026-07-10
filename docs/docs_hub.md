# Docs Hub

프로젝트 문서를 빠르게 찾기 위한 인덱스이다. 새 문서 파일을 만들거나 문서 위치를 바꾸면 이 파일을 함께 갱신한다.

## 상위 문서

| 문서 | 위치 | 용도 |
| --- | --- | --- |
| 프로젝트 개요 | `../README.md` | CT Cine Reviewer 명칭, 현재 단계, v0.1 범위와 제외 범위 |
| Phase 1 Handoff | `../HANDOFF_PHASE1.md` | 새 Codex 프로젝트에서 Phase 1을 이어가기 위한 현재 상태와 시작 절차 |
| 프로젝트 작업 지침 | `../AGENTS.md` | 중요한 결정 전 사용자 확인, 의료·보안 경계, 단계별 검증 원칙 |

## 기획 문서

| 문서 | 위치 | 용도 |
| --- | --- | --- |
| Project Charter | `00_PROJECT_CHARTER.md` | 문제, 사용자, 목표, 비목표, 한계와 성공 정의 |
| Product Requirements | `01_PRODUCT_REQUIREMENTS.md` | P0/P1/P2 요구사항, 사용자 흐름, 조작, 오류, 성능 목표 |
| Architecture Options | `02_ARCHITECTURE_OPTIONS.md` | 기술 후보 비교, 1순위 제안과 위험 |
| Technical Spike Plan | `03_TECHNICAL_SPIKE_PLAN.md` | 대표 MP4 분석, 프레임·PTS·캐시 검증 계획과 합격 기준 |
| Data and State Model | `04_DATA_AND_STATE_MODEL.md` | 원본 식별, 프레임, 보정, 주석, preset, 프로젝트 저장 개념 |
| Roadmap | `05_ROADMAP.md` | Phase별 목적, 산출물, 진입·완료 조건과 사용자 승인 |
| Decisions and Open Questions | `06_DECISIONS_AND_OPEN_QUESTIONS.md` | 확정 사항, 제안, 미결정과 Phase 1 승인 체크리스트 |
| Phase 1 Spike Results | `07_PHASE1_SPIKE_RESULTS.md` | Phase 1 scaffold, 테스트, 실제 샘플 측정 결과와 남은 차단 사항 |
| FFmpeg Distribution | `08_FFMPEG_DISTRIBUTION.md` | 고정 BtbN 자산, checksum, buildconf, 라이선스와 취득 절차 |
| Frame Decoding and Cache | `09_FRAME_DECODING_AND_CACHE.md` | Phase 1C 프레임 전달·정확성·캐시 실측과 추천 전략 |
| Project Troubleshooting | `troubleshooting.md` | CT Cine Reviewer에서만 발생하는 문제와 검증된 해결 방법 |
| Docs Hub | `docs_hub.md` | 프로젝트 문서 목록과 위치 안내 |

## 현재 단계

- Phase 0 기획은 완료됐다.
- Phase 1 기술 스파이크와 Electron/React/TypeScript 최소 검증 UI 구현을 완료했다.
- Phase 1C 프레임 디코딩과 캐시 전략 비교를 완료하고 61-frame RAM 구간 캐시를 추천안으로 결정했다.
- 사용자 승인 전 Phase 2 제품 기능, 재생, 보정과 주석을 시작하지 않는다.

## 갱신 규칙

- 새 문서를 추가하면 위 표에 문서 이름, 위치, 용도를 기록한다.
- 문서가 삭제되거나 이동하면 이 인덱스도 같은 작업에서 수정한다.
- 중요한 결정이나 운영 원칙은 먼저 `../AGENTS.md`에 맞는지 확인한다.
