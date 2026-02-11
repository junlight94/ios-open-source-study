- 메모리 저장소와 디스크 저장소를 통합해서 관리
    - MemoryStorage : 빠르고 휘발성
    - DiskStorage : 느리고 영속성

## 핵심 설계 패턴

### 3-Tier 캐싱 전략

```swift
// 이미지 조회 흐름
func retrieveImage(forKey key: String, ...) {
    // Tier 1: Memory Cache (0.001ms)
    if let image = memoryStorage.value(forKey: key) {
        return .memory(image)  // 가장 빠름!
    }
    
    // Tier 2: Disk Cache (10ms)
    if let image = diskStorage.value(forKey: key) {
        // 디스크에서 찾았으면 메모리에도 저장
        memoryStorage.store(image, forKey: key)
        return .disk(image)
    }
    
    // Tier 3: Network (1000ms)
    return .none  // 캐시 없음, 다운로드 필요
}
```

- 요청 1: 메모리에서 찾음 → 0.001ms
- 요청 2: 디스크에서 찾음 → 10ms → 메모리 저장
- 요청 3: 같은 이미지 → 메모리에서 → 0.001ms

### ComputedKey

- 키 생성 전략

```swift
extension String {
    func computedKey(with identifier: String) -> String { // identity 붙이기 위함
        if identifier.isEmpty {
            return self  // "photo.jpg"
        } else {
            return appending("@\(identifier)")  // "photo.jpg@blur_10"
        }
    }
}

// 사용
let url = "https://example.com/user/12345/profile.jpg"
let processor = ResizingImageProcessor(size: CGSize(width: 100, height: 100))

let memoryKey = url.computedKey(with: processor.identifier)
// "https://example.com/user/12345/profile.jpg@com.kingfisher.processor.resize.100x100"

// 디스크 파일명
let fileName = config.usesHashedFileName 
    ? memoryKey.kf.sha256  // SHA256 해싱
    : memoryKey            // 그대로 사용
```

- 같은 원본 이미지에 대해서 블러 처리, 리사이즈된 이미지 등등을 별도 캐시하기 위해서 사용
- 해싱을 사용하는 이유
    - 개인 정보 보호 : URL 역추적 불가능
    - 일관된 길이
    - 파일명 관련 오류 발생 방지: 특수문자나 공백등으로 일어나는 오류 방지
- autoExtAfterHashedFileName
    - 확장자는 노출되어도 큰 문제 없음 → UIImage의 타입 추론 / 렌더링 시 사용하기 위해 확장자 표시

# 핵심 구현 사항

## **Convenience** init

- Parameters
    - name: 캐시 객체의 이름
        - 디스크 캐시 디렉터리와 IO 큐를 설정하는 데 사용
        - 중복 금지 → 디스크 저장소 간에 충돌 발생
        - 빈 문자열 불가
    - cacheDirectoryURL : 디스크 상의 캐시 디렉터리
        - Diskstorag의 Init에 전달됨
        - nil인 경우 사용자 도메인 마스크 아래의 캐시 디렉터리가 사용
    - diskCachePathClosure: 선택적 초기 경로 문자열을 입력으로 받아 최종 디스크 캐시 경로를 생성하는 클로저
        - 캐시 경로 커스텀 가능
        - throws: 이미지 캐시 생성 중에 발생하는 오류(예: 지정된 경로에 디렉터리를 생성할 수 없는 경우)

Public Convenience Init (throws)  : throws로 에러 전파

```swift
    public convenience init(
        name: String,
        cacheDirectoryURL: URL?,
        diskCachePathClosure: DiskCachePathClosure? = nil
    ) throws
    // DiskStorage 생성이 실패할 수 있음
```

Internal Convenience Init (no throw) : 에러 무시 / 항상 성공

```swift
convenience init(
    noThrowName name: String,
    cacheDirectoryURL: URL?,
    diskCachePathClosure: DiskCachePathClosure?
)
```

- static let 변수 생성 시 사용
    
    ```swift
    // ImageCache.default 초기화
    public static let `default` = ImageCache(name: "default")
    ```
    
    - Swift는 static stored property에서 throwing initializer 호출 불가
- try?로 실패를 무시, 계속 진행 후 디렉토리 생성 → 재시도
- storageReady를 이용해서 크래시를 발생 시키지 않고 캐시 진행 → 사용 시점에서 에러 전달

## Notification 등록의 비동기 패턴

### Task + @MainActor 조합

