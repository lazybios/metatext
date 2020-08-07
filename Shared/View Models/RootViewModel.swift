// Copyright © 2020 Metabolist. All rights reserved.

import Foundation
import Combine

class RootViewModel: ObservableObject {
    @Published private(set) var identityID: String?
    private let environment: AppEnvironment
    private var cancellables = Set<AnyCancellable>()

    init(environment: AppEnvironment) {
        self.environment = environment
        identityID = environment.identityDatabase.mostRecentlyUsedIdentityID
    }
}

extension RootViewModel {
    func newIdentitySelected(id: String) {
        identityID = id
    }

    func addIdentityViewModel() -> AddIdentityViewModel {
        AddIdentityViewModel(environment: environment)
    }

    func mainNavigationViewModel(identityID: String) -> MainNavigationViewModel? {
        let identifiedEnvironment: IdentifiedEnvironment

        do {
            identifiedEnvironment = try IdentifiedEnvironment(identityID: identityID, appEnvironment: environment)
        } catch {
            return nil
        }

        identifiedEnvironment.observationErrors
            .receive(on: RunLoop.main)
            .map { [weak self] _ in self?.environment.identityDatabase.mostRecentlyUsedIdentityID }
            .assign(to: &$identityID)

        return MainNavigationViewModel(environment: identifiedEnvironment)
    }
}
