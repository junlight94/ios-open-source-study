
```swift
public enum ImageCacheResult: Sendable {
        case disk(KFCrossPlatformImage)
        case memory(KFCrossPlatformImage)
        case none
}
```

### 설명

`ImageCacheResult`는 캐시 조회의 결과를 “출처 + 데이터”가 결합된 값으로 표현해,

캐시 히트/미스를 안전하고 명확하게 다루도록 설계된 결과 타입이다.

### 의도

- 캐시 조회 결과는 항상 세 가지 중 하나
    1. 메모리 캐시 히트
    2. 디스크 캐시 히트
    3. 캐시 미스

이 결과를 **분기 없이 타입으로 표현**해, 호출자가 안전하게 처리하도록 유도

캐시 결과를 상태(state)가 아닌 **값(value)** 으로 다룸

### 왜 이미지가 associated value 인가?

캐시 히트 시 결과 + 데이터는 항상 함께 의미를 가짐

별도 튜플이나 옵셔널 대신 enum으로 묶어 상태와 데이터를 **불분리하게 표현**

### 🔹 `image` 프로퍼티

```swift
public var image: KFCrossPlatformImage?
```

대부분의 호출부는 “이미지가 있냐 없냐”만 필요

하지만 타입 자체는 출처 정보(disk / memory)를 보존

### 🔹 `cacheType` 프로퍼티

```swift
public var cacheType: CacheType
```

- `ImageCacheResult` → `CacheType`로의 **정규화된 변환**
- UI 로깅, 성능 분석, 정책 분기에서 사용
