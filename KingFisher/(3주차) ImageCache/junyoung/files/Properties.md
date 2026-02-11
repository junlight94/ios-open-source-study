
## 🔹 Default Static Cache

```swift
public static let `default` = ImageCache(name:"default")
```

### **설명**

Kingfisher 전체에서 공용으로 사용하는 “표준 이미지 캐시 인스턴스”

### **의도**

- 라이브러리 사용자에게 설정 없이 바로 쓸 수 있는 캐시 제공
- 앱 전반에서 캐시가 분산되지 않고 공유되도록 함
- 메모리 / 디스크 캐시를 하나의 글로벌 캐시 풀로 통합

---

## 🔹 ioQueue

```swift
private let ioQueue: DispatchQueue
```

### **설명**

`ImageCache` 내부의 모든 I/O 작업을 하나의 직렬 흐름으로 묶어, 
캐시 상태와 디스크 접근의 순서를 보장하기 위한 전용 큐

### **의도**

- 디스크 I/O + 캐시 로직을 메인 스레드에서 분리
- 동시에 들어오는 store / retrieve 요청을 순서대로 처리
- lock 없이도 race condition 방지
- 병렬성보다 정합성(correctness)과 예측 가능성을 우선한 설계

---

## 🔹 memoryStorage

```swift
public let memoryStorage: MemoryStorage.Backend<KFCrossPlatformImage>
```

### **설명**

**이미지를 RAM에 저장해, 가장 빠른 캐시 hit을 제공하는 1차 캐시 저장소**

### **의도**

- 디스크 접근 없이 **즉시 이미지 반환** (UI 성능 최우선)
- 시스템 메모리 압박 시 자동으로 비워질 수 있는 **휘발성 캐시**
- 비용(cost) 기반 eviction으로 **메모리 사용량 제어**

---

## 🔹 diskStorage

```swift
public let diskStorage: DiskStorage.Backend<Data>
```

### **설명**

**이미지를 파일로 저장해 앱 재실행 이후에도 유지되는 영속 캐시 저장소**

### 의도

- 네트워크 재요청을 줄이기 위한 **지속 캐시**
- 만료 시간(expiration)과 최대 용량(size limit)으로 **디스크 사용량 관리**
- 메모리 캐시 miss 시의 **2차 백업 계층**
