## 1. 캐시 아키텍처 (2-Tier Cache)

메모리 저장소와 디스크 저장소를 통합해서 관리하는 하이브리드 구조.

| 저장소 | 특성 |
| --- | --- |
| `MemoryStorage` | 빠름, 휘발성 |
| `DiskStorage` | 느림, 영속성 |

```swift
memoryStorage: MemoryStorage.Backend<KFCrossPlatformImage>  // UIImage의 TypeAlias
diskStorage: DiskStorage.Backend<Data>                       // 이미지를 Data 형태로 저장
```

### 캐시 조회 흐름 (Cache Promotion 포함)

```
요청 1: Memory Miss → Disk Hit → 메모리 승격(promote) 후 반환   → ~10ms
요청 2: Memory Hit (승격된 캐시)                                → ~0.001ms
요청 3: Memory Miss, Disk Miss → 네트워크 → Disk + Memory 저장
```

> **2-Tier 구조 + Cache Promotion 패턴**
저장소는 2개(메모리/디스크)이지만, 디스크에서 찾은 이미지는 자동으로 메모리에 승격되어
이후 요청은 메모리에서 즉시 반환된다.
> 

### retrieveImage — 계층적 검색 + 프로모션

```swift
open func retrieveImage(forKey key: String, options: KingfisherParsedOptionsInfo, ...) {
    guard let completionHandler = completionHandler else { return }

    // 1단계: 메모리 체크
    if let image = retrieveImageInMemoryCache(forKey: key, options: options) {
        callbackQueue.execute { completionHandler(.success(.memory(image))) }

    // 2단계: fromMemoryCacheOrRefresh 옵션
    } else if options.fromMemoryCacheOrRefresh {
        callbackQueue.execute { completionHandler(.success(.none)) }

    // 3단계: 디스크 체크
    } else {
        self.retrieveImageInDiskCache(...) { result in
            switch result {
            case .success(let image):
                guard let image = image else { ... return }

                // 4단계: 캐시 프로모션 (디스크 → 메모리)
                var cacheOptions = options
                cacheOptions.callbackQueue = .untouch  // 불필요한 dispatch 방지
                self.store(image, forKey: key, options: cacheOptions, toDisk: false) { _ in
                    // store() 완료 후 호출 → 메모리 승격 완전히 끝남을 보장
                    callbackQueue.execute { completionHandler(.success(.disk(image))) }
                }
            }
        }
    }
}
```

**`completionHandler`를 `store()` 완료 후 호출하는 이유:**
완료 전 호출 시 호출부가 바로 다시 조회하면 메모리 Miss가 발생할 수 있기 때문.
"이미지를 찾았다"가 아니라 "메모리 승격까지 완전히 끝났다"를 보장한 뒤 호출.

### `fromMemoryCacheOrRefresh` 옵션

디스크 캐시를 의도적으로 건너뛰는 옵션.

```
메모리 Hit  → 메모리 이미지 반환
메모리 Miss → 디스크 무시 → .none 반환 → 네트워크에서 새로 받아옴
```

**사용 시나리오:** 프로필 사진처럼 서버 이미지가 바뀌었을 때 구버전 디스크 캐시를 무시하고 최신 이미지를 강제로 받아와야 하는 경우.

```swift
// 디스크 캐시 무시, 메모리에 없으면 즉시 다운로드
cache.retrieveImage(forKey: user.id, options: [.fromMemoryCacheOrRefresh]) { result in
    if let image = result.image {
        profileImageView.image = image  // 메모리 캐시 사용
    } else {
        downloadNewImage()              // 디스크 건너뛰고 네트워크 요청
    }
}
```

---

## 2. 스레드 안전성 설계

`ImageCache`는 `@unchecked Sendable`로 선언되어 Swift 컴파일러의 안전성 검증을 끄고, 내부적으로 직접 스레드 안전성을 관리한다.

### 메모리 캐시 — `MemoryStorage` 내부에서 처리

`NSCache`를 사용하며, `NSCache`는 Apple이 멀티스레드 환경을 위해 설계한 클래스로 자체 락(lock)이 내장되어 있다.

```
Thread A: store()  ─┐
Thread B: value()  ─┤─→ NSCache 내부 락 → 순차 처리
Thread C: remove() ─┘
```

`ImageCache` 레벨에서 별도 큐가 필요 없고 `MemoryStorage`에 그냥 호출하면 자동으로 안전하다.

### 디스크 캐시 — `ioQueue` (전용 직렬 큐)

디스크는 `NSCache` 같은 편리한 도구가 없어 파일 시스템을 직접 다루므로, 직렬 큐로 보호한다.

```swift
private let ioQueue: DispatchQueue
// 이름에 UUID 포함 → 여러 ImageCache 인스턴스가 있어도 각자의 큐 사용, 디버깅 시 구분 가능
let ioQueueName = "com.onevcat.Kingfisher.ImageCache.ioQueue.\(UUID().uuidString)"
```

```
Thread A: 파일 쓰기  ─┐
Thread B: 파일 읽기  ─┤─→ ioQueue(직렬) → 한 번에 하나씩만 실행
Thread C: 파일 삭제  ─┘
```

