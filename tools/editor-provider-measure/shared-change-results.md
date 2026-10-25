# 공유 변경 범위 재사용 실측

기준은 main `04c78fa1d802e7e1255b049efcf5ae584a8d3b6e`와 같은 main 위의 구현 사본이다.
같은 고정 입력과 계측기를 사용한다. 아래 시간은 계측된 제품 함수 경과시간이며 실제 HID·화면 표시 지연이나 RSS가 아니다.
`flat-50000.zig`는 50,000개 함수·200,000개 LF이며 50,000줄 파일을 뜻하지 않는다.

## 전체 편집 경로

파일 5종·작업 8종·전후 3회씩 총 240개 프로세스/3,090편집에서 매 편집 전체 접힘 결과가 일치했다.
첫 입력을 제거하지 않았다. 입력 종류마다 표본 수가 다르며 붙여넣기는 각 프로세스에서 1회다.
큰 Zig 공유 입력은 중앙값 52.534→43.909ms였다. 단일 뷰 구조 편집은 39.132→42.849ms로 느린 표본이 있어 별도 반복 확인했다.
같은 바이너리·입력으로 순서를 교대해 추가 20개 프로세스/200편집을 대조한 중앙값은
36.700→36.539ms, C 파싱은 17.236→17.138ms였다. 최초의 9.5% 차이는 이 반복에서는
재현되지 않았다. 원인을 확정하지 않았으며 최초 느린 표본도 아래 표에 그대로 남긴다.
전체 입력의 일률적 개선이나 모든 언어의 성능을 보장하지 않는다.

| 파일 | 작업 | 전 p50/p95 ms | 후 p50/p95 ms | p50 변화 |
| --- | --- | ---: | ---: | ---: |
| flat-15000.zig | typing | 9.910/11.627 | 9.831/11.727 | -0.8% |
| flat-15000.zig | slow | 10.097/13.130 | 9.891/11.282 | -2.0% |
| flat-15000.zig | structure | 10.368/14.111 | 10.002/13.554 | -3.5% |
| flat-15000.zig | paste | 19.719/20.189 | 19.002/19.008 | -3.6% |
| flat-15000.zig | undo | 9.561/11.695 | 9.614/13.533 | +0.6% |
| flat-15000.zig | shared | 13.335/15.669 | 11.878/15.152 | -10.9% |
| flat-15000.zig | folded | 9.826/11.259 | 9.543/11.269 | -2.9% |
| flat-15000.zig | command | 12.077/14.044 | 12.002/13.996 | -0.6% |
| flat-3000.zig | typing | 2.399/2.828 | 2.423/2.707 | +1.0% |
| flat-3000.zig | slow | 2.564/5.251 | 2.451/2.826 | -4.4% |
| flat-3000.zig | structure | 2.629/3.037 | 2.570/3.049 | -2.3% |
| flat-3000.zig | paste | 7.871/7.898 | 7.596/7.647 | -3.5% |
| flat-3000.zig | undo | 2.375/2.792 | 2.480/2.817 | +4.4% |
| flat-3000.zig | shared | 3.090/3.550 | 2.752/3.194 | -10.9% |
| flat-3000.zig | folded | 2.486/4.646 | 2.449/2.765 | -1.5% |
| flat-3000.zig | command | 4.731/5.592 | 4.733/5.830 | +0.0% |
| flat-50000.zig | typing | 35.753/42.595 | 36.206/44.638 | +1.3% |
| flat-50000.zig | slow | 38.034/65.292 | 34.778/48.316 | -8.6% |
| flat-50000.zig | structure | 39.132/50.528 | 42.849/61.292 | +9.5% |
| flat-50000.zig | paste | 59.166/60.553 | 54.649/57.770 | -7.6% |
| flat-50000.zig | undo | 38.965/81.839 | 37.959/47.266 | -2.6% |
| flat-50000.zig | shared | 52.534/71.876 | 43.909/53.278 | -16.4% |
| flat-50000.zig | folded | 36.531/43.783 | 35.964/43.217 | -1.6% |
| flat-50000.zig | command | 36.708/47.038 | 37.532/45.332 | +2.2% |
| real-build.zig | typing | 7.292/7.710 | 7.379/7.640 | +1.2% |
| real-build.zig | slow | 7.415/8.456 | 7.388/7.726 | -0.4% |
| real-build.zig | structure | 7.364/7.895 | 7.396/7.963 | +0.4% |
| real-build.zig | paste | 12.518/12.621 | 12.436/12.537 | -0.7% |
| real-build.zig | undo | 7.216/7.849 | 7.441/14.443 | +3.1% |
| real-build.zig | shared | 8.773/11.573 | 8.527/9.915 | -2.8% |
| real-build.zig | folded | 7.723/8.828 | 7.588/9.661 | -1.7% |
| real-build.zig | command | 87.759/105.709 | 87.624/98.947 | -0.2% |
| real-host.swift | typing | 7.880/9.084 | 7.854/11.026 | -0.3% |
| real-host.swift | slow | 7.894/12.784 | 7.890/10.300 | -0.0% |
| real-host.swift | structure | 9.414/10.529 | 8.559/11.083 | -9.1% |
| real-host.swift | paste | 19.993/20.932 | 19.674/20.059 | -1.6% |
| real-host.swift | undo | 7.700/9.759 | 7.367/12.736 | -4.3% |
| real-host.swift | shared | 11.140/11.982 | 10.896/11.824 | -2.2% |
| real-host.swift | folded | 5.920/6.546 | 5.878/6.762 | -0.7% |
| real-host.swift | command | 43.616/50.851 | 43.450/45.707 | -0.4% |

