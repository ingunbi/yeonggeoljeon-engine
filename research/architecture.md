# 초기 엔진 구조

```text
caller-owned original files
  ├─ resource_formats.py        bounded LS11 / pixel codecs
  ├─ prepare_resources.py       source graphics, geometry and identities
  ├─ prepare_scene.py           source instructions and dialogue references
  ├─ prepare_campaign.py        source record directory and transitions
  └─ prepare_battles.py         source battle maps and placement facts
          ↓ local-only JSON + PNG
  DataSet                      typed, contained native data
          ↓
  Runtime                      command cursor, actor state, movement batches
  BattleSession                explicitly selected experimental policy
  CampaignSession              research previews, identities and result origin
          ↓
  Renderer                     640×400 source-coordinate canvas
          ↓
  AppKit host                  window, elapsed time and confirmation input
```

파서가 원작 형식을 소유한다. 소비자는 원시 바이트 범위나 표시 식별값을 다시
해석하지 않는다. 액터/인물 ID, 객체 패턴 ID, 객체 인스턴스 ID는 서로 다른 의미를
유지한다. 원작 위치는 커맨드와 런타임 추적으로 변환된 뒤에도 남는다.

런타임 시간은 명시적인 정수 마이크로초다. 확인 입력은 타이틀 또는 대사 경계
하나를 진행시킨다. 이동은 원작 묶음의 모든 구성원이 끝날 때까지 시간을 소유한다.
진단은 결정적 입력으로 같은 런타임과 렌더러를 사용한다. 대화형 사용 중에는
호스트가 실제 경과 시간과 macOS 입력을 공급한다.

알려지지 않은 연산과 잘못된 피연산자는 명시적인 결과다. 미지원 원작 경계에
도달하는 것은 지원되는 장면을 소비하는 것과 다르며, 둘 다 런타임 실패와 다르다.
진단은 커맨드 루프가 멈췄다는 이유만으로 성공을 추정해서는 안 된다.

원작 캠페인 카탈로그와 네이티브 전투 연구 정책은 처음의 제한된 궁전 구현을
확장한다. 완전한 캠페인 디스패치, 원작 전투 규칙/AI, 플레이어가 조작하는 마을
탐색, 원작 글꼴 렌더링, 사운드, 진행 저장은 추가 구현과 원작 런타임 비교가
필요하다. 실험적 전투 메커니즘은 그 공백을 원작 동작으로 메우지 않는다. 다른
게임 엔진의 기존 코드나 세이브를 암묵적으로 사용하지 않는다.
