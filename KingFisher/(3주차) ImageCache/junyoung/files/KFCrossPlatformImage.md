```swift
extension KFCrossPlatformImage: CacheCostCalculable {
        public var cacheCost: Int { return kf.cost }
}
```

### 설명

이 확장은 `KFCrossPlatformImage`가 메모리 캐시에서 차지하는 비용을 스스로 계산해 제공함으로써,
이미지 크기에 기반한 합리적인 메모리 eviction 정책을 가능하게 한다.

### 핵심 의도

메모리 캐시는 단순히 “개수”가 아니라 **실제 메모리 사용량을 기준으로 eviction**해야 함

이미지마다 크기가 크게 다르기 때문에 동일 개수라도 메모리 부담은 천차만별

메모리 압박 상황에서도 예측 가능한 캐시 동작을 만들기 위함