## 구문 내부 경로

별도 성능 표본 60개 프로세스/1,200편집과 정확성 표본 20개/400편집을 분리했다.
성능 집계는 각 조건·사본당 3회/60편집이다. 구간은 중첩되므로 표의 중앙값을 더하지 않는다.
정확성 표본의 C 범위 계산은 전 300회, 후 205회였고 후 재사용은 95회였다. 각 공유 입력의 첫 편집은 재사용 0회이며 표본에 포함했다.
원시 기록의 실제 호출 수·부모/자식 시간·소스/바이너리/입력 해시를 집계기가 다시 검증했다.

| 파일/작업 | 전 전체 p50 ms | 후 전체 p50 ms | 전 C 파싱 p50 ms | 후 C 파싱 p50 ms | 전 C 범위 p50 ms | 후 C 범위 p50 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| flat-15000.zig/shared | 13.381 | 11.383 | 3.745 | 3.620 | 3.794 | 1.890 |
| flat-15000.zig/typing | 9.336 | 9.162 | 3.483 | 3.580 | 1.839 | 1.881 |
| flat-3000.zig/shared | 3.020 | 2.687 | 0.549 | 0.550 | 0.620 | 0.309 |
| flat-3000.zig/typing | 2.356 | 2.389 | 0.555 | 0.549 | 0.308 | 0.312 |
| flat-50000.zig/shared | 51.513 | 42.429 | 18.374 | 17.883 | 15.748 | 7.670 |
| flat-50000.zig/typing | 37.481 | 35.839 | 19.801 | 16.839 | 7.726 | 7.681 |
| real-build.zig/shared | 8.759 | 8.149 | 2.611 | 2.519 | 0.841 | 0.422 |
| real-build.zig/typing | 7.431 | 7.397 | 2.582 | 2.519 | 0.435 | 0.426 |
| real-host.swift/shared | 11.128 | 10.830 | 0.811 | 0.794 | 0.694 | 0.351 |
| real-host.swift/typing | 7.797 | 7.804 | 0.786 | 0.791 | 0.353 | 0.354 |

## 구조 크기

aarch64 macOS에서 측정한 `TermRuntime`은 18,432→18,512바이트, registry `Document`는 480→496바이트다.
각 파싱 뷰의 지연 할당 payload는 368바이트다. 중첩 구조를 다시 더하지 않았으며 allocator 관리 정보와 RSS는 제외한다.

## 원시 자료

저장소 밖 `/Users/yoonhb/.cache/maru-agent-artifacts/`에 아래 자료를 보존한다. 로컬 경로는 GitHub 공개 artifact가 아니다.

| 자료 | SHA-256 |
| --- | --- |
| `shared-change-origin-paired-1/paired-order.json` | `05da3c0a1957fe778e8dfc26c26529c2122f1e723cf500f1840c4fd69f4a3310` |
| `shared-change-origin-paired-1/paired-summary.json` | `cae5a652f50b92e2a3265cb68c768fe086a77b630fa3a9ebb92cca5c3acc3bfd` |
| `shared-change-origin-paired-1/post-run.json` | `37169f6d40662f5c6820573a03b1431ca734a18c0ba20ecf86bd682c1a57efa2` |
| `shared-change-origin-scoped-order.json` | `7800cc6185f79cafe00000d7d673a6c8d2a1a524524b3886f00d44623c29befe` |
| `shared-change-origin-provider-baseline-1/provider-summary.json` | `f0512f7a09c14c8a4377636c25b372fdc96d552ce92c54fca8b7510206bee050` |
| `shared-change-origin-provider-setup-1/provider-summary.json` | `8a5f8cc5d2116f18c2eb8aea0e8ce53219297ab5e3b32109057264d0bdd3a136` |
| `shared-change-origin-accuracy-integrity.json` | `b6dadf9aeed1c47ff3d72e27fe2b39fa9202fe5e851a45e36fe156252a918f6c` |
| `shared-change-origin-memory-3/summary.json` | `17b0dab4a46cdc70972cbbc84138b83a356776c112c834ab0b7918446506d82e` |
| `shared-change-origin-final-attacks-2/receipt.json` | `bc3e0139f40cca89273c91c91acdcb88229aaa9b6e77e815bd57c2139543bf6c` |
| `shared-change-origin-structure-followup-1/order.json` | `2ceb32bed757010b2807687abf224918a01c9c85826bd987036c56acb55e96e5` |
| `shared-change-origin-structure-followup-1/summary.json` | `f21bc008314d9aec19f35634b800bf156d1d5675c0ac3eaf8825f409683a5713` |
