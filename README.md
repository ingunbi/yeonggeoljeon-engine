# Yeonggeoljeon Engine · 영걸전 자체 엔진

[![Engine source checks](https://github.com/ingunbi/yeonggeoljeon-engine/actions/workflows/verify.yml/badge.svg)](https://github.com/ingunbi/yeonggeoljeon-engine/actions/workflows/verify.yml)

한국어 DOS/V판 삼국지 영걸전의 원본 자료와 정적 분석을 바탕으로 만드는
Swift/AppKit 자체 엔진입니다. **0.3.0 연구 개발판**은 원작 전투 계산·AI·책략과
캠페인 실행기를 복원하는 단계입니다. **전체 캠페인 완주 기능은 아직 미완성입니다.**

공개 저장소에는 새 엔진 코드·문서·합성 테스트만 들어 있습니다. 원작 실행 파일,
그림·음악·대사·지도·시나리오·수치표와 이를 담은 앱은 포함하지 않습니다.
사용자가 보유한 자료를 지정하면 자신의 컴퓨터에서 실행 자료를 생성합니다.
이전 공개 엔진 기반 시험 앱과 분리했으며 그 코드·콘텐츠 팩·대체 에셋을 사용하지 않습니다.

## 현재 구현

| 부분 | 구현과 한계 |
|---|---|
| 원작 자료 해독 | LS11·NPK·TF-DCE·planar 자체 해독. 궁전23·마을12·세계지도4·전투지도58, 삽화38·초상화240과 인물384개 연결. 결과는 로컬에만 생성. |
| 원작 전투 수치 | 병과·레벨·장비·사기 기반 능력, 상성·지형·병력 피해, 반격, 경험치·레벨 상승, 사기·상태이상·회복·MP. 인물 상태는 캠페인과 유닛이 공유. |
| 원작 책략 | 0~35 명령의 사용 가능 조건, 피해·상태·사기·단일/범위 회복, 확산 순서·비용·경험치. 실제 명령과 AI 예상 점수를 분리. |
| 원작 이동·AI | 병과별 이동 비용, 진영 점유·ZOC, 원작 공격 패턴, 명령0~4의 목표·영향권·후보 평가, 물리/책략 비교와 후보별 RNG 소비. 미해석 점유 상태에서는 중단. |
| 원작 턴 | 날씨, 진영별 회복·상태 회복, AI 우선순위, 이동 취소·대기, 원작 턴 제한 결과와 캠페인 이벤트 프로브. 일반 전멸 판정으로 승리를 만들지 않음. |
| 캠페인 실행기 | 5장·18멤버·225블록·2,144레코드의 단계 그룹·반복·조건·플래그·선택·전환. 시나리오가 실행한 배치 프로그램을 사용하며 기록 목록의 다음 행으로 진행하지 않음. |
| 장면 실행 | 동일 런타임에서 인물 배치·동시 이동·퇴장·대사·원작 삽화·초상화·세계지도 이동을 유지. 원작 삽화 창의 수명과 좌표를 복원. 원작 글꼴·창 테두리·전환 시간은 미복원. |

전투 창은 원작 지도 위에 진단용 유닛 표식을 그립니다. 원작 전투 인물 그림과
연출 전체를 재현하는 화면은 아닙니다. `--battle`은 복원 규칙을 사용하는 독립
검증 상태이며, 초기 플래그를 비운 배치가 실제 캠페인에서 도달 가능한지는 별도 문제입니다.
이전 `experimentalV1`은 `--experimental-rules`를 지정한 연구 모드에만 남아 있습니다.

실행기는 아직 미복원인 파티 선택·상호작용·일부 전투 스크립트·진행 저장·엔딩
경계에서 멈춥니다. 퇴장 이벤트가 선택지를 열었을 때의 중단·재개도 더 필요합니다.
기록 해독이나 개별 전투 검사를 전체 캠페인 완주로 보고하지 않습니다.

## macOS 빌드

Apple Silicon Mac, 설치된 Xcode Command Line Tools, Python3.11 이상이 필요합니다.
전역 패키지를 설치하지 않습니다.

```sh
python3 tools/build.py --game /path/to/original/GAME --verify --install
```

`--game`에는 `GAME/` 폴더가 든 원본 ZIP도 지정할 수 있습니다. DOS 프로그램은
실행하거나 수정하지 않습니다. 앱은 `build/Yeonggeoljeon Engine.app`, 설치 위치는
`~/Applications/Yeonggeoljeon Engine.app`입니다. 기존 연구 앱을 교체하기 전 ZIP 백업을 만듭니다.
이전 공개 엔진 기반 앱은 교체하지 않습니다.

제공된 판본의 `OPGRP.R3` 타이틀 영역은 손상되어 있습니다. 정상 자료를 보유했다면
`--title-opgrp /path/to/intact/OPGRP.R3`를 추가할 수 있습니다. 자동 다운로드는 하지 않습니다.

기본 화면은 검증된 첫 궁전 장면입니다. 메뉴 **연구 → 원작 캠페인 실행 연구**는
시나리오 첫 단계에서 시작하는 실행기를 엽니다. **원작 전투 복원 검증**에서는
독립 전투를 엽니다. 클릭으로 선택·이동·공격, Space로 대기, Return으로 턴 종료,
Backspace로 이동을 취소합니다. 캠페인의 현재 미지원 경계는 화면에 표시합니다.

## 소스 검사와 로컬 진단

```sh
python3 -m unittest discover -s Tests -v
swift run yeonggeoljeon-engine --self-test
python3 tools/audit_source.py --output build/source-audit.json
python3 tools/source_release.py
```

실물 검사는 `ORIGINAL_GAME_DIR`, 선택 타이틀 검사는 `TITLE_OPGRP_FILE`을 명시해야
실행됩니다. 건너뛴 실물 검사를 통과로 계산하지 않습니다. GitHub CI는 원작 자료를
보관하거나 다운로드하지 않습니다.

```sh
swift run yeonggeoljeon-engine --data /path/to/GameData --battle 0:0:5
swift run yeonggeoljeon-engine --data /path/to/GameData --verify-battle --battle 0:0:5 --output /path/to/new-battle-report
swift run yeonggeoljeon-engine --data /path/to/GameData --verify-vm --output /path/to/new-campaign-report
swift run yeonggeoljeon-engine --data /path/to/GameData --list-campaign
```

출력은 입력과 분리된 빈 폴더여야 합니다. 전투 진단의 아군 입력은 검사 드라이버가
생성하며 원작 AI로 주장하지 않습니다. 캠페인 진단은 대사·이동을 진행하다 원작
이벤트·선택·미지원 경계에서 멈추며 승리나 다음 장면을 주입하지 않습니다.

현재 실제 원본 검사에서는 첫 독립 전투가 7라운드·28교전 후 원작 목표 이벤트8에
도달했습니다. 이는 패배 경로이며 캠페인 승리 검증이 아닙니다. 캠페인 실행기는
첫7레코드를 진행해 원작 인물 대화 이벤트를 기다렸습니다. 원본69개 파일의
해시 불변과 원작 없이 실행하는 합성 검사를 별도로 확인했습니다.

수학·정수 폭·난수 호출·형식의 정적 복원 및 새 코드 검사는 DOS 원본 런타임과의
비교와 다릅니다. 고정 진단 seed1, 전체 난수 시간축, 실제 OS 입력, 원작 화면의
픽셀 일치, 전체 캠페인 완주를 서로 구분합니다. TF-DCE 그림은 명시적 zero-plane
바탕을 사용하며 원본의 보존 plane 정보도 로컬 메타데이터에 남깁니다.

## 근거와 기여

- [원본 식별과 구현 출처](research/README.md)
- [원작 전투 수식](research/original-combat.md) · [원작 책략 실행](research/original-strategies.md)
- [원작 이동·AI·턴](research/original-ai-and-turns.md) · [전투 스크립트](research/original-script-battle.md)
- [캠페인 실행기](research/original-campaign-vm.md) · [도시·세계지도](research/exploration-formats.md)
- [TF-DCE 그림 형식](research/tf-dce-format.md) · [그래픽 팔레트](research/graphics-formats.md)
- [기여 안내](CONTRIBUTING.md)

이전 공개 엔진 소스를 본 이력이 있으므로 격리된 클린룸 개발이라고 주장하지
않습니다. 새 코드는 [GPL-3.0-only](LICENSE)로 공개하며 원작 콘텐츠의 권리는
이 코드 라이선스에 포함되지 않습니다. 원작 자료를 넣어 만든 로컬 앱은 공개 배포하지 않습니다.
