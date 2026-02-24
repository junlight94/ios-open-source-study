# ImageCache 스터디 정리

## 📋 회의 내용 요약

### 🔑 주요 논의 사항

#### 1️⃣ Actor vs Queue 성능 비교 실험

**🧪 순서 보장 실험 결과**: IOQ 방식이유, Actor로 대체했을 때의 동작 검증

- 단일 serial queue 방식이 저장/읽기 순서 보장에 가장 효과적
- 메서드마다 개별 큐 사용 시엔 개별 큐 내에서는 순서 보장되나 저장-읽기 간 순서 보장 안 됨
- Actor로 타입 변경시에 serial Queue와 같이 작동확인, 성능 비교 확인 필요
- 실시간 라이브 코딩으로 Queue를 Actor로 변환하여 순서 보장 확인
-  결과 
   - **단일 Serial Queue(ioQueue)가 순서 보장에 가장 효과적** 
   - **Actor 타입도 똑같이 동작함**

| 방식 | 저장 순서 | 읽기 순서 | 저장-읽기 순서 |
|------|----------|----------|---------------|
| **Kingfisher (단일 Serial Queue)** | ✅ | ✅ | ✅ |
| Global Queue | ❌ | ❌ | ❌ |
| 메서드별 개별 Serial Queue | ✅ (개별 큐 내) | ✅ (개별 큐 내) | ❌ |


#### 2️⃣ 디스크 I/O 최적화

**분석**: `loadDiskFileSynchronously` 옵션의 존재 이유

- `Untouch`: 현재 스레드에서 그대로 실행 (스레드 전환 비용 없음)
- `Dispatch IoQ`: ioQueue로 스레드 이동하여 백그라운드 비동기 실행
- 작은 이미지의 경우 스레드 전환 비용이 실제 I/O 작업보다 클 수 있어 Untouch 옵션 제공

#### 3️⃣ 주요 설계 결정 사항

- **Notification**: 디스크 캐시 정리 시 삭제된 항목 정보를 Public으로 제공 (사용자 observe 가능)
- **compactedKey**: 동일 이미지의 리사이징/프로세싱 변형본을 구분하여 저장
- **CacheStoreResult 분리**: 메모리(실패 없음)와 디스크(파일 시스템 에러 가능)의 성격 차이로 타입 분리
- **디스크 expiration**: 특정 이미지를 영구 보존 가능 (`.never` 옵션)

---

#### 🤖 AI 도구 활용 논의

- **Claude Code**: Skills와 Workflow로 토큰 최적화
- **Cursor**: 다양한 AI 모델 선택 가능, Xcode 연동
- **Oh My OpenCode**: 에이전트별로 다른 모델 사용 (GPT-4.5/Claude/Gemini)
- **토큰 소비 문제**: 문제해결법..뭘까..., 메모리 에이전트로 MD 파일 저장하여 절약

---

#### 💼 개발자 커리어 전망

- 3년 내 개발자 수요 급감 예상, 기획자 라이브코딩 시대 도래
- Product Management 전환, AI 활용 능력(프롬프트 엔지니어링) 중요

---

#### 📝 채용 과제 관련

- 당근, 뱅크샐러드 등에서 이미지 캐시 구현 요구
- Kingfisher 수준 불가능, **저장 구조의 효율적 설계**가 핵심인 것 같다!


---


## 📚 ImageCache 핵심 개념

### 1. 구조

**ImageCache = MemoryStorage + DiskStorage를 하나의 인터페이스로 제공하는 하이브리드 캐시**
```swift
// 구성 요소
- MemoryStorage: NSCache 기반, 빠른 RAM 접근
- DiskStorage: 파일 시스템 기반, 장기 저장
- ioQueue: 디스크 I/O 직렬화 처리 (순서 보장)
```

---

### 2. 캐시 키 설계
```swift
let computedKey = key.computedKey(with: identifier)
```