직렬 큐 없이 동시 접근하면:

- 쓰기 + 읽기 동시 → 부분적으로 쓰여진 데이터 읽기
- 쓰기 + 삭제 동시 → 크래시 가능

### 왜 디스크를 `ImageCache`에서 직접 관리하나?

```
메모리 저장 → 완료 (동기, 즉시)
디스크 저장 → ioQueue 예약 → 비동기 완료 → 콜백 필요
```

`DiskStorage` 내부에 큐를 넣으면 `completionHandler` 체이닝과 콜백 큐 제어가 복잡해지므로, `ImageCache`가 `ioQueue`를 직접 들고 비동기 흐름을 조율한다.

### `@unchecked Sendable` — 컴파일러와의 타협

`NSCache`가 `Sendable`이 아니어서 `MemoryStorage` → `ImageCache` 전체가 `Sendable` 불가. 그래서 `@unchecked`를 선언하고 수동으로 안전성을 보장한다.

- Swift의 Sendable : Swift 5.5부터 도입된 프로토콜로, **"이 타입은 여러 스레드/Task에서 동시에 안전하게 사용할 수 있다"** 는 컴파일 타임 보장
- Sendable를 쓰지 못한 이유
    - `ImageCache`가 `Sendable`을 만족하려면 모든 저장 프로퍼티가 `Sendable`이어야 함
    - `NSCache`가 `Sendable`이 아니기 때문에 **연쇄적으로** `MemoryStorage` → `ImageCache` 전체가 `Sendable` 불가 상태
    
    ```swift
    // 문제가 되는 프로퍼티들
    public let memoryStorage: MemoryStorage.Backend<KFCrossPlatformImage>
    // MemoryStorage.Backend는 내부적으로 NSCache 사용
    // NSCache는 Objective-C 클래스 → Sendable 보장 없음 ❌
    
    public let diskStorage: DiskStorage.Backend<Data>
    // 파일시스템 접근 → 내부 상태 변경 ❌
    ```
    
- Kingfisher는 unchecked로 선언했으므로 수동으로 안전성 보장해야 함
    - 컴파일러 대신 NSCache의 내부 락과 ioQueue 직렬화 두가지 매켜니즘으로 안전성 수동 보장
    
    ```swift
    // 1. 메모리: NSCache 자체 락에 위임
    memoryStorage.storeNoThrow(...)  // NSCache 내부가 thread-safe 처리
    
    // 2. 디스크: ioQueue 직렬 큐로 보호
    ioQueue.async {
        self.diskStorage.store(...)  // 항상 ioQueue를 통해서만 접근
    }
    ```
    
- Actor를 사용하지 않은 이유
1. open class → 상속 필요 → actor는 상속 불가 
2. 하위 호환성 → iOS 13 이하 지원 필요 → actor는 iOS 15+ 
3. @objc 메서드 필요 → actor와 비호환 
    
    ex) `@objc func clearMemoryCache()`,`@objc func cleanExpiredDiskCache()`
    

### 핵심 트레이드오프

```
Sendable (자동 검증)
  장점: 컴파일 타임 안전 보장
  단점: NSCache 등 ObjC 타입과 호환 불가

@unchecked Sendable (수동 보장)
  장점: 기존 ObjC 생태계 활용 가능, open class 유지
  단점: 개발자가 모든 안전성 책임

actor (가장 이상적)
  장점: 컴파일 타임 보장 + 자동 직렬화
  단점: 상속 불가, iOS 15+, @objc 불가
```

### 복잡한 큐 전략 — `loadDiskFileSynchronously`

```swift
let loadingQueue: CallbackQueue = options.loadDiskFileSynchronously ? .untouch : .dispatch(ioQueue)
```

| 상황 | 전략 |
| --- | --- |
| 빠른 SSD + 작은 이미지(썸네일) | `.untouch` — 스레드 디스패치 오버헤드 없이 즉시 실행 |
| 큰 이미지(원본) | `.dispatch(ioQueue)` — UI 블로킹 방지 |

---

## 3. 캐시 키 전략 — `computedKey`

```swift
extension String {
    func computedKey(with identifier: String) -> String {
        if identifier.isEmpty { return self }
        else { return appending("@\(identifier)") }
    }
}

// 결과 예시
"https://example.com/profile.jpg"
"https://example.com/profile.jpg@com.kingfisher.processor.resize.100x100"
```

같은 원본 이미지라도 블러 처리, 리사이즈 등 다른 처리를 거친 이미지는 별도 캐시로 저장된다.

### 디스크 파일명 해싱

```swift
let fileName = config.usesHashedFileName
    ? memoryKey.kf.sha256  // SHA256 해싱
    : memoryKey            // 그대로 사용
```

해싱을 사용하는 이유:

- **개인 정보 보호**: URL 역추적 불가
- **일관된 길이**: 파일명 길이 제한 문제 방지
- **특수문자/공백 처리**: 파일명 관련 오류 방지

