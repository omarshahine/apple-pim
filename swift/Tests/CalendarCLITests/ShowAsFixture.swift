import Foundation

/// Keyed archives synthesized with PropertyListSerialization in the shape macOS writes to
/// `CalendarItem.external_rep`: an outer archive whose `iCalExtraProperties` is a nested
/// archive of `CalItemMetadata.CalXProps`, each property an `ICSMultiValueProperty` whose
/// `Value` is an array of strings. Class names are plain strings; nothing is instantiated.
enum ShowAsFixture {
    /// A real `CF$UID` node. A Swift `["CF$UID": n]` dictionary serializes as an ordinary
    /// dictionary; parsing it from XML is what makes PropertyListSerialization emit a UID.
    static func uid(_ n: Int) -> Any {
        let xml = "<plist version=\"1.0\"><dict><key>CF$UID</key><integer>\(n)</integer></dict></plist>"
        return try! PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil)
    }

    static func plist(_ object: Any) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }

    static func archive(_ objects: [Any]) -> Data {
        plist([
            "$archiver": "NSKeyedArchiver",
            "$version": 100000,
            "$top": ["root": uid(1)],
            "$objects": objects,
        ] as [String: Any])
    }

    static func rep(busyStatus: String, innerAsRawData: Bool = false, innerOverride: Data? = nil,
                     danglingValueUID: Bool = false, valueAsNumber: Bool = false,
                     outerPadding: Int = 0, extraInnerObjects: Int = 0) -> Data {
        rep(properties: [("X-MICROSOFT-CDO-BUSYSTATUS", busyStatus)], innerAsRawData: innerAsRawData,
            innerOverride: innerOverride, danglingValueUID: danglingValueUID,
            valueAsNumber: valueAsNumber, outerPadding: outerPadding,
            extraInnerObjects: extraInnerObjects)
    }

    /// `properties` maps a property name to its single value, or to nil for an empty value list.
    static func rep(properties: [(String, String?)], dedupeStrings: Bool = false,
                     innerAsRawData: Bool = false, innerOverride: Data? = nil,
                     danglingValueUID: Bool = false, valueAsNumber: Bool = false,
                     outerPadding: Int = 0, extraInnerObjects: Int = 0) -> Data {
        // Inner archive, laid out as macOS lays it out.
        var objects: [Any] = ["$null"]
        func add(_ o: Any) -> Int { objects.append(o); return objects.count - 1 }
        let metadataIndex = add("placeholder")      // 1: CalItemMetadata
        let xpropsIndex = add("placeholder")        // 2: NSMutableDictionary
        let arrayClass = add(["$classname": "NSMutableArray", "$classes": ["NSMutableArray", "NSArray", "NSObject"]])
        let propClass = add(["$classname": "ICSMultiValueProperty", "$classes": ["ICSMultiValueProperty", "ICSProperty", "NSObject"]])
        var stringIndex: [String: Int] = [:]
        var keyRefs: [Any] = []
        var valueRefs: [Any] = []
        for (name, value) in properties {
            keyRefs.append(uid(add(name)))
            var valueList: [Any] = []
            if let value {
                let s: Int
                if valueAsNumber {
                    s = add(42)
                } else if dedupeStrings, let existing = stringIndex[value] {
                    s = existing
                } else {
                    s = add(value)
                    stringIndex[value] = s
                }
                valueList = [uid(danglingValueUID ? 9_999 : s)]
            }
            let values = add(["$class": uid(arrayClass), "NS.objects": valueList] as [String: Any])
            let prop = add(["$class": uid(propClass), "Type": 5007, "Parameters": uid(0), "Value": uid(values)] as [String: Any])
            valueRefs.append(uid(add(["$class": uid(arrayClass), "NS.objects": [uid(prop)]] as [String: Any])))
        }
        // One repeated filler: the binary writer stores it once, so only the table grows.
        for _ in 0..<extraInnerObjects { _ = add("f") }
        let dictClass = add(["$classname": "NSMutableDictionary", "$classes": ["NSMutableDictionary", "NSDictionary", "NSObject"]])
        let metaClass = add(["$classname": "CalItemMetadata", "$classes": ["CalItemMetadata", "NSObject"]])
        objects[metadataIndex] = ["$class": uid(metaClass), "CalXProps": uid(xpropsIndex)] as [String: Any]
        objects[xpropsIndex] = ["$class": uid(dictClass), "NS.keys": keyRefs, "NS.objects": valueRefs] as [String: Any]
        let inner = innerOverride ?? archive(objects)

        // Outer archive: { iCalExtraProperties: NSMutableData(inner) }.
        var outer: [Any] = ["$null"]
        let outerDictClass = 5
        outer.append(["$class": uid(outerDictClass), "NS.keys": [uid(2)], "NS.objects": [uid(3)]] as [String: Any])
        outer.append("iCalExtraProperties")
        if innerAsRawData {
            outer.append(inner)
        } else {
            outer.append(["$class": uid(4), "NS.data": inner] as [String: Any])
        }
        outer.append(["$classname": "NSMutableData", "$classes": ["NSMutableData", "NSData", "NSObject"]])
        outer.append(["$classname": "NSMutableDictionary", "$classes": ["NSMutableDictionary", "NSDictionary", "NSObject"]])
        if outerPadding > 0 { outer.append(Data(count: outerPadding)) }
        return archive(outer)
    }
}