```swift
public init(...) {
    self.memoryStorage = memoryStorage
    self.diskStorage = diskStorage
    self.ioQueue = DispatchQueue(...)

    Task { @MainActor in
        let notifications: [(Notification.Name, Selector)]
        #if !os(macOS) && !os(watchOS)
        notifications = [
            (UIApplication.didReceiveMemoryWarningNotification, 
             #selector(clearMemoryCache)),
            (UIApplication.willTerminateNotification, 
             #selector(cleanExpiredDiskCache)),
            (UIApplication.didEnterBackgroundNotification, 
             #selector(backgroundCleanExpiredDiskCache))
        ]
        #elseif os(macOS)
        notifications = [
            (NSApplication.willResignActiveNotification, 
             #selector(cleanExpiredDiskCache)),
        ]
        #else
        notifications = []
        #endif
        
        notifications.forEach {
            NotificationCenter.default.addObserver(
                self, 
                selector: $0.1, 
                name: $0.0, 
                object: nil
            )
        }
    }
}
```

- `addObserver` 는 어느 스레드에서든 호출 가능
- `UIApplication.shared` 는 메인 스레드 전용
- addObserve가 직접 호출하거나 이미지 캐시가 백그라운드에서 스레드 초기화 하면 → *크래시 발생*

**해결 방법 비교**

- 방법 1: DispatchQueue.main.async

```swift
public init(...) {
    // ...
    DispatchQueue.main.async {
        NotificationCenter.default.addObserver(...)
    }
}
```

- 문제점
    - 비동기라 init 완료 후 등록됨
    - init 직후 메모리 경고 발생 시 누락

- 방법 2: Task + @MainActor (채택된 방법)

```swift
// 
Task { @MainActor in
    NotificationCenter.default.addObserver(...)
}
```

- 장점
    - @MainActor 로 메인 스레드 보장
    - 비구조화된 동시성 (unstructured concurrency) → init이 블로킹 안됨

## ioQueue

- 디스크 I/O 전용 큐
    
    ```swift
    public final class ImageCache {
        private let ioQueue: DispatchQueue
        
        public init(
            memoryStorage: MemoryStorage.Backend<Image>,
            diskStorage: DiskStorage.Backend<Data>
        ) {
            self.memoryStorage = memoryStorage
            self.diskStorage = diskStorage
            
            // ioQueue 생성
            let ioQueueName = "com.onevcat.Kingfisher.ImageCache.ioQueue.\(UUID().uuidString)"
            ioQueue = DispatchQueue(label: ioQueueName)
            // ...
        }
    }
    ```
    

ioQueue의 역할 

- 모든 디스크 작업 집중화
    - 저장 조회 삭제 정리 / 크기 계산 / 직접 디스크 저장 등의 디스크 작업을 일관된 패턴 - 예측 가능한 동작 가능

UUID를 사용하는 이유:

- ImageCache 인스턴스마다 고유한 큐 사용
    - 여러 ImageCache 인스턴스가 있어도 각자의 ioQueue를 이용해서 서로 영향 없이 I/O 작업.
    - 디버깅 시에도 서로 구분 가능

Serial Queue의 특성

- ioQueue는 Serial Queue
- 순차 실행 보장
    - 파일 시스템 충돌 방지 : 동시 실행일 경우에는 Thread 1이 읽는 동안 Thread 2가 파일을 삭제하는 경우 크래시 발생 가능
    - 파일 시스템 순서 보장: 같은 키로 연속 작업할 경우 잘못된 데이터 반환 가능성 있음

성능 영향

- MainThread 에서 실행 시 : UI가 멈추는 위혐성 존재
- ioQueue 사용 : MainThread는 즉시 해제되기 때문에 UI 블로킹 X

복잡한 큐 전략

```swift
 let loadingQueue: CallbackQueue = options.loadDiskFileSynchronously ? .untouch : .dispatch(ioQueue)
```

- untouch: 실행 중인 스레드 사용
- dispatch(ioQueue): ioQueue로 dispatch

```swift
loadingQueue.execute {
    // 디스크 읽기
    let data = try self.diskStorage.value(forKey: computedKey, ...)
    
    // 디코딩
    image = options.cacheSerializer.image(with: data, options: options)
    
    // 백그라운드 디코딩
    if options.backgroundDecode {
        image = image?.kf.decoded(scale: options.scaleFactor)
    }
    
    // 콜백
    callbackQueue.execute { completionHandler(.success(image)) }
}
```

