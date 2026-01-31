## cacheFileURL

<aside>
💡

CRUD 전체에서 사용하는 파일 위치 계산하는 메서드

</aside>

```swift
public func cacheFileURL(forKey key: String, forcedExtension: String? = nil) -> URL {
    let fileName = cacheFileName(forKey: key, forcedExtension: forcedExtension)
    return directoryURL.appendingPathComponent(fileName, isDirectory: false)
}
```

---

## cacheFileName

<aside>
💡

캐시 key를 실제 디스크 파일 이름으로 변환하는 메서드

</aside>

```swift
func cacheFileName(forKey key: String, forcedExtension: String? = nil) -> String {
    let baseName = config.usesHashedFileName ? key.kf.sha256 : key
    
    if let ext = fileExtension(key: key, forcedExtension: forcedExtension) {
        return "\(baseName).\(ext)"
    }
    
    return baseName
}
```

---

## fileExtension

<aside>
💡

캐시 파일 이름에 붙일 확장자를 우선순위 규칙에 따라 결정하는 메서드

</aside>

```swift
func fileExtension(key: String, forcedExtension: String?) -> String? {
    if let ext = forcedExtension ?? config.pathExtension {
        return ext
    }

    if config.usesHashedFileName && config.autoExtAfterHashedFileName {
        return key.kf.ext
    }

    return nil
}
```

- forcedExtension
    - true == config에 있는 확장자 리턴
- 해시 파일
    - 파일 이름을 해시로 쓰면 확장자가 사라지므로
    - 원래 key(URL 등)에서 확장자를 추출해 복구

---

## allFileURLs

<aside>
💡

캐시 디렉토리 아래에 있는 모든 파일(및 하위 항목)의 URL을 열거해 반환하는 메서드

</aside>

```swift
func allFileURLs(for propertyKeys: [URLResourceKey]) throws -> [URL] {
    let fileManager = config.fileManager

    guard let directoryEnumerator = fileManager.enumerator(
        at: directoryURL, includingPropertiesForKeys: propertyKeys, options: .skipsHiddenFiles) else
    {
        throw KingfisherError.cacheError(reason: .fileEnumeratorCreationFailed(url: directoryURL))
    }

    guard let urls = directoryEnumerator.allObjects as? [URL] else {
        throw KingfisherError.cacheError(reason: .invalidFileEnumeratorContent(url: directoryURL))
    }
    return urls
}
```

---

## removeExpiredValues

<aside>
💡

기준 시점(referenceDate)을 기준으로 만료된 캐시 파일들을 찾아 삭제하고,

삭제된 파일들의 URL을 반환하는 정리(cleanup)

</aside>

```swift
func removeExpiredValues(referenceDate: Date) throws -> [URL] {
    let propertyKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .contentModificationDateKey
    ]

    let urls = try allFileURLs(for: propertyKeys)
    let keys = Set(propertyKeys)
    let expiredFiles = urls.filter { fileURL in
        do {
            let meta = try FileMeta(fileURL: fileURL, resourceKeys: keys)
            if meta.isDirectory {
                return false
            }
            return meta.expired(referenceDate: referenceDate)
        } catch {
            return true
        }
    }
    try expiredFiles.forEach { url in
        try removeFile(at: url)
    }
    return expiredFiles
}
```

---

## removeSizeExceededValues

<aside>
💡

디스크 캐시 총 용량이 제한을 초과하면,

LRU(Least Recently Used) 기준으로 오래된 파일부터 삭제해서

캐시 크기를 줄이는 정리(eviction) 메서드

</aside>

```swift
public func removeSizeExceededValues() throws -> [URL] {

    if config.sizeLimit == 0 { return [] }

    var size = try totalSize()
    if size < config.sizeLimit { return [] }

    let propertyKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .creationDateKey,
        .fileSizeKey
    ]
    let keys = Set(propertyKeys)

    let urls = try allFileURLs(for: propertyKeys)
    var pendings: [FileMeta] = urls.compactMap { fileURL in
        guard let meta = try? FileMeta(fileURL: fileURL, resourceKeys: keys) else {
            return nil
        }
        return meta
    }

    pendings.sort(by: FileMeta.lastAccessDate)

    var removed: [URL] = []
    let target = config.sizeLimit / 2
    while size > target, let meta = pendings.popLast() {
        size -= UInt(meta.fileSize)
        try removeFile(at: meta.url)
        removed.append(meta.url)
    }
    return removed
}
```

### 사이즈 제한 검사

config.sizeLimit이 0이면 사이즈 제한을 두지 않았기 때문에 빈 값 반환.

### LRU 정렬

`pendings.sort(by: FileMeta.lastAccessDate)`을 통해서 마지막 접근 시간으로 정렬

### 오래된 파일부터 제거

- 캐시 크기가 **sizeLimit의 절반 이하**가 될 때까지 제거
- 매번 limit까지 딱 맞추지 않음 → 잦은 정리 방지

---

## totalSize

<aside>
💡

디스크 캐시 디렉토리 안에 있는 모든 파일의 총 용량(bytes)을 계산하는 메서드

</aside>

`removeSizeExceededValues`에서 용량을 측정하기 위해 사용

```swift
public func totalSize() throws -> UInt {
    let propertyKeys: [URLResourceKey] = [.fileSizeKey]
    let urls = try allFileURLs(for: propertyKeys)
    let keys = Set(propertyKeys)
    let totalSize: UInt = urls.reduce(0) { size, fileURL in
        do {
            let meta = try FileMeta(fileURL: fileURL, resourceKeys: keys)
            return size + UInt(meta.fileSize)
        } catch {
            return size
        }
    }
    return totalSize
}
```
