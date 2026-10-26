# Yeonggeoljeon Engine · 영걸전 자체 엔진

[![Engine source checks](https://github.com/ingunbi/yeonggeoljeon-engine/actions/workflows/verify.yml/badge.svg)](https://github.com/ingunbi/yeonggeoljeon-engine/actions/workflows/verify.yml)

한국어 DOS/V판 삼국지 영걸전의 원본 자료와 정적 분석을 바탕으로 만드는
Swift/AppKit 자체 엔진입니다. **0.4.0 연구 개발판**은 원작 전투 계산·AI·책략과
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
| 장면 실행 | 동일 런타임에서 인물 배치·동시 이동·퇴장·대사·원작 삽화·초상화를 유지. 도시/인물 입력은 경로·인접 판정·상호 방향 확인 뒤 원작 이벤트를 호출. 목적지 도착은 원작대로 기록 종류2(세계지도는 5)를 찾음. 일치 기록이 없으면 원작 내장 전환으로 방 입장·궁전 출구(복귀 문맥)·마을 출구(세계지도)를 처리하고 기본 플레이어를 배치. 원작 창 테두리·전환 시간·진입 음악은 미복원. |
| 저장·이어하기 | 원작 3D 저장 질문 시점의 자체 엔진 상태를 JSON으로 저장하고 그대로 이어서 진행. 타이틀 뒤 원작 MAIN 메뉴(개시·재개·기능설정·오프닝)를 원작 문구로 표시. 원작 세이브 슬롯(MSAVE)은 읽거나 쓰지 않음. |
| 전투와 캠페인 연결 | 출전 선택·보존 부대의 재배치·승리 보너스·다음 전투 연결. 퇴장 이벤트 동안 물리 공격/반격/범위 책략을 중단·재개하며 공유 문맥과 새 대상 상태를 재조회. 전투 종료 뒤 원작 결과표로 스크립트가 고른 지도(09·11) 진입, 패배 마스크, 재시작을 구분. 패배하면 원작 MAIN의 재시작 선택(문구는 로컬 자료에서 읽음)을 띄우고 예는 새 캠페인으로, 아니요는 창 닫기로 처리. |
| 전투 그림·엔딩 | 원본 전투 인물 및 일부 일기토 프레임을 로컬 해독. 엔딩은 원작 첫33프레임/43초까지만 복원되어 이후 경계를 명시. |

전투 창은 원작 지도·부대 그림에 자체 조작 UI와 진단 정보를 표시합니다.
공격·일기토·엔딩의 화면 전체와 원작 타이밍을 재현했다는 뜻은 아닙니다.
`--battle`은 독립 검증 상태입니다. 초기 플래그를 비운 배치의 캠페인 도달 여부는
실제 시나리오 입력 재생과 별도로 확인해야 합니다. 이전 `experimentalV1`은
`--experimental-rules`를 명시한 연구 모드에만 남아 있습니다.

상점과 시민, 궁전7번 방의 특수 인물, 전투 결과1의 재시작, 기능설정, 원작 세이브
슬롯과 원작 불러오기 경로, 엔딩 후속 장면 등에는 미복원 경계가 남아 있습니다. 이 경계는
생략해 진행하지 않습니다. 전체 캠페인 완주를 지원하거나 검증했다고 보고하지 않습니다.

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

기본 화면은 원작 캠페인 실행기입니다. 타이틀 뒤 원작 메뉴에서 새로 시작하거나,
원작 저장 질문에서 만든 자체 엔진 저장 파일로 이어서 진행합니다. 저장 파일은 기본적으로
`~/Library/Application Support/Yeonggeoljeon Engine/Saves`에 둡니다.
메뉴 **연구 → 원작 캠페인 실행 연구**에서 새 실행 창을 열 수 있습니다. **원작 전투 복원 검증**에서는
독립 전투를 엽니다. 클릭으로 선택·이동·공격, Space로 대기, Return으로 턴 종료,
Backspace로 이동을 취소합니다. S 또는 책략 버튼으로 사용 가능한 명령을 고르고
대상을 지정합니다. 이름 표가 연결되지 않은 책략은 ID와 MP 비용으로 표시합니다.
캠페인의 현재 미지원 경계는 화면에 표시합니다.

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
swift run yeonggeoljeon-engine --data /path/to/GameData --verify-play --inputs /path/to/local-inputs.json --output /path/to/new-play-report
swift run yeonggeoljeon-engine --data /path/to/GameData --verify-play --resume /path/to/native-save.json --inputs /path/to/rest.json --output /path/to/new-resume-report
swift run yeonggeoljeon-engine --data /path/to/GameData --list-campaign
```

출력은 입력과 분리된 빈 폴더여야 합니다. 전투 진단의 아군 입력은 검사 드라이버가
생성하며 원작 AI로 주장하지 않습니다. 캠페인 진단은 대사·이동을 진행하다 원작
이벤트·선택·미지원 경계에서 멈추며 승리나 다음 장면을 주입하지 않습니다.

현재 실제 원본 검사에서는 명시한 플레이어 입력41개로 첫 전투의 원작 일기토·승리
이벤트를 거쳐 다음 장면으로 복귀하고, 두 번째 전투의 수동 조작 단계까지
이어졌습니다. 로컬 입력138개로는 두 번째 전투를 원작 이벤트로 이기고 서장 끝을
지나 1장의 궁전·마을 이동과 출전 선택을 거쳐 1장 첫 전투(1:0:6)까지 진행했습니다.
그 전투의 패배는 원작 재시작 선택으로 끝났습니다. 같은 입력의 세 저장 지점에서
자체 저장 후 이어 진행한 최종 상태는 끊김 없이 진행한 상태와 같았습니다. 배치·승리·플래그를
검사기가 주입하지 않습니다. 입력 경로와 화면·대사
보고서는 로컬에만 보관합니다. 플레이어 입력을 고른 검사 정책은 원작 AI가 아니며,
적과 비수동 아군의 행동은 복원한 엔진이 처리합니다. 원본69개 파일의 해시 불변과
원작 없이 실행하는 합성 검사를 별도로 확인했습니다.

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
- [부대·출전 선택](research/original-party.md) · [퇴장 실행](research/original-retirement.md)
- [시나리오 지도 반환](research/original-map-return.md) · [입력 재생 검사](research/original-play-verification.md)
- [바깥 루프·전투 종료·재시작 선택](research/original-framework.md) · [저장·타이틀 메뉴·이어하기](research/native-resume.md)
- [전투 그림](research/original-battle-sprites.md) · [엔딩](research/original-ending.md)
- [기여 안내](CONTRIBUTING.md)

이전 공개 엔진 소스를 본 이력이 있으므로 격리된 클린룸 개발이라고 주장하지
않습니다. 새 코드는 [GPL-3.0-only](LICENSE)로 공개하며 원작 콘텐츠의 권리는
이 코드 라이선스에 포함되지 않습니다. 원작 자료를 넣어 만든 로컬 앱은 공개 배포하지 않습니다.
