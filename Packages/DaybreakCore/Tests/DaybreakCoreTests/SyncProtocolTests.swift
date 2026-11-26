import Foundation
import Testing
import DaybreakCore

struct SyncProtocolTests {
    @Test func sha256KnownVectorsAndDigestValidation() {
        #expect(
            SyncContentDigest.hashing(Data()).hex
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        #expect(
            SyncContentDigest.hashing(Data("abc".utf8)).hex
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        #expect(
            SyncContentDigest(hex: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")?.hex
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        #expect(SyncContentDigest(hex: "abc") == nil)
        #expect(SyncContentDigest(hex: String(repeating: "g", count: 64)) == nil)

        let data = Data("asset-bytes".utf8)
        let digest = SyncContentDigest.hashing(data)
        #expect(digest.matches(data))
        #expect(!digest.matches(Data("other".utf8)))
    }

    @Test func deviceIdentifierIsFileSafe() {
        #expect(SyncDeviceID("device-a") != nil)
        #expect(SyncDeviceID("device_a1") != nil)
        #expect(SyncDeviceID("device.a") == nil)
        #expect(SyncDeviceID("../evil") == nil)
        #expect(SyncDeviceID("") == nil)
        #expect(SyncDeviceID(String(repeating: "a", count: 65)) == nil)
        #expect(SyncDeviceID.random().rawValue.isEmpty == false)
    }

    @Test func causalVectorDominanceAndMerge() throws {
        let deviceA = SyncFixture.deviceA
        let deviceB = SyncFixture.deviceB
        let older = try SyncVersionVector([deviceA: 1])
        let newer = try SyncVersionVector([deviceA: 2])
        let otherDevice = try SyncVersionVector([deviceB: 1])

        #expect(newer.dominates(older))
        #expect(!older.dominates(newer))
        #expect(newer.isConcurrent(with: otherDevice))
        #expect(!newer.dominates(otherDevice))
        #expect(newer.dominates(SyncVersionVector()))

        let merged = try newer.merging(otherDevice)
        #expect(merged.counter(for: deviceA) == 2)
        #expect(merged.counter(for: deviceB) == 1)
        let advanced = try merged.advancing(deviceA, to: 3)
        #expect(advanced.counter(for: deviceA) == 3)

        do {
            _ = try newer.advancing(deviceA, to: 2)
            Issue.record("Expected non-advancing sequence to fail")
        } catch let error as SyncProtocolError {
            #expect(error == .sequenceNotAdvanced(device: deviceA, existing: 2, requested: 2))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func operationIdentityIsDeterministic() {
        let first = SyncFixture.favorite("img-a", isFavorite: true, device: .deviceA, sequence: 1)
        let same = SyncFixture.favorite("img-a", isFavorite: true, device: .deviceA, sequence: 1)
        let different = SyncFixture.favorite("img-a", isFavorite: false, device: .deviceA, sequence: 1)

        #expect(first == same)
        #expect(first.id == same.id)
        #expect(first.id != different.id)
        #expect(first.context.counter(for: .deviceA) == 1)
    }

    @Test func everyPayloadRoundTripsThroughTheWireFile() throws {
        let device = SyncFixture.deviceA
        let image = SyncFixture.image("img-a")
        let occurrence = SyncFixture.occurrence(imageID: "img-a")
        let metadata = SyncFixture.metadata(imageID: "img-a")
        let wallpaper = SyncFixture.wallpaper(imageID: "img-a", variants: [SyncFixture.variant("img-a")])
        let story = SyncFixture.story()
        let asset = SyncFixture.assetReference("img-a")

        let operations: [SyncOperation] = [
            SyncFixture.favorite("img-a", isFavorite: true, device: device, sequence: 1),
            SyncFixture.pin(imageID: "img-a", isPinned: true, device: device, sequence: 1),
            SyncFixture.occurrenceOperation(occurrence, device: device, sequence: 1),
            SyncFixture.metadataOperation(metadata, device: device, sequence: 1),
            SyncFixture.wallpaperOperation(wallpaper, device: device, sequence: 1),
            SyncFixture.storyOperation(story, device: device, sequence: 1),
            SyncFixture.assetsOperation([asset], device: device, sequence: 1)
        ]
        #expect(operations.count == 7)
        #expect(image.isValid)

        for operation in operations {
            let file = SyncOperationFile(operation: operation)
            let data = try file.encoded()
            let again = try file.encoded()
            #expect(data == again)

            let decoded = try SyncOperationFile.decode(data)
            #expect(decoded.operation == operation)
            #expect(decoded.checksum == operation.id.digest)
            #expect(decoded.fileName == file.fileName)

            let parsed = SyncOperationFile.parseFileName(file.fileName)
            guard let parsed else {
                Issue.record("Expected a canonical operation file name")
                continue
            }
            #expect(parsed.deviceID == operation.deviceID)
            #expect(parsed.operationID == operation.id)
        }
    }

    @Test func wireRejectsUnknownProtocolVersionBeforeBodyDecode() throws {
        let operation = SyncFixture.favorite("img-a", isFavorite: true, device: .deviceA, sequence: 1)
        let data = try SyncOperationFile(operation: operation).encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"protocolVersion\":1"))

        let tampered = text.replacingOccurrences(
            of: "\"protocolVersion\":1",
            with: "\"protocolVersion\":999"
        )
        do {
            _ = try SyncOperationFile.decode(Data(tampered.utf8))
            Issue.record("Expected unknown protocol version to be rejected")
        } catch let error as SyncProtocolError {
            #expect(error == .unsupportedProtocolVersion(found: 999, supported: 1))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func wireRejectsFormatChecksumAndPayloadTampering() throws {
        let operation = SyncFixture.favorite("img-a", isFavorite: true, device: .deviceA, sequence: 1)
        let data = try SyncOperationFile(operation: operation).encoded()
        let text = String(decoding: data, as: UTF8.self)

        let wrongFormat = text.replacingOccurrences(
            of: SyncWireProtocol.format,
            with: "other.format"
        )
        do {
            _ = try SyncOperationFile.decode(Data(wrongFormat.utf8))
            Issue.record("Expected format rejection")
        } catch let error as SyncProtocolError {
            #expect(error == .unsupportedFormat("other.format"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let zeros = String(repeating: "0", count: 64)
        let wrongChecksum = text.replacingOccurrences(of: operation.id.rawValue, with: zeros)
        do {
            _ = try SyncOperationFile.decode(Data(wrongChecksum.utf8))
            Issue.record("Expected checksum rejection")
        } catch let error as SyncProtocolError {
            #expect(
                error == .checksumMismatch(
                    expected: operation.id.digest,
                    found: SyncContentDigest(hex: zeros)!
                )
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let changedPayload = text.replacingOccurrences(
            of: "\"isFavorite\":true",
            with: "\"isFavorite\":false"
        )
        do {
            _ = try SyncOperationFile.decode(Data(changedPayload.utf8))
            Issue.record("Expected tampered payload checksum rejection")
        } catch let error as SyncProtocolError {
            guard case .checksumMismatch = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let unknownKind = text.replacingOccurrences(of: "\"kind\":\"favorite\"", with: "\"kind\":\"future\"")
        do {
            _ = try SyncOperationFile.decode(Data(unknownKind.utf8))
            Issue.record("Expected unknown payload kind rejection")
        } catch let error as SyncProtocolError {
            guard case .malformedFile = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func wireRejectsOversizeAndNonCanonicalFileNames() throws {
        let oversized = Data(repeating: 0, count: SyncWireProtocol.maxOperationFileBytes + 1)
        do {
            _ = try SyncOperationFile.decode(oversized)
            Issue.record("Expected oversize rejection")
        } catch let error as SyncProtocolError {
            #expect(
                error == .fileTooLarge(
                    found: oversized.count,
                    limit: SyncWireProtocol.maxOperationFileBytes
                )
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let operation = SyncFixture.favorite("img-a", isFavorite: true, device: .deviceA, sequence: 1)
        let file = SyncOperationFile(operation: operation)
        let data = try file.encoded()
        #expect(SyncOperationFile.parseFileName("../evil.json") == nil)
        #expect(SyncOperationFile.parseFileName("device-a.not-a-digest.json") == nil)

        do {
            _ = try SyncOperationFile.decode(data, fileName: "../evil.json")
            Issue.record("Expected file name mismatch")
        } catch let error as SyncProtocolError {
            #expect(error == .fileNameMismatch(expected: file.fileName, found: "../evil.json"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func operationValidationRejectsBadContextAndDuplicates() throws {
        let change = SyncFavoriteChange(wallpaperID: SyncFixture.image("img-a"), isFavorite: true)

        do {
            _ = try SyncOperation(
                deviceID: .deviceA,
                sequence: 2,
                context: SyncFixture.versionVector(["device-a": 1]),
                payload: .favorite(change)
            )
            Issue.record("Expected context mismatch")
        } catch let error as SyncProtocolError {
            #expect(
                error == .operationContextMismatch(
                    device: .deviceA,
                    sequence: 2,
                    contextSequence: 1
                )
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            _ = try SyncOperation(
                deviceID: .deviceA,
                sequence: 0,
                context: SyncFixture.versionVector(["device-a": 1]),
                payload: .favorite(change)
            )
            Issue.record("Expected invalid sequence")
        } catch let error as SyncProtocolError {
            #expect(error == .invalidSequence(0))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            _ = try SyncOperationFactory.favorite(
                wallpaperID: SyncFixture.image("img-a"),
                isFavorite: true,
                deviceID: .deviceA,
                sequence: 2,
                knownContext: SyncFixture.versionVector(["device-a": 2])
            )
            Issue.record("Expected sequence not advanced")
        } catch let error as SyncProtocolError {
            #expect(error == .sequenceNotAdvanced(device: .deviceA, existing: 2, requested: 2))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let asset = SyncFixture.assetReference("img-a")
        do {
            _ = try SyncOperationFactory.assets(
                [asset, asset],
                deviceID: .deviceA,
                sequence: 1,
                knownContext: SyncVersionVector()
            )
            Issue.record("Expected duplicate asset reference")
        } catch let error as SyncProtocolError {
            #expect(error == .duplicateAssetReference(asset.id))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func assetReferencesAreContentAddressedAndPathFree() throws {
        let bytes = Data("asset-bytes".utf8)
        let reference = SyncFixture.assetReference("img-a", data: bytes)
        #expect(reference.isValid)
        #expect(reference.matches(bytes))
        #expect(!reference.matches(Data("other".utf8)))

        let empty = SyncAssetReference(
            wallpaperID: SyncFixture.image("img-a"),
            kind: .original,
            contentSHA256: SyncContentDigest.hashing(Data()),
            byteCount: 0
        )
        #expect(!empty.isValid)

        let wrongMIME = SyncAssetReference(
            wallpaperID: SyncFixture.image("img-a"),
            kind: .original,
            contentSHA256: SyncContentDigest.hashing(bytes),
            byteCount: bytes.count,
            mimeType: "text/html"
        )
        #expect(!wrongMIME.isValid)

        let blobName = SyncAssetBlobNaming.fileName(for: reference.contentSHA256)
        #expect(SyncAssetBlobNaming.digest(fromFileName: blobName) == reference.contentSHA256)
        #expect(SyncAssetBlobNaming.digest(fromFileName: "../../evil") == nil)

        let operation = SyncFixture.assetsOperation(
            [reference],
            device: .deviceA,
            sequence: 1
        )
        let text = String(decoding: try SyncOperationFile(operation: operation).encoded(), as: UTF8.self)
        #expect(!text.contains("\"relativePath\""))
        #expect(!text.contains("\"localPath\""))
        #expect(!text.contains("\"fileURL\""))
    }
}
