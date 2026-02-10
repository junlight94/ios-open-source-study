## A) ImageCache 정리

### 1) ImageCache가 하는 일

**ImageCache = 메모리 캐시(MemoryStorage/NSCache 계열) + 디스크 캐시(DiskStorage/파일 I/O)** 를 묶어서 (facade)

“저장(store) / 조회(retrieve) / 삭제(remove) / 정리(clean)”를 **한 인터페이스로 제공**하는 객체.

---

### 2) 구성 요소 (무엇으로 이루어져 있나)

- **memoryStorage: MemoryStorage.Backend**
  - 빠른 조회/저장용 (RAM)
  - 만료(expiration) / cost 기반 eviction
- **diskStorage: DiskStorage.Backend**
  - 파일로 저장 (디스크)
  - 만료/용량 제한 기반 정리, 파일 확장자/경로 규칙
- **ioQueue (serial DispatchQueue)**
  - 디스크 I/O(저장/삭제/정리)를 **직렬화(serialize)** 해서 처리
  - 목적: 경쟁/경합을 줄이는 것뿐 아니라, **파일 쓰기/삭제/정리 순서를 강제하여 일관성·안정성을 높이고** DiskStorage 구현을 단순하게 유지

---

### 3) 키 설계: “원본 key + processor identifier”

- `computedKey = key.computedKey(with: identifier)`
- processor를 적용하면 **같은 URL이어도 결과 이미지가 달라질 수 있음**
  - 예: 리사이즈, 원형 크롭, 블러 등
- 그래서 **캐시 키에 processor의 identifier를 붙여** 결과물을 분리 저장.

---

### 4) 저장 흐름 (store)

#### 4-1. 메모리 저장은 “현재 컨텍스트에서 바로”

- `memoryStorage.storeNoThrow(...)`
- 이유:
  - 디스크처럼 파일 생성/쓰기 같은 I/O가 아니라 **in-memory 구조(NSCache 계열)** 에 넣는 작업
  - 그래서 일반적으로 빠르고, **실패 요인(디렉토리 생성, 파일 쓰기 권한/공간 부족 등)이 거의 없음**
  - (중요) 캐시는 정책적으로 eviction될 수 있지만, 이는 “실패”라기보다 **캐시의 정상 동작(베스트-effort)**

> 즉 “NSCache가 thread-safe라서”는 **동시성 안전성**의 이유이고,  
> “실패 가능성이 낮다”는 건 **I/O가 없고 throw 경로가 거의 없기 때문**에 가깝다.

#### 4-2. 디스크 저장은 ioQueue에서 비동기

- 디스크는 serializer가 `image -> data`로 변환 가능해야 저장 가능
- `ioQueue.async { syncStoreToDisk(...) }`
- 디스크 저장 실패는 `KingfisherError`로 completion에 전달 가능

#### 4-3. completionHandler 큐 제어

- 결과 콜백은 `callbackQueue.execute { ... }`
- 즉 “저장 작업은 내부 큐에서 하되, **콜백은 사용자가 원하는 큐로 돌려준다**”가 기본 설계

---

### 5) 조회 흐름 (retrieveImage)

#### 5-1. 1차: 메모리 캐시 먼저

- 메모리는 가장 빠르니까 먼저 확인
- 있으면 즉시 `.memory(image)`로 반환

#### 5-2. 옵션에 따라 “메모리만 보거나(fromMemoryCacheOrRefresh)” 디스크도 본다

- `fromMemoryCacheOrRefresh == true`면
  - 메모리에 없으면 **디스크 캐시를 건너뛰고** `.none` 반환
  - 즉 “디스크까지 뒤져서 오래된 캐시를 쓰지 않고, refresh/download 쪽으로 가게 하려는” 성격

#### 5-3. 2차: 디스크 조회 후 메모리에 “재적재”

- 디스크에서 데이터를 찾으면:
  - serializer로 `data -> image`
  - 옵션에 따라 `backgroundDecode`로 디코딩까지 수행
- 그리고 디스크에서 찾은 이미지는 **다시 메모리 캐시에 올려서** 다음 접근을 빠르게 함
  - 이 때 `toDisk: false`로 “메모리만” 저장

---

### 6) 삭제 흐름 (removeImage)

- `fromMemory`면 메모리에서 삭제 즉시
- `fromDisk`면 ioQueue에서 파일 삭제 후 completion
- completion은 error 포함 버전 / error 무시 버전 두 가지 제공

---

### 7) 정리(Cleaning)와 라이프사이클 연동

#### 7-1. cleanExpired*

- 메모리: 만료된 엔트리 제거
- 디스크: 만료된 파일 제거 + 용량 초과분 제거

