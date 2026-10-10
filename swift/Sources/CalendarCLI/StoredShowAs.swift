import Foundation

// The availability macOS keeps for an item of a subscribed calendar (its Microsoft
// show-as, else the stored column), read from the local Calendar store when EventKit
// reports `notSupported` for it.
//
// EventKit exposes no availability for ICS subscriptions, but macOS preserves each item's
// extra iCalendar properties in `CalendarItem.external_rep`: a keyed archive whose
// `iCalExtraProperties` entry is a second keyed archive of
// `CalItemMetadata.CalXProps[name] -> [ICSMultiValueProperty].Value -> [String]`.
// Those are private classes, so the archive is walked as plist data and nothing in it is
// ever instantiated. Every size and shape is checked; anything unexpected is "no answer",
// never a guess.

enum StoredShowAs {
    /// Largest `external_rep` (and nested archive) parsed. Observed rows are a few KB.
    static let maxArchiveBytes = 64 * 1024
    /// Largest `$objects` table walked in either archive. Observed tables hold about 60.
    static let maxObjects = 4096

    /// The show-as, in precedence order. MS-OXCICAL treats the MSNCALENDAR form as a
    /// synonym of the CDO one on import.
    private static let busyStatusProperties = ["X-MICROSOFT-CDO-BUSYSTATUS", "X-MICROSOFT-MSNCALENDAR-BUSYSTATUS"]

    /// Microsoft's published ICS show-as values, mapped onto EventKit's names. Any other
    /// value (WORKINGELSEWHERE, or one added later) has no EventKit equivalent here.
    private static let showAsToAvailability: [String: String] = [
        "FREE": "free",
        "TENTATIVE": "tentative",
        "BUSY": "busy",
        "OOF": "unavailable",
    ]

    /// The item's availability from what the store holds, or nil when it holds nothing
    /// usable (the caller then keeps EventKit's value).
    ///
    /// First, the first Microsoft show-as, in `busyStatusProperties` order, with a listed value.
    /// Otherwise, the stored `availability` column, which is binary for subscriptions.
    static func resolve(column: Int64?, externalRep: Data?) -> String? {
        let showAs = externalRep.map { busyStatuses(externalRep: $0) } ?? []
        if let mapped = showAs.lazy.compactMap({ showAsToAvailability[$0] }).first {
            return mapped
        }
        return availability(column: column)
    }

    /// `CalendarItem.availability` as stored for subscribed items: 0 busy, 1 free.
    static func availability(column: Int64?) -> String? {
        switch column {
        case 0: return "busy"
        case 1: return "free"
        default: return nil
        }
    }

    /// The raw show-as values present, in `busyStatusProperties` order; empty if none is
    /// present or the archive is not readable.
    static func busyStatuses(externalRep: Data) -> [String] {
        guard let outer = KeyedArchive(externalRep),
              let entries = outer.dictionary(outer.root),
              let payload = outer.object(entries["iCalExtraProperties"]),
              let innerData = outer.data(payload),
              let inner = KeyedArchive(innerData),
              let metadata = inner.root as? [String: Any],
              let xprops = inner.dictionary(inner.object(metadata["CalXProps"]))
        else { return [] }
        return busyStatusProperties.compactMap { name in
            guard let properties = inner.array(inner.object(xprops[name])),
                  let property = inner.object(properties.first) as? [String: Any],
                  let values = inner.array(inner.object(property["Value"]))
            else { return nil }
            return inner.object(values.first) as? String
        }
    }
}

/// A bounded, read-only view of an NSKeyedArchiver plist. Objects are dereferenced by UID
/// index into `$objects`; no class named in the archive is looked up or instantiated.
private struct KeyedArchive {
    let objects: [Any]
    let root: Any?

    init?(_ data: Data) {
        guard data.count <= StoredShowAs.maxArchiveBytes,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let top = plist as? [String: Any],
              top["$archiver"] as? String == "NSKeyedArchiver",
              let objects = top["$objects"] as? [Any],
              objects.count <= StoredShowAs.maxObjects,
              let rootRef = (top["$top"] as? [String: Any])?["root"]
        else { return nil }
        self.objects = objects
        guard let index = keyedArchiveUID(rootRef), index > 0, index < objects.count else { return nil }
        root = objects[index]
    }

    /// The object a UID reference points at; nil for `$null`, a non-UID, or out of range.
    func object(_ ref: Any?) -> Any? {
        guard let ref, let index = keyedArchiveUID(ref), index > 0, index < objects.count else {
            return nil
        }
        return objects[index]
    }

    /// An archived NSDictionary as `[key: value reference]`, keys dereferenced.
    func dictionary(_ object: Any?) -> [String: Any]? {
        guard let dict = object as? [String: Any],
              let keys = dict["NS.keys"] as? [Any],
              let values = dict["NS.objects"] as? [Any],
              keys.count == values.count
        else { return nil }
        var result: [String: Any] = [:]
        for (key, value) in zip(keys, values) {
            guard let name = self.object(key) as? String else { return nil }
            result[name] = value
        }
        return result
    }

    /// An archived NSArray's element references.
    func array(_ object: Any?) -> [Any]? {
        (object as? [String: Any])?["NS.objects"] as? [Any]
    }

    /// NSData archives inline as raw data; NSMutableData as `{NS.data: ...}`.
    func data(_ object: Any) -> Data? {
        if let raw = object as? Data { return raw }
        return (object as? [String: Any])?["NS.data"] as? Data
    }
}

/// The CF type of a keyed-archive UID, taken from one PropertyListSerialization parses.
private let keyedArchiveUIDTypeID: CFTypeID = {
    let xml = "<plist version=\"1.0\"><dict><key>CF$UID</key><integer>0</integer></dict></plist>"
    let sample = try? PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil)
    return sample.map { CFGetTypeID($0 as AnyObject) } ?? 0
}()

private let uidXMLPattern = try! NSRegularExpression(
    pattern: #"<key>CF\$UID</key>\s*<integer>(\d+)</integer>"#)

/// The index a keyed-archive UID holds, or nil if `value` is not one.
///
/// Foundation decodes a UID to an opaque CF object with no public accessor. Its XML plist
/// form is the documented `{CF$UID: n}` dictionary, so the index is read from there.
private func keyedArchiveUID(_ value: Any) -> Int? {
    guard keyedArchiveUIDTypeID != 0,
          CFGetTypeID(value as AnyObject) == keyedArchiveUIDTypeID,
          let xml = try? PropertyListSerialization.data(fromPropertyList: [value], format: .xml, options: 0),
          let text = String(data: xml, encoding: .utf8),
          let match = uidXMLPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return Int(text[range])
}
