# ioQueue

디스크 I/O 전용 직렬큐로 파일 접근 동시성을 제어하며 thread-safe를 보장하기 위한 Queue

# callbackQueue

```swift
public enum CallbackQueue: Sendable {
    
    /// Dispatches the closure to `DispatchQueue.main` with an `async` behavior.
    case mainAsync
    
    /// Dispatches the closure to `DispatchQueue.main` with an `async` behavior if the current queue is not `.main`.
    ///  Otherwise, it calls the closure immediately on the current main queue.
    case mainCurrentOrAsync
    
    /// Does not change the calling queue for the closure.
    case untouch
    
    /// Dispatches the closure to a specified `DispatchQueue`.
    case dispatch(DispatchQueue)

    /// Dispatches the closure to an operation-queue–like type.
    ///
    /// Use this case when you want to integrate Kingfisher's work into your own scheduling policy.
    /// For example, you can control concurrency, priority, or implement a LIFO execution order.
    ///
    /// - Note: Execution order and whether the block runs serially or concurrently depend on the
    ///   provided queue. Kingfisher does not enforce ordering guarantees for this case.
    case operationQueue(CallbackOperationQueue)

    /// Executes the `block` in a dispatch queue defined by `self`.
    /// - Parameter block: The block needs to be executed.
    public func execute(_ block: @Sendable @escaping () -> Void) {
        switch self {
        case .mainAsync:
            CallbackQueueMain.async { block() }
        case .mainCurrentOrAsync:
            CallbackQueueMain.currentOrAsync { block() }
        case .untouch:
            block()
        case .dispatch(let queue):
            queue.async { block() }
        case .operationQueue(let queue):
            queue.addOperation(block)
        }
    }

    var queue: DispatchQueue {
        switch self {
        case .mainAsync: return .main
        case .mainCurrentOrAsync: return .main
        case .untouch: return OperationQueue.current?.underlyingQueue ?? .main
        case .dispatch(let queue): return queue
        case .operationQueue(let queue): return queue.underlyingQueue ?? .main
        }
    }
}
```

completion 실행 전략을 표현하는 enum, 단순 `DispatchQueue` 래퍼가 아니라 **정책 객체**

## 각 case 정확한 의미

## mainAsync

```swift
DispatchQueue.main.async { block() }
```

### 특징

무조건 MainThread에서 실행함.

## mainCurrentOrAsync

```swift
static func currentOrAsync(_ block: @MainActor @Sendable @escaping () -> Void) {
    if Thread.isMainThread {
            // runUnsafely는 이미 메인 액터라고 가정하고 즉시 실행
            // 컴파일러가 isolation 체크하지 않아서 datarace 가능성이 있음
            // 여기서는 isMainThread를 체크하고 들어와서 안전
        MainActor.runUnsafely { block() }
    } else {
        DispatchQueue.main.async { block() }
    }
}
```

### 동작

현재가 main이면 즉시 실행 아니면 MainThread에서 실행

### 특징

- main에서 불필요한 async hop 방지
- 가장 균형 잡힌 기본 옵션

## untouch

현재 스레드 유지

### 의미

어떤 queue도 강제하지 않음, 호출자 thread policy를 존중

## dispatch(DispatchQueue)

### 동작

```swift
queue.async { block() }
```

### 의미

- 특정 GCD queue에 실행 위임
- 병렬/직렬 여부는 해당 queue에 의존

## operationQueue(CallbackOperationQueue)

### 동작

```swift
queue.addOperation(block)
```

### 의미

- GCD가 아니라 OperationQueue 스타일
- LIFO, priority, maxConcurrentOperationCount 제어 가능
- 실행 순서 보장 안 함 (Kingfisher는 관여하지 않음)

### 고급 사용 케이스

- 이미지 로딩을 LIFO로 처리
- low priority 작업 분리
- 네트워크 파이프라인 통합

# execute

```swift
public func execute(_ block: @Sendable @escaping () -> Void) {
    switch self {
    case .mainAsync:
        CallbackQueueMain.async { block() }
    case .mainCurrentOrAsync:
        CallbackQueueMain.currentOrAsync { block() }
    case .untouch:
        block()
    case .dispatch(let queue):
        queue.async { block() }
    case .operationQueue(let queue):
        queue.addOperation(block)
    }
}
```

### 해석

> "block을 어떤 실행 정책으로 실행할지 결정"
> 

## 사용 경로

### **직접 파라미터로 전달**

```swift
retrieveImage(
    forKey: key,
    options: options,
    callbackQueue: .dispatch(.global())
)
```

### **options 안에서 설정**

```swift
let options = KingfisherParsedOptionsInfo([
    .callbackQueue(.dispatch(myQueue))
])

let callbackQueue = options.callbackQueue
```

---

## loadingQueue

**디스크에서 이미지를 읽을 때**만 등장 (retrieveImageInDiskCache)

디스크 읽기 실행 전략을 런타임에 선택

```swift
let loadingQueue: CallbackQueue = options.loadDiskFileSynchronously ? .untouch : .dispatch(ioQueue)
```
