import Foundation

/// 서지 정보로 논문을 넣은 결과(식별자로 추가). 같은 논문이 이미 있으면 새로 만들지 않고,
/// 사이드바에서 고른 컬렉션과 'Allow references' 설정에 따라 그 항목을 참조로 넣거나 그대로 둔다.
public enum AddOutcome: Equatable {
    /// 새 항목을 만들었다.
    case added
    /// 이미 있고, 컬렉션을 고르지 않았다(All Items 등). 바꾸지 않았다.
    case alreadyInLibrary
    /// 이미 고른 컬렉션에 들어 있다. 바꾸지 않았다.
    case alreadyInCollection
    /// 이미 있던 항목을 고른 컬렉션에 참조로 넣었다.
    case addedReference
    /// 참조가 꺼져 있어(논문은 한 컬렉션에만 속한다) 넣지 않았다. 지금 든 컬렉션들(비면 Unfiled).
    case referencesOff(in: Set<Int64>)

    /// 이미 있는 항목(지금 든 컬렉션 collectionIDs)을 selected 컬렉션에 넣으려 할 때 할 일.
    /// 참조가 꺼져 있으면 ⌥ 끌기·Add Reference to처럼 참조를 만들지 않는다. 옮기기(PDF 폴더까지 바뀐다)도 하지 않고 알리기만 한다.
    public static func existing(in collectionIDs: Set<Int64>, selected: Int64?, allowReferences: Bool) -> AddOutcome {
        guard let selected else { return .alreadyInLibrary }
        if collectionIDs.contains(selected) { return .alreadyInCollection }
        return allowReferences ? .addedReference : .referencesOff(in: collectionIDs)
    }

    /// 여러 개를 넣은 뒤 보일 요약. collection은 고른 컬렉션 이름, name은 컬렉션 id → 이름.
    public static func summary(_ outcomes: [AddOutcome], collection: String?, name: (Int64) -> String?) -> String {
        let single = outcomes.count == 1
        let here = collection ?? "the collection"
        var parts: [String] = []
        func count(_ n: Int, _ one: String, _ many: String) {
            guard n > 0 else { return }
            parts.append(single ? one : "\(n) " + (n == 1 ? one.prefix(1).lowercased() + one.dropFirst() : many))
        }
        let added = outcomes.filter { $0 == .added }.count
        if added > 0 { parts.append("Added \(added) paper\(added == 1 ? "" : "s").") }
        count(outcomes.filter { $0 == .addedReference }.count,
              "Added to \(here) as a reference.", "added to \(here) as references.")
        count(outcomes.filter { $0 == .alreadyInCollection }.count, "Already in \(here).", "already in \(here).")
        count(outcomes.filter { $0 == .alreadyInLibrary }.count, "Already in the library.", "already in the library.")

        var homes: [String] = [], off = 0
        for case .referencesOff(let ids) in outcomes {
            off += 1
            let names = ids.compactMap(name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for n in names.isEmpty ? ["Unfiled"] : names where !homes.contains(n) { homes.append(n) }
        }
        if off > 0 {
            let place = " (in \(homes.joined(separator: ", ")))."
            count(off, "Already in the library" + place, "already in the library" + place)
            parts.append("Turn on Allow references in Settings to add \(off == 1 ? "it" : "them") to \(here) too.")
        }
        return parts.joined(separator: " ")
    }
}

extension Library {
    /// 이미 있는 항목 id를 selected 컬렉션에 맞춘다. 참조로 넣을 때만 DB를 고친다(Workspace.addReferences와 같이 소속만 더한다).
    public func placeExisting(_ id: Int64, in selected: Int64?, allowReferences: Bool) throws -> AddOutcome {
        let outcome = AddOutcome.existing(in: try item(id)?.collectionIDs ?? [], selected: selected, allowReferences: allowReferences)
        if outcome == .addedReference, let selected { try moveItem(id, from: nil, to: selected) }
        return outcome
    }
}
