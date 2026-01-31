## store

> 💡
> 
> 값을 디스크 캐시에 직렬화해 저장하고, 만료 정책과 파일 메타데이터를 함께 설정하는 저장 API

```swift
public func store(
    value: T,
    forKey key: String,
    expiration: StorageExpiration? = nil,
    writeOptions: Data.WritingOptions = [],
    forcedExtension: String? = nil
) throws
{
    guard storageReady else {
        throw KingfisherError.cacheError(reason: .diskStorageIsNotReady(cacheURL: directoryURL))
    }

    let expiration = expiration ?? config.expiration
    // The expiration indicates that already expired, no need to store.
    guard !expiration.isExpired else { return }
    
    let data: Data
    do {
        data = try value.toData()
    } catch {
        throw KingfisherError.cacheError(reason: .cannotConvertToData(object: value, error: error))
    }

    let fileURL = cacheFileURL(forKey: key, forcedExtension: forcedExtension)
    do {
        try data.write(to: fileURL, options: writeOptions)
    } catch {
        if error.isFolderMissing {
            // The whole cache folder is deleted. Try to recreate it and write file again.
            do {
                try prepareDirectory()
                try data.write(to: fileURL, options: writeOptions)
            } catch {
                throw KingfisherError.cacheError(
                    reason: .cannotCreateCacheFile(fileURL: fileURL, key: key, data: data, error: error)
                )
            }
        } else {
            throw KingfisherError.cacheError(
                reason: .cannotCreateCacheFile(fileURL: fileURL, key: key, data: data, error: error)
            )
        }
    }

    let now = Date()
    let attributes: [FileAttributeKey : Any] = [
        // The last access date.
        .creationDate: now.fileAttributeDate,
        // The estimated expiration date.
        .modificationDate: expiration.estimatedExpirationSinceNow.fileAttributeDate
    ]
    do {
        try config.fileManager.setAttributes(attributes, ofItemAtPath: fileURL.path)
    } catch {
        try? config.fileManager.removeItem(at: fileURL)
        throw KingfisherError.cacheError(
            reason: .cannotSetCacheFileAttribute(
                filePath: fileURL.path,
                attributes: attributes,
                error: error
            )
        )
    }

    maybeCachedCheckingQueue.async {
        self.maybeCached?.insert(fileURL.lastPathComponent)
    }
}
```

### Data.WritingOptions

`Data`를 디스크에 쓸 때의 동작 방식을 제어하는 옵션

- atomic: 원자성은 보장하지만 느림
- default []: 바로 해당 경로에 쓰고 빠르지만, 중간에 실패시 파일이 깨질 가능성 있음.

### forcedExtension

캐시 파일 이름에 강제로 붙일 확장자 (png, jpeg)

원본 파일의 이름을 해시값으로 저장하면 확장자 정보가 사라지기 때문에 해시로 저장한 경우 확장자 명시

### storageReady

init 단계에서 실패시 `false`, 디렉토리 생성 실패 이력이 있으면 즉시 실패

### expiration

만료 정책 확인 후 만료되었으면 즉시 리턴

### toData

Data 형식으로 변환

### cacheFileURL

실제 파일 위치 확정

### 디스크 쓰기 + 복구

디스크 쓰기 단계에서 실패 시 `isFolderMissing` 에러 타입을 확인하고 `FolderMissing`인 경우에 디렉토리가 존재하지 않는 에러이기 때문에 디렉토리를 재생성해서 다시 write를 시도

### 캐시 메타데이터 설정

attribute에 캐시 메타 저장

---

## value

> 💡
> 
> 디스크 캐시에서 값을 조회하고, 만료 여부를 검사한 뒤 필요하면 데이터를 로드하며, 접근에 따라 만료 시간을 연장하는 조회 API

