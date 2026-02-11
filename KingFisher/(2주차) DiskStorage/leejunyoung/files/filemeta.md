> 💡
> 
> 디스크 캐시 파일 하나의 메타데이터를 파일 attribute 기반으로 표현한 값 타입

```swift
    struct FileMeta {
    
        let url: URL
        
        let lastAccessDate: Date?
        let estimatedExpirationDate: Date?
        let isDirectory: Bool
        let fileSize: Int
        
        static func lastAccessDate(lhs: FileMeta, rhs: FileMeta) -> Bool {
            return lhs.lastAccessDate ?? .distantPast > rhs.lastAccessDate ?? .distantPast
        }
        
        init(fileURL: URL, resourceKeys: Set<URLResourceKey>) throws {
            let meta = try fileURL.resourceValues(forKeys: resourceKeys)
            self.init(
                fileURL: fileURL,
                lastAccessDate: meta.creationDate,
                estimatedExpirationDate: meta.contentModificationDate,
                isDirectory: meta.isDirectory ?? false,
                fileSize: meta.fileSize ?? 0)
        }
        
        init(
            fileURL: URL,
            lastAccessDate: Date?,
            estimatedExpirationDate: Date?,
            isDirectory: Bool,
            fileSize: Int)
        {
            self.url = fileURL
            self.lastAccessDate = lastAccessDate
            self.estimatedExpirationDate = estimatedExpirationDate
            self.isDirectory = isDirectory
            self.fileSize = fileSize
        }

        func expired(referenceDate: Date) -> Bool {
            return estimatedExpirationDate?.isPast(referenceDate: referenceDate) ?? true
        }
        
        func extendExpiration(with fileManager: FileManager, extendingExpiration: ExpirationExtending) {
            guard let lastAccessDate = lastAccessDate,
                  let lastEstimatedExpiration = estimatedExpirationDate else
            {
                return
            }

            let attributes: [FileAttributeKey : Any]

            switch extendingExpiration {
            case .none:
                return
                
            case .cacheTime:
                let originalExpiration: StorageExpiration =
                    .seconds(lastEstimatedExpiration.timeIntervalSince(lastAccessDate))
                attributes = [
                    .creationDate: Date().fileAttributeDate,
                    .modificationDate: originalExpiration.estimatedExpirationSinceNow.fileAttributeDate
                ]
                
            case .expirationTime(let expirationTime):
                attributes = [
                    .creationDate: Date().fileAttributeDate,
                    .modificationDate: expirationTime.estimatedExpirationSinceNow.fileAttributeDate
                ]
            }

            try? fileManager.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }
```

## lastAccessDate

마지막 접근 시점 (LRU 기준으로 데이터 삭제를 위함)

## estimatedExpirationDate

만료 예정 시점

## **expired(referenceDate:)**

주어진 기준 시점에 대해 만료 여부를 판단하는 메서드

## extendExpiration(with:extendingExpiration:)

파일 접근 시 만료 시간과 접근 시간을 갱신하는 메서드

- `.none` → 갱신 안 함
- `.cacheTime` → 기존 만료 간격 유지
- `.expirationTime`  → 새 만료 정책 강제 적용
- 내부적으로
    - `creationDate` = now
    - `modificationDate` = 새 만료 시점
