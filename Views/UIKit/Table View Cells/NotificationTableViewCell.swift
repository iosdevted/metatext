// Copyright © 2020 Metabolist. All rights reserved.

import UIKit
import ViewModels

final class NotificationTableViewCell: UITableViewCell {
    var viewModel: NotificationViewModel?

    override func updateConfiguration(using state: UICellConfigurationState) {
        guard let viewModel = viewModel else { return }

        contentConfiguration = NotificationContentConfiguration(viewModel: viewModel).updated(for: state)
        accessibilityElements = [contentView]
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        if UIDevice.current.userInterfaceIdiom == .phone {
            separatorInset.left = 0
            separatorInset.right = 0
        } else {
            separatorInset.left = layoutMargins.left
            separatorInset.right = layoutMargins.right
        }
    }
}