```swift
func value(
    forKey key: String,
    referenceDate: Date,
    actuallyLoad: Bool,
    extendingExpiration: ExpirationExtending,
    forcedExtension: String?
) throws -> T?
{
    guard storageReady else {
        throw KingfisherError.cacheError(reason: .diskStorageIsNotReady(cacheURL: directoryURL))
    }

    let fileManager = config.fileManager
    let fileURL = cacheFileURL(forKey: key, forcedExtension: forcedExtension)
    let filePath = fileURL.path

    let fileMaybeCached = maybeCachedCheckingQueue.sync {
        return maybeCached?.contains(fileURL.lastPathComponent) ?? true
    }
    guard fileMaybeCached else {
        return nil
    }
    guard fileManager.fileExists(atPath: filePath) else {
        return nil
    }

    let meta: FileMeta
    do {
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
        meta = try FileMeta(fileURL: fileURL, resourceKeys: resourceKeys)
    } catch {
        throw KingfisherError.cacheError(
            reason: .invalidURLResource(error: error, key: key, url: fileURL))
    }

    if meta.expired(referenceDate: referenceDate) {
        return nil
    }
    if !actuallyLoad { return T.empty }

    do {
        let data = try Data(contentsOf: fileURL)
        let obj = try T.fromData(data)
        metaChangingQueue.async {
            meta.extendExpiration(with: self.config.fileManager, extendingExpiration: extendingExpiration)
        }
        return obj
    } catch {
        throw KingfisherError.cacheError(reason: .cannotLoadDataFromDisk(url: fileURL, error: error))
    }
}
```

### referenceDate

캐시 만료 여부를 판단하기 위한 기준 시점

### actuallyLoad

실제 파일 데이터를 디스크에서 읽을지 여부

- true: 파일 읽기 + 디코딩 수행
- false: 존재 + 만료 여부만 확인하고 데이터는 로드하지 않음.

### storageReady

init 단계에서 실패시 `false`, 디렉토리 생성 실패 이력이 있으면 즉시 실패

### fileMaybeCached

- `maybeCached` 메모리 Set으로 1차 필터
- 없다고 확실하면 디스크 접근 없이 `nil`
- 있으면 `fileExists`로 2차 확인

### 파일 메타데이터 로드

- `creationDate` / `modificationDate` 읽기
- 만료 판단을 위한 최소 정보만 조회
- FileMeta 세팅

### 만료 여부 검사

`meta.expired(referenceDate: referenceDate)` 

현재 날짜 기준으로 만료일 판단해서 만료 되었으면 return

### 로드 여부 분기

- `actuallyLoad == false`
    - 존재 + 유효 여부만 확인
    - 더미 값(`T.empty`) 반환

### 실제 데이터 로드 및 변환

- `Data(contentsOf:)`로 파일 읽기
- `T.fromData`로 객체 복원

### 만료 시간 연장 (비동기)

- 접근 사실을 반영해 expiration 갱신
- `metaChangingQueue.async`
- 반환 경로 차단 안 함

---

## isCached

> 💡
> 
> 디스크 캐시에 해당 키의 유효한 값이 존재하는지만 빠르게 확인하는 API

```swift
public func isCached(forKey key: String, referenceDate: Date, forcedExtension: String? = nil) -> Bool {
    do {
        let result = try value(
            forKey: key,
            referenceDate: referenceDate,
            actuallyLoad: false,
            extendingExpiration: .none,
            forcedExtension: forcedExtension
        )
        return result != nil
    } catch {
        return false
    }
}
```

### actuallyLoad

`false`로 설정하면 디스크에서 데이터를 직접 읽지 않고, 파일 존재 여부와 만료 여부만 검사해 캐시 유효성만 빠르게 판단함으로써 성능을 향상시킵니다.

---

## remove, removeFile

> 💡
> 
> 캐시 삭제 API

```swift
public func remove(forKey key: String, forcedExtension: String? = nil) throws {
    let fileURL = cacheFileURL(forKey: key, forcedExtension: forcedExtension)
    try removeFile(at: fileURL)
}

func removeFile(at url: URL) throws {
    try config.fileManager.removeItem(at: url)
}
```

---

## removeAll

> 💡
> 
> removeAll은 캐시 디렉토리 전체를 삭제하는 API

```swift
func removeAll(skipCreatingDirectory: Bool) throws {
    try config.fileManager.removeItem(at: directoryURL)
    if !skipCreatingDirectory {
        try prepareDirectory()
    }
}
```

### skipCreatingDirectory

모든 캐시를 삭제한 뒤, 캐시 디렉토리를 다시 만들지 여부를 결정하는 플래그
