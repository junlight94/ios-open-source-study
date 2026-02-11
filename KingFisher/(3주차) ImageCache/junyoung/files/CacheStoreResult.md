
```swift
public struct CacheStoreResult: Sendable {
        public let memoryCacheResult: Result<(),Never>
        public let diskCacheResult: Result<(),KingfisherError>
}
```

---

### 설명

`CacheStoreResult`는 **이미지 저장을 단일 이벤트가 아닌** 

**“메모리 / 디스크로 분리된 두 개의 결과”로 표현함으로써,**

**캐시 계층의 현실적인 실패 모델을 정확히 드러내는 타입**이다.

### 의도

Kingfisher의 저장은 항상 **두 단계**로 이루어짐 (메모리, 디스크)

이 둘은 성격이 다르고, 실패 가능성도 다름

**하나의 Bool / 하나의 Result로는 의미를 정확히 표현할 수 없음**

### 왜 메모리와 디스크를 분리했나?

메모리 캐시는 단순 in-memory 저장해서, 실패 요인이 사실상 없음
그래서 `Never`를 failure 타입으로 사용 **“실패하지 않는 작업”임을 타입으로 명시**

반면 디스크 캐시는 (파일 시스템 접근, 권한, 용량, I/O 에러 등) 실패 가능성이 항상 존재

### 왜 struct + Result 조합인가?
