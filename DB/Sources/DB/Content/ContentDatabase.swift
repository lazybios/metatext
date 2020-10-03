// Copyright © 2020 Metabolist. All rights reserved.

import Combine
import Foundation
import GRDB
import Keychain
import Mastodon
import Secrets

public struct ContentDatabase {
    private let databaseWriter: DatabaseWriter

    public init(identityID: UUID, inMemory: Bool, keychain: Keychain.Type) throws {
        if inMemory {
            databaseWriter = DatabaseQueue()
        } else {
            let path = try Self.fileURL(identityID: identityID).path
            var configuration = Configuration()

            configuration.prepareDatabase {
                try $0.usePassphrase(Secrets.databaseKey(identityID: identityID, keychain: keychain))
            }

            databaseWriter = try DatabasePool(path: path, configuration: configuration)
        }

        try migrator.migrate(databaseWriter)
        try clean()
    }
}

public extension ContentDatabase {
    static func delete(forIdentityID identityID: UUID) throws {
        try FileManager.default.removeItem(at: fileURL(identityID: identityID))
    }

    func insert(status: Status) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher(updates: status.save)
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func insert(statuses: [Status], timeline: Timeline) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher {
            let timelineRecord = TimelineRecord(timeline: timeline)

            try timelineRecord.save($0)

            let maxIDPresent = try String.fetchOne($0, timelineRecord.statuses.select(max(StatusRecord.Columns.id)))

            for status in statuses {
                try status.save($0)

                try TimelineStatusJoin(timelineId: timeline.id, statusId: status.id).save($0)
            }

            if let maxIDPresent = maxIDPresent,
               let minIDInserted = statuses.map(\.id).min(),
               minIDInserted > maxIDPresent {
                try LoadMoreRecord(timelineId: timeline.id, afterStatusId: minIDInserted).save($0)
            }
        }
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func insert(context: Context, parentID: String) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher {
            for (index, status) in context.ancestors.enumerated() {
                try status.save($0)
                try StatusAncestorJoin(parentId: parentID, statusId: status.id, index: index).save($0)
            }

            for (index, status) in context.descendants.enumerated() {
                try status.save($0)
                try StatusDescendantJoin(parentId: parentID, statusId: status.id, index: index).save($0)
            }

            try StatusAncestorJoin.filter(
                StatusAncestorJoin.Columns.parentId == parentID
                    && !context.ancestors.map(\.id).contains(StatusAncestorJoin.Columns.statusId))
                .deleteAll($0)

            try StatusDescendantJoin.filter(
                StatusDescendantJoin.Columns.parentId == parentID
                    && !context.descendants.map(\.id).contains(StatusDescendantJoin.Columns.statusId))
                .deleteAll($0)
        }
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func insert(pinnedStatuses: [Status], accountID: String) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher {
            for (index, status) in pinnedStatuses.enumerated() {
                try status.save($0)
                try AccountPinnedStatusJoin(accountId: accountID, statusId: status.id, index: index).save($0)
            }

            try AccountPinnedStatusJoin.filter(
                AccountPinnedStatusJoin.Columns.accountId == accountID
                    && !pinnedStatuses.map(\.id).contains(AccountPinnedStatusJoin.Columns.statusId))
                .deleteAll($0)
        }
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func append(accounts: [Account], toList list: AccountList) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher {
            try list.save($0)

            let count = try list.accounts.fetchCount($0)

            for (index, account) in accounts.enumerated() {
                try account.save($0)
                try AccountListJoin(accountId: account.id, listId: list.id, index: count + index).save($0)
            }
        }
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func setLists(_ lists: [List]) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher {
            for list in lists {
                try TimelineRecord(timeline: Timeline.list(list)).save($0)
            }

            try TimelineRecord
                .filter(!lists.map(\.id).contains(TimelineRecord.Columns.listId)
                            && TimelineRecord.Columns.listTitle != nil)
                .deleteAll($0)
        }
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func createList(_ list: List) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher(updates: TimelineRecord(timeline: Timeline.list(list)).save)
            .ignoreOutput()
            .eraseToAnyPublisher()
    }

    func deleteList(id: String) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher(updates: TimelineRecord.filter(TimelineRecord.Columns.listId == id).deleteAll)
            .ignoreOutput()
            .eraseToAnyPublisher()
    }

    func setFilters(_ filters: [Filter]) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher {
            for filter in filters {
                try filter.save($0)
            }

            try Filter.filter(!filters.map(\.id).contains(Filter.Columns.id)).deleteAll($0)
        }
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func createFilter(_ filter: Filter) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher(updates: filter.save)
            .ignoreOutput()
            .eraseToAnyPublisher()
    }

    func deleteFilter(id: String) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher(updates: Filter.filter(Filter.Columns.id == id).deleteAll)
            .ignoreOutput()
            .eraseToAnyPublisher()
    }

    func observation(timeline: Timeline) -> AnyPublisher<[[Timeline.Item]], Error> {
        ValueObservation.tracking { db -> (TimelineItemsInfo?, [Filter]) in
            (try TimelineItemsInfo.request(
                TimelineRecord.filter(TimelineRecord.Columns.id == timeline.id)).fetchOne(db),
            try Filter.active.fetchAll(db))
        }
        .map { $0?.items(filters: $1) ?? [] }
        .removeDuplicates()
        .publisher(in: databaseWriter)
        .eraseToAnyPublisher()
    }

    func contextObservation(parentID: String) -> AnyPublisher<[[Timeline.Item]], Error> {
        ValueObservation.tracking { db -> (ContextItemsInfo?, [Filter]) in
            (try ContextItemsInfo.request(StatusRecord.filter(StatusRecord.Columns.id == parentID)).fetchOne(db),
            try Filter.active.fetchAll(db))
        }
        .map { $0?.items(filters: $1) ?? [] }
        .removeDuplicates()
        .publisher(in: databaseWriter)
        .eraseToAnyPublisher()
    }

    func listsObservation() -> AnyPublisher<[Timeline], Error> {
        ValueObservation.tracking(TimelineRecord.filter(TimelineRecord.Columns.listId != nil)
                                    .order(TimelineRecord.Columns.listTitle.asc)
                                    .fetchAll)
            .removeDuplicates()
            .publisher(in: databaseWriter)
            .tryMap { $0.map(Timeline.init(record:)).compactMap { $0 } }
            .eraseToAnyPublisher()
    }

    func activeFiltersObservation(date: Date) -> AnyPublisher<[Filter], Error> {
        ValueObservation.tracking(
            Filter.filter(Filter.Columns.expiresAt == nil || Filter.Columns.expiresAt > date).fetchAll)
            .removeDuplicates()
            .publisher(in: databaseWriter)
            .eraseToAnyPublisher()
    }

    func expiredFiltersObservation(date: Date) -> AnyPublisher<[Filter], Error> {
        ValueObservation.tracking(Filter.filter(Filter.Columns.expiresAt < date).fetchAll)
            .removeDuplicates()
            .publisher(in: databaseWriter)
            .eraseToAnyPublisher()
    }

    func accountObservation(id: String) -> AnyPublisher<Account?, Error> {
        ValueObservation.tracking(AccountInfo.request(AccountRecord.filter(AccountRecord.Columns.id == id)).fetchOne)
            .removeDuplicates()
            .map {
                if let info = $0 {
                    return Account(info: info)
                } else {
                    return nil
                }
            }
            .publisher(in: databaseWriter)
            .eraseToAnyPublisher()
    }

    func accountListObservation(_ list: AccountList) -> AnyPublisher<[Account], Error> {
        ValueObservation.tracking(list.accounts.fetchAll)
            .removeDuplicates()
            .map { $0.map(Account.init(info:)) }
            .publisher(in: databaseWriter)
            .eraseToAnyPublisher()
    }
}

private extension ContentDatabase {
    static func fileURL(identityID: UUID) throws -> URL {
        try FileManager.default.databaseDirectoryURL(name: identityID.uuidString)
    }

    func clean() throws {
        try databaseWriter.write {
            try TimelineRecord.deleteAll($0)
            try StatusRecord.deleteAll($0)
            try AccountRecord.deleteAll($0)
            try AccountList.deleteAll($0)
        }
    }
}
