import Env
import Foundation
import Models
import Network
import SwiftUI

@MainActor
@Observable public class StatusDetailViewModel {
  public var statusId: String?
  public var remoteStatusURL: URL?

  var client: Client?
  var routerPath: RouterPath?

  enum State {
    case loading, display(statuses: [StatusLike]), error(error: Error)
  }

  var state: State = .loading
  var title: LocalizedStringKey = ""
  var scrollToId: String?
  var scrollForUser = false

  @ObservationIgnored
  var indentationLevelPreviousCache: [String: UInt] = [:]
  @ObservationIgnored
  var jumpsUp: [String: Bool] = [:]

  init(statusId: String) {
    state = .loading
    self.statusId = statusId
    remoteStatusURL = nil
  }

  init(status: Status) {
    state = .display(statuses: [StatusHolder(baseStatus: status)])
    title = "status.post-from-\(status.account.displayNameWithoutEmojis)"
    statusId = status.id
    remoteStatusURL = nil
    if status.inReplyToId != nil {
      indentationLevelPreviousCache[status.id] = 1
    }
  }

  init(remoteStatusURL: URL) {
    state = .loading
    self.remoteStatusURL = remoteStatusURL
    statusId = nil
  }

  func fetch() async -> Bool {
    if statusId != nil {
      await fetchStatusDetail(animate: false)
      return true
    } else if remoteStatusURL != nil {
      return await fetchRemoteStatus()
    }
    return false
  }

  private func fetchRemoteStatus() async -> Bool {
    guard let client, let remoteStatusURL else { return false }
    let results: SearchResults? = try? await client.get(endpoint: Search.search(query: remoteStatusURL.absoluteString,
                                                                                type: "statuses",
                                                                                offset: nil,
                                                                                following: nil),
                                                        forceVersion: .v2)
    if let statusId = results?.statuses.first?.id {
      self.statusId = statusId
      await fetchStatusDetail(animate: false)
      return true
    } else {
      return false
    }
  }

  struct ContextData {
    let status: Status
    let context: StatusContext
  }

  private func fetchStatusDetail(animate: Bool) async {
    guard let client, let statusId else { return }
    do {
      let data = try await fetchContextData(client: client, statusId: statusId)
      title = "status.post-from-\(data.status.account.displayNameWithoutEmojis)"
      var statuses = data.context.ancestors
      statuses.append(data.status)
      statuses.append(contentsOf: data.context.descendants)
      cacheReplyTopPrevious(statuses: statuses)
      StatusDataControllerProvider.shared.updateDataControllers(for: statuses, client: client)

      if animate {
        withAnimation {
          state = .display(statuses: statuses.map{StatusHolder(baseStatus: $0)})
        }
      } else {
        state = .display(statuses: statuses.map{StatusHolder(baseStatus: $0)})
        let statusHolder = StatusHolder(baseStatus: data.status)
        scrollForUser = false
        scrollToId = statusHolder.scrollID
      }
    } catch {
      if let error = error as? ServerError, error.httpCode == 404 {
        _ = routerPath?.path.popLast()
      } else {
        state = .error(error: error)
      }
    }
  }

  private func fetchContextData(client: Client, statusId: String) async throws -> ContextData {
    async let status: Status = client.get(endpoint: Statuses.status(id: statusId))
    async let context: StatusContext = client.get(endpoint: Statuses.context(id: statusId))
    return try await .init(status: status, context: context)
  }

  private func cacheReplyTopPrevious(statuses: [Status]) {
    indentationLevelPreviousCache = [:]
    var lastValue = UInt(0)
    for status in statuses {
      jumpsUp[status.id] = false
      if let inReplyToId = status.inReplyToId,
         let prevIndent = indentationLevelPreviousCache[inReplyToId]
      {
        let nextValue = prevIndent + 1
        if lastValue > nextValue {
          jumpsUp[status.id] = true
        }
        indentationLevelPreviousCache[status.id] = nextValue
        lastValue = nextValue
      } else {
        indentationLevelPreviousCache[status.id] = 0
        lastValue = 0
      }
    }
  }

  func handleEvent(event: any StreamEvent, currentAccount: Account?) {
    Task {
      if let event = event as? StreamEventUpdate,
         event.status.account.id == currentAccount?.id
      {
        await fetchStatusDetail(animate: true)
      } else if let event = event as? StreamEventStatusUpdate,
                event.status.account.id == currentAccount?.id
      {
        await fetchStatusDetail(animate: true)
      } else if event is StreamEventDelete {
        await fetchStatusDetail(animate: true)
      }
    }
  }

  func getIndentationLevel(id: String, maxIndent: UInt) -> (indentationLevel: UInt, extraInset: Double, jumpUp: Bool) {
    let level = min(indentationLevelPreviousCache[id] ?? 0, maxIndent)
    let jumpUp = jumpsUp[id] ?? false

    let barSize = Double(level) * 2
    let spaceBetween = (Double(level) - 1) * 3
    let size = barSize + spaceBetween + 8

    return (level, size, jumpUp)
  }
  
  func removeStatuses(after beginStatus: String, to endStatus: String) {
    let statusList: [StatusLike]
    switch state {
      case let .display(statuses):
        statusList = statuses
      default:
        return
    }
    
    let baseIndex = statusList.firstIndex { status in
      status.id == beginStatus
    }
    let endIndex = statusList.firstIndex { status in
      status.id == endStatus
    }
    if let baseIndex,
       let endIndex,
       baseIndex + 1 < endIndex
    {
      let firstIncluded = statusList[baseIndex + 1].baseStatus
      var newStatus = NoStatus(baseStatus: firstIncluded, detailViewModel: self)
      
      var statusListCopy = statusList
      for index in baseIndex + 1 ..< endIndex {
        let status = statusList[index]
        if let noStatus = status as? NoStatus,
               noStatus.baseStatus.id == beginStatus {
          newStatus.addStatusToIncluded(contentsOf: noStatus.includedStatuses)
        } else {
          newStatus.addStatusToIncluded(status)
        }
        
        statusListCopy.remove(at: baseIndex + 1)
      }
  
      statusListCopy.insert(newStatus, at: baseIndex + 1)
      withAnimation {
        state = .display(statuses: statusListCopy)
      }
    }
  }
  
  func reloadAllStatuses(replacement: [StatusLike]) {
    var statusList: [StatusLike]
    switch state {
      case let .display(statuses):
        statusList = statuses
      default:
        return
    }
    guard let first = replacement.first,
          let beginIndex = statusList.firstIndex(where: {first.id == $0.id}) else {return}
    let afterIndex = statusList.index(after: beginIndex)
    
    if afterIndex != beginIndex {
      let after = statusList[afterIndex]
      scrollForUser = true
      scrollToId = after.scrollID
    }
    
    statusList.remove(at: beginIndex)
    statusList.insert(contentsOf: replacement, at: beginIndex)
    
    withAnimation {
      state = .display(statuses: statusList)
    }
  }
}
