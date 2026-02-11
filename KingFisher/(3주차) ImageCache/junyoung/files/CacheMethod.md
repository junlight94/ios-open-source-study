## 🔹 store

```swift
open func store(
    _ image: KFCrossPlatformImage,
    original: Data? = nil,
    forKey key: String,
    options: KingfisherParsedOptionsInfo,
    toDisk: Bool = true,
    completionHandler: (@Sendable (CacheStoreResult) -> Void)? = nil
)
```

### 설명

이 `store` 메서드는 **메모리 캐시는 즉시·무조건 저장하고,** 

**디스크 캐시는 비동기로 best-effort 처리함으로써,**

**캐시 저장이 성능이나 안정성을 해치지 않도록 의도적으로 “느슨한 성공 모델”을 채택한 구현**이다.

### 1️⃣ key는 반드시 “processor 포함 key”로 변환됨

> *“원본 key”가 아니라 “결과 이미지 key”를 캐시한다*
> 

```swift
let identifier = options.processor.identifier
let computedKey = key.computedKey(with: identifier)
```

같은 URL이라도 processor(리사이즈, 필터 등)가 다르면 **다른 캐시 항목으로 판단**

캐시 충돌 방지를 위한 **필수 정규화 단계** 

### 2️⃣ 메모리 캐시는 항상, 즉시, 실패 없이 저장

```swift
memoryStorage.storeNoThrow(...)
```

디스크 성공 여부와 **완전히 분리**

- 동기적
- 실패 없음
- ioQueue도 사용하지 않음

### 3️⃣ `toDisk == false`는 “메모리 전용 캐시” 모드

```swift
guard toDiskelse {...return }
```

- 디스크 캐시 자체를 스킵
- completion은 **즉시 callbackQueue에서 호출**
- 이 경우 **ioQueue를 전혀 타지 않음**

### 4️⃣ 디스크 저장은 항상 `ioQueue.async`

```swift
ioQueue.async {... }
```

디스크 I/O는 느리고 block 가능성이 있기 때문에 절대 호출 스레드에서 처리하지 않음

- `store`는 **논블로킹 API**

### 5️⃣ 디스크 저장의 첫 관문은 “직렬화”

```swift
let serializer = options.cacheSerializer
serializer.data(with:image, original:)
```

이미지 → Data 변환 실패 가능

이 단계는 디스크 문제가 아니라 **이미지/포맷 serialization 에러**

### 6️⃣ 직렬화 성공 → 실제 디스크 저장

```swift
self.syncStoreToDisk(...)
```

이름에 `sync`가 있지만 이미 `ioQueue.async` 안이며

의미는 **ioQueue 내부에서는 순차적** “blocking”이 아니라 “순서 보장” 의미의 sync

### 7️⃣ 직렬화 실패 → 메모리는 성공, 디스크만 실패

```swift
CacheStoreResult(
    memoryCacheResult: .success(()),
    diskCacheResult: .failure(...)
)
```

**부분 성공(partial success)** 을 명확히 표현 메모리 캐시는 롤백하지 않음

- 캐시는 best-effort
- 디스크 실패로 UI/기능을 망치지 않음

### 왜 메모리는 실패를 고려하지 않나?

메모리 캐시는 eviction은 나중 문제 store 자체는 실패 개념이 없음

### 왜 디스크 실패 시 메모리를 지우지 않나?

캐시는 **트랜잭션 시스템이 아님** 메모리에라도 남아 있으면 사용자 경험은 개선됨

### 왜 disk key에 `key`와 `processorIdentifier`를 다시 넘기나?

디스크 저장은 파일명, 확장자, 하위 디렉토리에 processor 정보가 필요

key 계산 책임을 **DiskStorage로 완전히 넘기지 않음**

### 설계 의도

캐시는 **동기화 대상이 아니라 성능 최적화 수단**

따라서 빠른 경로는 무조건 살리고, 느린 경로는 비동기, 실패는 국소화

---

## 🔹 store

```swift
open func store(
    _ image: KFCrossPlatformImage,
    original: Data? = nil,
    forKey key: String,
    processorIdentifier identifier: String = "",
    forcedExtension: String? = nil,
    cacheSerializer serializer: any CacheSerializer = DefaultCacheSerializer.default,
    toDisk: Bool = true,
    callbackQueue: CallbackQueue = .untouch,
    completionHandler: (@Sendable (CacheStoreResult) -> Void)? = nil
)
```

### 한 줄 요약(의미)

이 `store`는 **processor 개념을 노출하지 않으면서도 캐시 key 분리를 유지하기 위해,**

**식별자만 전달하는 더미 processor로 옵션을 구성해 기존 저장 로직에 위임하는 편의 API**다.

### 1️⃣ `TempProcessor`의 정체 (가장 헷갈리는 부분)

```swift
struct TempProcessor: ImageProcessor {
    let identifier: String
    func process(...) -> KFCrossPlatformImage? { return nil }
}
```

왜 process가 `nil`을 반환하는가?

이 processor는 **이미지를 처리하기 위한 용도가 아니고,** 오직 `processor.identifier`를 

캐시 key 계산에 사용하기 위한 **식별자 전달용 더미 객체**

**“processor = 변환”이 아니라, “processor.identifier = 캐시 구분자”만 필요**

### 2️⃣ 왜 그냥 identifier를 넘기지 않고 processor로 감싸나?

Kingfisher의 캐시 시스템은 processor를 기준으로 캐시를 분리

key 계산 로직이 processor에 묶여 있고, API 일관성을 위해

“processor가 없다”는 케이스를 만들지 않음

### 3️⃣ 옵션을 만들어서 기존 store로 위임

```swift
let options = KingfisherParsedOptionsInfo([...])
store(image, original: ..., forKey: key, options: options, ...)
```

실제 로직은 **앞에서 분석한 `store(options:)`**

이 메서드는 옵션 생성만 담당, 중복 로직 ❌

### 4️⃣ 이 API가 필요한 이유

라이브러리 사용자 중 다수는 `KingfisherOptionsInfo`, `ImageProcessor`구조를 잘 모름

하지만 이미 가공된 이미지를 직접 캐시에 넣고 싶을 때 고급 개념을 숨긴 실용 API를 제공

### 이 store는 실제로 이미지를 처리(process)하나?

`process`는 호출되지 않고, identifier만 사용됨

### identifier를 안 주면?

기본값 `""` 원본 key 그대로 사용하고, processor 없는 이미지와 동일한 캐시 취급

### 설계 의도 요약

캐시 시스템 내부 규칙은 그대로 유지

사용자에게는 단순한 API 제공

내부 구현은 하나의 코드 경로만 유지

---