#### 7-2. NotificationCenter로 OS 이벤트에 붙임

생성 시점에 내부에서 구독:

- **메모리 경고** → `clearMemoryCache`
- **앱 종료/백그라운드 진입** → `cleanExpiredDiskCache` / `backgroundCleanExpiredDiskCache`

즉 ImageCache는 “앱이 살면서 겪는 이벤트”에 맞춰 캐시를 자동 관리하려고 함.

> (보강) 등록 로직을 `Task { @MainActor in ... }`로 감싼 건  
> UIKit/AppKit 라이프사이클 이벤트와 연동되는 selector 기반 동작을 **안전하게 main 컨텍스트에서 세팅하려는 관례적 선택**으로 이해하면 좋음.

#### 7-3. 디스크 정리 완료 Notification

- 만료/용량 초과로 실제 파일 삭제가 발생하면
  - `.KingfisherDidCleanDiskCache` 발행
  - userInfo에 삭제된 hash 목록 제공

---

### 8) 캐시 상태/경로 유틸리티

- `imageCachedType` / `isCached`: 메모리/디스크 어디에 있는지 확인
- `hash(forKey:)`: 실제 파일명(해시) 확인
- `cachePath` / `cacheFileURLIfOnDisk`: 로컬 파일 경로 얻기(웹뷰/디버깅 등)

---

## B) 추가로 파고든 내용 (궁금/검증 파트)

### 1) “메모리 한도 = physicalMemory/4” 와 Int.max 비교 (타입/플랫폼/안전성)

```swift
private static func createMemoryStorage() -> MemoryStorage.Backend<KFCrossPlatformImage> {
    let totalMemory = ProcessInfo.processInfo.physicalMemory
    let costLimit = totalMemory / 4
    let memoryStorage = MemoryStorage.Backend<KFCrossPlatformImage>(config:
        .init(totalCostLimit: (costLimit > Int.max) ? Int.max : Int(costLimit)))
    return memoryStorage
}
```

- `physicalMemory: UInt64`
  - “물리 RAM 용량”은 음수가 불가능 → unsigned가 자연스러움
- `totalCostLimit: Int`
  - 여기서 cost는 “정확한 바이트 수”라기보단 **캐시 정책용 weight(가중치)** 성격
  - 또한 Foundation/ObjC 계열 API가 오래 전부터 `NSInteger`(= signed) 기반으로 설계되어 왔고,
  - 내부 연산(증감/차감/비교)과 Swift 호환을 고려하면 `Int`가 자연스러운 선택
- `costLimit > Int.max ? Int.max : Int(costLimit)`
  - `UInt64 -> Int` 변환 overflow 방지용 clamp
  - 32-bit/특수 환경까지 고려한 “방어적 코드”

**“RAM의 1/4” 근거**
- 표준 공식이라기보다 **보수적인 디폴트**에 가까움
- 캐시는 OS 메모리 압박 시 언제든 정리될 수 있고, 앱이 캐시에 RAM을 크게 점유하면 메모리 워닝/종료 위험이 커질 수 있으므로
- “안전한 상한을 디폴트로 잡고(예: 1/4), 앱 성격(이미지-heavy 여부)에 따라 조정하도록” 한 선택으로 이해하는 게 맞음

---

### 2) 디스크 경로 커스터마이징: cacheDirectoryURL / diskCachePathClosure

- `cacheDirectoryURL`
  - 디스크 캐시를 저장할 **기본 디렉토리 위치를 바꾸는 입력값**
  - nil이면 “시스템 기본 캐시 디렉토리(유저 도메인)” 사용
- `DiskCachePathClosure (URL, String) -> URL`
  - (기본 디렉토리 URL, 캐시 이름) → 최종 캐시 URL 생성
  - 목적: 회사/앱 구조에 맞게 **폴더 구조를 완전히 커스터마이즈** 가능

---

### 3) options / KingfisherParsedOptionsInfo / callbackQueue / untouch (큐 정책 한 덩어리)

- `options`는 “캐시/로딩 정책 묶음”
  - processor, serializer, expiration, backgroundDecode, forcedExtension,
  - callbackQueue, loadDiskFileSynchronously 등
- `KingfisherParsedOptionsInfo`
  - 옵션 배열(`KingfisherOptionsInfo`)을 받아 **정규화(parse/normalize)한 구조체**
  - 매번 배열을 순회/매칭하지 않고, 필요한 값을 **속성으로 O(1) 접근**할 수 있게 만든 컨테이너
  - “하드코딩”이 아니라, **사용자가 전달한 옵션을 정리해 둔 결과물**에 가깝다
