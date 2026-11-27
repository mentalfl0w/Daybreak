import Testing
@testable import Daybreak

struct StoragePaginationTests {
    @Test func emptyListHasNoPages() {
        let pagination = StoragePagination(totalCount: 0)

        #expect(pagination.pageCount == 0)
        #expect(pagination.pageIndex == 0)
        #expect(pagination.range.isEmpty)
        #expect(!pagination.canGoPrevious)
        #expect(!pagination.canGoNext)
    }

    @Test func pagesCoverTheListWithoutOverlap() {
        let pagination = StoragePagination(totalCount: 45, pageSize: 20)

        #expect(pagination.pageCount == 3)
        #expect(StoragePagination(totalCount: 45, pageSize: 20, requestedPageIndex: 0).range == 0..<20)
        #expect(StoragePagination(totalCount: 45, pageSize: 20, requestedPageIndex: 1).range == 20..<40)
        #expect(StoragePagination(totalCount: 45, pageSize: 20, requestedPageIndex: 2).range == 40..<45)

        #expect(StoragePagination(totalCount: 45, pageSize: 20, requestedPageIndex: 0).canGoPrevious == false)
        #expect(StoragePagination(totalCount: 45, pageSize: 20, requestedPageIndex: 0).canGoNext == true)
        #expect(StoragePagination(totalCount: 45, pageSize: 20, requestedPageIndex: 2).canGoPrevious == true)
        #expect(StoragePagination(totalCount: 45, pageSize: 20, requestedPageIndex: 2).canGoNext == false)
    }

    @Test func defaultPageSizePaginatesEachKindIndependentlyAndClampsAfterRefresh() {
        #expect(StoragePagination.defaultPageSize == 6)

        let originals = StoragePagination(totalCount: 8, requestedPageIndex: 1)
        let thumbnails = StoragePagination(totalCount: 9, requestedPageIndex: 1)
        #expect(originals.pageCount == 2)
        #expect(originals.range == 6..<8)
        #expect(thumbnails.pageCount == 2)
        #expect(thumbnails.range == 6..<9)

        let refreshedOriginals = StoragePagination(
            totalCount: 5,
            requestedPageIndex: originals.pageIndex
        )
        #expect(refreshedOriginals.pageIndex == 0)
        #expect(refreshedOriginals.range == 0..<5)
        #expect(thumbnails.pageIndex == 1)
    }

    @Test func exactlyOneFullPageHasNoTrailingEmptyPage() {
        let pagination = StoragePagination(totalCount: 20, pageSize: 20)

        #expect(pagination.pageCount == 1)
        #expect(pagination.range == 0..<20)
        #expect(!pagination.canGoPrevious)
        #expect(!pagination.canGoNext)
    }

    @Test func deletingTheOnlyRowOnTheLastPageClampsToThePreviousPage() {
        let beforeDeletion = StoragePagination(
            totalCount: 41,
            pageSize: 20,
            requestedPageIndex: 2
        )
        #expect(beforeDeletion.pageCount == 3)
        #expect(beforeDeletion.range == 40..<41)
        #expect(beforeDeletion.canGoNext == false)

        let afterDeletion = StoragePagination(
            totalCount: 40,
            pageSize: 20,
            requestedPageIndex: 2
        )
        #expect(afterDeletion.pageCount == 2)
        #expect(afterDeletion.pageIndex == 1)
        #expect(afterDeletion.range == 20..<40)
        #expect(afterDeletion.canGoPrevious == true)
        #expect(afterDeletion.canGoNext == false)
    }

    @Test func requestedPageIsClampedToTheAvailableRange() {
        #expect(StoragePagination(totalCount: 5, pageSize: 20, requestedPageIndex: 9).pageIndex == 0)
        #expect(StoragePagination(totalCount: 5, pageSize: 20, requestedPageIndex: -3).pageIndex == 0)
        #expect(StoragePagination(totalCount: 5, pageSize: 20, requestedPageIndex: 9).range == 0..<5)
    }

    @Test func invalidCountsAndPageSizeNormalize() {
        #expect(StoragePagination(totalCount: -4).pageCount == 0)
        #expect(StoragePagination(totalCount: -4).range.isEmpty)

        let singleItemPages = StoragePagination(totalCount: 3, pageSize: 0)
        #expect(singleItemPages.pageSize == 1)
        #expect(singleItemPages.pageCount == 3)
        #expect(singleItemPages.range == 0..<1)
    }
}
