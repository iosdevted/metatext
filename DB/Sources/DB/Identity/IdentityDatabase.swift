// Copyright © 2020 Metabolist. All rights reserved.

import Combine
import Foundation
import GRDB
import Keychain
import Mastodon
import Secrets

public enum IdentityDatabaseError: Error {
    case identityNotFound
}

public struct IdentityDatabase {
    private let databaseWriter: DatabaseWriter

    public init(inMemory: Bool, appGroup: String, keychain: Keychain.Type) throws {
        if inMemory {
            databaseWriter = DatabaseQueue()
            try Self.migrator.migrate(databaseWriter)
        } else {
            let url = try FileManager.default.databaseDirectoryURL(
                name: Secrets.identityDatabaseName(keychain: keychain),
                appGroup: appGroup)

            databaseWriter = try DatabasePool.withFileCoordinator(url: url, migrator: Self.migrator) {
                try Secrets.databaseKey(identityId: nil, keychain: keychain)
            }
        }
    }
}

public extension IdentityDatabase {
    func createIdentity(id: Identity.Id, url: URL, authenticated: Bool, pending: Bool) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher(
            updates: IdentityRecord(
                id: id,
                url: url,
                authenticated: authenticated,
                pending: pending,
                lastUsedAt: Date(),
                preferences: Identity.Preferences(),
                instanceURI: nil,
                lastRegisteredDeviceToken: nil,
                pushSubscriptionAlerts: .initial)
                .save)
            .ignoreOutput()
            .eraseToAnyPublisher()
    }

    func deleteIdentity(id: Identity.Id) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher(updates: IdentityRecord.filter(IdentityRecord.Columns.id == id).deleteAll)
            .ignoreOutput()
            .eraseToAnyPublisher()
    }

    func updateLastUsedAt(id: Identity.Id) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher {
            try IdentityRecord
                .filter(IdentityRecord.Columns.id == id)
                .updateAll($0, IdentityRecord.Columns.lastUsedAt.set(to: Date()))
        }
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func updateInstance(_ instance: Instance, id: Identity.Id) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher {
            try Identity.Instance(
                uri: instance.uri,
                streamingAPI: instance.urls.streamingApi,
                title: instance.title,
                thumbnail: instance.thumbnail,
                version: instance.version,
                maxTootChars: instance.maxTootChars)
                .save($0)
            try IdentityRecord
                .filter(IdentityRecord.Columns.id == id)
                .updateAll($0, IdentityRecord.Columns.instanceURI.set(to: instance.uri))
        }
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func updateAccount(_ account: Account, id: Identity.Id) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher(
            updates: Identity.Account(
                id: account.id,
                identityId: id,
                username: account.username,
                displayName: account.displayName,
                url: account.url,
                avatar: account.avatar,
                avatarStatic: account.avatarStatic,
                header: account.header,
                headerStatic: account.headerStatic,
                emojis: account.emojis,
                followRequestCount: account.source?.followRequestsCount ?? 0)
                .save)
            .ignoreOutput()
            .eraseToAnyPublisher()
    }

    func confirmIdentity(id: Identity.Id) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher {
            try IdentityRecord
                .filter(IdentityRecord.Columns.id == id)
                .updateAll($0, IdentityRecord.Columns.pending.set(to: false))
        }
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func updatePreferences(_ preferences: Mastodon.Preferences, id: Identity.Id) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher {
            guard let storedPreferences = try IdentityRecord.filter(IdentityRecord.Columns.id == id)
                    .fetchOne($0)?
                    .preferences else {
                throw IdentityDatabaseError.identityNotFound
            }

            try Self.writePreferences(storedPreferences.updated(from: preferences), id: id)($0)
        }
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func updatePreferences(_ preferences: Identity.Preferences, id: Identity.Id) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher(updates: Self.writePreferences(preferences, id: id))
            .ignoreOutput()
            .eraseToAnyPublisher()
    }

    func updatePushSubscription(alerts: PushSubscription.Alerts,
                                deviceToken: Data? = nil,
                                id: Identity.Id) -> AnyPublisher<Never, Error> {
        databaseWriter.writePublisher {
            let data = try IdentityRecord.databaseJSONEncoder(
                for: IdentityRecord.Columns.pushSubscriptionAlerts.name)
                .encode(alerts)

            try IdentityRecord
                .filter(IdentityRecord.Columns.id == id)
                .updateAll($0, IdentityRecord.Columns.pushSubscriptionAlerts.set(to: data))

            if let deviceToken = deviceToken {
                try IdentityRecord
                    .filter(IdentityRecord.Columns.id == id)
                    .updateAll($0, IdentityRecord.Columns.lastRegisteredDeviceToken.set(to: deviceToken))
            }
        }
        .ignoreOutput()
        .eraseToAnyPublisher()
    }

    func identityPublisher(id: Identity.Id, immediate: Bool) -> AnyPublisher<Identity, Error> {
        ValueObservation.tracking(
            IdentityInfo.request(IdentityRecord.filter(IdentityRecord.Columns.id == id)).fetchOne)
            .removeDuplicates()
            .publisher(in: databaseWriter, scheduling: immediate ? .immediate : .async(onQueue: .main))
            .tryMap {
                guard let info = $0 else { throw IdentityDatabaseError.identityNotFound }

                return Identity(info: info)
            }
            .eraseToAnyPublisher()
    }

    func identitiesPublisher() -> AnyPublisher<[Identity], Error> {
        ValueObservation.tracking(
            IdentityInfo.request(IdentityRecord.order(IdentityRecord.Columns.lastUsedAt.desc)).fetchAll)
            .removeDuplicates()
            .publisher(in: databaseWriter)
            .map { $0.map(Identity.init(info:)) }
            .eraseToAnyPublisher()
    }

    func recentIdentitiesPublisher(excluding: Identity.Id) -> AnyPublisher<[Identity], Error> {
        ValueObservation.tracking(
            IdentityInfo.request(IdentityRecord.order(IdentityRecord.Columns.lastUsedAt.desc))
                .filter(IdentityRecord.Columns.id != excluding)
                .limit(9)
                .fetchAll)
            .removeDuplicates()
            .publisher(in: databaseWriter)
            .map { $0.map(Identity.init(info:)) }
            .eraseToAnyPublisher()
    }

    func authenticatedIdentitiesPublisher() -> AnyPublisher<[Identity], Error> {
        ValueObservation.tracking(
            IdentityInfo.request(IdentityRecord.order(IdentityRecord.Columns.lastUsedAt.desc))
                .filter(IdentityRecord.Columns.authenticated == true && IdentityRecord.Columns.pending == false)
                .fetchAll)
            .removeDuplicates()
            .publisher(in: databaseWriter)
            .map { $0.map(Identity.init(info:)) }
            .eraseToAnyPublisher()
    }

    func immediateMostRecentlyUsedIdentityIdPublisher() -> AnyPublisher<Identity.Id?, Error> {
        ValueObservation.tracking(
            IdentityRecord.select(IdentityRecord.Columns.id)
                .order(IdentityRecord.Columns.lastUsedAt.desc).fetchOne)
            .removeDuplicates()
            .publisher(in: databaseWriter, scheduling: .immediate)
            .eraseToAnyPublisher()
    }

    func fetchIdentitiesWithOutdatedDeviceTokens(deviceToken: Data) -> AnyPublisher<[Identity], Error> {
        databaseWriter.readPublisher(
            value: IdentityInfo.request(IdentityRecord.order(IdentityRecord.Columns.lastUsedAt.desc))
                .filter(IdentityRecord.Columns.authenticated == true
                            && IdentityRecord.Columns.pending == false
                            && IdentityRecord.Columns.lastRegisteredDeviceToken != deviceToken)
                .fetchAll)
            .map { $0.map(Identity.init(info:)) }
            .eraseToAnyPublisher()
    }

    func mostRecentAuthenticatedIdentity() throws -> Identity? {
        guard let info = try databaseWriter.read(
                IdentityInfo.request(IdentityRecord.order(IdentityRecord.Columns.lastUsedAt.desc))
                    .filter(IdentityRecord.Columns.authenticated == true
                                && IdentityRecord.Columns.pending == false)
                    .fetchOne)
        else { return nil }

        return Identity(info: info)
    }

    // Only for use in notification extension
    func identity(id: Identity.Id) throws -> Identity? {
        guard let info = try databaseWriter.read(
                IdentityInfo.request(IdentityRecord.filter(IdentityRecord.Columns.id == id))
                    .fetchOne)
        else { return nil }

        return Identity(info: info)
    }
}

private extension IdentityDatabase {
    static func writePreferences(_ preferences: Identity.Preferences, id: Identity.Id) -> (Database) throws -> Void {
        {
            let data = try IdentityRecord.databaseJSONEncoder(
                for: IdentityRecord.Columns.preferences.name).encode(preferences)

            try IdentityRecord
                .filter(IdentityRecord.Columns.id == id)
                .updateAll($0, IdentityRecord.Columns.preferences.set(to: data))
        }
    }
}