- `callbackQueue`
  - completion을 어느 큐에서 호출할지 결정
- `untouch`
  - “큐를 건드리지 않는다”: **추가 dispatch 없이 현재 실행 컨텍스트에서 그대로 실행**
  - 따라서 `.untouch`는 “다른 큐로 지정된다”가 아니라, **큐 전환을 하지 않는다**는 의미
  - (보강) 그래서 호출자가 어디에서 부르느냐에 따라 completion 실행 위치가 달라질 수 있어, 라이브러리가 callbackQueue 옵션을 제공함

**왜 큐 스위칭을 하나?**
- UI 업데이트는 메인에서 해야 안전 → 결과를 `.main`으로 보내려는 필요
- 반대로, 이미 적절한 큐에서 실행 중이면 **불필요한 dispatch는 비용/지연**
  - 그래서 디스크에서 이미지를 찾고 → 메모리에 올릴 때 같은 내부 흐름에서  
    `cacheOptions.callbackQueue = .untouch`로 바꿔 **중복 디스패치/불필요한 큐잉을 제거**하는 최적화가 들어감

---

### 4) 디스크 로딩 큐 선택: loadDiskFileSynchronously

```swift
let loadingQueue: CallbackQueue =
    options.loadDiskFileSynchronously ? .untouch : .dispatch(ioQueue)
loadingQueue.execute { ... }
```

- 옵션이 “동기로 읽겠다”면: 지금 컨텍스트에서 바로 실행(untouch)
- 아니면: ioQueue로 보내서 디스크 I/O를 직렬화하고, 호출자 스레드(UI 등)를 막지 않게 함

---

### 5) backgroundCleanExpiredDiskCache 내부 (왜 actor/UIApplication.shared가 필요?)

- 백그라운드 진입 시, 디스크 정리를 하려면 시간이 필요할 수 있음
- iOS는 백그라운드에서 오래 실행 못 하게 하므로:
  - `beginBackgroundTask`로 “조금 더 실행할 시간”을 OS에 요청
  - 만료되면 expirationHandler에서 종료 처리
- `BackgroundTaskState actor`
  - backgroundTaskIdentifier를 안전하게 저장/무효화 (동시 접근 안전성)
- 정리 끝나면 `endBackgroundTask`로 마무리

---

### 6) App Extension 대응: UIApplication.shared를 “있을 때만” 가져오기

```swift
extension KingfisherWrapper where Base: UIApplication {
  public static var shared: UIApplication? {
    let selector = NSSelectorFromString("sharedApplication")
    guard Base.responds(to: selector) else { return nil }
    guard let unmanaged = Base.perform(selector) else { return nil }
    return unmanaged.takeUnretainedValue() as? UIApplication
  }
}
```

- **앱 익스텐션(위젯, 공유 확장 등)** 에서는 `UIApplication.shared` 사용이 제한/불가한 경우가 있음
- 그래서 런타임에 selector 존재 여부를 보고
  - 가능하면 sharedApplication을 얻고
  - 불가능하면 nil 처리해서 크래시/거부를 피함

---

### 7) CallbackQueue와 MainActor: DispatchQueue.main vs MainActor (개념 정리)

- `DispatchQueue.main`:
  - GCD의 “메인 큐(주로 메인 스레드에서 실행되는 작업 큐)”
- `MainActor`:
  - Swift Concurrency의 “메인에서 직렬 실행되어야 하는 코드/상태”를 나타내는 **격리 모델(논리적 실행 컨텍스트)**

보통 MainActor는 메인 실행기(main executor)에 매핑되어 **결과적으로 메인 스레드에서 직렬 실행**됩니다.

차이를 요약하면:

- GCD는 “큐에 작업을 넣는다(스케줄링 도구)”
- Actor는 “데이터 격리/경쟁 방지 규칙 + 실행 컨텍스트”를 제공하고,
  실제 실행은 런타임이 해당 actor의 executor(대개 main)에 **스케줄**함

`Thread.isMainThread` 체크는:

- 이미 메인 스레드면 굳이 `DispatchQueue.main.async`로 보내지 않고 **즉시 실행**해서
  - 불필요한 지연/큐잉을 줄이려는 최적화

```swift
enum CallbackQueueMain {
    static func currentOrAsync(_ block: @MainActor @Sendable @escaping () -> Void) {
        if Thread.isMainThread {
            MainActor.runUnsafely { block() }
        } else {
            DispatchQueue.main.async { block() }
        }
    }

    static func async(_ block: @MainActor @Sendable @escaping () -> Void) {
        DispatchQueue.main.async { block() }
    }
}
```
