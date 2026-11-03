# 첫 플레이 가능 연구 범위

이것은 이전 공개 엔진 포크와 분리된 새 구현이다. 그 엔진의 구현이나 생성된
콘텐츠 팩을 복사하거나 개작하지 않는다. 지원하는 동작은 원작 게임 바이트와 원작에
근거한 디스어셈블리/연구 기록으로 구현한다. 재사용한 연구 참고 자료는 모두
기록한다. 이는 법적으로 격리된 클린룸 절차를 수행했다는 주장이 아니다.

## 리소스 내보내기

`tools/prepare_resources.py --game-dir PATH --output PATH [--title-opgrp PATH]`는
호출자가 고른 게임 디렉터리를 바꾸지 않고 읽어, 출력 폴더 아래에 PNG와
`resources.json`을 쓴다. 각 이미지 경로는 출력 폴더 기준 상대 경로이며 그 안에
머물러야 한다.

JSON 형태:

```json
{"format":1,"title":"images/title.png","maps":{"8192":{"image":"images/palace-0.png","width":512,"height":320}},"actors":{"319":{"image":"images/person-319.png","frameWidth":32,"frameHeight":40,"frames":4,"anchorX":0,"anchorY":24}},"portraits":{},"provenance":{}}
```

맵 JSON 키는 10진수 묶음 맵 ID다. 액터 키는 BAKDATA 인물 ID 그대로다. 액터
시트는 원작 프레임 네 개를 가로로 담는다. 원작에 근거한 방향 선택은 액터 레코드의
선택 필드 `directions`로 제공하며, 이는 객체 `{ "frame":0,"flip":false }` 네
개의 배열이다. 원작 마을 좌표는 원작 규칙에 따라 픽셀 좌표로 변환한다. 이 규칙을
문서화하고 장면 메타데이터에 노출한다. 이미지 경로와 선택 필드는 추가 방식으로
확장할 수 있다. 원작 이미지는 로컬 빌드 출력이며 저장소 내용이 되지 않는다.

## 원작 첫 장면 추출

`tools/prepare_scene.py --game-dir PATH --output PATH`는 `scene.json`을 쓴다.

```json
{"format":1,"id":"original-opening-palace","name":"낙양 궁전","width":640,"height":400,"coordinateSystem":"town","commands":[{"op":"map","map":8192,"source":{}},{"op":"place","person":319,"x":26,"y":8,"facing":0,"source":{}},{"op":"move","person":319,"x":26,"y":12,"source":{}},{"op":"say","person":319,"speaker":"동탁","text":"...","source":{}},{"op":"remove","person":319,"source":{}},{"op":"end","reason":"bounded first-scene extraction","source":{}}],"provenance":{}}
```

원작 레코드로 실제 확인된 명령만 구현한다. 연출을 지어내거나 알려지지 않은
바이트코드를 조용히 건너뛰지 않는다. 필요하면 명시적인 미지원 경계로 끝낸다.
지원하는 추가 명령: 초 단위의 `wait`, 초와 `to`(`black` 또는 `visible`)를 받는
`fade`, 원작 x/y 좌표를 받는 `camera`. 연속한 `move` 명령은 동시에 실행하는 한
묶음이며, 런타임은 그 묶음이 끝나기를 기다린다. 모든 명령은 출처 리소스/멤버와
바이트 오프셋을 보존한다.

## 네이티브 런타임

외부 게임 엔진 의존성 없이 Swift/AppKit/CoreGraphics로 만든다. 소스 파일은
`Sources/YeonggeoljeonEngine`에 있다. `resources.json`과 `scene.json`은 명시한
`--data` 디렉터리나 앱의 `Resources/GameData`에서 읽는다. 타이틀 -> 원작 장면,
액터, 이동, 원작 대사. 최근접 이웃 640x400 캔버스. 공개 엔진의 세이브나 앱 파일은
수정하지 않는다.

스크린샷과 JSON 증거를 남기는 범위 한정 결정적 런타임 검증을 위해
`--verify --data PATH --output PATH`를 제공한다. 검증 모드는 반드시 종료해야 하며
사용자 진행을 바꾸지 않아야 한다. 앱 번들/빌드 통합은 루트가 담당한다.
