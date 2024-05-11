import SwiftUI
import Models

protocol StatusLike {
    @MainActor
    func getView(viewModel: StatusRowViewModel) -> any View
    var baseStatus: Status { get }
}

extension StatusLike {
    var id: String {
        baseStatus.id
    }
    var scrollID: String {
        return id + (baseStatus.editedAt?.asDate.description ?? "")
    }
}

struct StatusHolder: StatusLike {@MainActor
    func getView(viewModel: StatusRowViewModel) -> any View {
        return StatusRowView(viewModel: viewModel, context: .detail)
    }
    
    let baseStatus: Status
}

struct NoStatus: StatusLike {
    var baseStatus: Status
    private (set) var count = 0
    private (set) var includedStatuses: [StatusLike] = []
    var detailViewModel: StatusDetailViewModel
    
    mutating func addStatusToIncluded(_ status: any StatusLike) {
        includedStatuses.append(status)
        if let status = status as? NoStatus {
            count += status.count
        } else {
            count += 1
        }
    }
    
    mutating func addStatusToIncluded(contentsOf statusList: [any StatusLike]) {
        includedStatuses.append(contentsOf: statusList)
        for status in statusList {
            if let status = status as? NoStatus {
                count += status.count
            } else {
                count += 1
            }
        }
    }
    
    @MainActor
    func getView(viewModel: StatusRowViewModel) -> any View {
        Text("Count: \(count)")
            .onTapGesture {
                detailViewModel.reloadAllStatuses(replacement: includedStatuses)
            }
    }
}
