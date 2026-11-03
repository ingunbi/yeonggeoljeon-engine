# 호출자가 고른 네이티브 입력 재생

`OriginalPlayVerification.swift`는 로컬 JSON 입력 파일을 읽고, 탐색과 캠페인
입력이 쓰는 것과 같은 네이티브 호스트 API를 호출한다. 공개 소스 코드에는 원작
경로, 인물 선택, 캠페인 입력 순서가 없다. 실제 원작 게임 스크립트, 내보낸 파일,
입력 재생 파일, 보고서는 모두 로컬에 둔다.

입력 객체는 형식 1, `inputs` 배열, 그리고 선택적인 명시 RNG 시드, 고정
마이크로초 스텝, 입력별 작업 상한을 쓴다. 지원하는 동작은
`talk`, `choice`, `save-skip`, `save-native`, `battle-retreat`, `battle-quit`, `field-quit`, `world-city`, `town-marker`, `town-cell`, `party-toggle`,
`party-confirm`, `expect-battle`, `battle-move`, `battle-attack`,
`battle-strategy`, `battle-item`, `battle-wait`, `battle-end-turn`, `retry-choice`,
`city-entry`, `shop-answer`, `field-exchange`이다. `city-entry`는 도착 질문에
인덱스 1 또는 0으로 답한다. `shop-answer`는 도구상의 현재 블로킹 호출에 답한다.
목록에서는 행 하나 또는 취소를 뜻하는 빈 값, 질문에서는 1 또는 0, 시간 제한
줄에서는 아무 값이다. [original-shop.md](original-shop.md)를 참고한다.
`field-exchange`는 필드 도구 교환처럼 `item`을 `person`에게서 `index`의
인물에게 옮긴다.
`battle-retreat`와 `battle-quit`은 전투 시스템 메뉴 항목을 쓰고,
`field-quit`은 필드 메뉴의 종료를 쓴다. `save-native`는 필드 메뉴의 저장처럼
대기 중인 필드에서도 동작한다.
`town-cell`은 명시한 거점 칸으로 걸어가며, 이는 여러 칸을 차지하는 표지의 한
칸을 고른다. `save-native`는 대기 중인 원작 저장 프롬프트에서 네이티브 재개
파일을 출력 폴더에 쓰고 계속 진행한다. `--resume FILE`로 따로 실행하면 입력
시드 없이 그 파일에서 시작한다. 알 수 없는 동작과 입력 필드, 명시적 null
피연산자, 잘못된 피연산자 조합은 거부한다. 원작 지도에서 모호한 마을 표지는
호스트가 거부하며, 드라이버는 일치하는 칸 가운데 임의의 칸을 고르지 않는다.

드라이버는 대화와 퇴장 팝업을 확인 처리하고, 고른 고정 스텝으로 이동을
진행한다. 분기 선택, 저장 프롬프트, 출전 선택에는 해당 입력 항목이 있어야 한다.
드라이버는 원작 전투 페이즈/퇴장 콜백을 연결하고 도달한 전투를 기록한다. 수동
전투 입력은 현재 호스트와 원작 흐름이 입력을 받아들여야 하며, 이동은 원작의
수동 부대 관문도 통과해야 한다. 공격, 책략, 대기, 턴 종료는 재개 가능한 퇴장
훅을 포함해 네이티브 뷰와 같은 페이즈 소유자를 쓴다. 드라이버는 어떤 행동도
스스로 고르지 않으며, 승리, 상태 편집, 순간 이동 동작을 제공하지 않는다. 시드는
명시적 테스트 입력이며 원작의 실제 시각 기반 RNG 타임라인을 확립하지 않는다.

보고서는 입력 경로/다이제스트, 순서가 있는 관찰, 프레임, 마지막 네이티브
체크포인트, 원작 쪽 실패, 추적을 보관한다. 입력이 거부되거나 복원하지 않은 원작
동작을 만나면 입력 재생을 멈추고, 있는 증거를 쓰고, 실패를 반환한다. 입력
목록이 끝났다는 것은 고른 동작들을 처리했다는 뜻일 뿐이며, 결코 캠페인 완주나
원작 런타임과의 일치를 주장하지 않는다. AppKit 프레임은 화면 밖 캡처이지
macOS 키보드/마우스 전달 검증이 아니다. 로컬 스토리 데이터에 MAIN의 화면 틀이
있으면 필드와 전투 프레임에 이를 포함한다([화면](original-screen.md)). 입력
파일이 슬롯으로 부대를 가리키므로 전투 캡처에는 부대 슬롯 표시도 붙는다.

전투 입력 형태는 `{kind:"battle-move",slot,x,y}`,
`{kind:"battle-attack",slot,target}`, 선택적 `target`이 있는
`{kind:"battle-strategy",slot,ability}`, 선택적 `target`이 있는
`{kind:"battle-item",slot,item}`, `{kind:"battle-wait",slot}`,
`{kind:"battle-end-turn"}`이다. 슬롯 식별과 좌표는 호출자 입력으로 남는다. 각
동작이 적법한지는 런타임 기하, 범위, 쓸 수 있는 능력, 비용, 원작 페이즈 상태가
정한다.
