
```swift
public enum CacheType: Sendable {
        case none
        case memory
        case disk
}
```

### 설명

**이미지가 “어디서 왔는지”를 표현하는 결과용 상태 값**

### 의도

> 캐시 존재 여부가 아니라 출처(origin) 를 표현
> 
- 새로 생성/다운로드된 것인지 (`none`)
- 메모리 캐시에서 나온 것인지 (`memory`)
- 디스크 캐시에서 나온 것인지 (`disk`)

---

## 🔹 cached

```swift
public var cached: Bool {
        switch self {
        case .memory, .disk: return true
        case .none: return false
}
```

### 의도

👉 **고수준 API는 단순하게, 저수준 정보는 유지**

- 대부분의 호출부는 “캐시였냐 아니냐”만 필요
- 하지만 타입 자체는 더 많은 정보를 담고 있음

### 설계적으로 중요한 표현 포인트

`none`은 “캐시에 없다”가 아니라 **“캐시에서 온 결과가 아니다”**

즉, 방금 다운로드된 이미지, 프로세서로 새로 생성된 이미지도 포함