- 빠른 SSD + 작은 이미지(썸네일) : 비동기 방식에서 스레드 디스패치보다 즉시 실행하는 게 나음 → *동기 로딩 사용*
- 큰 이미지(원본 이미지) : I/O가 느리기 때문에 UI 블로킹 위험 존재→ *비동기 로딩 사용*

### store 메서드의 오버 로딩

```swift
// API 1: KingfisherParsedOptionsInfo 버전 (내부용)
open func store(
    _ image: KFCrossPlatformImage,
    original: Data? = nil,
    forKey key: String,
    options: KingfisherParsedOptionsInfo,  // 이미 파싱된 상태의 Option 정보
    toDisk: Bool = true,
    completionHandler: (@Sendable (CacheStoreResult) -> Void)? = nil
)

// API 2: 개별 파라미터 버전 (공개용)
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

- 공개용 store 메서드

```swift
 struct TempProcessor: ImageProcessor {
        let identifier: String
        
        func process(
            item: ImageProcessItem, 
            options: KingfisherParsedOptionsInfo
        ) -> KFCrossPlatformImage? {
            return nil  // 🔥 절대 호출 안됨!
        }
    }
    
    let options = KingfisherParsedOptionsInfo([
        .processor(TempProcessor(identifier: identifier)),
        .cacheSerializer(serializer),
        .callbackQueue(callbackQueue),
        .forcedCacheFileExtension(forcedExtension)
    ])
```

- KingfisherParsedOptionsInfo 는 설정해야 할 프로퍼티가 많음
- 사용자가 하나씩 설정하는 것보다 딱 필요한 것들만 전달

### retrieve의 계층적 검색과 프로모션

- 전체 흐름 분석

```swift
open func retrieveImage(
    forKey key: String,
    options: KingfisherParsedOptionsInfo,
    callbackQueue: CallbackQueue = .mainCurrentOrAsync,
    completionHandler: (@Sendable (Result<ImageCacheResult, KingfisherError>) -> Void)?
) {
    guard let completionHandler = completionHandler else { return }

    // ===== 1단계: 메모리 체크 =====
    if let image = retrieveImageInMemoryCache(forKey: key, options: options) {
        callbackQueue.execute { 
            completionHandler(.success(.memory(image))) 
        }
        return  // 🎯 Early return
    } 
    
    // ===== 2단계: fromMemoryCacheOrRefresh 옵션 =====
    else if options.fromMemoryCacheOrRefresh {
        callbackQueue.execute { 
            completionHandler(.success(.none)) 
        }
        return  // 🎯 디스크 건너뛰고 즉시 .none
    } 
    
    // ===== 3단계: 디스크 체크 =====
    else {
        self.retrieveImageInDiskCache(
            forKey: key, 
            options: options, 
            callbackQueue: callbackQueue
        ) { result in
            switch result {
            case .success(let image):
                guard let image = image else {
                    // 디스크에도 없음
                    callbackQueue.execute { 
                        completionHandler(.success(.none)) 
                    }
                    return
                }

                // ===== 4단계: 캐시 프로모션 =====
                var cacheOptions = options
                cacheOptions.callbackQueue = .untouch  // 🔥 중요!
                
                self.store(
                    image,
                    forKey: key,
                    options: cacheOptions,
                    toDisk: false  // 메모리만
                ) { _ in
                    callbackQueue.execute { 
                        completionHandler(.success(.disk(image))) 
                    }
                }
                
            case .failure(let error):
                callbackQueue.execute { 
                    completionHandler(.failure(error)) 
                }
            }
        }
    }
}
```

- fromMemoryCacheOrRefresh
    - 프로필 사진 처럼 바로 다운로드를 해야할 때 디스크 캐시를 무시하고 메모리 캐시가 없으면 즉시 다운로드
    
    ```swift
    // 시나리오: 프로필 사진 업데이트
    
    // Before
    user.updateProfilePicture(newImage)
    
    // Option 1: 일반 retrieve
    cache.retrieveImage(forKey: user.id) { result in
        if let image = result.image {
            // 🔴 문제: 오래된 캐시 이미지 표시
            profileImageView.image = image
        } else {
            downloadNewImage()
        }
    }
    
    // Option 2: fromMemoryCacheOrRefresh
    cache.retrieveImage(
        forKey: user.id,
        options: [.fromMemoryCacheOrRefresh]
    ) { result in
        if let image = result.image {
            // ✅ 메모리에 있으면 즉시 표시 (빠름)
            profileImageView.image = image
        } else {
            // ✅ 메모리에 없으면 바로 다운로드 (최신)
            // 디스크 캐시 건너뛰기!
            downloadNewImage()
        }
    }
    
    ```