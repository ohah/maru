# Third-party 라이선스와 Attribution

Maru 자체는 MIT 라이선스다([LICENSE](../LICENSE)). 이 문서는 Maru가 **번들·재배포하는 제3자 자산**과 그 라이선스, 그리고 우리가 지켜야 하는 의무를 단일 출처로 정리한다. 새 제3자 자산(폰트·아이콘·코드 등)을 동봉하면 반드시 이 문서를 갱신한다.

> 빌드/실행에만 쓰고 산출물에 **포함하지 않는** dev/test 의존성(libvterm·libghostty-vt 등)은 여기 대상이 아니다 — [project-rules.md](project-rules.md) §의존성, [references.md](references.md) 참고. 이 문서는 **배포물(`.app`/`.dmg`)에 실제로 들어가는** 자산만 다룬다.

## 번들 폰트

`assets/fonts/<Family>/`의 폰트를 `build.zig`가 `Maru.app/Contents/Resources/Fonts/`로 복사하고, `MaruAppHost-Info.plist`의 `ATSApplicationFontsPath`가 실행 시 등록한다(메커니즘 단일 출처: [font-strategy.md](font-strategy.md) §번들 폰트). 동봉 폰트는 모두 **원본 무수정**으로 재배포한다.

| 패밀리 | 버전 | 라이선스 | 저작권 | 출처 |
| --- | --- | --- | --- | --- |
| JetBrains Mono | 2.304 | OFL 1.1 | Copyright 2020 The JetBrains Mono Project Authors | <https://github.com/JetBrains/JetBrainsMono> |
| Fira Code | 6.2 | OFL 1.1 | Copyright 2014–2021 The Fira Code Project Authors | <https://github.com/tonsky/FiraCode> |
| Cascadia Code | v2407.24 | OFL 1.1 (RFN "Cascadia Code") | © 2021 Microsoft Corporation | <https://github.com/microsoft/cascadia-code> |
| Hack | v3.003 | MIT + Bitstream Vera | © 2018 Source Foundry Authors / © 2003 Bitstream, Inc. | <https://github.com/source-foundry/Hack> |

각 라이선스 전문은 폰트 옆(`assets/fonts/<Family>/OFL.txt` 또는 `LICENSE.md`)에 두고, 번들에도 패밀리명 프리픽스로 함께 들어간다(`Resources/Fonts/<Family>-OFL.txt` 등).

## 라이선스별 의무와 충족 방법

### SIL Open Font License 1.1 (OFL) — JetBrains Mono · Fira Code · Cascadia Code

OFL은 폰트 전용 자유 라이선스로, **앱에 임베드·번들·재배포(무료/상용 무관)가 명시적으로 허용된 사용 방식**이다. 로열티·사용료 없음. 의무는 셋:

1. **라이선스·저작권 고지 동봉** — 폰트 사본마다 OFL 전문과 copyright를 함께 배포한다.
   - 충족: `assets/fonts/<Family>/OFL.txt`를 두고 빌드가 번들 `Resources/Fonts/`에 복사한다.
2. **폰트 단독 판매 금지** — 폰트는 더 큰 소프트웨어 패키지의 일부로만 배포·판매할 수 있다(폰트 파일만 따로 팔 수 없다).
   - 충족: Maru 앱 번들의 일부로만 배포한다.
3. **Reserved Font Name(RFN)** — RFN이 지정된 폰트는 **수정본**에 그 이름을 쓸 수 없다(수정본은 다른 이름으로, 역시 OFL로 배포).
   - 충족: RFN이 걸린 건 Cascadia Code("Cascadia Code")뿐이고, 우리는 **무수정 원본**을 재배포하므로 이름을 그대로 쓴다. 향후 서브셋·패치 등 **수정**을 하려면 반드시 RFN과 다른 패밀리명으로 바꾸고 OFL로 배포한다.

### MIT + Bitstream Vera — Hack

OFL보다 느슨하다. Hack 본체는 MIT(Source Foundry), DejaVu에서 온 부분은 Bitstream Vera 라이선스다. 의무는 **저작권·라이선스 고지 유지**뿐. 단독 판매·이름·임베드 제약 없음.
- 충족: `assets/fonts/Hack/LICENSE.md`(MIT+Bitstream Vera 전문)를 두고 번들에 동봉한다.

## About 화면 attribution(권장)

법적 최소 의무는 번들 내 라이선스 파일로 충족되지만, 관례상 앱 About/정보 화면이나 배포 페이지에 동봉 폰트의 라이선스 고지를 노출하는 것을 권장한다. 노출 시 위 표(패밀리·버전·라이선스·저작권)를 그대로 쓴다. (미구현 — 후속.)

## 동봉 자산 추가 규칙

새 폰트(또는 그 밖의 제3자 자산)를 번들에 추가할 때:

1. **라이선스 호환 확인** — 재배포·임베드 허용 라이선스인지 본다(OFL·MIT·Apache-2.0 등). 불확실하면 사용자와 논의한다([project-rules.md](project-rules.md) §의존성).
2. **원본 무수정 원칙** — 가능하면 원본을 그대로 넣는다. 수정(서브셋·패치)이 필요하면 RFN·상표·라이선스 표기 의무를 먼저 확인한다.
3. **라이선스 파일 동봉** — `assets/fonts/<Family>/`에 폰트와 함께 라이선스 전문(`OFL.txt`/`LICENSE.md`/`LICENSE.txt`)을 둔다. `build.zig` 번들 단계가 이 파일명을 패밀리명 프리픽스로 자동 복사한다.
4. **이 문서 + [font-strategy.md](font-strategy.md) 표 갱신** — 패밀리·버전·라이선스·저작권·출처를 기록한다.
