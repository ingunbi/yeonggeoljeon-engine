# Yeonggeoljeon Engine · 영걸전 자체 엔진

[![Engine source checks](https://github.com/ingunbi/yeonggeoljeon-engine/actions/workflows/verify.yml/badge.svg)](https://github.com/ingunbi/yeonggeoljeon-engine/actions/workflows/verify.yml)

한국어 DOS/V판 삼국지 영걸전의 자료와 실행 동작을 분석하여 만드는 자체
네이티브 엔진입니다. 현재는 **0.2.0 연구 개발판**이며, 원작 전체를 플레이하는
캠페인 실행과 원작 전투 규칙은 아직 복원 중입니다.

**공개 저장소에는 엔진 코드·문서·합성 테스트만 들어 있습니다.** 원작 실행 파일,
그림·음악·대사·지도·시나리오 데이터와 이를 포함한 앱은 배포하지 않습니다.
사용자가 보유한 원작 자료를 지정하면 자신의 컴퓨터에서 실행 자료를 생성합니다.
이전의 공개 엔진 기반 시험 앱과 분리한 구현이며, 외부 게임 엔진이나 대체 에셋
묶음을 사용하지 않습니다.

## 현재 구현 범위

| 부분 | 구현과 한계 |
|---|---|
| 원작 리소스 | 자체 LS11·NPK·planar 해독. 궁전 지도23개·소품·인물 그림29묶음과 인물 식별자384개 연결. 원작 글꼴·초상화·음악은 미복원. |
| 장면 실행 | 인물 배치·동시 이동·퇴장·대사·화면 상태. 첫 궁전 레코드40명령을 원본 FF 경계까지 재생. |
| 전투 자료 | 원작 지도58개와 지도 선택 지점60개 해독. 60개는 전체 전투 수나 플레이 가능 수를 뜻하지 않음. 조건부 편성과 원작 수치는 불명 상태를 보존. |
| 전술 엔진 | 선택·이동·공격·대기·턴·결정적 AI·승패. 현재는 명시적으로 선택한 experimentalV1 규칙만 실행. 원작 피해·병과 이동 비용·AI·전투 목표는 미복원. |
| 캠페인 자료 | 5개 장·18개 멤버·225개 블록·2,144개 레코드의 명령 경계 해독. 원작 조건과 분기를 따라 전체 캠페인을 자동 진행하는 기능은 미구현. |
| 캠페인 연구 | 기록 선택·미리보기·중단 경계·전투 참조·결과 출처 보존. 실험 전투 결과를 원작 플래그로 반영하지 않음. |

전투 화면은 로컬에서 읽은 원작 지도 위에 연구용 유닛 표식을 표시합니다.
실험 수치와 규칙은 보존된 원작 값·불명 값과 분리하며, 조건부 편성을 거짓으로
확정하지 않습니다. 원작 규칙으로 시작하는 요청은 명시적으로 미지원 처리합니다.

캠페인의 정적 미리보기 분류는 supported-record 3개, partial-record 47개,
data-only 2,094개입니다. 이는 원작의 전체 도달 가능성이나 플레이 검증 결과가
아닙니다. 알 수 없는 명령·조건·이전 상태에서는 원인을 기록하고 멈춥니다.

## macOS 빌드와 실행

Apple Silicon Mac, 설치된 Xcode Command Line Tools, Python3.11 이상이 필요합니다.
빌드 도구는 전역 패키지를 설치하지 않습니다.

```sh
python3 tools/build.py --game /path/to/original/GAME --verify --install
```

--game에는 GAME/ 폴더가 든 원본 ZIP도 지정할 수 있습니다. 입력은 읽기만
하며 DOS 프로그램을 실행하거나 수정하지 않습니다. 결과는
build/Yeonggeoljeon Engine.app, 설치 위치는 ~/Applications/Yeonggeoljeon Engine.app입니다.

제공된 판본의 OPGRP.R3 배경 영역은 손상되어 있습니다. 정상 자료를 별도로
보유한 경우 --title-opgrp /path/to/intact/OPGRP.R3를 추가할 수 있습니다.
도구는 원작 파일을 자동으로 다운로드하지 않습니다. 정상 타이틀 자료가 없으면
그 상태를 표시하고 첫 장면을 실행합니다.

Return·Space·클릭으로 대사를 진행하고 Esc로 장면 창을 종료합니다.
메뉴 **연구 → 실험 전투** 또는 **연구 → 캠페인 분석**에서 추가 기능을 엽니다.
전투 창에서는 클릭으로 선택·이동·공격, Space로 대기, Return으로 턴을 종료합니다.
조건부 기록 미리보기는 별도 선택이며 원작 진행 조건을 충족한 것으로 처리하지 않습니다.

## CLI와 검사

원작 없이 실행하는 소스 검사는 다음과 같습니다.

```sh
python3 -m unittest discover -s Tests -v
swift run yeonggeoljeon-engine --self-test
python3 tools/audit_source.py --output build/source-audit.json
python3 tools/source_release.py
```

실물 검사 네 개는 ORIGINAL_GAME_DIR, 정상 타이틀 검사는 추가로
TITLE_OPGRP_FILE을 지정해야 실행됩니다. 선택하지 않은 실물 검사는 건너뛰며
통과로 계산하지 않습니다. GitHub CI는 원작 파일을 받거나 내려받지 않습니다.

변환한 로컬 자료에 대한 연구 명령은 다음과 같습니다.

```sh
swift run yeonggeoljeon-engine --data /path/to/GameData --list-battles
swift run yeonggeoljeon-engine --data /path/to/GameData --list-campaign
swift run yeonggeoljeon-engine --data /path/to/GameData --battle 0:0:5 --experimental-rules
swift run yeonggeoljeon-engine --data /path/to/GameData --verify-battle --battle 0:0:5 --experimental-rules --output /path/to/new-battle-report
swift run yeonggeoljeon-engine --data /path/to/GameData --verify-campaign --output /path/to/new-campaign-report
```

진단 출력 폴더는 입력과 분리된 빈 폴더여야 합니다. 진단은 사용자 진행 상태를
읽거나 저장하지 않습니다. 소스 ZIP 도구는 공개 후보 목록과 파일별 SHA-256을
ZIP에서 다시 읽어 확인하며, 원작 콘텐츠와 로컬 앱을 포함하지 않습니다.

## 실행한 검증

2026-10-25 Apple Silicon Mac에서 Python45개 검사(실물4개 포함),
네이티브 자체 진단80항목을 실행했습니다. 첫 궁전 실제 렌더5장과 실험 전투의
이동·공격·종료 화면을 확인했습니다. 첫 실험 전투는 양측 자동 입력10턴에서
종료했고 반복 상태·이벤트가 일치했습니다. 이는 원작 전투 결과가 아닙니다.

2,144개 캠페인 기록의 독립 실행 검사는 원본 경계1개, 선언된 미지원 경계30개,
네이티브 실패0개, 자동 선택하지 않은 기록2,113개를 보고했습니다.
전체 캠페인을 플레이한 결과는 아닙니다. 새 전투·캠페인 UI의 OS 입력 검사는
아직 실행하지 않았으며, 진단 렌더와 구분합니다. 원본69개 파일의 해시 보존도 확인했습니다.

## 다음 복원 범위와 자료

원작 피해·반격·병력 차감, 병과별 이동 비용, 조건부 전투 편성,
원작 플래그·선택지·이벤트 디스패처와 캠페인 진행, 도시·세계지도,
전투 인물 그림·원작 UI·글꼴·소리·진행 저장을 이어서 구현합니다.
원작 실행 결과와의 비교 검증도 별도로 필요합니다.

- [원본 식별과 구현 출처](research/README.md)
- [그래픽 형식과 팔레트 근거](research/graphics-formats.md)
- [전투 자료 형식](research/battle-formats.md) · [실험 규칙](research/battle-rules.md)
- [전투 수치 생산자 분석](research/battle-source-notes.md)
- [캠페인 형식과 한계](research/campaign-format.md)
- [런타임 계약](research/runtime-contracts.md) · [기여 안내](CONTRIBUTING.md)

이전 공개 엔진 소스를 본 이력이 있으므로 격리된 클린룸 개발이라고 주장하지
않습니다. 새 엔진 코드는 [GPL-3.0-only](LICENSE)로 공개하며, 원작 콘텐츠의
권리는 이 코드 라이선스에 포함되지 않습니다. 로컬에서 원작 실행 자료를 넣어
만든 앱도 이 저장소의 공개 배포물에 포함하지 않습니다.
