# Yeonggeoljeon Engine · 영걸전 자체 엔진

[![Engine source checks](https://github.com/ingunbi/yeonggeoljeon-engine/actions/workflows/verify.yml/badge.svg)](https://github.com/ingunbi/yeonggeoljeon-engine/actions/workflows/verify.yml)

한국어 DOS/V판 삼국지 영걸전의 원본 자료와 정적 분석을 바탕으로 만드는
Swift/AppKit 자체 엔진입니다. **0.4.0 연구 개발판**은 원작 전투 계산·AI·책략과
캠페인 실행기를 복원하는 단계입니다. 첫 전투부터 엔딩까지 이어서 플레이할 수 있지만, 사람이 끝까지 해 본 검증은 아직 없습니다.

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
| 전투 도구 | 속성 변경·전직, 공격서, 혼란서, 단일/범위 회복, 폭탄의 조건·대상 범위·난수 순서·소모. 거부와 취소는 도구와 행동을 소모하지 않음. |
| 필드 기능 | 장수 정보, 장수 간 도구 교환, 세계지도의 전체 지도와 도시 선택 이동, 스토리 정보. 출전 선택은 장수 능력을 함께 보여 주는 창으로 표시. |
| 음악 | 코에이 드라이버(SBOPL2.COM)의 곡 해석기를 옮기고 OPL2 합성기를 자체 구현해 MUSIC.R3 20곡을 원작 선택 그대로 재생. 필드·전투 메뉴의 BGM으로 켜고 끔. 효과음 43개와 오프닝·엔딩 음악도 재생. 곡이 바뀔 때는 원작처럼 이전 곡을 약 0.6초 동안 줄인 뒤 바꿈. 그 밖의 페이드와 페이드 동안의 진행 멈춤은 미복원이고, 음량은 엔진이 정하는 출력 음량 하나. |
| 도구상 | 세계지도 도착 시 입장 질문, 궁전7번 방의 상인 배치와 방 음악, 도시별 재고, 구매·판매 가격, 소지금 상한, 장수별 8칸 소지품, 원작 문구와 구매·판매·거절 효과음. 원작 창 모양은 복원하지 않음. |
| 원작 이동·AI | 병과별 이동 비용, 진영 점유·ZOC, 원작 공격 패턴, 명령0~4의 목표·영향권·후보 평가, 물리/책략 비교와 후보별 RNG 소비. 미해석 점유 상태에서는 중단. |
| 원작 턴 | 날씨, 진영별 회복·상태 회복, AI 우선순위, 이동 취소·대기, 원작 턴 제한 결과와 캠페인 이벤트 프로브. 일반 전멸 판정으로 승리를 만들지 않음. |
| 캠페인 실행기 | 5장·18멤버·225블록·2,144레코드의 단계 그룹·반복·조건·플래그·선택·전환. 시나리오가 실행한 배치 프로그램을 사용하며 기록 목록의 다음 행으로 진행하지 않음. |
| 장면 실행 | 동일 런타임에서 인물 배치·동시 이동·퇴장·대사·원작 삽화·초상화를 유지. 도시/인물 입력은 경로·인접 판정·상호 방향 확인 뒤 원작 이벤트를 호출. 목적지 도착은 원작대로 기록 종류2(세계지도는 5)를 찾음. 일치 기록이 없으면 원작 내장 전환으로 방 입장·궁전 출구(복귀 문맥)·마을 출구(세계지도)를 처리하고 기본 플레이어를 배치. 장 제목은 원작처럼 짧은 상자로 보인 뒤 장 표시줄에 남고, 장소 이름과 획득 알림은 원작 시간(96틱, 약 1.6초) 뒤 저절로 닫히는 상자로 표시. 지도가 바뀔 때는 원작처럼 이전 화면이 약 0.53초 동안 어두워지고, 스크립트의 05 명령에서 새 지도가 밝아짐. 세계지도에서는 처음 배치한 부대를 기준으로 원작 규칙대로 화면을 맞춤. 원작 창 테두리, 이야기 그림의 패턴 전환, 전투 진입 페이드, 기본 진입 음악 일부는 미복원. |
| 저장·이어하기 | 원작 3D 저장 질문 시점과, 마을·세계지도에서 오른쪽 클릭으로 여는 원작 필드 메뉴(게임 종료·로드·세이브)에서 자체 엔진 상태를 JSON으로 저장하고 그대로 이어서 진행. 오프닝이 끝나면 바로 원작 MAIN 메뉴(개시·재개·기능설정·오프닝)가 원작 문구로 뜸. 원작 화면 틀에서는 원작처럼 검은 화면에 MARK 그림으로 그린 MAIN의 메뉴 창을, 엔진 화면에서는 타이틀 그림의 로고 아래에 메뉴를 표시. 기능설정은 원작의 모니터·BGM·효과음 세 줄. 메뉴를 취소하면 원작처럼 종료 화면을 보인 뒤 게임이 끝남. 새로 시작과 불러오기는 원작처럼 약 0.53초 동안 어두워졌다가 밝아짐. 불러오기 목록에서 원작 세이브 슬롯(MSAVE·ESAVE)을 읽기 전용으로 가져옴. 원작 파일에는 쓰지 않음. |
| 편의 기능 | 원작에 없는 엔진 추가 기능. Control을 누르는 동안 4배 빨리 감기(대사는 0.1초 만에 넘김), 대사 기록, 장면·지도가 바뀔 때마다 자동 저장, 빠른 저장·불러오기, 공격 대상 위의 예상 피해와 반격 확률 표시, 적 공격 범위 표시, 다음 부대 선택, 행동하지 않은 부대가 남았을 때의 턴 종료 확인, 마우스를 올린 부대의 정보. |
| 게임 화면 | 원작 MAIN이 그리는 필드 화면 틀(PACKGRP 0번)과 우측 HUD(주인공 초상화·돈·레벨·현재영토)와 좌하단 위치 표시를 MAIN 명령의 좌표로 배치. 전투 화면 틀(1번)에는 13×11칸 스크롤 지도, 전투 이름, 세력 이름, 아군/적군 전환, 병력 막대가 붙은 부대 목록, 미니맵과 시야 사각형, 기능 메뉴, 승리조건 창, 빈 칸을 눌렀을 때의 지형 정보 창을 원작 규칙으로 표시. 부대를 고르면 이동 칸을 정한 뒤 원작 위치에 공격·책략·도구·대기 창이 뜨고, 취소하면 원위치로 돌아감. 부대 걷기, 칼 부딪힘, 화살·투석, 책략과 도구 효과가 원작 그림과 원작 타이머 단위로 재생되고, 공격마다 원작 확대 전투 화면(지형별 배경, 병력 수에 따른 병사, 결과 창)이 나옴. 클릭은 대기 단계를 넘기고, 오른쪽 클릭이나 Esc는 장면을 끝냄. 도구는 사용·건네기·버리기·보기를 복원. 저장 질문·재시작·선택지·타이틀/필드 메뉴·출전 선택·전투 대사는 화면 안 자체 선택 창으로 표시하고 예/아니요는 원작 MARK 버튼 그림을 사용. 원작 화면 틀에서는 HUD 숫자·현재영토·장 표시줄과 타이틀 메뉴 글자를 원작 MAIN 글꼴(ALL_FONT.16P·HANKAKU.FNT)로 원작 위치에 그림. 대화창·명령 창의 테두리와 글꼴은 미복원. |
| 엔진 화면 | 기본 화면은 엔진 배치. 필드는 지도가 창 전체를 채우고 HUD가 떠 있는 카드로 표시되며, 전투는 15×12칸 지도와 사이드바를 씀. 대화·선택·저장 질문·명령 창·도구상은 공통 디자인(`CanvasTheme`)으로 그림. 보기 → 원작 화면 틀(⌘⇧F)로 원작 틀로 돌아갈 수 있음. 게임 규칙과 원작 그림은 바꾸지 않음. |
| 전투와 캠페인 연결 | 출전 선택·보존 부대의 재배치·승리 보너스·다음 전투 연결. 퇴장 이벤트 동안 물리 공격/반격/범위 책략을 중단·재개하며 공유 문맥과 새 대상 상태를 재조회. 전투 종료 뒤 원작 결과표로 스크립트가 고른 지도(09·11) 진입, 연속 전투 재진입, 패배 마스크, 재시작을 구분. 전투 메뉴의 총퇴각은 원작 36 체크포인트에서 그 전투를 다시 시작하고(연속 전투에서는 원작처럼 거부), 게임종료는 재시작 선택으로 이어짐. 패배하면 원작 MAIN의 재시작 선택(문구는 로컬 자료에서 읽음)을 띄우고 예는 새 캠페인으로, 아니요는 창 닫기로 처리. |
| 전투 그림·오프닝·엔딩 | 원본 전투 인물과 일기토 프레임을 로컬 해독. 일기토는 원작 순서대로 등장·돌진·합·도주·쓰러짐을 원작 틱과 효과음, 지형별 배경, 아래 두 정보 창과 함께 재생하고 그동안 일기토 음악을 틂. 오프닝 데모 전체(16장면), 엔딩 세 갈래(END1 두 종류, END2), 공통 크레딧을 원작 그림·글꼴·음악으로 재생. 원작을 실행해 비교하지는 않음. |

전투 화면은 지도를 클릭해 조작하고 방향키·휠·미니맵 클릭으로 시야를 옮깁니다.
공격·일기토·엔딩의 화면 전체와 원작 타이밍을 재현했다는 뜻은 아닙니다.
`--battle`은 독립 검증 상태입니다. 초기 플래그를 비운 배치의 캠페인 도달 여부는
실제 시나리오 입력 재생과 별도로 확인해야 합니다. 이전 `experimentalV1`은
`--experimental-rules`를 명시한 연구 모드에만 남아 있습니다.

강화한 시험 봇은 여러 시드와 분기에서 첫 전투부터 엔딩까지 도달했고, 전투 64개를 모두
지나갔습니다. 일반 수치로 사람이 끝까지 플레이한 검증은 아닙니다. 원작 세이브 다섯 슬롯도 모두 불러와 같은 방식으로 엔딩까지 이어졌습니다. 슬롯에 저장되지
않는 난수·전투 중 상태는 복원하지 않습니다([원작 세이브](research/original-saves.md)).

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
`~/Library/Application Support/Yeonggeoljeon Engine/Saves`에 두며, 환경 변수
`YEONGGEOLJEON_SAVES`로 다른 폴더를 지정할 수 있습니다.

캠페인 창의 엔진 추가 단축키는 다음과 같습니다. Control을 누르고 있으면 빨리 감기, L 또는 ⌘J로
대사 기록, F5 또는 ⌘S로 빠른 저장, F9 또는 ⌘L로 빠른 불러오기, ⌘T로 빨리 감기 고정입니다. 전투에서는 D 또는 ⌘D로 적 공격 범위를
켜고 끄며, Tab과 Shift-Tab으로 아직 행동하지 않은 부대를 차례로 고릅니다.
자동 저장과 빠른 저장은 불러오기 목록에 함께 나옵니다.
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
- [바깥 루프·전투 종료·재시작 선택](research/original-framework.md) · [저장·타이틀 메뉴·이어하기](research/native-resume.md) · [타이틀 메뉴](research/original-title-menu.md) · [지도 전환](research/original-map-transitions.md) · [MAIN 글꼴](research/original-main-font.md)
- [필드·전투 화면 틀·HUD·화면 안 선택 창](research/original-screen.md) · [전투 도구 사용](research/original-items.md) · [도구상과 도시 입장](research/original-shop.md) · [시민](research/original-citizens.md) · [확대 전투 화면](research/original-combat-view.md) · [음악](research/original-music.md)
- [전투 그림](research/original-battle-sprites.md) · [일기토](research/original-duel.md) · [엔딩](research/original-ending.md) · [오프닝과 엔딩 프로그램](research/original-screen-programs.md)
- [기여 안내](CONTRIBUTING.md)

이전 공개 엔진 소스를 본 이력이 있으므로 격리된 클린룸 개발이라고 주장하지
않습니다. 새 코드는 [GPL-3.0-only](LICENSE)로 공개하며 원작 콘텐츠의 권리는
이 코드 라이선스에 포함되지 않습니다. 원작 자료를 넣어 만든 로컬 앱은 공개 배포하지 않습니다.