- 원본 key + processor identifier 조합
- 같은 URL도 processor 적용 시 다른 결과물 → 별도 저장

---

### 3. 저장 흐름

#### 메모리 저장
```swift
memoryStorage.storeNoThrow(...)  // 현재 컨텍스트에서 즉시
```

- In-memory 구조, 빠르고 실패 거의 없음
- NSCache thread-safe는 **동시성 안전성**, 실패 없음은 **I/O 없기 때문**

#### 디스크 저장
```swift
ioQueue.async { syncStoreToDisk(...) }  // 비동기 직렬화
```

- image → data 변환 후 파일 저장
- 실패 시 `KingfisherError` 반환

---

### 4. 조회 흐름
```
1. 메모리 확인 → 있으면 즉시 반환
2. fromMemoryCacheOrRefresh 체크
   - true면 디스크 스킵, refresh 유도
3. 디스크 조회
   - 발견 시 data → image 변환
   - 메모리에 재적재 (다음 접근 빠르게)
```

---

### 5. 정리(Cleaning) 메커니즘

#### 라이프사이클 연동
```swift
// NotificationCenter 구독
- 메모리 경고 → clearMemoryCache
- 앱 종료/백그라운드 → cleanExpiredDiskCache
```

#### 디스크 정리 Notification
```swift
.KingfisherDidCleanDiskCache  // Public 노출
```

- 삭제된 hash 목록 제공
- 사용자가 직접 observe 가능

---

## 🎯 주요 설계 결정

### 1. 메모리 한도 = physicalMemory / 4
```swift
let totalMemory = ProcessInfo.processInfo.physicalMemory  // UInt64
let costLimit = totalMemory / 4
let limit = (costLimit > Int.max) ? Int.max : Int(costLimit)  // overflow 방지
```

- **1/4**: 보수적 디폴트 (표준 공식 아님)
- 캐시 과다 점유 시 메모리 워닝 위험 → 안전한 상한 설정
- `UInt64 → Int` 변환 시 overflow 방어

---

### 2. CacheStoreResult 타입 분리
```swift
// 메모리: 실패 없음
struct MemoryCacheResult { ... }

// 디스크: 실패 가능
enum DiskCacheResult {
    case success(...)
    case failure(KingfisherError)  // 파일시스템 에러
}
```

**이유**: 성격이 다르므로 명확한 의미 표현

---

### 3. loadDiskFileSynchronously 옵션
```swift
let loadingQueue: CallbackQueue = 
    options.loadDiskFileSynchronously ? .untouch : .dispatch(ioQueue)
```

- **Untouch**: 현재 스레드에서 실행 (전환 비용 제거)
- **Dispatch**: ioQueue로 비동기 (호출자 블록 방지)
- 작은 이미지는 스레드 전환 비용 > I/O 비용 → 선택권 제공

---

### 4. CallbackQueue 최적화
```swift
// 불필요한 디스패치 제거
if Thread.isMainThread {
    MainActor.runUnsafely { block() }  // 즉시 실행
} else {
    DispatchQueue.main.async { block() }
}
```

- 이미 적절한 큐면 전환 생략 → 지연 감소

---

### 5. 디스크 Expiration 옵션
```swift
.diskCacheExpiration(.never)  // 영구 보존
```

- 정적 리소스, 잘 안 바뀌는 이미지용
- LRU 정리 시에도 제외

---

## 🛠 주요 유틸리티

### App Extension 대응
```swift
// UIApplication.shared 런타임 체크
let selector = NSSelectorFromString("sharedApplication")
guard Base.responds(to: selector) else { return nil }
```

- 앱 익스텐션에서는 사용 불가 → 크래시 방지

---

### 백그라운드 정리
```swift
UIApplication.shared.beginBackgroundTask { ... }
// 정리 완료 후
UIApplication.shared.endBackgroundTask(identifier)
```

- iOS 백그라운드 실행 시간 제한 → 추가 시간 요청

---