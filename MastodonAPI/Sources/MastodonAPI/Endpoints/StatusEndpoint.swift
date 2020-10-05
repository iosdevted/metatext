// Copyright © 2020 Metabolist. All rights reserved.

import Foundation
import HTTP
import Mastodon

public enum StatusEndpoint {
    case status(id: Status.Id)
    case favourite(id: Status.Id)
    case unfavourite(id: Status.Id)
}

extension StatusEndpoint: Endpoint {
    public typealias ResultType = Status

    public var context: [String] {
        defaultContext + ["statuses"]
    }

    public var pathComponentsInContext: [String] {
        switch self {
        case let .status(id):
            return [id]
        case let .favourite(id):
            return [id, "favourite"]
        case let .unfavourite(id):
            return [id, "unfavourite"]
        }
    }

    public var method: HTTPMethod {
        switch self {
        case .status:
            return .get
        case .favourite, .unfavourite:
            return .post
        }
    }
}