`autoExtAfterHashedFileName`: 확장자는 노출되어도 큰 문제 없어 `UIImage` 타입 추론과 렌더링에 활용하기 위해 확장자를 표시한다.

---

## 4. 저장 흐름 및 직렬화

### `store()` 처리 순서

1. **메모리에 즉시 저장** (`storeNoThrow`) — 동기적, 실패하지 않음
2. `toDisk: false`면 바로 완료
3. `toDisk: true`면 `ioQueue`로 비동기 전환
4. `CacheSerializer`로 이미지를 `Data`로 변환
5. 디스크에 저장

### 설계 철학 — 메모리는 절대 실패하지 않는다

```swift
public let memoryCacheResult: Result<(), Never>        // Never = 에러 없음
public let diskCacheResult: Result<(), KingfisherError> // 디스크만 실패 가능
```

### `store()` 오버로딩 전략

```swift
// API 1: 내부용 — 이미 파싱된 옵션 사용
open func store(_ image: KFCrossPlatformImage, forKey key: String,
                options: KingfisherParsedOptionsInfo, toDisk: Bool = true, ...)

// API 2: 공개용 — 개별 파라미터 전달
open func store(_ image: KFCrossPlatformImage, forKey key: String,
                processorIdentifier identifier: String = "",
                cacheSerializer serializer: any CacheSerializer = DefaultCacheSerializer.default,
                toDisk: Bool = true, ...)
```

공개용 API는 내부에서 `TempProcessor`를 만들어 `KingfisherParsedOptionsInfo`로 변환 후 내부 API를 호출한다. 사용자가 복잡한 옵션 구조를 몰라도 되도록 하기 위한 설계.

---

## 5. Throw vs NoThrow 분리

```swift
// Throwing 버전 — 사용자 지정 경로 사용 시
public convenience init(name: String, cacheDirectoryURL: URL?, ...) throws

// NoThrow 버전 — 내부/싱글톤용
convenience init(noThrowName name: String, ...)
```

**분리한 핵심 이유: `static let`은 `throws` 불가**

```swift
// 불가
public static let `default` = try ImageCache(name: "default")

// NoThrow 버전 사용
public static let `default` = ImageCache(name: "default")
```

| 상황 | 적합한 처리 |
| --- | --- |
| 기본 싱글톤 / 일반 `init(name:)` | 실패해도 진행 → **NoThrow** |
| 사용자 지정 경로 사용 | 디렉토리 생성 실패 가능 → **Throw** |

---

## 6. 시스템 알림 기반 자동 정리

| 플랫폼 | 트리거 | 동작 |
| --- | --- | --- |
| iOS/tvOS | `didReceiveMemoryWarning` | 메모리 캐시 전체 삭제 |
| iOS/tvOS | `willTerminate` | 만료된 디스크 캐시 정리 |
| iOS/tvOS | `didEnterBackground` | 백그라운드에서 디스크 정리 |
| macOS | `willResignActive` | 만료된 디스크 캐시 정리 |

`cleanExpiredDiskCache()`는 두 가지 기준으로 정리:

- **시간 만료** (`removeExpiredValues`)
- **용량 초과** (`removeSizeExceededValues`)

> 정리 후 `KingfisherDidCleanDiskCache` 노티피케이션 발송 → 외부에서 감지 가능
단, **수동 삭제(`clearDiskCache`)는 노티피케이션을 발송하지 않는다.**
> 

### Notification 등록의 비동기 패턴

```swift
public init(...) {
    Task { @MainActor in
        notifications.forEach {
            NotificationCenter.default.addObserver(self, selector: $0.1, name: $0.0, object: nil)
        }
    }
}
```

`UIApplication.shared`는 메인 스레드 전용이므로 `@MainActor`로 메인 스레드를 보장한다.
`Task { @MainActor in }` 사용으로 `init`을 블로킹하지 않으면서 메인 스레드 실행을 보장.

| 방법 | 문제점 |
| --- | --- |
| `DispatchQueue.main.async` | init 완료 후 등록 → init 직후 메모리 경고 발생 시 누락 가능 |
| `Task { @MainActor in }`  | 메인 스레드 보장 + init 블로킹 없음 |

---

## 7. Swift Concurrency 지원 (async/await)

기존 콜백 기반 API를 `withCheckedThrowingContinuation`으로 래핑해 async/await를 지원한다.

```swift
open func retrieveImage(forKey key: String, options: KingfisherParsedOptionsInfo) async throws -> ImageCacheResult {
    try await withCheckedThrowingContinuation { continuation in
        retrieveImage(forKey: key, options: options) { continuation.resume(with: $0) }
    }
}
```

기존 콜백 코드를 **재사용**하면서 async API를 추가한 실용적 패턴. 코드 중복 없이 두 스타일을 모두 지원한다.

**`Checked` vs `Unchecked` Continuation:**

```swift
// Checked: resume을 0번 또는 2번 이상 호출 시 런타임 경고/크래시
withCheckedThrowingContinuation { ... }  // Kingfisher 채택

// Unchecked: 검증 없음, 잘못 사용 시 정의되지 않은 동작(UB)
withUnsafeThrowingContinuation { ... }
```