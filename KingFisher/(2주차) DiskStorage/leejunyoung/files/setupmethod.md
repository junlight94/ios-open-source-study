## setupCacheChecking

<aside>
💡

디스크 캐시 디렉토리를 한 번 스캔해서 `maybeCached` (메모리 Set)를 초기화하는 메서드

</aside>

```swift
private func setupCacheChecking() {
    DispatchQueue.global(qos: .default).async {
        do {
            let allFiles = try self.config.fileManager.contentsOfDirectory(atPath: self.directoryURL.path)
            let maybeCached = Set(allFiles)
            self.maybeCachedCheckingQueue.async {
                self.maybeCached = maybeCached
            }
        } catch {
            self.maybeCachedCheckingQueue.async {
                self.maybeCached = nil
            }
        }
    }
}
```

### global queue로 감싼 이유

초기화 과정에서 디스크를 스캔하는 느린 작업이 객체 생성이나 메인 스레드를 막지 않기 위한 작업이기 때문에 비동기로 처리.

---

## prepareDirectory

<aside>
💡

디스크 캐시 디렉토리가 이미 있으면 그대로 두고, 없으면 생성하는 메서드

</aside>

캐시 디렉토리가 준비돼 있는지 보장하고, 실패하면 이 스토리지를 비활성화하는 초기화 단계

```swift
private func prepareDirectory() throws {
    let fileManager = config.fileManager
    let path = directoryURL.path

    guard !fileManager.fileExists(atPath: path) else { return }

    do {
        try fileManager.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: nil)
    } catch {
        self.storageReady = false
        throw KingfisherError.cacheError(reason: .cannotCreateDirectory(path: path, error: error))
    }
}
```

### fileExists

해당 경로가 이미 존재하는지 확인하고 만약 있다면 early return

### fileManager.createDirectory

경로에 존재하는 파일이 없다면 `createDirectory` 메서드를 통해서 디렉토리 생성
